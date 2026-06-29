# Background Probes & Hot Spares for WireGuard Failover

## Problem Statement

The current failback probe mechanism causes a ~15-second traffic disruption every time it checks whether the primary connection has recovered. It works by live-swapping the active tunnel to the primary config, waiting for a WireGuard handshake, and reverting if the handshake doesn't complete. During those 15 seconds, if the primary is still dead, the user has no working VPN.

Additionally, forward failover (primary→fallback) takes ~40 seconds to detect (30s traffic timeout + 10s poll interval) and then requires a live config swap that triggers a new handshake — adding another second or two before traffic flows on the new connection.

## Goals

1. **Non-disruptive failback probing**: Test primary recovery without interrupting the active fallback connection.
2. **Hot spare mode**: Keep the next failover connection pre-established so failover is near-instantaneous.
3. **Zero-handshake promotion**: When promoting a hot spare, reuse its existing WireGuard session — no re-handshake, no RTT delay.

## Key Insight: Background WireGuard Devices with Swappable Tun

The Go bridge already runs two concurrent `device.Device` instances for Tunnel-in-Tunnel (TiT). The critical realization is that a WireGuard device doesn't need a real utun to be useful — it just needs:

- **`conn.Bind` (network I/O)**: `conn.NewStdNetBind()` for real UDP sockets — this is what performs the handshake and communicates with the remote peer.
- **`tun.Device` (tunnel I/O)**: For a probe/spare, we don't need to route actual user traffic. A **null tun device** that discards writes and never produces reads is sufficient.

A background WireGuard device with real UDP sockets and a null tun will:
1. Send a handshake initiation to the remote peer
2. Complete the Noise IK handshake (proving the endpoint is reachable and has valid keys)
3. Maintain the session via keepalive packets (if configured)
4. Report `last_handshake_time` via UAPI — provable health signal

When it's time to promote the probe to become the active tunnel, we **swap the null tun for the real utun fd** inside the running device. The wireguard-go goroutines keep running with their existing Noise session — no re-handshake needed.

This is strictly less resource-intensive than TiT (which runs two full devices processing real traffic), and the pattern is already proven in-process.

## Architecture

### Go-Side Components

#### Swappable Tun Device

The probe's tun is wrapped in a `swappableTunDevice` — an indirection layer that allows atomic replacement of the inner `tun.Device`. The wireguard-go goroutines (`RoutineReadFromTUN`, `RoutineTUNEventReader`) call through the wrapper and never know the inner changed.

```go
type swappableTunDevice struct {
    inner  atomic.Value // stores tun.Device — lock-free reads on hot path
    events chan tun.Event
    closed chan struct{}
}
```

**Read path (hot path)**: `atomic.Value.Load()` — a single atomic memory read with zero synchronization overhead. This is critical because after promotion, every packet flows through this wrapper.

**Swap (one-time)**: `atomic.Value.Swap()` atomically replaces the inner. The old null tun is closed, which unblocks the read goroutine. The `Read()` method detects the inner changed and retries with the new (real) tun device.

```
Probe phase:     swappableTunDevice → nullTunDevice (blocks reads, discards writes)
After promotion: swappableTunDevice → real utun (full packet processing)
                 ↑ wireguard-go goroutines never restarted, Noise session preserved
```

#### Null Tun Device

A minimal `tun.Device` implementation used as the initial inner device for probes:

```go
type nullTunDevice struct {
    closed chan struct{}
    mtu    int
}

func (t *nullTunDevice) Read(data []byte, offset int) (int, error) {
    <-t.closed          // Block until closed — no packets to deliver
    return 0, os.ErrClosed
}

func (t *nullTunDevice) Write(data []byte, offset int) (int, error) {
    return len(data) - offset, nil  // Discard decrypted packets
}
```

#### Probe Handle Management

```go
type probeHandle struct {
    *device.Device
    *device.Logger
    tunDev *swappableTunDevice  // retained for promotion
}

var probeHandles = make(map[int32]probeHandle)
```

Exported functions:

| Function | Purpose |
|----------|---------|
| `wgProbeOn(settings, keepalive_override)` | Create probe: `swappableTunDevice(nullTun)` + real UDP sockets |
| `wgProbeOff(handle)` | Shut down probe device |
| `wgProbeGetConfig(handle)` | Get UAPI config (handshake time, tx/rx stats) |
| `wgProbeSetConfig(handle, settings)` | Update config |
| `wgProbeBumpSockets(handle)` | Rebind sockets after network change |
| `wgProbePromote(handle, tun_fd)` | **Swap null tun → real utun, move to tunnelHandles** |

The `keepalive_override` parameter is important: probes always send keepalives (25s default) regardless of the user's tunnel config, so the remote peer maintains the session. The override is injected via `injectKeepalive()` at the Go layer so it doesn't affect the user's saved config.

`wgProbePromote` is the key innovation: it creates a real `tun.Device` from the fd, calls `swappableTunDevice.swap()` to atomically replace the null inner, then moves the device from `probeHandles` to `tunnelHandles`. The existing Noise session, peer state, and keepalive timers continue uninterrupted.

### Swift-Side Integration

#### WireGuardAdapter

Probe handles are tracked separately from the main tunnel handle:

```swift
private var probeHandles: [Int32: Bool] = [:]
```

Methods on `WireGuardAdapter` (also exposed via `FailoverAdapterProtocol`):

```swift
func startProbe(tunnelConfiguration:completionHandler:)       // → probe handle
func stopProbe(handle:)
func getProbeRuntimeConfiguration(handle:completionHandler:)  // → UAPI config string
func bumpProbeSockets(handle:)
func promoteProbe(probeHandle:tunnelConfiguration:completionHandler:)
```

`promoteProbe()` sets `reasserting = true` for clean `NEVPNStatus` transitions, updates network settings, calls `wgProbePromote`, tears down the old tunnel, and updates adapter state.

Network path changes bump all probe sockets alongside the main tunnel. On iOS offline, all probes are stopped (the health monitor restarts them when needed).

#### ConnectionHealthMonitor

The monitor supports two probe modes, controlled by `FailoverSettings`:

**1. Non-Disruptive Failback Probe** (`useBackgroundProbes: true`, default)

```
Old flow (disruptive):
  adapter.update(primary) → wait 15s → check handshake → adapter.update(fallback)
                             ↑ traffic disrupted ↑

New flow (non-disruptive):
  adapter.startProbe(primary) → wait for handshake → check handshake
                                 ↑ no disruption ↑        |
                                                           ↓ (if healthy)
                                                adapter.promoteProbe(primary)
                                                   ↑ session preserved, no re-handshake ↑
```

If the background probe fails to start (e.g., can't bind UDP socket), falls back to the legacy disruptive approach. If promotion fails, falls back to `adapter.update()`.

**2. Hot Spare Mode** (`hotSpare: true`, opt-in)

A continuously running background probe that pre-validates the next failover target:

```
Active tunnel: config[0] (primary)
Hot spare:     config[1] (fallback) — background probe with live WireGuard session

On primary failure detected:
  1. Hot spare has an established Noise session → promote immediately
  2. adapter.promoteProbe(config[1]) → null tun swapped for real utun
  3. Existing session starts routing traffic — zero handshake delay
  4. Start new hot spare for config[2] (the next forward target)
```

The hot spare always pre-warms the **next forward failover target** — the same
config the health monitor would switch to if the active connection went unhealthy,
i.e. `(activeIndex + 1) % configs.count` (wrapping back to the primary at the end of
the chain). For example, on `config[1]` the spare probes `config[2]`. This keeps the
single spare slot dedicated to instant *forward* failover.

Failback to the primary is handled independently by the periodic failback probe
(`probeFailbackBackground`, see above), so the hot spare does not need to double as a
failback monitor.

### Data Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Network Extension Process                         │
│                                                                      │
│  ┌────────────────────────────────────────────────────┐              │
│  │  Active WireGuard Device (tunnelHandles[0])        │              │
│  │  ┌───────────────────┐    ┌──────────────┐         │              │
│  │  │ swappableTunDevice│    │ StdNetBind   │── UDP ── Server A      │
│  │  │  └─ real utun     │    │ (real socks) │         │              │
│  │  └───────────────────┘    └──────────────┘         │              │
│  │  Routes all user traffic                           │              │
│  └────────────────────────────────────────────────────┘              │
│                                                                      │
│  ┌────────────────────────────────────────────────────┐              │
│  │  Hot Spare Probe (probeHandles[0])                 │              │
│  │  ┌───────────────────┐    ┌──────────────┐         │              │
│  │  │ swappableTunDevice│    │ StdNetBind   │── UDP ── Server B      │
│  │  │  └─ nullTunDevice │    │ (real socks) │         │              │
│  │  └───────────────────┘    └──────────────┘         │              │
│  │  Handshake-only — no user traffic                  │              │
│  │  On promote: nullTun swapped for real utun         │              │
│  └────────────────────────────────────────────────────┘              │
│                                                                      │
│  ConnectionHealthMonitor                                             │
│    ├─ Polls active device: tx/rx bytes                               │
│    ├─ On unhealthy: promoteProbe(spare) — zero-handshake failover    │
│    ├─ Failback probe: startProbe(primary), check, promoteProbe       │
│    └─ After any switch: start new hot spare for next target          │
└──────────────────────────────────────────────────────────────────────┘
```

### Promotion Sequence

```
1. Hot spare has been running for minutes/hours with an established Noise session
2. Health monitor detects active tunnel is unhealthy (tx without rx > 30s)
3. tryHotSpareFailover() calls adapter.promoteProbe()
4. Swift: setNetworkSettings() for the new config
5. Swift: wgProbePromote(probeHandle, tunnelFileDescriptor)
6. Go: dup(tunFd) → tun.CreateTUNFromFile → swappableTunDevice.swap(realTun)
   6a. atomic.Value.Swap replaces nullTunDevice with real utun
   6b. nullTunDevice.Close() unblocks RoutineReadFromTUN goroutine
   6c. swappableTunDevice.Read() detects inner changed, retries with real utun
   6d. Noise session continues — next packet is encrypted/decrypted normally
7. Go: move device from probeHandles → tunnelHandles
8. Swift: wgTurnOff(oldHandle) tears down the previous active tunnel
9. Traffic flows on the promoted device with zero handshake delay
```

## Settings

```swift
public struct FailoverSettings: Codable {
    var trafficTimeout: TimeInterval        // default: 30s
    var healthCheckInterval: TimeInterval   // default: 10s
    var failbackProbeInterval: TimeInterval // default: 300s
    var autoFailback: Bool                  // default: true
    var useBackgroundProbes: Bool           // default: true — non-disruptive failback
    var hotSpare: Bool                      // default: false — opt-in hot spare mode
}
```

## Key Files

| File | What it does |
|------|-------------|
| `Sources/WireGuardKitGo/api-apple.go` | `nullTunDevice`, `swappableTunDevice`, probe API, `wgProbePromote` |
| `Sources/WireGuardKitGo/wireguard.h` | C header for probe functions |
| `Sources/WireGuardKit/WireGuardAdapter.swift` | `startProbe`, `stopProbe`, `promoteProbe`, probe socket bumping |
| `Sources/WireGuardKit/ConnectionHealthMonitor.swift` | Background failback probes, hot spare lifecycle, `tryHotSpareFailover` |
| `Sources/WireGuardKit/FailoverSettings.swift` | `useBackgroundProbes`, `hotSpare` settings |

## Considerations

### Performance: swappableTunDevice Overhead

After promotion, every packet through the tunnel passes through `swappableTunDevice.Read()`/`.Write()`. The inner device is loaded via `atomic.Value.Load()`, which compiles to a single atomic memory read — effectively zero overhead. There is no mutex, no lock, no contention.

This wrapper is **only used for failover group tunnels**. Regular single-config tunnels use `wgTurnOn` directly and never go through the wrapper. The `atomic.Value.Swap()` (the only write) happens exactly once per failover — during probe promotion.

### Resource Usage

Each background WireGuard device consumes:
- ~2-3 goroutines (device management, packet processing, keepalive timer)
- One UDP socket (ephemeral port, no conflict with the active tunnel)
- Minimal memory (no tun buffer, no packet queues beyond wireguard-go's internal buffers)
- ~1 keepalive packet per 25 seconds (~64 bytes/pkt = ~150 bytes/min)

This is negligible compared to the active tunnel. TiT already runs two full devices processing real traffic.

### Privacy: Observable Traffic Signature

Probe and hot-spare devices send real WireGuard handshakes and keepalives over
the physical interface, outside the tunnel. An on-path observer therefore sees
the client maintaining contact with **two** VPN servers simultaneously: while
failed over, the failback probe periodically handshakes with the primary; with
hot spare enabled, the spare continuously keepalives the next failover target.
This is a distinctive fingerprint compared to a single WireGuard flow. Users
whose threat model includes traffic-analysis adversaries should disable
`useBackgroundProbes` and `hotSpare` (failback then uses the disruptive
swap-and-check method, which only ever talks to one server at a time).

### Battery Impact

- Keepalive every 25s is one small UDP packet — less than a typical push notification
- No timer wakeups beyond what wireguard-go already manages internally
- The health monitor's 10s poll timer is already the dominant cost

### Port Conflicts

Each WireGuard device binds its own UDP port (wireguard-go picks an ephemeral port by default). Multiple devices can coexist as long as they don't try to bind the same port. Since we don't specify `listen_port` for probes, this is automatic.

### Server-Side Considerations

The remote WireGuard server will see two concurrent sessions from different source ports with different public keys (each failover config has its own keypair). The probe and active tunnel are completely independent peers from the server's perspective.

### Probe Routing vs. the Active Tunnel

A probe's UDP socket is bound to no specific interface (`conn.NewStdNetBind()`), so the kernel's default route applies. When the active tunnel is up with `AllowedIPs = 0.0.0.0/0`, that default route is utun — the probe's keepalive and handshake packets get encapsulated into the active tunnel and sent to *its* server, not directly to the probe's target. This breaks the probe as a reachability test and pollutes the active tunnel's tx/rx counters with probe traffic.

NEPacketTunnelProvider's automatic routing exception only covers the active tunnel's own server endpoint, not sibling failover endpoints. We bypass this manually — see [docs/probe-routing-bypass.md](docs/probe-routing-bypass.md) for the two approaches considered (per-socket `IP_BOUND_IF` vs. per-IP `excludedRoutes`), the chosen approach, and its limitations.

### Interaction with TiT

Probes use real UDP sockets (not PipedBind), same as TiT's OUTER device. The probe is testing reachability to a different server, not routing through the TiT pipe. Probes work identically regardless of whether the active tunnel is regular or TiT.

Probe promotion is currently not supported for TiT tunnels (`promoteProbe` returns `.invalidState`). TiT requires both an INNER and OUTER device, and the probe only establishes the INNER session. Supporting TiT promotion would require running paired probe devices — deferred for now.

### Failure Modes

| Scenario | Behavior |
|----------|----------|
| Probe can't bind UDP socket | Log error, fall back to legacy disruptive probe |
| Probe handshake never completes | Probe reports stale handshake, don't swap |
| Promotion fails (can't dup tun fd) | Fall back to `adapter.update()` (re-handshake) |
| Active tunnel + probe both on same server | Different keys, different sessions — no conflict |
| iOS goes offline | Stop all probes; health monitor restarts on reconnect |
| Network changes | Bump probe sockets (same as active tunnel) |
| Memory pressure | Probes are lightweight, but could add adaptive teardown |

## Resolved Questions

1. **Should hot spare probes use the same private key as the active config, or the target config's key?** Must use the target config's key — the remote peer needs to recognize the public key to accept the handshake. Each failover config already has its own keypair.

2. **Can we reuse the probe's WireGuard session when promoting?** Yes — the `swappableTunDevice` approach preserves the existing Noise session. The wireguard-go goroutines keep running, and the only change is which tun device they read from/write to.

3. **Maximum number of concurrent probes?** One hot spare (the immediate next failover target or the primary for failback). Could expand to N if there's demand for monitoring all configs simultaneously.

4. **Should `persistent_keepalive` be hardcoded in probes?** Yes — probes need keepalives to maintain sessions and detect health, regardless of user config. 25s is the WireGuard recommended value. The override is injected by `injectKeepalive()` at the Go layer so it doesn't affect the user's saved config.

5. **What is the per-packet overhead of `swappableTunDevice`?** Effectively zero. `atomic.Value.Load()` is a single atomic memory read (~1-2ns). There is no mutex, no lock contention. The wrapper is only used for failover group tunnels, not regular tunnels.

## Alternatives Considered

### ICMP/TCP Probe Instead of WireGuard Handshake

Could ping the endpoint or try a TCP connect to check reachability without spinning up a WireGuard device.

**Rejected**: This only proves network reachability, not WireGuard reachability. The server could be up but WireGuard could be misconfigured, keys could be wrong, firewall could block UDP but not ICMP. A real WireGuard handshake is the only reliable signal.

### Transfer Session State Between Devices

After a probe establishes a session, transfer the Noise session keys to the active device to avoid re-handshaking.

**Rejected**: wireguard-go doesn't expose session state transfer. The `swappableTunDevice` approach is simpler — we keep the same device and swap what it reads from/writes to, avoiding the need to transfer state entirely.

### Fork wireguard-go to Add `ReplaceTUN()`

Add a method to `device.Device` that pauses the read goroutines, swaps the tun, and resumes.

**Rejected**: Maintenance burden of carrying a fork. The `swappableTunDevice` wrapper achieves the same result from the outside, without modifying wireguard-go internals. The `atomic.Value` approach has negligible per-packet overhead.

### Mutex-Based Tun Wrapper

Use `sync.Mutex` instead of `atomic.Value` for the swappable tun device.

**Rejected**: Mutex lock/unlock on every Read/Write (~15-25ns per packet) is unnecessary since the inner device is only swapped once during promotion. `atomic.Value.Load()` is a single atomic read with effectively zero overhead.

### Run Probe via TiT OUTER Device

Route the probe's packets through the active tunnel's TiT pipe.

**Rejected**: Unnecessarily complex, and the probe needs independent network access to test a different server's reachability. If the active tunnel is the problem, we can't route the probe through it.

### Use `connect()` on UDP Socket

Create a UDP socket, connect to the endpoint, and check for ICMP unreachable errors.

**Rejected**: UDP connect() on Apple platforms doesn't reliably surface unreachable errors. WireGuard's Noise handshake is a more reliable reachability test.
