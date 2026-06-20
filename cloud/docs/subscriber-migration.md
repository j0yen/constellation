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
3. **ARM binaries** — see "ARM build options" below.
4. **uv installed on hub** — for the homeward-embed Python sidecar.

## ARM build options

The hub is ARM64 (aarch64). Two paths for homeward-ingest and homeward-report:

### Option A — cross-compile on laptop (preferred for CI)

```bash
# Install cross-compile toolchain (Arch)
sudo pacman -S aarch64-linux-gnu-gcc

# Add target
rustup target add aarch64-unknown-linux-gnu

# Build
cargo build --release --target aarch64-unknown-linux-gnu \
    -p homeward-ingest -p homeward-report

# Copy to hub
rsync target/aarch64-unknown-linux-gnu/release/homeward-ingestd \
      target/aarch64-unknown-linux-gnu/release/homeward-reportd \
      hub:~/.local/bin/
```

### Option B — native build on hub (simpler, no cross toolchain)

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
