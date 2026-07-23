# wgnext echo responder

Server-side component of **warm spare cellular failover** (see
[`DESIGN-warm-spare-cellular-failover.md`](../../DESIGN-warm-spare-cellular-failover.md)).
A stateless UDP echo service that replies to fixed-size probe datagrams with
the echoed token and the source `ip:port` it observed.

The iOS client uses it for three things:

1. **NAT keepalives** — periodic probes from the warm cellular socket keep the
   carrier CGNAT mapping alive so failover can reuse it.
2. **Quality probes** — RTT/loss measurement on both the default path and the
   cellular path (the keepalive echoes double as samples).
3. **EIM self-test** — probes to two adjacent ports; comparing the observed
   external ports reveals whether the carrier NAT does endpoint-independent
   mapping (RFC 4787 REQ-1).

## Deployment

Run it **on the same host as the WireGuard server** (the client assumes the
probe target IP equals the tunnel endpoint IP), on a port that is **not** the
WireGuard port:

```
go build -o wgnext-echod .
./wgnext-echod -port 51821 -ports 2
```

`-ports 2` listens on 51821 and 51822; the second port exists solely for the
EIM self-test. The client's `probePort` setting must match `-port`.

Example systemd unit:

```ini
[Unit]
Description=wgnext warm-spare echo responder
After=network.target

[Service]
ExecStart=/usr/local/bin/wgnext-echod -port 51821 -ports 2
DynamicUser=yes
Restart=always

[Install]
WantedBy=multi-user.target
```

## Wire protocol

All integers big-endian. Requests are exactly 40 bytes; anything else is
dropped silently.

```
Request (client → server), 40 bytes:
  0..3   magic "WGE1"
  4      type 0x01
  5..12  opaque token (echoed verbatim)
  13..39 zero padding

Reply (server → client), 20 bytes (IPv4) or 32 bytes (IPv6):
  0..3   magic "WGE1"
  4      type 0x02
  5..12  token
  13     observed address family (4 or 6)
  14..15 observed source port
  16..   observed source IP (4 or 16 bytes)
```

The request is padded so that the reply is always *smaller* than the request:
the service cannot be used for reflection amplification. Per-source-IP token
bucket rate limiting (default 5 pps sustained, burst 10) bounds reflection at
1:1 even under sustained abuse; the source table is capped (`-max-sources`)
so spoofed floods can't exhaust memory.

No authentication is used, by design: the reply only tells a client what the
server observed about that client's own packet.

The client-side implementation of this protocol lives in
`Sources/WireGuardKitGo/warmspare.go` — keep the two in sync.
