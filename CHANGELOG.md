# Changelog

All notable changes to this project are documented here.

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
