# Roaming test procedures (ACs 2–4, 6)

This document is the "documented reproducible test" called for by the
constellation-mesh acceptance criteria. It demonstrates (and lets you
re-verify) the three roaming properties the mesh must provide:

- **AC2** — Every node resolves every other node by stable MagicDNS name.
- **AC3** — A roaming node that changes networks reconnects automatically,
  reachable by the same name, with no config change.
- **AC4** — From outside the home network (simulated cross-NAT), the laptop
  reaches the desktop's brain/STT port by its MagicDNS name over the
  encrypted tunnel; no public IP or port-forward is involved.
- **AC6** — When the tower (desktop/forge) is unreachable, the brain ladder
  falls through to the Anthropic cloud API automatically, with no turn
  failure; the keep-awake strategy is documented.

---

## Preconditions

All three nodes (`hub`, `forge`, `nomad`) must be enrolled:

```bash
# On each node (adjust --role)
./mesh/constellation-mesh enroll --role <cloud|desktop|laptop>
```

Then on any enrolled node:

```bash
./mesh/constellation-mesh status
# Expected: Fleet complete — all expected nodes reachable.
```

---

## AC2 — MagicDNS name resolution

Run on **nomad** (laptop) after enrollment:

```bash
# Confirm tailscale knows the MagicDNS suffix
SUFFIX=$(tailscale status --json | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['MagicDNSSuffix'])")
echo "Tailnet suffix: $SUFFIX"

# Resolve and ping each peer by stable MagicDNS name (name, not IP)
ping -c2 hub.${SUFFIX}
ping -c2 forge.${SUFFIX}

# constellation-mesh names shows the same map
./mesh/constellation-mesh names
```

Expected: all three `ping` calls succeed.

Run the same block on **forge** (desktop) and **hub** (cloud) to confirm
bidirectional name resolution.

---

## AC3 — Roaming reconnect (simulated network change)

Run on **nomad** (laptop):

```bash
# 1. Note current MagicDNS name
MY_NAME=$(tailscale status --json | python3 -c \
    "import sys,json; d=json.load(sys.stdin); \
     print(d['Self']['HostName'] + '.' + d['MagicDNSSuffix'])")
echo "My stable name: $MY_NAME"

# 2. Simulate a network change: disconnect Wi-Fi, wait 3s, reconnect
# (on a real phone hotspot, just switch SSIDs; in CI use a netns trick)
# Minimal simulation: bounce the tailscaled daemon itself.
sudo systemctl restart tailscaled
sleep 5

# 3. Verify the daemon recovered without any config change
tailscale status
# Expected: peers appear, MagicDNSSuffix unchanged

# 4. Ping from another enrolled node (SSH in from hub/forge) using the same name
#    e.g. on hub:
#      ping -c2 nomad.<SUFFIX>
# Expected: ping reaches the laptop despite having changed network state.
```

Rationale: Tailscale re-establishes the WireGuard tunnel via the DERP relay
automatically on every netpath change. No manual `tailscale up` or IP change
is needed.

---

## AC4 — Cross-NAT reach to the desktop's brain port

This test proves that **nomad** can reach **forge**'s brain API on `:8080`
from behind a different NAT than **forge** is behind, with no public IP or
port-forward configured on either side.

### Setup

1. Move **nomad** to a network with a different upstream than **forge** (e.g.
   a phone hotspot, a coffee-shop Wi-Fi, or any second ISP path).
   **Confirm**: `curl ifconfig.me` on nomad and forge return different public
   IPs. Neither IP should be a static home IP with an open inbound port.

2. On **forge**, start a small probe listener on port 8080 (or use the real
   brain API if it's running):

   ```bash
   # On forge — temporary probe listener
   python3 -m http.server 8080 &
   PROBE_PID=$!
   trap "kill $PROBE_PID 2>/dev/null" EXIT
   ```

3. On **nomad**, connect through the Tailscale mesh:

   ```bash
   SUFFIX=$(tailscale status --json | python3 -c \
       "import sys,json; print(json.load(sys.stdin)['MagicDNSSuffix'])")

   # Hit the desktop brain endpoint via MagicDNS name — NOT by IP
   curl -v --max-time 10 "http://forge.${SUFFIX}:8080/"
   ```

   Expected: HTTP 200 (or a real brain API response).

4. **Assert no public path**: on any host **not** enrolled in the tailnet,
   try to reach **forge**'s `:8080` directly by forge's home public IP:

   ```bash
   # On a non-tailnet host / from a VPS outside the tailnet
   curl --max-time 5 "http://<forge-public-ip>:8080/" && echo FAIL || echo PASS
   ```

   Expected: connection refused or timeout (firewall / no port-forward), PASS.

### DERP relay path verification

To confirm the tunnel uses the DERP relay (worst-case CGNAT path):

```bash
# On nomad
tailscale ping --verbose forge.${SUFFIX}
# Look for "relay via <DERP datacenter>" in the output.
# P2P path will say "pong from … ts.net … via ..." without "relay"
```

Both relay and P2P paths are valid; either proves the mesh works across NATs.

---

## AC6 — Tower-unreachable fallback (keep-awake + brain ladder)

### Keep-awake strategy

**Chosen approach: inhibit-sleep systemd target on forge.**

The tower runs `systemd-inhibit --mode=block --what=sleep --who=wm-brain \
--why="brain endpoint must stay online"` whenever the brain server is active.
This is simpler and more reliable than Wake-on-LAN for a home machine that
stays plugged in. If the tower needs to sleep (maintenance, power-out), the
laptop's brain ladder provides the fallback.

Wake-on-LAN is explicitly **not** relied upon: it requires a static home IP
(or a DDNS workaround), an open inbound UDP port, and the network card to
stay in a powered state — none of which this mesh provides unconditionally.

Implementation: `wm-brain.service` on forge should include
`ExecStartPre=systemd-inhibit ...` or use `WantedBy=sleep.target Conflicts=sleep.target`.
This is owned by the `brain-cuda` PRD; this mesh PRD documents the choice
and references it.

### Brain ladder fallback test

When forge is unreachable (powered off or `tailscale down` on forge), the
laptop's `wmd` brain-ladder must skip `local-gpu` and fall through to the
cloud Anthropic API without a turn failure.

```bash
# 1. Simulate forge offline: on forge, run `sudo tailscale down`,
#    or simply power it off.

# 2. On nomad, trigger a brain query that would normally hit forge:
wm-query "test query — forge should be unreachable"

# 3. Observe wmd logs:
journalctl -u wmd -n 50
# Expected log lines:
#   [brain] tier local-gpu: forge.<tailnet> unreachable, skipping
#   [brain] tier cloud-haiku: OK, response received

# 4. Restore forge: `sudo tailscale up`
```

The brain-ladder skip is controlled by `WM_BRAIN_SKIP_TIERS` (see
`~/wintermute/brain/README.md`); the ladder itself is owned by the
`brain-cuda` PRD. This PRD's contribution is:

- The mesh ensures forge is always reachable from nomad **when forge is online**.
- The ACL ensures forge's `:8080` is reachable from fleet tags only.
- The keep-awake inhibitor ensures forge stays online as long as wm-brain is running.
- The brain ladder provides the graceful fallback when forge is offline.

Together these satisfy AC6: "when the tower is asleep/offline, a roaming
laptop's brain ladder skips `local-gpu` and falls through to the cloud
Anthropic API with no turn failure."

### Home upstream bandwidth note

For honesty on operating expectations:

- Text brain replies are typically 1–10 KB: negligible on any home upstream.
- STT audio (whisper input) is approximately 100–200 KB/turn (uncompressed
  mono 16 kHz 16-bit at ~15s/turn): well within any home broadband upload
  (≥1 Mbit/s).
- The added cost of the mesh path vs. direct LAN is internet RTT, typically
  10–50 ms additional. This is negligible compared to ~1–3 s generation time.
- No special home-network configuration (static IP, port-forward, DDNS) is
  needed at any point.

---

## Running all checks at once

```bash
# Offline ACL semantic check (no tailscale required)
./tests/acl-policy-check.sh

# Structural cloud-role check (no live Hetzner box required)
./tests/cloud-role-check.sh

# Live fleet health (requires enrolled nodes)
./mesh/constellation-mesh status

# Full name map
./mesh/constellation-mesh names
```

All of the above should exit 0 on a healthy fleet.
