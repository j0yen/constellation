# Subscriber daemon migration — homeward-* to fleet hub

This document covers relocating the homeward suite from the laptop to the
always-on fleet hub (Hetzner CAX21 / Oracle A1 spare) so the AIMD cadence
loop is not interrupted by lid-close events.

## Why

- `homeward-ingest` runs an AIMD cadence loop (adaptive cadence for shelter pulls).
  When the laptop sleeps the loop pauses, corrupting its timing state.
- `homeward-report` and `homeward-embed` are downstream consumers that belong
  co-located with the ingest daemon.
- Per-node daemons (`wm-busbridge`, `wm-tether`) must NOT move — one per node
  is the topology constraint.

## Placement classification

See `cloud/placement.toml`:

| daemon           | placement   | reason                              |
|------------------|-------------|-------------------------------------|
| homeward-ingest  | hub         | AIMD loop; must run 24/7            |
| homeward-report  | hub         | co-located with ingest              |
| homeward-embed   | hub         | DINOv2 sidecar; co-located          |
| wm-busbridge     | node-local  | one per node by topology            |
| wm-tether        | node-local  | one per node by topology            |
| recalld          | (unset)     | out of scope — future PRD           |

## Prerequisites

1. **Hub SSH access** — `ssh hub` must work (see `carbon-hub-access` PRD).
2. **wm-node installed on hub** — provides `wm-node should-run <daemon>` used
   in `ExecCondition` guards.
3. **Binaries on hub** — hub is x86_64 (Hetzner CPX22, AMD EPYC); laptop
   binaries are also x86_64 — direct scp works (no cross-compile needed).
4. **uv installed on hub** — for the homeward-embed Python sidecar.

## Binary assessment (2026-06-20)

Hub architecture: **x86_64** (Hetzner CPX22, AMD EPYC) — NOT ARM as
previously documented. This simplifies deployment significantly.

Laptop binaries (all x86_64 ELF, dynamically linked against glibc):
- `~/.local/bin/homeward-ingestd` — ELF 64-bit x86-64, glibc ABI
- `~/.local/bin/homeward-reportd` — ELF 64-bit x86-64, glibc ABI
- `~/.local/bin/homeward` (CLI) — ELF 64-bit x86-64, glibc ABI
- `~/.local/bin/homeward-match` — ELF 64-bit x86-64, glibc ABI

**These can be scp'd directly to the hub.** The hub runs a standard Debian/Ubuntu
userland with glibc, so dynamically-linked binaries from this Arch laptop will
work provided glibc version is compatible (hub glibc ≥ laptop build target).

### Direct binary copy (x86_64 to x86_64)

```bash
scp ~/.local/bin/homeward-ingestd hub:~/.local/bin/homeward-ingestd
scp ~/.local/bin/homeward-reportd hub:~/.local/bin/homeward-reportd
# Verify
ssh hub "~/.local/bin/homeward-reportd --version 2>/dev/null || \
          ~/.local/bin/homeward-reportd --help 2>&1 | head -3"
```

### Fallback — native hub build (if glibc incompatibility)

```bash
ssh hub
git clone https://github.com/j0yen/homeward ~/src/homeward
cd ~/src/homeward
cargo build --release -p homeward-ingest -p homeward-report
cp target/release/homeward-ingestd target/release/homeward-reportd ~/.local/bin/
```

### homeward-embed (Python/uv)

No compile needed. The relocation script syncs the project directory to the hub
and runs `uv sync` to install dependencies.

```bash
rsync -av ~/wintermute/homeward/homeward/embed/ hub:~/wintermute/homeward/homeward/embed/
ssh hub 'cd ~/wintermute/homeward/homeward/embed && uv sync'
```

## DB sync procedure

The homeward SQLite databases live in `~/.local/share/homeward/*.db`.
This is a **one-time** sync at migration time:

```bash
ssh hub 'mkdir -p ~/.local/share/homeward'
rsync -av ~/.local/share/homeward/*.db hub:~/.local/share/homeward/
```

**Warning:** Once the hub daemons are live and writing, do NOT re-run this
rsync from the laptop — it would overwrite hub data with stale laptop copies.
The laptop DB files become read-only historical snapshots after migration.

## Running the migration

The migration script handles all phases automatically:

```bash
# Full migration (native hub build)
./cloud/scripts/relocate-subscribers.sh

# Full migration with cross-compile
./cloud/scripts/relocate-subscribers.sh --cross

# Skip binary install (hub already has binaries)
./cloud/scripts/relocate-subscribers.sh --skip-build

# Verify only (no changes)
./cloud/scripts/relocate-subscribers.sh --verify-only
```

The script:
1. Syncs homeward-embed Python project to hub and runs `uv sync`
2. Builds ARM binaries on hub (or cross-compiles if `--cross`)
3. Rsyncs SQLite DBs to hub (one-time)
4. Deploys `~/.config/homeward/homeward.env` to hub
5. Copies hub systemd units from `cloud/systemd/hub/` to hub
6. Enables and starts hub units (`systemctl --user enable --now`)
7. Disables homeward-* units on laptop (`systemctl --user disable --now`)
8. Runs verification checks

## Verification steps

After migration, verify:

```bash
# Hub services active
ssh hub 'systemctl --user is-active homeward-ingest homeward-report homeward-embed'

# Ingest cadence loop logging
ssh hub 'journalctl --user -u homeward-ingest -n 30 --no-pager'

# Report API health (replace <hub-tailscale-ip> with actual IP)
curl http://<hub-tailscale-ip>:8081/healthz

# Laptop per-node daemons still running
systemctl --user is-active wm-busbridge wm-tether

# Hub busbridge (separate from laptop busbridge — both should be active)
ssh hub 'systemctl --user is-active wm-busbridge && wm-busbridge selftest'
```

## Rollback

If hub deployment fails and you need to restore laptop operation:

```bash
systemctl --user enable --now homeward-ingest homeward-report homeward-embed
```

The laptop DB files are still there (stale if any hub writes occurred since
migration). If hub was live for any duration and wrote to DBs, export from hub
first:

```bash
rsync -av hub:~/.local/share/homeward/*.db ~/.local/share/homeward/
```

## Client base-URL update

The homeward report API was previously at `http://localhost:8081` (or the
laptop's Tailscale IP). After migration it lives at the hub's Tailscale IP.
Update any clients (scripts, integrations, web UI) that had the old address.

The hub's Tailscale IP is stable (MagicDNS name `hub.tail…`); prefer the
MagicDNS name over the raw IP in client configs so failover (hub-failover.sh)
re-points clients automatically.
