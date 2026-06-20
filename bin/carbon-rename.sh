#!/usr/bin/env bash
set -uo pipefail

# carbon-rename.sh — idempotent rename of this laptop from "wintermute" to "carbon"
# as a named fleet peer in the wintermute constellation.
#
# Run: bash ~/wintermute/constellation/bin/carbon-rename.sh
# Safe to re-run: each step is idempotent.

echo "=== carbon-rename: renaming this node to 'carbon' ==="
echo ""

# Step 1: hostname (user-gated sudo)
if [ "$(hostname)" != "carbon" ]; then
  echo "Renaming hostname to carbon (requires sudo)..."
  sudo hostnamectl set-hostname carbon
  echo "hostname: done"
else
  echo "hostname: already carbon (no-op)"
fi

# Step 2: Write node.toml
mkdir -p ~/.config/wintermute
if [ ! -f ~/.config/wintermute/node.toml ]; then
  cat > ~/.config/wintermute/node.toml <<'EOF'
name = "carbon"
roles = ["voice"]
fleet = "wintermute"
EOF
  echo "node.toml: written"
else
  echo "node.toml: already exists (no-op)"
fi

# Step 3: Tailscale (manual gate — cannot be scripted)
echo ""
echo "MANUAL STEP REQUIRED:"
echo "  Tailscale node name must be updated in the admin panel:"
echo "  https://login.tailscale.com/admin/machines"
echo "  Rename 'wintermute' -> 'carbon'"
echo "  (This does not auto-follow the system hostname.)"
echo ""

# Step 4: Grep and update WM_NODE=wintermute references in env/service files
found=$(grep -r "WM_NODE=wintermute" ~/.config/systemd/user/ ~/.config/environment.d/ 2>/dev/null | wc -l)
if [ "$found" -gt 0 ]; then
  echo "Found $found WM_NODE=wintermute references — updating..."
  grep -rl "WM_NODE=wintermute" ~/.config/systemd/user/ ~/.config/environment.d/ 2>/dev/null | while read -r f; do
    sed -i 's/WM_NODE=wintermute/WM_NODE=carbon/g' "$f"
    echo "  updated: $f"
  done
  echo "WM_NODE references: updated"
else
  echo "WM_NODE=wintermute: none found (clean)"
fi

echo ""
echo "carbon-rename: done"
echo "  Verification (once wm-node is installed):"
echo "    hostname"
echo "    cat ~/.config/wintermute/node.toml"
echo "    wm-node id"
