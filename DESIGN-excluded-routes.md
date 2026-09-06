# Excluded Routes: Bypassing the Tunnel for Chosen Destinations

## Problem Statement

WireGuard's `AllowedIPs` only expresses what *goes into* the tunnel. With `0.0.0.0/0, ::/0` everything does, including the router you are sitting next to and, on Starlink, the dish's management address (192.168.100.1), which is not even on the local subnet. The existing "Exclude private IPs" preset carves every RFC 1918 range out of `AllowedIPs`, which is both too broad (all private space bypasses the VPN, everywhere you go) and static (it cannot follow you from one network to the next).

Wanted:

1. **Explicit exclusions** — a short list of addresses or ranges that always skip the tunnel.
2. **Local network bypass** — "whatever network I am directly attached to right now, and its gateway", recomputed as the device roams.

## How It Works

### Two new interface keys

Both live in the `[Interface]` section of the wg-quick text so they round-trip through export/import, group packing, and the macOS text editor:

```
[Interface]
PrivateKey = …
Address = 10.7.0.2/32
ExcludedIPs = 192.168.100.1/32, 10.99.0.0/16
ExcludeLocalNetwork = true
```

- `ExcludedIPs` is a comma-separated list of addresses or CIDR ranges (multiple lines allowed, like `Address`).
- `ExcludeLocalNetwork` accepts `true/false`, `yes/no`, `on/off`, `1/0`.

`InterfaceConfiguration` carries them as `excludedIPs: [IPAddressRange]` and `excludeLocalNetwork: Bool`. Other WireGuard clients reject unknown keys, so a config exported with these set is WGnext-only; the macOS "unrecognized key" alert lists them as valid.

### System excluded routes, not AllowedIPs surgery

`AllowedIPs` is left untouched. `PacketTunnelSettingsGenerator.excludedRoutes()` folds three sources into `NEIPv4Settings.excludedRoutes` / `NEIPv6Settings.excludedRoutes`:

| Source | Shape | Purpose |
|---|---|---|
| Sibling failover endpoints | host routes | Keep probe traffic off the active utun (see `docs/probe-routing-bypass.md`) |
| `interface.excludedIPs` | as written, normalised to network/prefix | User's explicit exclusions |
| Local-network snapshot | on-link subnets + gateway host routes | `ExcludeLocalNetwork` |

Routes are de-duplicated and the tunnel's own interface addresses are never excluded. Because the exclusions are system routes, packets for those destinations leave through the physical interface without ever reaching wireguard-go; the crypto-key routing table (`allowed_ip=0.0.0.0/0`) is unaffected.

### Resolving the local network

`LocalNetwork.snapshot(preferredInterface:tunnelInterface:gateways:)` (WireGuardKit) builds the bypass set:

1. Pick the physical interface: `NWPath.availableInterfaces.first` when the path monitor has reported one, otherwise the interface of the physical `default` route from the kernel routing table (`wgd_dump_routing_table`, now in `WireGuardKitC`). Our own utun is never chosen.
2. From `getifaddrs`, take that interface's IPv4 subnets narrower than /31 and globally routable IPv6 prefixes, anchored at their network address (192.168.1.37/24 → 192.168.1.0/24). Link-local, loopback, multicast, and point-to-point host addresses contribute nothing, so on cellular the set is usually empty.
3. Add gateways from `NWPath.gateways` and the physical default routes as /32 or /128 host routes when they are not already inside a collected subnet.

The adapter records the snapshot and, on every `NWPathMonitor` update while online, recomputes it; if it changed (Wi-Fi → cellular, a different LAN) it re-applies `setTunnelNetworkSettings` with the new routes around a brief `reasserting`. The iOS offline → online resume path resolves the snapshot before re-applying settings, so it costs one round trip, not two. Probe devices and the tunnel-in-tunnel outer half never apply system settings, so they never touch the snapshot.

### Where it shows up

- iOS tunnel editor: "Bypass Tunnel" section with an Excluded IPs field and an Exclude local network switch. Detail view lists both.
- macOS tunnel editor: the keys are highlighted and validated in the text view; an "Exclude local network" checkbox toggles the line. Detail view lists both.
- Connection Details: "Tunnel Routes" shows every installed exclusion, the configured excluded IPs, and the resolved local-network bypass with the interface it came from.
- Failover groups and tunnel-in-tunnel: nothing extra. Exclusions travel inside each member's wg-quick text, so switching configs regenerates them; for TiT the inner config's settings are the ones applied.

## Caveats

- **Device-wide.** Excluded routes apply to every process, exactly like the failover sibling bypass.
- **iOS honours excluded routes only alongside an included default route.** A split-tunnel `AllowedIPs` that does not cover the excluded destination simply never routed it through the tunnel; the exclusion is then redundant but harmless.
- **Servers that share your LAN's address space.** With `ExcludeLocalNetwork` on a 192.168.1.0/24 network, remote 192.168.1.x hosts behind the VPN become unreachable for the duration. That is the intended trade.
- **The dish is not on the subnet.** Starlink's 192.168.100.1 is reached via a route the router advertises, so it needs an explicit `ExcludedIPs` entry; `ExcludeLocalNetwork` only gets you the router.
- **IPv6 prefixes** are excluded as the on-link /64 (or whatever the interface reports). Unique-local prefixes are treated as routable and excluded too.

## Files

- `Sources/WireGuardKit/InterfaceConfiguration.swift` — model
- `Sources/Shared/Model/TunnelConfiguration+WgQuickConfig.swift` — parse/serialize, `parseBool`
- `Sources/WireGuardKit/PacketTunnelSettingsGenerator.swift` — `excludedRoutes()`, `replacingLocalNetworkRoutes`
- `Sources/WireGuardKit/LocalNetwork.swift` — snapshot resolver
- `Sources/WireGuardKit/WireGuardAdapter.swift` — snapshot tracking, path-change re-apply
- `Sources/WireGuardKitC/NetworkDiagnostics.{c,h}` — routing table dump
- `Sources/WireGuardApp/UI/TunnelViewModel.swift`, iOS/macOS edit and detail controllers, `highlighter.c`
