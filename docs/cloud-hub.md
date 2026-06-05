# constellation-cloud: always-on hub node

## Architecture

The fleet needs one node that is always on to host the NATS JetStream hub,
anchor the Tailscale mesh, and provide an offline-fallback brain.

```
                     ┌──────────────────────────────────┐
                     │  Hetzner CAX21 (hub)  ~€8/mo     │
                     │  ARM, 4vCPU, 8GB RAM             │
                     │                                  │
  laptop (nomad) ────┤  nats-server :7422 (leafnode TLS)│
  desktop (forge) ───┤  tailscaled  (exit node)         │
  oracle spare   ────┤  ollama      (fallback brain)    │
  (hub-spare)        └──────────────────────────────────┘
```

**Primary latency brain: Anthropic API** (see §cost-rationale below).
The ollama model on this node is the *degraded* path only.

---

## Cost rationale

| Option | Cost | Quality |
|---|---|---|
| Anthropic Haiku 4.5 (prompt-cached) | ~$3-11/mo at 200 turns/day | Best |
| Anthropic Sonnet 4.5 | ~$20-50/mo at 200 turns/day | Excellent |
| Self-hosted RTX 4090 ($0.69/hr × 730h) | ~$504/mo | OK |
| Self-hosted A40 ($0.44/hr × 730h) | ~$321/mo | OK |
| Hetzner CAX21 + fallback model | ~€8/mo (degraded only) | Degraded |

Break-even for self-hosted GPU vs. Anthropic API: **~15-20M tokens/day sustained**.
At 200 voice turns/day (~1K tokens each) = 200K tokens/day — **100× below break-even**.

**Decision: Pay the Anthropic API. Use the cloud node as a cheap coordinator only.**

GPU usage is *burst-only* via constellation-dispatch (e.g. RunPod/Vast.ai spun up
per job and killed). No persistent GPU is provisioned by this role.

---

## Ansible provisioning

### Prerequisites

1. A Hetzner account + `hcloud` CLI (or manual server creation).
2. A Tailscale auth key (pre-authorized, tagged `tag:cloud`) stored in `pass`:
   ```
   pass insert constellation/tailscale/auth-key-cloud
   ```
3. (Optional) An Anthropic API key for the brain ladder:
   ```
   pass insert constellation/anthropic/api-key
   ```

### Provision the primary hub

```bash
# 1. Create the server (Hetzner CLI example — CAX21, Ubuntu/Arch)
hcloud server create --name hub --type cax21 --image arch-linux \
  --ssh-key ~/.ssh/id_ed25519.pub --location fsn1

# 2. Get the IP
hcloud server ip hub

# 3. Uncomment hub in ansible/inventory/hosts and set ansible_host=<ip>
vim ansible/inventory/hosts

# 4. Dry-run (requires ansible + community.general collection)
ansible-playbook -i inventory/hosts site.yml --limit hub --check

# 5. Apply
ansible-playbook -i inventory/hosts site.yml --limit hub

# 6. Verify NATS is up
ssh jsy@<hub-ip> systemctl status nats-server
ssh jsy@<hub-ip> /usr/local/bin/nats-assets   # create WM_WORK + WM_NODES if needed

# 7. Verify Tailscale enrollment
ssh jsy@<hub-ip> tailscale status
```

### Verify NATS JetStream assets

```bash
# From the hub itself (or any fleet node with the nats CLI + creds):
nats stream info WM_WORK --server nats://hub:4222
nats kv info WM_NODES   --server nats://hub:4222
```

### Verify leaf connectivity (from a fleet node)

```bash
# Enroll leaf with --remote-url pointing to hub (done by constellation-bus role)
nats --server "nats://hub.tail:7422" sub "wm.>" &
nats --server "nats://hub.tail:7422" pub "wm.test" "hello"
```

---

## Failover: Oracle Always-Free A1 spare

The Oracle A1 (4 ARM / 24GB, $0) is the hot standby. It runs the same
`cloud` Ansible role but is **not** the primary leafnode URL.

### Promotion procedure

When Hetzner is down and the Oracle spare must become hub:

```bash
# 1. Ensure oracle spare is provisioned (same role)
ansible-playbook -i inventory/hosts site.yml --limit hub-spare

# 2. Verify it's enrolled in Tailscale and reachable
tailscale ping hub-spare

# 3. Re-point MagicDNS name (Tailscale admin → rename hub-spare → hub)
#    OR: update fleet-nodes.conf and each leaf's NATS_HUB_URL env var
#    from "nats://hub.tail:7422" to "nats://hub-spare.tail:7422"

# 4. Each fleet leaf reconnects automatically after NATS reconnect timeout
#    (default 2s exponential backoff; full reconnect < 30s)

# 5. Confirm JetStream state restored
nats --server nats://hub-spare.tail:7422 stream info WM_WORK
nats --server nats://hub-spare.tail:7422 kv info WM_NODES

# 6. Update inventory/hosts: comment out hub, uncomment hub-spare as primary
```

The MagicDNS approach (rename the spare node to `hub`) is preferred over
updating env vars on all fleet nodes — it's a single admin-console action.

### Demotion (return to Hetzner)

```bash
# Rename hub-spare back; Hetzner hub re-enrolls; leaves reconnect automatically.
```

---

## NATS TLS notes

The `cloud` role generates a self-signed certificate for the initial rollout.
Replace with a Let's Encrypt cert for production:

```bash
# On the hub node, using certbot with Hetzner DNS challenge:
certbot certonly --dns-hetzner --email jyen.tech@gmail.com \
  -d hub.yourdomain.com
# Then update nats_creds_dir certs and reload nats-server.
```

---

## Monitoring

- NATS: `http://127.0.0.1:8222` (loopback only; SSH tunnel to access)
- Tailscale: `tailscale status` on hub
- ollama: `ollama list` + `ollama run qwen2.5:3b "hello"` for a smoke test
