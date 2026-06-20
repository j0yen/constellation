# Timer Placement — Fleet vs Node-Local

## Problem

Systemd `--user` timers only fire when the node running them is awake. A laptop with its lid
closed misses scheduled jobs. For "reminder"-style timers — periodic tasks that should fire on
wall-clock time regardless of which node is active — the right home is the always-on hub.

## Classification

Timers are classified in `cloud/placement.toml`:

- `"hub"` — **fleet timer**: fires once, on the hub. Hub is always on so the schedule is reliable.
- `"node-local"` — **node-local timer**: must run on every node because it depends on
  node-specific resources (local kernel state, local cloud credentials, etc.).

### Current classification

| Timer | Placement | Rationale |
|---|---|---|
| `roundtable` | hub | Daily session management — node-agnostic |
| `roundtable-bind` | hub | Weekly bind — node-agnostic |
| `claude-self-review` | hub | Nightly review — needs to fire at 00:30 sharp |
| `claude-review-due` | hub | Daily marker — node-agnostic trigger |
| `adopt-cron` | hub | Binary adoption for the fleet, runs every 6h |
| `consign-drain` | hub | Git push-debt drain for the whole fleet |
| `claude-chaff` | hub | Git hygiene, fires 4× daily |
| `trim-relief` | hub | Memory/swap compaction every 6h |
| `ballast-guard` | hub | Disk SLO guard, fires hourly |
| `cloudbuild-watchdog` | node-local | Kills stale Hetzner builders — only where builds launch |
| `ctrace-reap` | node-local | Reaps root-owned bpftrace tracers — local kernel state |

## How relocation works

`cloud/scripts/relocate-timers.sh` performs the relocation:

1. Reads `cloud/placement.toml` to identify fleet timers.
2. Copies `.timer` + `.service` files to the hub via rsync.
3. Each hub `.service` file has `ExecCondition=wm-node role hub` in its `[Service]` section.
   This is a belt-and-suspenders guard: if a unit ever ends up enabled on a non-hub node,
   it will exit-0 immediately without doing any work.
4. Enables the timer on the hub: `systemctl --user enable --now <name>.timer`
5. Disables the timer on the laptop: `systemctl --user disable --now <name>.timer`

Pre-modified hub service files live in `cloud/systemd/hub/`. The relocation script uses these
in preference to the laptop originals (since the laptop originals have hardcoded `/home/jsy/`
paths that need `%h` substitution for cross-user portability).

## Adding a new timer

1. Edit `cloud/placement.toml` and add an entry:
   ```toml
   my-new-timer = "hub"     # or "node-local"
   ```

2. If it's a **fleet timer**, create a hub service file at
   `cloud/systemd/hub/my-new-timer.service` with `ExecCondition=wm-node role hub` in
   `[Service]`. Use `%h` instead of `/home/jsy/` for portability.

3. Commit and push. On next relocation pass, `relocate-timers.sh` will pick it up.

## Prerequisites

- **carbon-hub-access**: SSH alias `hub` must resolve to the always-on hub node.
- **carbon-node-identity**: `wm-node` binary must be installed on the hub and support
  `wm-node role hub` (exits 0 if this node is the hub, non-zero otherwise).

## Verification

After relocation:

```bash
# On hub — timer should be enabled
ssh hub 'systemctl --user is-enabled claude-self-review.timer'
# → enabled

# On laptop — timer should be disabled (no double-fire)
systemctl --user is-enabled claude-self-review.timer
# → disabled

# Node-local timers must NOT be on the hub
ssh hub 'systemctl --user list-timers cloudbuild-watchdog.timer 2>&1'
# → 0 timers listed (or not-found)

# Node-local timers must remain enabled on laptop
systemctl --user is-enabled cloudbuild-watchdog.timer
# → enabled
```
