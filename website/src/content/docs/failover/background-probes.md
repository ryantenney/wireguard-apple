---
title: Background Probes & Hot Spare
description: Non-disruptive failback probing and zero-handshake hot spare failover.
---

WGnext can run lightweight background WireGuard devices to test tunnel health without disrupting your active connection. This eliminates the ~15-second traffic disruption during failback probes and enables near-instantaneous failover with hot spare mode.

## The problem with legacy failback probes

When running on a fallback tunnel, WGnext periodically checks whether the primary has recovered. The legacy approach:

1. Swap the active tunnel to the primary config
2. Wait up to 15 seconds for a WireGuard handshake
3. If the handshake completes, stay on primary
4. If not, swap back to the fallback

During step 2, **all traffic is disrupted**. If the primary is still down, you have no working VPN for 15 seconds.

## Background probes (default)

With background probes enabled (the default), failback testing runs a **separate WireGuard device** alongside your active tunnel. This device has real UDP sockets but a null tun interface — it performs a full WireGuard handshake without routing any user traffic.

```
Active tunnel:   ── real utun ── StdNetBind ── UDP ── Server A  (routes traffic)
Background probe: ── null tun ── StdNetBind ── UDP ── Server B  (handshake only)
```

The failback flow becomes:

1. Start a background probe for the primary config
2. Wait for a handshake — **active tunnel continues uninterrupted**
3. If handshake completes: promote the probe to become the active tunnel
4. If not: stop the probe, try again later

:::tip
Background probes are enabled by default. No configuration needed — your failback probes are already non-disruptive if you're running a recent version.
:::

## Hot spare mode

Hot spare mode takes background probes further: instead of only probing during failback checks, it maintains a **continuously running** background WireGuard device for the next failover target.

When the active tunnel fails, the hot spare is already connected and ready. WGnext promotes it to become the active tunnel with **zero handshake delay**.

### How it works

```
Normal operation:
  Active:    config[0] (primary)  ── routes traffic
  Hot spare: config[1] (fallback) ── background probe, handshake maintained

When primary fails:
  1. Health monitor detects unhealthy connection (~40s)
  2. Hot spare already has an established WireGuard session
  3. Probe promoted to active tunnel — session preserved
  4. New hot spare started for config[2] (the next forward target)
```

The hot spare always tracks the **next forward failover target** — the same config
WGnext would switch to next. On `config[1]` it pre-warms `config[2]`, and so on,
wrapping back to the primary at the end of the chain. Failback to the primary is
handled separately by the periodic failback probe, so the spare stays dedicated to
forward failover.

### Zero-handshake promotion

The key innovation is that WGnext **reuses the hot spare's existing WireGuard session** when promoting it. Under the hood:

- The probe device uses a "swappable tun" — a wrapper around the null tun interface
- On promotion, the null tun is atomically swapped for the real utun file descriptor
- The WireGuard goroutines keep running with their existing Noise session
- The very next packet is encrypted/decrypted normally — no re-handshake needed

This means failover latency is limited to health detection time (~40 seconds) plus the tun swap (~microseconds). There is no additional handshake RTT.

:::caution
Hot spare mode is opt-in and disabled by default. Enable it in your failover group settings if you need the fastest possible failover.
:::

### Resource usage

Each hot spare consumes minimal resources:

| Resource | Usage |
|----------|-------|
| Goroutines | ~2-3 (device management, keepalive) |
| Network | 1 UDP socket, ~64 bytes every 25 seconds |
| Memory | Minimal (no packet buffers — null tun discards everything) |
| Battery | Less than a push notification |

This is negligible compared to the active tunnel.

## Performance

After a hot spare is promoted, every packet passes through the swappable tun wrapper. The inner device is loaded using an atomic memory read (~1-2 nanoseconds) — effectively zero overhead. There is no mutex or lock.

This wrapper is **only used for failover group tunnels**. Regular single-config tunnels are unaffected.

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| Background Probes | Enabled | Use non-disruptive background probes for failback testing |
| Hot Spare | Disabled | Maintain a continuously running background probe |

See [Failover Configuration](/failover/configuration/) for all settings.

## Fallback chain

WGnext uses a graceful degradation approach:

1. **Hot spare promotion** — zero-handshake session transfer (if hot spare enabled and running)
2. **Background probe + promotion** — non-disruptive probe, then promote (if background probes enabled)
3. **Background probe + config swap** — non-disruptive probe, then `adapter.update()` with re-handshake (if promotion fails)
4. **Legacy disruptive probe** — swap-wait-check-revert (if background probe can't start)

Each level falls back to the next if something goes wrong. You always get failover — the question is how seamless it is.

## Limitations

- **TiT tunnels**: Probe promotion is not yet supported for Tunnel-in-Tunnel configurations. Background probes still work for health checking, but failover uses `adapter.update()` (re-handshake).
- **One hot spare at a time**: Only one background probe runs (the immediate next failover target). Multiple concurrent spares may be supported in the future.
- **Server-side sessions**: The probe and active tunnel are independent WireGuard peers from the server's perspective (different keys). The server sees two concurrent sessions during hot spare operation.
