# Captive Portal Handling

## Problem Statement

Captive portal Wi-Fi networks (hotels, airports, coffee shops, in-flight Wi-Fi) intercept all traffic until the user authenticates through a web page. Until then, the network is a UDP blackhole that *looks* healthy to the system: the interface is up, DHCP succeeded, and `NWPath` reports `.satisfied`.

This breaks WireGuard in general, and interacts especially badly with our connection failover feature:

1. **The tunnel silently blackholes.** Because `NWPath` stays `.satisfied` on a captive network, `WireGuardAdapter.didReceivePathUpdate()` never takes the iOS `temporaryShutdown` path. The tunnel starts, claims the default route, and the Noise handshake just fails silently — indistinguishable, from inside the extension, from "server is down."

2. **On-demand creates a chicken-and-egg lockout.** Our on-demand rules are plain `NEOnDemandRuleConnect`. The moment the user joins portal Wi-Fi, the system force-starts the tunnel. The utun then swallows the default route, so the OS's captive-portal detection probes and the sign-in sheet's traffic are blackholed too. The user often cannot reach the portal page to authenticate — the very thing that would unblock the tunnel. If they manually disconnect, on-demand immediately reconnects.

3. **The failover engine misdiagnoses the portal as a server outage.** `ConnectionHealthMonitor.evaluateHealth()` sees tx-without-rx for `trafficTimeout` seconds and starts walking the config list. Every config is equally blackholed, so it cycles through all of them, increments `consecutiveCycles`, and after `maxCyclesBeforeCooldown` cycles enters the 300 s cooldown. Hot spare and background probes fail for the same reason, so `tryHotSpareFailover()` never has a validated spare. Worst case: the user authenticates with the portal while the monitor is sitting in cooldown on a fallback config, and nothing notices for minutes — portal authentication does not generate an `NWPath` change, so `networkPathDidChange()` never fires.

### Failure Timeline (today, failover group on captive Wi-Fi)

```
t=0     Join hotel Wi-Fi. On-demand force-starts tunnel. Handshake blackholed.
t=30s   trafficTimeout hit → switch to config #1. Also blackholed.
t=90s   (minimumHoldTime) → switch to config #2. Also blackholed.
...     cycles through entire list 3 times
t≈5min  Enters 300s cooldown on an arbitrary fallback config.
t=?     User finally authenticates (if the sign-in sheet worked at all).
        No NWPath change → nothing reacts until the next timer fires,
        possibly minutes later, possibly on a non-primary config.
```

## Solution Overview

Layered, in increasing implementation size. Each phase is independently useful.

| Phase | What | Where | Status |
|-------|------|-------|--------|
| 1 | `probeURL` on on-demand Connect rules | `ActivateOnDemandOption.swift` | **Implemented** |
| 2 | Captive-portal detector in the extension | `CaptivePortalDetector.swift` in WireGuardKit | **Implemented** |
| 3 | Captive-aware `ConnectionHealthMonitor` | `ConnectionHealthMonitor.swift` | **Implemented** |
| 4 | Surface state to the user | IPC type 1 + app UI | IPC keys **implemented**; UI planned |
| 5 | Guided sign-in: notification + in-app portal browser | extension notification + app WKWebView sheet | Planned |

## Phase 1: `probeURL` on On-Demand Connect Rules (Implemented)

`NEOnDemandRule.probeURL` is Apple's built-in captive-portal escape hatch: a Connect rule with `probeURL` set only matches if the system can fetch that URL and receive an HTTP 200 **without redirection**. On a captive network the portal intercepts the request (redirect or interception page), the probe fails, the Connect rule does not match, and on-demand holds off — so the system's captive-portal sign-in flow works normally. Once the user authenticates, the interface leaves its captive state, on-demand rules are re-evaluated, the probe passes, and the tunnel comes up.

We set `probeURL` to `http://captive.apple.com/hotspot-detect.html` — the same endpoint Apple's own captive network assistant uses — on **every** `NEOnDemandRuleConnect` we build, for both regular tunnels and failover groups (both funnel through `ActivateOnDemandOption.apply(on:)`).

### Design decisions

- **Rule shapes are unchanged.** We only set an additional property on existing Connect rules. The round-trip parser (`ActivateOnDemandOption.create(from:)`) matches on `action` / `interfaceTypeMatch` / `ssidMatch` and ignores `probeURL`, so reading settings back is unaffected, as is downgrade compatibility.
- **The probe applies to cellular/ethernet Connect rules too**, not just Wi-Fi. Splitting the `.anyInterface(.anySSID)` single `Connect(.any)` rule into a Wi-Fi-with-probe rule plus a cellular-without-probe rule would change rule counts and break the round-trip parser (see Rejected Approaches). Captive interception on cellular is essentially nonexistent, and the probe endpoint is Apple's own high-availability captive-check host — if it is unreachable, the network is effectively broken for most traffic anyway.
- **HTTP, not HTTPS, on purpose.** The probe must be interceptable by the portal to fail; an HTTPS probe would fail with an opaque TLS error rather than a redirect. The fetch is performed by the system's on-demand evaluator, not by our app or extension, so App Transport Security does not apply.
- **Existing installs migrate automatically.** Rules are rebuilt from `ActivateOnDemandOption` every time a tunnel or failover group is saved, so the probe URL is added the next time the user edits (or the app re-applies) on-demand settings.

### Behavior notes

- With SSID-scoped rules (`onlySpecificSSIDs`), a captive network whose SSID matches will fail the probe on the Connect rule and then match the following `Disconnect(wiFi)` rule — the tunnel is kept down during the captive phase. That is the desired outcome (the portal is reachable), and it converges to Connect once the probe passes.
- If no rule matches (e.g. `.wiFiInterfaceOnly` on captive Wi-Fi: Connect fails probe, `Disconnect(cellular)` doesn't match the interface), on-demand simply leaves the VPN state alone — the tunnel stays down until the probe passes.
- `probeURL` is only consulted at rule-evaluation time (network-environment changes). It does not tear down an already-established tunnel that later lands behind a portal (e.g. Wi-Fi network flips into a re-auth window). That scenario is what Phases 2–3 cover.

## Phase 2: Captive-Portal Detector in the Extension (Implemented)

`Sources/WireGuardKit/CaptivePortalDetector.swift` — usable from the Network Extension (and compiled into the app targets too, for Phase 5's app-side re-probing).

**Key enabler:** traffic originating in the packet tunnel provider *process* bypasses its own utun — that is how wireguard-go's UDP sockets reach the physical network while the tunnel holds the default route. A plain `URLSession` GET from the extension therefore tests the **underlying** network even while the tunnel is up.

- Probe: GET `http://captive.apple.com/hotspot-detect.html`, 5 s timeout, ephemeral session, caching and cookies disabled, `waitsForConnectivity` off.
- Redirects are recorded and **refused** (a `URLSessionTaskDelegate` returning `nil` from `willPerformHTTPRedirection`), so the portal's bounce stays visible instead of silently landing on the sign-in page.
- Classification (`UnderlyingNetworkStatus`):
  - HTTP 200 with the expected `Success` body → `.clear` (underlying network fine; a sick tunnel is a *server* problem)
  - Redirect, 200 with any other body, or any other status (e.g. 511) → `.captive` (portal is intercepting)
  - Timeout / connection failure / DNS failure → `.offline` (network genuinely down or fully blocked)
- ATS exception scoped to the probe host (`NSExceptionDomains` → `captive.apple.com`, allow insecure HTTP) added to the Network Extension's `Info.plist`. HTTP is required for the same reason as in Phase 1.

## Phase 3: Captive-Aware ConnectionHealthMonitor (Implemented)

The failover engine now distinguishes "the network is blocked" from "this server is down."

- **Config switches are gated on the detector.** When `evaluateHealth()` decides the active config is unhealthy (and the anti-flap guards pass), it first runs `CaptivePortalDetector.check`. On `.clear` it proceeds to `performFailover()` (hot spare, then next config) exactly as before. On `.captive`/`.offline` it enters the `networkBlocked` holding state instead. Gated by `FailoverSettings.captivePortalDetection` (default `true`); disabling it restores the old behavior exactly.
- **Holding state semantics:** health-check evaluation, failback probes, and hot-spare starts are all suspended (they cannot succeed and only burn battery); no cycle counting; no consumption of `minimumHoldTime`/`cooldownDuration`; `txWithoutRxSince` reset. The detector is polled every 15 s, and immediately on `networkPathDidChange()` (the user may have switched networks).
- **On clear:** `adapter.bumpTunnelSockets()` (new `FailoverAdapterProtocol` requirement) rebinds the active tunnel's sockets to force an immediate handshake retry, traffic baselines are reset, hot spare restarts, and normal monitoring resumes. The monitor deliberately stays on the config that was active going in — time spent blocked says nothing about which server is best.
- **Delegate events:** `didDetectBlockedNetwork(status:)` / `healthMonitorDidClearBlockedNetwork` (default no-op implementations, so existing conformers are unaffected). `PacketTunnelProvider` currently logs these; Phase 5 hangs the sign-in notification off the first one.
- **Hot-spare corroboration (future refinement):** if the active tunnel is unhealthy *and* the hot spare probe to a different server also has no recent handshake, two independent endpoints are dead simultaneously — almost certainly a local-network problem. Could serve as an additional pre-check before even running the HTTP probe. Not implemented; the detector covers the cases it would.

### Target timeline (Phases 1–3 in place)

```
t=0     Join hotel Wi-Fi. probeURL fails → on-demand holds off. Sign-in sheet works.
t=30s   User authenticates. Interface leaves captive state → rules re-evaluated →
        probe passes → tunnel starts on the PRIMARY config, handshake succeeds.
```

And for a portal appearing mid-session (re-auth window):

```
t=0     Portal starts intercepting. tx-without-rx accumulates.
t=30s   trafficTimeout hit → detector says .captive → enter networkBlocked.
        No config cycling, no cooldown. IPC reports captivePortalDetected.
t=?     User authenticates. Next detector poll (≤15s) returns .clear →
        bump sockets → handshake on the same config → healthy.
```

## Phase 4: Surfacing to the User (IPC implemented; UI planned)

- **Implemented:** the health monitor's state snapshot — merged into the IPC type 1 (failover state) response, which the app already polls every 2–5 s while visible — now carries `networkBlocked: Bool`, `captivePortalDetected: Bool`, and `networkBlockedSince: TimeInterval` while in the holding state.
- **Planned:** UI reading those keys — show "This Wi-Fi network requires sign-in" on the tunnel/group detail and list views instead of a flapping status.

## Phase 5: Guided Sign-In — Notification + In-App Portal Browser (Planned)

The interactive follow-up to Phase 4: when a portal appears mid-session, actively walk the user through signing in, instead of just reporting the state.

### Local notification from the extension

Network extensions can post local notifications, and this codebase already does — `PacketTunnelProvider` posts disconnect and failover notifications via `UNUserNotificationCenter` (authorization is requested by the app; per-type toggles live in `NotificationSettings`). Phase 5 reuses that pattern:

- On `didDetectBlockedNetwork(.captive)`, post a "Wi-Fi network requires sign-in — tap to open" notification, gated by a new `NotificationSettings` toggle and debounced to once per blocked episode.
- Give it a notification category (e.g. `CAPTIVE_PORTAL`) so the app's `UNUserNotificationCenterDelegate` can route the tap straight to the sign-in sheet. Tapping a notification always foregrounds the app; no special API needed.
- Only `.captive` warrants a notification — `.offline` is not user-actionable.

### Is there built-in iOS functionality for the sign-in itself? Effectively no.

- **Captive Network Assistant (the system sign-in sheet):** there is no public API to summon it. It appears on network *join* — and with Phase 1 keeping the tunnel down at join time, it works normally there. For a portal appearing mid-session (expired session, re-auth window), it cannot be re-triggered programmatically.
- **`NEHotspotHelper`** is Apple's real built-in for participating in captive-portal auth, but it requires the `com.apple.developer.networking.HotspotHelper` entitlement, which Apple grants only to carrier/hotspot-aggregator apps by special request. Not viable here.
- **`NEHotspotConfiguration`** joins networks; it does not handle portal auth.

So the sign-in surface has to be ours: an in-app browser sheet.

### WKWebView, not SFSafariViewController

`SFSafariViewController` is isolated by design — the app cannot observe navigation, inject the probe flow, or detect when sign-in completed, so the sheet would just sit there after auth. A `WKWebView` sheet can run the whole loop:

1. Load the probe URL (`CaptivePortalDetector.defaultProbeURL`); the portal redirect lands the user on the sign-in page.
2. User authenticates (use a non-persistent `WKWebsiteDataStore`; portal credentials shouldn't outlive the sheet).
3. The app re-probes with `CaptivePortalDetector` (WireGuardKit is compiled into the app targets, so the same class is available) until `.clear`, then auto-dismisses.

App-side `Info.plist` needs `NSAllowsArbitraryLoadsInWebContent` — the purpose-built ATS key that exempts *WKWebView content only* — since portal sign-in pages are arbitrary plain-HTTP hosts. The app also needs the `captive.apple.com` exception for its own re-probe requests.

### Ordering caveat, and a Phase 1 synergy

Unlike extension traffic, **the app's traffic routes through the tunnel**. The sheet must therefore stop the tunnel before loading the portal page. Phase 1 makes this pleasantly simple: while the portal is intercepting, the on-demand Connect rule's `probeURL` check fails, so on-demand *cannot* fight the user by reconnecting — no on-demand suspension bookkeeping needed. And once the user signs in, the next rule evaluation sees the probe pass and reconnects automatically. So the flow is just: stop tunnel → present sheet → user signs in → probe clears → dismiss → reactivate (or let on-demand do it). `OnDemandSuspensionStore` remains available as a belt-and-braces fallback if rule re-evaluation proves unreliable on some OS versions.

## Approaches Considered and Rejected

**Splitting `Connect(.any)` into `Connect(.wiFi, probe)` + `Connect(.cellular)`** — would scope the probe to Wi-Fi only, but changes rule counts/shapes, breaking `ActivateOnDemandOption.create(from:)` round-tripping and older app versions reading the same `NETunnelProviderManager`. Not worth it given the probe host's reliability.

**Relying on `NWPath` for captive detection** — there is no public captive-portal signal on `NWPath` (`unsatisfiedReason` does not cover it; the path is simply `.satisfied`). Self-probing is the only reliable option.

**Detecting via the app process instead of the extension** — the app is frequently suspended or killed while the extension keeps running; the failover engine lives in the extension and must not depend on the app. (The app can still *display* what the extension detects.)

**Hot-spare corroboration as the sole mechanism** — only works when `hotSpare` is on (off by default), and cannot distinguish captive from genuine dual-server outage or tell when the portal clears. Kept as a corroborating signal, not the primary detector.

**`includeAllNetworks`** — we do not set it, and must not: with it set, even provider-process traffic handling gets stricter and captive portals become entirely unusable. No change needed; noted as a constraint.

## Testing Notes

- Real portals are easiest to simulate with a travel router or a Raspberry Pi running a captive portal (e.g. nodogsplash/openNDS), or a firewall rule that redirects port 80 and drops UDP.
- Phase 1: join the portal network with on-demand enabled → tunnel must stay down and the sign-in sheet must load; after auth, tunnel must come up without user action. Verify rule round-tripping by re-opening the on-demand editor.
- Phases 2–3: with `FAILOVER_TESTING` builds, verify no config cycling occurs behind a portal (health monitor logs `networkBlocked` instead of `switching to`), and that recovery lands on the config that was active before the portal appeared.
- Simulator caveat: uses `MockTunnels`; on-demand and NE behavior require a real device.
