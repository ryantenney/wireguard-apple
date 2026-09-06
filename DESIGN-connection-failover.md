# Connection Failover for WireGuard iOS/macOS

## Problem Statement

A user has two home internet connections, each running its own WireGuard server with **different keys** (different private keys, different peer public keys, different endpoints). One connection has poor upload speed and should only be used when the primary is unavailable. Today, switching between tunnels requires manual intervention: deactivate one, activate the other.

## Solution Overview

Failover groups let users define an ordered list of WireGuard tunnel configurations. When activated, the primary tunnel is started. If the primary becomes unreachable, the system automatically hot-swaps to the next configuration in the list — seamlessly, without tearing down the VPN tunnel. When the primary recovers, it can automatically fail back.

The entire failover engine runs inside the Network Extension process, so it works even when the app is killed or suspended.

## Key Discovery: In-Place Configuration Swap

`WireGuardAdapter.update()` can hot-swap the entire tunnel configuration on a running tunnel — including interface private key, all peers (public keys, endpoints, allowed IPs, preshared keys), and network settings. It does this by:

1. Setting `packetTunnelProvider.reasserting = true`
2. Calling `setTunnelNetworkSettings()` with new settings
3. Calling `wgSetConfig()` with new UAPI config (`replace_peers=true`)
4. Setting `packetTunnelProvider.reasserting = false`

From the OS perspective, the VPN stays "connected" — it briefly enters "reasserting" state. No tunnel teardown, no connectivity gap visible to the user.

## Architecture

### Data Flow

```
┌─────────────────────────────────────────────────┐
│                    App Process                    │
│                                                   │
│  TunnelsManager                                   │
│    │                                              │
│    ├─ tunnels: [TunnelContainer]        (regular) │
│    └─ failoverGroupTunnels: [TunnelContainer]     │
│         │                                         │
│         │  Packs all wg-quick configs +           │
│         │  FailoverSettings into                  │
│         │  providerConfiguration dict             │
│         │                                         │
│  UI: TunnelsListTableViewController               │
│    │  FailoverGroupDetailTableViewController      │
│    │  FailoverGroupEditTableViewController        │
│    │                                              │
│    │  Polls failover state via IPC every 2-5s     │
└────┼──────────────────────────────────────────────┘
     │
     │  NETunnelProviderSession.sendProviderMessage()
     ▼
┌─────────────────────────────────────────────────┐
│             Network Extension Process            │
│                                                   │
│  PacketTunnelProvider                             │
│    │                                              │
│    ├─ failoverConfigs: [TunnelConfiguration]      │
│    ├─ activeConfigIndex: Int                      │
│    │                                              │
│    └─ ConnectionHealthMonitor                     │
│         │                                         │
│         ├─ Polls tx_bytes/rx_bytes every 10s      │
│         ├─ Detects unhealthy: tx increasing,      │
│         │  rx flat for trafficTimeout seconds      │
│         ├─ Calls adapter.update() to switch       │
│         └─ Probes primary for failback            │
└───────────────────────────────────────────────────┘
```

### IPC Message Protocol

| Type | Direction | Purpose | Response |
|------|-----------|---------|----------|
| `0` | App → Extension | Get UAPI runtime config | Raw UAPI string (tx/rx bytes, handshake times) |
| `1` | App → Extension | Get failover state + stats | JSON with activeConfig, tx/rx bytes, handshake time, health monitor state |
| `2` | App → Extension | Force failover (debug only) | `{"success": true/false}` |
| `3` | App → Extension | Force failback (debug only) | `{"success": true/false}` |
| `4` | App → Extension | Get tunnel-in-tunnel stats | JSON with inner/outer tx/rx bytes and handshake times |
| `5` | App → Extension | Get connection details | JSON with adapter state, applied network settings, network path, per-peer UAPI stats, health monitor internals, failover/TiT config, session events, host interfaces, routing table, process info |
| `6` | App → Extension | Reload group configuration in place | `{"success": true/false}` |

Message types 2 and 3 are only compiled when `FAILOVER_TESTING` is set.

Message type 6 carries a JSON payload after the type byte: for failover groups the packed wg-quick
configs, names, and base64 `FailoverSettings`; for tunnel-in-tunnel the outer/inner configs and
names. The extension keeps the connection that is currently up (matched by name), hot-swaps it via
`adapter.update` only when its config or the sibling-endpoint set changed, and rebuilds the health
monitor with `initialActiveIndex`. Tunnel-in-tunnel restarts both devices in place. The app sends it
from `applyConfigurationToRunningGroup` after any member or group edit and falls back to restarting
the group if the extension does not confirm. Delegate callbacks from a monitor that has since been
replaced are ignored.

Message type 5 backs the "Connection Details" view (`ConnectionDiagnosticsModel` in the app,
`PacketTunnelProvider.buildDiagnostics` in the extension). It is a superset of types 1 and 4
and is only polled while that view is on screen (every 2 s).

## Approaches Considered and Rejected

### App-Level Tunnel Switching

Deactivate one `NETunnelProviderManager`, activate another.

**Rejected**: 1-5s downtime per switch. App must be running. `NETunnelProviderManager` save/load cycle is slow and unreliable.

### Per-Peer Endpoint Failover (same keys, different IPs)

Add fallback endpoints to each peer. Switch endpoints via `wgSetConfig()`.

**Rejected for this use case**: Only works when the same WireGuard server is reachable at multiple IPs. Doesn't apply when servers have different keys (the entire reason this feature exists).

### DNS-Based Failover

Health-checked DNS where servers share a hostname. When primary goes down, DNS resolves to secondary.

**Rejected**: DNS TTL causes slow failover (minutes). No client-side priority control. Doesn't work when servers have different keys. Requires server-side infrastructure.

### Handshake-Based Health Detection (our initial approach)

The first implementation monitored `last_handshake_time` via UAPI to detect stale connections. If no handshake occurred within `handshakeTimeout` seconds, failover triggered.

**Replaced**: Handshake time is only reliable when `persistent_keepalive` is enabled and the interval is known. Without it, handshakes only occur when there's traffic, making idle tunnels appear unhealthy. It also required the user to carefully coordinate `persistent_keepalive` and `handshakeTimeout` values. The traffic-based approach (see below) is more robust because it only flags a connection as unhealthy when there's actual evidence of a problem: data is being sent but nothing is coming back.

## How It Actually Works

### Health Detection: Traffic-Based

The `ConnectionHealthMonitor` polls the WireGuard backend every `healthCheckInterval` seconds (default 10s) via `adapter.getRuntimeConfiguration()`, parsing `tx_bytes` and `rx_bytes` from the UAPI output.

**Detection logic** (in `evaluateHealth()`):
- If `rxDelta > 0`: healthy. Traffic is flowing both ways.
- If `txDelta == 0`: idle. No outgoing traffic means the tunnel is just quiet, not broken.
- If `txDelta > 0` and `rxDelta == 0`: potential problem. The device is sending data but receiving nothing. Start a timer.
- If this state persists for `trafficTimeout` seconds (default 30s): **unhealthy**. Trigger failover.

This approach correctly handles:
- Idle tunnels (no false positives)
- Brief network glitches (30s grace period)
- Active connections that go dead (detected within ~40s)

Two gates run before the timer is even consulted:
- **Path state.** The adapter forwards every `NWPathMonitor` update as `networkPathDidChange(isSatisfied:)`. While the path is unsatisfied nothing is evaluated (on iOS the backend is paused anyway; on macOS this is what stops a dead Wi-Fi from counting as a dead server). For `pathChangeGrace` seconds (default 15) after any path change, tx-without-rx is ignored so roaming blips do not accumulate.

### Confirmation: Link Outage or Server Outage?

Tx-without-rx says the active server is unreachable *from here*; it cannot say whether the server died or the uplink did. On a flaky link (Starlink) the latter is common, and switching servers during it only adds a handshake to the recovery. With `confirmBeforeFailover` (default on) the monitor asks the next configuration's server to vouch for the link before switching:

1. If a hot spare is running for the next config, its last handshake is the witness: fresher than 150 s (keepalives re-handshake every ~2 min while the server answers) confirms a server-side outage.
2. Otherwise a temporary confirmation probe is started for the next config (same machinery as a hot spare, null tun, real sockets). A handshake within `confirmationTimeout` (default 15 s) confirms it.
3. Confirmed → fail over now. A confirmation probe is promoted with `promoteProbe`, so the new connection keeps the session it just established; a hot spare is promoted as before.
4. Not confirmed → **held**. Logged once and recorded as a `.suppressed` session event. The probe stays up and the check repeats every tick, so the switch happens the moment any server becomes reachable while the active one still is not. If traffic resumes on its own the incident is cleared and counted as a false alarm. After `linkDownHoldTime` (default 300 s, 0 = never) the monitor switches anyway with a plain config swap (the spare has no session worth promoting), in case only the current server is blocked on this network; a hold that ends this way is not counted as a false alarm.

While `NWPath` is unsatisfied every probe handle is forgotten (the adapter tears probes down offline on iOS) and the hot spare is restarted once the path is back, so a dead handle is never read as "never handshaked". A health tick that lands while a swap or promotion is still in flight (`isSwitching`) waits instead of starting a second one.
5. If the probe cannot even start, the monitor switches without confirmation rather than sit still.

Confirmation only costs anything during an outage; a running hot spare makes it free.

### Adaptive Sensitivity

With `adaptiveSensitivity` (default on) the effective traffic timeout is `trafficTimeout × min(1.5ⁿ, 4)` where `n` counts recent false alarms: held outages that recovered on their own, and failbacks that landed within two hold times of the failover that preceded them. One false alarm is forgiven per quiet half hour. Connection Details shows the effective value and the count.

### Anti-Flap Protection

| Guard | Value | Purpose |
|-------|-------|---------|
| `minimumHoldTime` | 60s | Won't switch configs more than once per minute |
| `maxCyclesBeforeCooldown` | 3 | After cycling through all configs 3 times... |
| `cooldownDuration` | 300s | ...enter a 5-minute cooldown before trying again |

### Failback Probing

When on a fallback config with `autoFailback` enabled, the monitor probes the primary every `failbackProbeInterval` seconds (default 300s). With `useBackgroundProbes` (default) this is a background WireGuard device that handshakes without touching traffic and is promoted in place on success (see `DESIGN-background-probes-and-hot-spares.md`). The legacy path:

1. Switch to primary config via `adapter.update()`
2. Wait up to 15 seconds for a handshake
3. Check `last_handshake_time` — if recent enough, stay on primary
4. Otherwise, revert to the fallback config

The legacy probe causes a brief (~15s) traffic disruption.

Network path changes (detected via `NWPathMonitor`) trigger an immediate probe when on a fallback, since a network change often means the primary may have recovered.

### Config Switching

`switchToConfig(at:)` calls `adapter.update(tunnelConfiguration:)` which:
1. Resolves DNS for the new endpoint
2. Sets new tunnel network settings (addresses, DNS, routes)
3. Pushes new UAPI config to wireguard-go (new private key, new peers)
4. The OS VPN stays "connected" throughout — just briefly enters "reasserting"

If the switch fails (e.g., DNS resolution failure), it automatically tries the next config in the list.

## Data Model

### Failover Groups as NETunnelProviderManagers

A failover group is **not** a separate data type stored in JSON. It's a `NETunnelProviderManager` — the same system type used for regular tunnels — with special data packed into its `providerConfiguration` dictionary:

```
providerConfiguration = [
    "FailoverGroupId":     UUID string (identifies this as a failover group)
    "FailoverConfigRefs":  [Data] (keychain persistent refs, one wg-quick config per member)
    "FailoverConfigNames": [String] (display names, parallel to refs)
    "FailoverSettings":    Data (JSON-encoded FailoverSettings)
    "UID":                 uid_t (macOS only)
]
```

Member configs (which contain private keys) are **never stored in
`providerConfiguration` itself** — that dictionary is persisted in the system
NE preferences, not the keychain. Each member's wg-quick config is a separate
keychain item owned by the group; the dictionary holds only persistent
references. The extension resolves them with `Keychain.openReference` at
startup. (Versions prior to the keychain migration stored plaintext configs
under a legacy `FailoverConfigs` key; `TunnelsManager.create()` migrates those
into the keychain on launch, and the extension retains a read-only fallback so
on-demand activation keeps working until the app has run once post-upgrade.)
The group's keychain items are created/superseded transactionally around
`saveToPreferences` and deleted when the group is removed.

The `passwordReference` is borrowed from the primary tunnel's Keychain entry (the wg-quick config for the primary is already stored there by the regular tunnel).

This approach means:
- Failover groups appear in the system VPN preferences alongside regular tunnels
- The `NETunnelProviderManager` lifecycle (save/load/activate/deactivate) works identically
- On-demand activation rules work natively — the group tunnel is a first-class VPN configuration
- The existing single-active-tunnel constraint is enforced by the OS automatically

### FailoverSettings

```swift
struct FailoverSettings: Codable, Equatable {
    var trafficTimeout: TimeInterval = 30       // Seconds of tx-without-rx before failover
    var healthCheckInterval: TimeInterval = 10  // How often to poll wireguard-go
    var failbackProbeInterval: TimeInterval = 300  // How often to probe primary when on fallback
    var autoFailback: Bool = true               // Attempt to return to primary
    var useBackgroundProbes: Bool = true        // Non-disruptive failback probes
    var hotSpare: Bool = false                  // Keep the next config pre-handshaked
    var persistentKeepaliveOverride: UInt16?    // Force keepalive on every peer
    var confirmBeforeFailover: Bool = true      // Require the next server to handshake first
    var confirmationTimeout: TimeInterval = 15  // How long a confirmation probe may take
    var linkDownHoldTime: TimeInterval = 300    // Max hold while no server answers (0 = forever)
    var adaptiveSensitivity: Bool = true        // Scale trafficTimeout after false alarms
    var pathChangeGrace: TimeInterval = 15      // Ignore tx-without-rx after a path change
}
```

Every field decodes with its default when absent, so older stored settings and `.failovergroup.conf` files keep working; the file format gained matching `ConfirmBeforeFailover`, `ConfirmationTimeout`, `LinkDownHoldTime`, `AdaptiveSensitivity`, and `PathChangeGrace` keys.

Originally this had a `handshakeTimeout` field; this was migrated to `trafficTimeout` when we switched from handshake-based to traffic-based detection. The decoder handles the legacy key transparently.

### FailoverGroup (Persistence Layer)

`FailoverGroupManager` persists group metadata (name, tunnel names, settings, on-demand config) as JSON in `failover-groups.json` in the app group container. This is used by the app UI for editing and is **separate** from the `providerConfiguration` data passed to the extension. When a group is saved, both are updated.

### TunnelsManager Integration

`TunnelsManager` maintains two separate arrays:
- `tunnels: [TunnelContainer]` — regular tunnels
- `failoverGroupTunnels: [TunnelContainer]` — failover groups

Both are derived from the same `NETunnelProviderManager.loadAllFromPreferences()` call, split by whether `FailoverGroupId` exists in the provider config.

Key integration points:
- **Name uniqueness** is enforced across both arrays
- **Active tunnel tracking** (`tunnelInOperation()`, `waitingTunnel()`) searches both
- **Tunnel modification** triggers `refreshFailoverGroupsContaining()` — if a tunnel referenced by a group is modified or renamed, the group's provider config is rebuilt with current data and, when the group is running, pushed into the extension with IPC type 6 (restart fallback)
- **Keychain ownership** — a group's `passwordReference` points at its own copy of the primary config, created at add/modify/refresh time. Groups created by older builds borrowed the primary's reference; `TunnelsManager.create` migrates them (and repairs dangling references) at launch. Orphan cleanup never removes a tunnel that a group still references
- **List reconcile** (`reload()`) matches tunnels by name and adopts changed managers in place, so a transient keychain read failure cannot drop a member row; removals are logged

## iOS UI

### Tunnel List

The tunnel list (`TunnelsListTableViewController`) has two sections:

1. **Failover Groups** — uses `FailoverGroupCell` with:
   - Group name
   - Tunnel names joined with " → " (e.g., "HomeOne → HomeTwo")
   - "Active: HomeOne" label (green, shown when tunnel is active)
   - "On-Demand" indicator when enabled
   - Activation toggle switch
   - Section header only shown when groups exist

2. **Tunnels** — existing `TunnelListCell`, unchanged

The "+" button menu now includes "Create Failover Group" alongside the existing import options.

Tapping a failover group row navigates to `FailoverGroupDetailTableViewController`.

### Failover Group Editor

`FailoverGroupEditTableViewController` provides:

- **Name**: editable text field
- **Connections**: ordered list with drag-to-reorder. First is labeled "Primary", rest "Fallback #N". Swipe-to-delete removes a tunnel from the group.
- **Add Tunnel**: presents a picker filtered to exclude already-selected tunnels
- **Failover Settings**: traffic timeout, health check interval, failback probe interval (numeric pickers), auto failback (toggle)
- **On-Demand**: WiFi/cellular toggles and SSID filtering (reuses existing `ActivateOnDemandViewModel`)
- **Delete**: destructive button with confirmation (only shown when editing existing group)

Validates: name not empty, at least 2 tunnels. Shows alert on validation failure.

### Failover Group Detail

`FailoverGroupDetailTableViewController` shows:

- **Status**: activation toggle (same pattern as regular tunnel detail)
- **Connections**: tunnel list with role labels and "(Active)" marker for the currently active config
- **Active Connection** (only when active, fields collapse when no data):
  - Data Received / Data Sent (hidden when 0)
  - Last Handshake (hidden until first handshake)
  - Failover Count (hidden when 0)
  - Last Failover (hidden when no switch has occurred)
  - Health Status (hidden when healthy — only shown as "Unhealthy (tx without rx for Xs)")
  - Failback Probe (hidden unless currently probing)
- **Failover Settings**: read-only display
- **On-Demand**: read-only display
- **Debug** (only with `FAILOVER_TESTING` flag): Force Failover / Force Failback buttons
- **Delete**: with confirmation alert

The detail view polls the extension every 2 seconds for live stats.

## What Didn't Work

### Handshake-Based Health Detection

Our first implementation used `last_handshake_time` from the UAPI config. If the handshake was older than `handshakeTimeout` (default 180s), the connection was considered dead.

**Problems**:
- Required `persistent_keepalive` to be enabled and set to a known value on all tunnels
- Users had to coordinate `handshakeTimeout > 2 * persistentKeepAlive` or risk false positives
- Idle tunnels with no `persistent_keepalive` would show stale handshakes even when the connection was fine
- The timeout was confusingly coupled to the keepalive interval

We replaced this with traffic-based detection (`tx_bytes` / `rx_bytes` delta monitoring), which doesn't care about keepalive settings and only triggers when there's actual evidence of a broken connection.

### Failover Groups as Separate JSON-Only Storage

Early design considered storing failover groups purely in a JSON file, with the app dynamically loading configs and managing activation at the app layer.

**Problems**:
- The app is frequently killed/suspended on iOS — no reliable place for failover logic
- Would have required the app to be running to trigger failover
- On-demand activation wouldn't work — the OS needs a `NETunnelProviderManager` to auto-activate

Giving each failover group its own `NETunnelProviderManager` solved all of these: the extension process is always alive, on-demand works natively, and the group is a first-class VPN configuration.

### Race Condition on iOS Tunnel Addition

On iOS, adding a new `NETunnelProviderManager` can cause the system to deactivate the currently active tunnel. This affected failover group creation — creating the group's tunnel provider would kill whatever tunnel was running.

**Fix**: After `saveToPreferences()` completes, check if a previously active tunnel was deactivated and immediately re-activate it. This is the `reactivateTunnelIfNeeded` pattern in `TunnelsManager+Failover.swift`.

### Drag-to-Reorder Duplication Bug

The initial `FailoverGroupEditTableViewController` drag-to-reorder implementation had a bug where moving a row would duplicate it in the `selectedTunnelNames` array. The `tableView(_:moveRowAt:to:)` was inserting before removing, causing index shifts.

**Fix**: Remove from old index first, then insert at new index.

## Files

### New Files

| File | Purpose |
|------|---------|
| `Sources/WireGuardKit/ConnectionHealthMonitor.swift` | Failover engine: traffic monitoring, config switching, failback probing, anti-flap |
| `Sources/WireGuardKit/FailoverSettings.swift` | Settings model (Codable) |
| `Sources/WireGuardApp/Tunnel/FailoverGroup.swift` | Data model, persistence (`FailoverGroupManager`), on-demand activation |
| `Sources/WireGuardApp/Tunnel/TunnelsManager+Failover.swift` | App-level CRUD, IPC, config sync, debug commands |
| `Sources/WireGuardApp/UI/iOS/View/FailoverGroupCell.swift` | List cell with status, active config, on-demand indicator |
| `Sources/WireGuardApp/UI/iOS/ViewController/FailoverGroupEditTableViewController.swift` | Create/edit UI with drag-to-reorder, tunnel picker, settings |
| `Sources/WireGuardApp/UI/iOS/ViewController/FailoverGroupDetailTableViewController.swift` | Read-only detail with live runtime stats |

### Modified Files

| File | Changes |
|------|---------|
| `Sources/WireGuardNetworkExtension/PacketTunnelProvider.swift` | Load failover configs, start health monitor, IPC message types 1-3 |
| `Sources/WireGuardApp/Tunnel/TunnelsManager.swift` | Dual arrays (tunnels + failoverGroupTunnels), failover group delegate, cross-array name uniqueness, config reconciliation |
| `Sources/WireGuardApp/UI/iOS/ViewController/TunnelsListTableViewController.swift` | Two-section table, failover group cells, state polling, navigation to detail/edit |
| `Sources/WireGuardApp/UI/ActivateOnDemandViewModel.swift` | `toOnDemandActivation()` conversion for failover groups |
| `Sources/WireGuardKit/WireGuardAdapter.swift` | `healthMonitor` property |
| `fastlane/Fastfile` | `device_failover` lane with `FAILOVER_TESTING` flag |
| `.swiftlint.yml` | Exclude `build/` directory |

## Testing

### Debug Controls

All gated behind `#if FAILOVER_TESTING` (zero code in release builds):

- **Force Failover** button in detail view — sends IPC message type 2, triggers immediate switch to next config
- **Force Failback** button — sends IPC message type 3, triggers immediate switch to primary
- **Fastlane lane**: `fastlane ios device_failover` builds and installs with the flag enabled

To enable manually, add `FAILOVER_TESTING` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in Xcode build settings.

### Manual Testing on Device

1. Create two WireGuard tunnels with different servers/keys
2. Create a failover group containing both
3. Activate the group
4. Observe the detail screen showing live stats
5. Block traffic to the primary server (e.g., firewall rule, unplug)
6. Within ~40s (30s timeout + 10s check interval), failover triggers
7. Observe the active config change in the UI
8. Restore primary connectivity
9. Within 5 minutes (failback probe interval), failback triggers

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| All configs unhealthy | Cycles through all, anti-flap kicks in after 3 consecutive switches, 5-minute cooldown |
| Rapid cycling | 60-second minimum hold time prevents ping-ponging |
| Network goes offline entirely | `NWPathMonitor` triggers `temporaryShutdown` on iOS; on both platforms the monitor is told the path is unsatisfied and stops counting tx-without-rx until it recovers, then waits out `pathChangeGrace`. |
| Uplink drops but Wi-Fi to the router stays up (Starlink) | Path stays satisfied, tx-without-rx accrues. Confirmation finds no server reachable, holds, records a `.suppressed` event, raises the effective timeout. Failover only happens if a server answers while the active one still does not, or after `linkDownHoldTime`. |
| App killed while on fallback | Extension keeps running. App queries state via IPC when reopened. |
| User activates different tunnel | Failover group implicitly deactivates (OS single-tunnel constraint). |
| Failback probe disrupts traffic | ~15s probe window. Reverts immediately if primary still dead. |
| Referenced tunnel deleted | Group becomes invalid. `cleanupGroups()` removes stale references. |
| Referenced tunnel modified | `refreshFailoverGroupsContaining()` rebuilds the group's provider config and hot-reloads a running group (IPC type 6); the active connection is only re-applied if its own config changed. |
| DNS resolution fails during switch | `adapter.update()` fails. Monitor skips to next config in list. |

## Not Yet Implemented

- **macOS UI**: The health monitor and extension logic work on macOS, but no macOS-specific UI has been built yet (no sidebar integration, no status bar changes).
- **Battery impact measurement**: The health monitor is lightweight (one UAPI query every 10s), but no formal power profiling has been done.
- **Automated tests**: No test suite. The `MockTunnels` simulator infrastructure doesn't run the network extension, so the failover engine can't be tested there. Real-device testing with the `FAILOVER_TESTING` debug controls is the current approach.
- **End-to-end confirmation pings**: confirmation is handshake-based. A stronger witness would inject ICMP echo requests into the confirmation probe's tun and require replies, proving the far side forwards traffic; that needs an injectable probe tun in Go and a `wgProbePing` bridge call.

## Related Documents

- [DESIGN-background-probes-and-hot-spares.md](DESIGN-background-probes-and-hot-spares.md) — non-disruptive failback probes and the hot spare promotion mechanism.
- [docs/probe-routing-bypass.md](docs/probe-routing-bypass.md) — why probe traffic must bypass the active tunnel and how we achieve that.
- [DESIGN-excluded-routes.md](DESIGN-excluded-routes.md) — user-facing excluded IPs and local-network bypass, built on the same `excludedRoutes` mechanism.
