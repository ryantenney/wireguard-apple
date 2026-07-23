# Warm Spare Cellular Failover

Status: Phases 1–3 of the implementation spec are built (mechanism, detection
& state machine, warming policy, config schema, EIM self-test, server
component, settings/status UI, `FAILOVER_TESTING` debug controls). The
on-device hardening pass (§Remaining Work) is not.

The dominant latency cost when leaving Wi-Fi coverage is not WireGuard session
re-establishment — it's waiting for iOS to bring up a cellular data path and
for the tunnel to notice and rebind. This feature keeps a pre-warmed UDP
socket on the cellular interface while Wi-Fi carries the tunnel, so failover
becomes an atomic path flip inside the running provider: WireGuard sessions
are keyed to the peer public key, not the 5-tuple, and the server re-homes the
peer endpoint from the source address of the first authenticated packet sent
out the cellular socket. Target failover latency is one RTT plus detection
time, with zero `NEVPNStatus` transitions.

## Spec → Implementation Reconciliation

The original spec (warm spare implementation spec, 2026-07) was written
against a generic provider. Decisions made reconciling it with this codebase:

1. **BSD sockets + `IP_BOUND_IF` instead of `NWConnection`.** The spec's
   cellular socket was an `NWConnection` with
   `requiredInterfaceType = .cellular`. Our bind lives in wireguard-go, and
   shuttling every packet across the cgo boundary to a Swift-owned
   `NWConnection` would cost far more than the failover saves. Instead the
   cellular sockets are Go `net.UDPConn`s with `IP_BOUND_IF` /
   `IPV6_BOUND_IF` set — the kernel forces their packets out the cellular
   interface regardless of routing tables. This is exactly "Approach A" from
   [docs/probe-routing-bypass.md](docs/probe-routing-bypass.md), which was
   rejected there only because of sibling-endpoint concerns that don't apply
   here (see #3). The interface index comes from a Swift
   `NWPathMonitor(requiredInterfaceType: .cellular)` and is passed through
   `wgWarmSetCellular`.

2. **`DualPathBind` wraps the stock `StdNetBind` rather than replacing it.**
   The primary socket remains a plain `StdNetBind` following the system
   default path, so `wgBumpSockets` → `device.BindUpdate()` (the existing
   network-change machinery, both platforms) keeps working untouched. The
   cellular sockets deliberately **survive** bind `Close()`/`Open()` cycles —
   a bump must not destroy the warm NAT mapping. Consequence of the wrap: on
   Wi-Fi loss the flip to the warm socket is instantaneous, and the primary
   socket independently rebinds onto cellular via the existing bump; when
   Wi-Fi returns, the primary rebinds onto Wi-Fi and the dwell timer flips
   back. `activePath == cellular` is a transient state around transitions,
   which matches the spec's operating model.

3. **No routing-loop problem, by construction.** The spec worried about
   provider sockets recursing into the utun. The failover-groups work already
   established that only the *active tunnel's own endpoint* gets an automatic
   routing exception — and warm spare probes target exactly that IP (the echo
   responder runs on the WireGuard server host, different port). Default-path
   probe traffic therefore bypasses the utun the same way the tunnel's own
   UDP does, and the cellular sockets bypass routing entirely via
   `IP_BOUND_IF`. This is why `probeAddr` is derived from the tunnel's first
   resolved endpoint rather than being independently configurable.

4. **"Always On" already exists in the on-demand model.** The spec's
   prerequisite (a single `NEOnDemandRuleConnect` for all interface types) is
   the existing `ActivateOnDemandOption.anyInterface(.anySSID)` case — no
   on-demand model changes were needed. `supportsWarmSpare` on
   `ActivateOnDemandOption` encodes the prerequisite for the future UI; the
   provider itself simply engages warm spare whenever it's running with the
   feature enabled.

5. **Coexistence with connection failover, TiT, and probes.** Warm spare
   engages for **single-config tunnels only**. Failover groups already have
   `ConnectionHealthMonitor` driving config switches, hot spares, and probe
   promotion; layering path flips under config swaps is future work (the
   `PathController` thresholds/dwell machinery was written to be reusable for
   it). TiT tunnels are excluded for the same reason. The provider logs and
   ignores warm spare settings on group tunnels.

6. **The state machine lives in Swift, the mechanism in Go.** Policy
   (`PathController`: states, thresholds, dwell, adaptive warming) needs
   `NWPathMonitor`; mechanism (sockets, keepalives, probe I/O, stats, the
   atomic flip) needs to touch the bind. The seam is four Go exports plus a
   JSON stats snapshot, mirroring the existing health-monitor pattern.

7. **The iOS offline teardown is preserved.** When the path is fully
   unsatisfied (airplane mode), the adapter still tears down the backend
   (`temporaryShutdown`) — warm spare state dies with the Go device and is
   rebuilt from cold on resume. Warm spare improves the *Wi-Fi → cellular*
   transition, where the path stays satisfied throughout; it does not try to
   change the nothing-to-something transition.

8. **`wgTurnOff` owns controller cleanup.** The warm tunnel handle lives in
   the same `tunnelHandles` map as regular tunnels, so `wgSetConfig`,
   `wgGetConfig`, `wgBumpSockets`, and `wgTurnOff` all work unchanged;
   `wgTurnOff` additionally stops the warm spare controller. If
   `wgTurnOnWarm` fails for any reason the adapter falls back to plain
   `wgTurnOn` — warm spare misconfiguration degrades to current-release
   behavior instead of failing the tunnel (and warm spare off is byte-for-byte
   the current start path).

## Architecture

```
┌────────────────────────── PacketTunnelProvider ──────────────────────────┐
│                                                                          │
│  wireguard-go device (tunnelHandles[i])                                  │
│        │                                                                 │
│        ▼                                                                 │
│  dualPathBind (conn.Bind)                            [Go, warmspare.go]  │
│    ├── inner: StdNetBind        — system default path (Wi-Fi when up)    │
│    └── cellularSockets          — IP_BOUND_IF(cellular ifindex), v4+v6   │
│              ▲ activePath (atomic int32)                                 │
│              │                                                           │
│  warmSpareController                                 [Go, warmspare.go]  │
│    ├── NAT keepalive loop       — echo to probePort from cell socket     │
│    ├── default-path prober      — echo to probePort, unbound socket      │
│    ├── EIM self-test            — probePort & probePort+1, compare ports │
│    └── stats JSON               — wgWarmGetState                         │
│                                                                          │
│  PathController                            [Swift, PathController.swift] │
│    ├── adapter NWPathMonitor    — hard-loss backstop (forwarded)         │
│    ├── cellular NWPathMonitor   — availability + interface index         │
│    └── state machine            — warm/cool, flip, dwell, thresholds     │
└──────────────────────────────────────────────────────────────────────────┘
                                        │ UDP echo (probePort, probePort+1)
                                        ▼
                          server/echo-responder (same host as WG server)
```

### States (`PathController.State`)

| State | Active socket | Cellular socket | Notes |
|---|---|---|---|
| `wifiActiveCellCold` | primary | closed | warm spare idle (adaptive) |
| `wifiActiveCellWarm` | primary | open, keepalives | ready for fast failover |
| `cellActive` | cellular | (is active) | Wi-Fi lost or breached thresholds |
| `recovering` | cellular | open | Wi-Fi back; dwell before flip-back |

Transition inputs:

- **Hard loss** — the adapter's `NWPathMonitor` reports the default path no
  longer uses Wi-Fi (or unsatisfied while cellular remains): immediate flip.
- **Soft degradation** — default-path probes breach `switchRttMs` /
  `switchLossPct` over the sample window (min 3 samples, median RTT):
  proactive flip while Wi-Fi is nominally still up.
- **Recovery** — default path uses Wi-Fi again: `recovering`, flip back after
  `dwellSeconds` of sustained health (breaching probes restart the dwell).
- **Cellular loss** — airplane mode / SIM out / data off is a normal cold
  state, not an error; if it happens while cellular is active, the controller
  reverts to the primary socket immediately.

### Warming policy

- **Adaptive** (default): cellular stays cold until default-path quality
  trends toward the thresholds (two-thirds of `switchRttMs`, half of
  `switchLossPct`); returns to cold after 120 s of healthy Wi-Fi.
- **Continuous** (`adaptiveWarming: false`): warm whenever cellular exists
  and Wi-Fi carries the tunnel. One 40-byte datagram per
  `warmKeepaliveInterval` (default 25 s — inside the RFC 4787 REQ-5 30 s
  mapping-timeout floor), but each send can wake the cellular radio
  (~seconds of connected-state power plus RRC tail), which is why adaptive
  is the default.

Default-path quality probes are themselves gated (`wgWarmSetPrimaryProbing`,
driven by the path controller): they run only while Wi-Fi is the default
path, since that's the only time they inform a decision — an always-on
tunnel spending the day on cellular sends no probe traffic at all. The
hard-loss `NWPathMonitor` backstop covers path transitions while probes are
off, and stats reset on each gate transition so stale samples can't feed
later decisions.

### Failover procedure

1. `wgWarmSetActivePath(handle, 1)` — atomic flip of the socket `Send()`
   writes to.
2. The Go side immediately calls `SendKeepalivesToPeersWithCurrentKeypair()`,
   pushing an authenticated transport packet out the cellular socket so the
   server re-homes the endpoint with no user traffic in flight.
3. If the session has expired, the keepalive is a no-op and the next outbound
   packet is a handshake initiation over the same warm socket — still one
   RTT, no special handling.

Inbound packets are accepted from **both** sockets at all times (WireGuard
authenticates by session), covering the transition window. Echo replies from
the probe port are filtered out before packets reach the device.

**Premature re-homing guard:** nothing but `Send()` with
`activePath == cellular` ever writes WireGuard traffic to the cellular
sockets; keepalives and probes go exclusively to `probePort`. If a cellular
send fails mid-flip (interface vanished), `Send()` falls back to the primary
socket so traffic still has a way out.

### EIM self-test

The warm-mapping trick assumes endpoint-independent mapping (RFC 4787
REQ-1): the CGNAT mapping kept alive by probe traffic is the same one the
WireGuard port will use. The self-test sends probes from the cellular socket
to `probePort` and `probePort+1` and compares the externally observed source
ports returned in the echoes:

- same port → `eim` — warm spare fully effective;
- different → `edm` — warm spare still helps (radio context and socket are
  warm) but the first exchange after failover may cost extra;
- no replies in 5 s → `unreachable`.

Triggered via IPC (message 6, warms the spare first if needed); verdict lands
in the status snapshot (message 5).

## Wire protocol (echo)

See [server/echo-responder/README.md](server/echo-responder/README.md) for the
byte layout. Fixed 40-byte requests, ≤32-byte replies (token echo + observed
`ip:port`), so the responder cannot amplify; per-source token-bucket rate
limiting on the server. Client implementation: `warmspare.go`; keep in sync.

## Configuration

`WarmSpareSettings` (WireGuardKit, `Codable`), stored per-tunnel as JSON in
`providerConfiguration["WarmSpareSettings"]` (preserved across tunnel edits
by `NETunnelProviderProtocol+Extension`), managed via
`TunnelsManager.warmSpareSettings(for:)` / `setWarmSpareSettings(_:for:)`:

```
enabled:               Bool     = false
adaptiveWarming:       Bool     = true     # false = continuous keepalives
warmKeepaliveInterval: Seconds  = 25
probePort:             UInt16   = 51821    # echo responder; ≠ WireGuard port
switchRttMs:           Int      = 300
switchLossPct:         Int      = 20
dwellSeconds:          Seconds  = 10
```

## Key files

| File | What it does |
|---|---|
| `Sources/WireGuardKitGo/warmspare.go` | `dualPathBind`, `cellularSockets`, `warmSpareController`, echo protocol, EIM test |
| `Sources/WireGuardKitGo/api-apple.go` | `wgTurnOnWarm`, `wgWarmSetCellular`, `wgWarmClearCellular`, `wgWarmSetActivePath`, `wgWarmGetState`, `wgWarmStartEimTest` |
| `Sources/WireGuardKit/PathController.swift` | Warming/flip state machine |
| `Sources/WireGuardKit/WarmSpareSettings.swift` | Settings model |
| `Sources/WireGuardKit/WireGuardAdapter.swift` | Warm start path, backend conformance, status/EIM accessors |
| `Sources/WireGuardNetworkExtension/PacketTunnelProvider.swift` | Settings parsing, IPC messages 5/6/7 |
| `Sources/WireGuardApp/Tunnel/TunnelsManager+WarmSpare.swift` | App-side persistence + IPC, `supportsWarmSpare` |
| `Sources/WireGuardApp/UI/iOS/ViewController/WarmSpareViewController.swift` | Settings + live status + NAT test UI (entry: tunnel detail) |
| `server/echo-responder/` | Stateless UDP echo responder (deploy on the WG server host) |

IPC message types (`handleAppMessage`): 0 runtime config, 1 failover state,
2/3 failover debug, 4 TiT stats, **5 warm spare status, 6 run EIM test,
7 debug force path (FAILOVER_TESTING; byte 1: 0=primary, 1=cellular,
2=auto)**.

## Known landmines (tracked from the spec)

- **`includeAllNetworks`** — history of breaking provider-originated cellular
  sockets while Wi-Fi is up. This app doesn't set it; if that ever changes,
  the combination needs an explicit test-matrix entry before shipping both.
- **Battery accounting** — provider-originated cellular traffic is billed to
  the app. Adaptive warming is the default for a reason; settings copy should
  say so.
- **Timers live in the extension** — keepalive/probe timers are all in the
  Go controller or the extension-side `PathController`. Keep it that way; no
  app-side timers.
- **`NWPathMonitor` semantics inside the NE process** — the default-path
  monitor's `usesInterfaceType(.wifi)` behavior with an active utun should be
  verified on-device (it's only the backstop; quality probes flip first, and
  the cellular-specific monitor is authoritative for availability). Test
  matrix item for Phase 4.

## Remaining work

- **Phase 4 hardening**: walk-out-the-door and attenuated-Wi-Fi testing
  against the ≤1 s acceptance criterion; Instruments energy comparison of
  cold / adaptive / continuous; flap soak test; known-EDM NAT rig (nftables
  SNAT with port randomization) for the EIM verdict.
- **Future**: reuse `PathController` thresholds for failover groups;
  cellular→cellular (dual SIM) is blocked on iOS API surface, as in the spec.
