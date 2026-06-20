#!/usr/bin/env bash
# hub-bootstrap.sh — one-shot idempotent bootstrap for the Hetzner CAX21 hub.
#
# Run this from the laptop AFTER you have injected the SSH public key via the
# Hetzner web console (see cloud/docs/hub-bootstrap-guide.md for instructions).
#
# What it does (all steps are idempotent):
#   1. Generate or reuse ~/.ssh/id_ed25519_hub
#   2. Display the public key (if the user hasn't added it yet) and prompt
#   3. Copy the public key to the hub via ssh-copy-id
#   4. Write an ~/.ssh/config entry for the "hub" host alias
#   5. Enable systemd --user linger on the hub
#   6. Stage the ansible/roles/cloud play for the next full provisioning run
#   7. Print the ARM build options for agorabus + other binaries
#
# Usage:
#   bash cloud/scripts/hub-bootstrap.sh [--hub-ip IP] [--hub-user USER]
#
# Environment overrides:
#   HUB_IP   — overrides the default Tailscale IP
#   HUB_USER — overrides the default SSH user (jsy)

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
HUB_IP="${HUB_IP:-100.66.158.49}"
HUB_USER="${HUB_USER:-jsy}"
SSH_KEY="${HOME}/.ssh/id_ed25519_hub"
SSH_CONFIG="${HOME}/.ssh/config"

# Parse CLI flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub-ip)   HUB_IP="$2";   shift 2 ;;
    --hub-user) HUB_USER="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

info()  { printf '\e[32m[bootstrap]\e[0m %s\n' "$*"; }
warn()  { printf '\e[33m[bootstrap]\e[0m %s\n' "$*"; }
die()   { printf '\e[31m[bootstrap]\e[0m %s\n' "$*" >&2; exit 1; }
sep()   { printf '%s\n' "──────────────────────────────────────────"; }

sep
info "Hub bootstrap — Hetzner CAX21 (ARM)"
info "  Target: ${HUB_USER}@${HUB_IP}"
sep

# ---------------------------------------------------------------------------
# Step 1: Generate hub SSH key (ed25519) if not present
# ---------------------------------------------------------------------------
if [[ ! -f "${SSH_KEY}" ]]; then
  info "Generating ${SSH_KEY} ..."
  ssh-keygen -t ed25519 -C "hub-access-$(date +%Y%m%d)" -f "${SSH_KEY}" -N ""
else
  info "SSH key already exists: ${SSH_KEY}"
fi

PUB_KEY="$(cat "${SSH_KEY}.pub")"
info "Public key:"
echo "  ${PUB_KEY}"

# ---------------------------------------------------------------------------
# Step 2: SSH config entry — idempotent (skip if already present)
# ---------------------------------------------------------------------------
touch "${SSH_CONFIG}"
chmod 600 "${SSH_CONFIG}"

if ! grep -q "^Host hub$" "${SSH_CONFIG}" 2>/dev/null; then
  info "Adding ~/.ssh/config entry for 'hub' ..."
  cat >> "${SSH_CONFIG}" <<EOF

Host hub
  HostName ${HUB_IP}
  User ${HUB_USER}
  IdentityFile ${SSH_KEY}
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 3
EOF
  info "Added 'Host hub' entry to ${SSH_CONFIG}"
else
  info "~/.ssh/config entry for 'hub' already present — skipping"
fi

# ---------------------------------------------------------------------------
# Step 3: Copy public key to hub
# ---------------------------------------------------------------------------
info "Attempting ssh-copy-id to ${HUB_USER}@${HUB_IP} ..."
info "(You may be prompted for a password — this is expected on first run.)"
if ssh-copy-id -i "${SSH_KEY}.pub" "${HUB_USER}@${HUB_IP}"; then
  info "Public key installed on hub."
else
  warn ""
  warn "ssh-copy-id failed. Possible causes:"
  warn "  • Password auth is disabled and the key hasn't been injected yet."
  warn "  • The hub's authorized_keys wasn't set via Hetzner console."
  warn ""
  warn "Manual fix (run from Hetzner web console):"
  warn "  mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  warn "  echo '${PUB_KEY}' >> ~/.ssh/authorized_keys"
  warn "  chmod 600 ~/.ssh/authorized_keys"
  warn ""
  die "Cannot continue without SSH access. See cloud/docs/hub-bootstrap-guide.md."
fi

# ---------------------------------------------------------------------------
# Step 4: Verify key-based login
# ---------------------------------------------------------------------------
info "Verifying key-based SSH login ..."
REMOTE_HOST="$(ssh hub hostname)"
info "Connected to: ${REMOTE_HOST} (hub)"

# ---------------------------------------------------------------------------
# Step 5: Enable systemd --user linger
# ---------------------------------------------------------------------------
info "Enabling systemd --user linger for ${HUB_USER} on hub ..."
ssh hub "loginctl enable-linger ${HUB_USER}"
LINGER="$(ssh hub "loginctl show-user ${HUB_USER} -p Linger" 2>/dev/null || true)"
info "Linger status: ${LINGER}"

if [[ "${LINGER}" != "Linger=yes" ]]; then
  warn "Linger may not have taken effect immediately — verify with:"
  warn "  ssh hub 'loginctl show-user ${HUB_USER} -p Linger'"
fi

# ---------------------------------------------------------------------------
# Step 6: Print next steps — full Ansible provisioning
# ---------------------------------------------------------------------------
sep
info "SSH access confirmed. Next steps:"
echo ""
echo "  # Full Ansible provisioning (cloud role — NATS, Tailscale, ollama):"
echo "  ansible-playbook -i ansible/inventory/hosts ansible/site.yml --limit hub"
echo ""
echo "  # Or run the hub-init role only (SSH hardening + linger + node.toml):"
echo "  ansible-playbook -i ansible/inventory/hosts ansible/site.yml \\"
echo "    --limit hub --tags hub-init"
echo ""
echo "  # ARM build — build agorabus natively on the hub (see Step 7 below)"
sep

# ---------------------------------------------------------------------------
# Step 7: ARM build guidance
# ---------------------------------------------------------------------------
info "ARM build path (hub is aarch64):"
echo ""
echo "  Option A — Build natively on the hub (recommended for bootstrap):"
echo "    ssh hub"
echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
echo "    source ~/.cargo/env"
echo "    # Clone wintermute and build:"
echo "    git clone https://github.com/j0yen/agorabus.git ~/src/agorabus"
echo "    cd ~/src/agorabus && cargo build --release"
echo ""
echo "  Option B — Cross-compile from laptop (aarch64-unknown-linux-gnu):"
echo "    cargo install cross"
echo "    cross build --target aarch64-unknown-linux-gnu --release"
echo "    scp target/aarch64-unknown-linux-gnu/release/agorabus hub:~/.local/bin/"
echo ""
echo "  See cloud/docs/arm-build-notes.md for detailed guidance."
sep

info "Bootstrap complete. Hub SSH access is working."
info "Proceed with Ansible provisioning to complete the hub setup."
