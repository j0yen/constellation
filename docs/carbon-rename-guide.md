# carbon-rename: Renaming This Laptop to "carbon"

## What and Why

This laptop has been running as `wintermute` — the informal center of the system.
The constellation vision promotes it to a **named peer** called `carbon`, so the
fleet has consistent identities: `carbon` (this laptop), `ryzen7` (work machine),
and future nodes.

The system/fleet brand stays "wintermute". Only the *node* is renamed.

## The Three Layers

A hostname rename spans three independent layers, each requiring its own action:

### Layer 1 — System Hostname

`hostnamectl set-hostname carbon` writes `/etc/hostname`. Requires `sudo`.
The script handles this with a user-visible prompt.

### Layer 2 — Tailscale Admin Panel

Tailscale's node name does **not** automatically follow the system hostname.
You must rename it by hand:

1. Go to <https://login.tailscale.com/admin/machines>
2. Find the machine currently listed as `wintermute`
3. Click the three-dot menu → **Edit machine name** → enter `carbon`

Until you do this, `tailscale status` still shows `wintermute`.

### Layer 3 — node.toml (Fleet Identity)

`~/.config/wintermute/node.toml` declares this node's identity to the
`wm-node` binary (from PRD-carbon-node-identity). The script writes:

```toml
name   = "carbon"
roles  = ["voice"]
fleet  = "wintermute"
```

## How to Run

```bash
bash ~/wintermute/constellation/bin/carbon-rename.sh
```

The script is idempotent — re-running is always safe. Each step checks its
current state and skips if already done.

## Verification

After running the script and completing the Tailscale admin step:

```bash
# Layer 1: system hostname
hostname
# expect: carbon

# Layer 3: node identity config
cat ~/.config/wintermute/node.toml
# expect: name = "carbon"

# Full identity (requires wm-node from PRD-carbon-node-identity)
wm-node id
# expect: carbon
```

## Notes

- `WM_NODE=wintermute` in `~/.config/systemd/user/` or `~/.config/environment.d/`
  is automatically updated by the script to `WM_NODE=carbon`.
- Journal paths under `~/brain/` reference the date, not the hostname; no rename needed.
- The fleet/brand name "wintermute" appears throughout docs, code, and daemons —
  those references are intentional and must **not** be changed by this script.
