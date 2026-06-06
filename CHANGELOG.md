# Changelog

All notable changes to this project are documented here.

## v0.2.0 — 2026-06-05

**constellation-mesh: one private network with stable names**

Before any bus or job traffic can flow, the roaming laptop, the home desktop,
and the cloud node need one private, NAT-traversing network with stable names.
This release enrolls every node into a Tailscale mesh (WireGuard underneath),
gives each a stable MagicDNS name, restricts access with a committed ACL, and
makes the cloud node the always-reachable exit/relay — the substrate every
later layer rides on. MagicDNS names (never IPs) are the load-bearing choice:
a roaming laptop reconnects from any network with zero config change.

### What's included

- **Ansible `tailscale` role** (`mesh/roles/tailscale/`) — scripted
  `tailscale up` per node with a pre-authorized auth key pulled from the
  encrypted `pass` store (`no_log:true`, no plaintext key in the repo);
  advertises `tag:fleet` + a dynamic `tag:<role>`.
- **`constellation-mesh` CLI** — `enroll | names | status | acl`. `names`
  prints the canonical fleet name map (table/json/env) for downstream layers;
  `status` pings every expected node by MagicDNS name and exits non-zero if the
  fleet is incomplete; `enroll --dry-run` works without Tailscale installed.
- **Committed ACL policy** (`mesh/config/acl-policy.hujson`) — mesh-only,
  default-deny: the bus (`:4222`/`:7422`) and brain (`:8080`) ports are
  reachable only from fleet tags, never from a public/wildcard source.
- **Headscale variant** (`mesh/docs/headscale.md` + `--headscale <url>` flag) —
  the self-hosted-control-plane sovereignty path, documented and selectable.
- **Roaming + fallback docs** (`mesh/docs/roaming-test.md`) — the documented
  reproducible tests for cross-NAT reach to the tower's brain/STT port (AC2–4),
  the keep-awake-vs-WoL decision, and the brain-ladder cloud fallback (AC6).
- **Offline gates** — `tests/mesh-role-check.sh` (role/enrollment invariants,
  AC1/AC7/AC8/AC10) and `tests/acl-policy-check.sh` (ACL mesh-only semantics,
  AC5/AC7/AC10) prove the invariants without a live tailnet.

## v0.1.0 — 2026-06-05

**constellation-cloud: the always-on hub that keeps the fleet coherent**

Personal machines sleep, roam, and power off; the fleet needs one node that is
always on to host the NATS hub, anchor the mesh, and provide an offline-fallback
brain. This release provisions that node cheaply — a ~€8/mo Hetzner ARM box
(Oracle free tier as hot spare) — running the JetStream hub, the mesh exit, and
a small local fallback brain, all from the same Ansible control plane. The
latency brain stays the Anthropic API, because at personal volume that beats any
rentable GPU by 20-40×.

### What's included

- **Ansible `cloud` role** — provisions a headless Hetzner CAX21 (ARM, 4vCPU,
  8GB) or Oracle A1 spare; enforces `voice_node: false` + `gpu: none` guardrails
  so no desktop or GPU resource is ever accidentally provisioned.
- **NATS JetStream hub** — `nats-server` with JetStream domain `hub`, TLS
  leafnode listener on `:7422`, `WM_WORK` work-queue stream and `WM_NODES` KV
  bucket created idempotently via `nats-assets` script.
- **Tailscale exit node** — enrolled as `tag:cloud` + `tag:fleet` with
  `--advertise-exit-node` so all NAT'd fleet nodes always have a reachable peer.
- **Offline-fallback brain** — `ollama` + `qwen2.5:3b` as the *degraded* path;
  the primary latency brain is the Anthropic API (cost rationale documented in
  `docs/cloud-hub.md`).
- **Oracle spare failover** — `cloud/scripts/hub-failover.sh` scripted promotion
  of the Always-Free A1 spare to primary hub via Tailscale MagicDNS rename.
- **Offline structural gate** — `tests/cloud-role-check.sh` asserts all
  acceptance invariants without a live server.
- **`docs/cloud-hub.md`** — architecture diagram, cost rationale table, full
  provisioning walk-through, failover procedure, TLS and monitoring notes.
