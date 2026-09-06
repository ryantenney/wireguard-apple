# Hot Spare Probe Routing Bypass

## Problem

A failover hot spare runs a second `device.Device` inside the network extension, alongside the active tunnel ([DESIGN-background-probes-and-hot-spares.md](../DESIGN-background-probes-and-hot-spares.md)). Each tunnel in a failover group typically points at a different server, so the probe's UDP socket talks to a different endpoint than the active tunnel does.

`NEPacketTunnelProvider` installs a single automatic routing exception — for the **active** tunnel's configured `serverAddress` — so the active tunnel's UDP socket can talk to its server without recursing back through utun. That exception does **not** extend to any other endpoint.

As a result, the hot spare probe's UDP traffic to a *different* server gets routed by the kernel through the default route — which, when the active tunnel has `AllowedIPs = 0.0.0.0/0`, is the active utun. Concretely:

1. Probe socket sends a packet to Server B.
2. Kernel's default route is utun (active tunnel).
3. Active wireguard reads the packet from utun, encrypts, and sends to Server A.
4. Server A receives it, may or may not forward to Server B depending on its routing.
5. If Server B does respond, the response comes back through Server A → active utun → kernel → probe socket.

This is wrong on two counts:

- **It violates failover semantics.** The probe's purpose is to verify "Server B is reachable from this device's underlying network." Routing the probe through Server A turns it into a tunnel-in-tunnel test instead.
- **It pollutes the active tunnel's tx/rx counters.** The probe's keepalives appear in the active tunnel's `tx_bytes`. If Server A drops the forwarded packets (no IP forwarding, ACL, etc.), the active tunnel sees tx growing without rx, and the health monitor's "tx-without-rx for `trafficTimeout`s" check trips a false-positive failover.

## Symptoms

When this is happening, the user observes:

- The hot spare cell shows "Connecting" / "Waiting for handshake" indefinitely. The probe's UAPI dump shows `tx_bytes=0` (Server A drops the packet) or non-zero `tx_bytes` with `rx_bytes=0` (Server A forwards but Server B's reply doesn't make it back).
- The primary tunnel briefly shows "Unhealthy" during quiet stretches. Probe keepalives generate periodic active-tunnel tx; if no other traffic flows for `trafficTimeout` seconds, the active tunnel looks one-sided.

The keepalive injection bug (probe was sending nothing because `injectKeepalive` saw the existing `=0` line and refused to override) masked symptom #2 entirely until that was fixed in commit `c261cf1`.

## Approaches

Two ways to make probe traffic bypass the active tunnel.

### A. `IP_BOUND_IF` on the probe socket

Bind the probe's UDP socket to a specific physical interface (`en0`, `pdp_ip0`, etc.) using the macOS/iOS `IP_BOUND_IF` (and `IPV6_BOUND_IF`) socket options. The kernel then forces packets out that interface regardless of routing tables.

**Sketch:**

- Swift: at probe-start, query `NWPathMonitor`'s default path for the current physical interface name, convert to an interface index via `if_nametoindex(3)`, pass through `wgProbeOn`.
- Go: write a custom `conn.Bind` that wraps `StdNetBind` and applies `IP_BOUND_IF` to its `*net.UDPConn` sockets after creation. wireguard-go's `conn.Bind` interface is small (`Open` / `Close` / `Send` / `SetMark` / `ParseEndpoint`), so a from-scratch implementation is feasible.
- Path changes: `NWPathMonitor` already feeds `WireGuardAdapter`. On underlying-interface change, call into the bind to reapply `IP_BOUND_IF` to the existing sockets via `SyscallConn().Control(...)` — same socket, same source port, same Noise session, just talking out a different door.
- Constants: `IP_BOUND_IF = 0x19`, `IPV6_BOUND_IF = 0x7d` (already in `golang.org/x/sys/unix` for darwin).

**Trade-offs:** surgical (only the probe socket bypasses) and the right architectural answer; no leakage of unrelated traffic. Costs a non-trivial Go bridge change, custom platform-specific socket code, and rebinding logic that has to handle path flap / interface disappearance gracefully.

### B. Per-IP exclusion via `NEPacketTunnelNetworkSettings.excludedRoutes` (chosen)

When constructing the network settings for an active failover-group tunnel, gather the resolved endpoint IPs of every *other* configuration in the group and add them to `NEIPv4Settings.excludedRoutes` / `NEIPv6Settings.excludedRoutes`. The kernel routes packets to those IPs out the underlying physical interface, exactly as it already does for the active tunnel's own server.

**Sketch:**

- `PacketTunnelSettingsGenerator` (or a sibling helper) accepts an optional list of "extra excluded routes."
- `PacketTunnelProvider` (failover startup path) resolves each non-active failover config's endpoint via the existing DNS resolution path, collects IPs, and passes them down.
- On config switch (`switchToConfig`, `promoteProbe`, `didFailbackToConfigAt`), regenerate the excluded-routes list with the *new* "other" endpoints and re-apply network settings via `setTunnelNetworkSettings`. This is already happening on every switch — we just need to fold the sibling-endpoint computation into it.

**Trade-offs:** pure Swift, no Go bridge work, no custom bind, no `IP_BOUND_IF`. Path changes are handled by the kernel automatically — the bypass is per-IP, not per-interface, so a Wi-Fi → cellular handoff just changes which physical interface the kernel picks for the excluded route. No rebinding logic to write.

## Limitations of Approach B

These are inherent to per-IP routing exclusion and worth documenting because they don't apply to Approach A:

1. **Sibling-endpoint traffic from any process bypasses the VPN.** The `excludedRoutes` are device-wide, not per-socket. If anything else on the device — a stray `curl`, a debug probe, a reverse-DNS lookup that hits one of the failover server IPs — sends to a sibling endpoint, that traffic skips the active tunnel. In practice these IPs are operator-controlled and nobody's connecting to them from outside the failover machinery, but it's a real difference from `IP_BOUND_IF`'s strictly per-socket bypass.

2. **DNS staleness.** We have to resolve each sibling endpoint to one or more IPs at network-settings setup time. If a sibling endpoint's hostname resolves to a different IP later (DNS rotation, anycast topology change), the exclusion is wrong: probes for that endpoint will go through the active tunnel again, and we won't know until the next time we re-apply network settings. The active tunnel already re-resolves on path change via `WireGuardAdapter.update()`; we should re-resolve siblings on the same hooks.

3. **Both address families need handling.** Endpoints can be IPv4 or IPv6. Sibling endpoint #1 might be IPv4, #2 might be IPv6, and we need both `NEIPv4Settings.excludedRoutes` and `NEIPv6Settings.excludedRoutes` populated. The existing `PacketTunnelSettingsGenerator` already separates the two; the new code follows the same split.

4. **Endpoints that change after group creation aren't reflected until the active tunnel re-applies settings.** If the user edits a failover config (e.g., changes the endpoint of `Failover #2`) while the group is running on `Failover #1`, the new endpoint isn't excluded until the active tunnel goes through a restart or a `switchToConfig` cycle. `refreshFailoverGroupsContaining()` already rebuilds the provider config when a referenced tunnel is modified; we should pair that with a `setTunnelNetworkSettings` re-apply when the modification touches an endpoint.

5. **Failure to resolve a sibling endpoint is non-fatal but silent.** If DNS for a sibling endpoint fails (the server is down, no hostname caching available), we'll have no exclusion for that sibling. Probes targeting it will revert to the broken behavior described above. Logging should make this visible; the probe's UAPI dump (added in commit `c261cf1`) will still show `tx_bytes=0` if the user notices in the UI.

6. **Doesn't help if the user's network blocks direct access to a sibling.** If the underlying network has firewall rules that block one of the failover servers but allow the other, the probe will fail to handshake from the underlying interface. That's not a bug — it's the failover system correctly reporting "Server B isn't reachable from where you are right now" — but worth being explicit that the probe is no longer a tunnel-encapsulated reachability test.

## Why we picked B over A

For our failover use case:

- The leakage in (1) is theoretical, not observed in practice; the IPs are part of the user's own VPN infrastructure.
- DNS staleness in (2) is bounded by how often the active tunnel re-applies network settings, which is already frequent enough (every config switch, every DNS re-resolve).
- We avoid two pieces of platform-specific code (custom Go bind + Swift interface lookup) and the rebind-on-path-change logic.
- The outcome is the same on the failure mode that motivated this work: probe socket talks directly to its server over the underlying network, primary's tx/rx counters are clean.

If a future use case surfaces where per-socket bypass actually matters — e.g., a feature where the probe target is a third-party endpoint we don't own, and we don't want general device traffic leaking to it — Approach A becomes the better answer. The two aren't mutually exclusive; B can be replaced with A later without changing the user-visible behavior.

## Status

Implemented (commit `d26a7c2`): `PacketTunnelProvider` passes sibling endpoints to the adapter on every start, switch, and promotion, and `PacketTunnelSettingsGenerator` installs them as host `excludedRoutes`. The same `excludedRoutes()` builder now also carries the user's `ExcludedIPs` and the `ExcludeLocalNetwork` bypass (see `DESIGN-excluded-routes.md`), and the Connection Details view lists every installed exclusion under "Tunnel Routes".

## Related

- [DESIGN-connection-failover.md](../DESIGN-connection-failover.md)
- [DESIGN-background-probes-and-hot-spares.md](../DESIGN-background-probes-and-hot-spares.md)