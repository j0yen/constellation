#!/usr/bin/env bash
# relocate-subscribers.sh — migrate homeward-* daemons from laptop to fleet hub.
#
# Prerequisites:
#   - Hub SSH access working (see carbon-hub-access PRD / scripts/hub-access.sh)
#   - Hub reachable via `ssh hub` (Tailscale MagicDNS name)
#   - wm-node binary installed on hub (for ExecCondition=wm-node should-run ...)
#   - ARM BUILD: either cross-compile on laptop or native build on hub (see below)
#
# ARM BUILD NOTE:
#   The hub is an ARM64 machine (Hetzner CAX21 / Oracle A1).
#   Two options for the homeward-ingest and homeward-report Rust binaries:
#
#   Option A — cross-compile on laptop (preferred for CI):
#     cargo build --release --target aarch64-unknown-linux-gnu \
#       -p homeward-ingest -p homeward-report
#     (Requires: sudo pacman -S aarch64-linux-gnu-gcc  or  cross tool)
#
#   Option B — native build on hub (simpler, no cross toolchain):
#     ssh hub 'git clone https://github.com/j0yen/homeward ~/src/homeward && \
#       cd ~/src/homeward && cargo build --release -p homeward-ingest -p homeward-report'
#
#   homeward-embed (Python/uv FastAPI sidecar) does NOT need cross-compile.
#   Sync the project directory and run `uv run` on the hub.
#
# Exit codes: 0 = success, 1 = preflight check failed, 2 = usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HUB_HOST="${HUB_HOST:-hub}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
    info "Preflight checks"

    # Hub SSH must be reachable
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${HUB_HOST}" true 2>/dev/null; then
        die "Cannot reach hub via 'ssh ${HUB_HOST}'. \
Run scripts/hub-access.sh first (carbon-hub-access PRD)."
    fi
    info "Hub SSH: OK"

    # wm-node must be installed on hub
    if ! ssh "${HUB_HOST}" 'command -v wm-node' &>/dev/null; then
        warn "wm-node not found on hub. ExecCondition guards will fail on hub units."
        warn "Install wm-node on hub before enabling services."
    fi
}

# ---------------------------------------------------------------------------
# Phase 1: sync homeward-embed Python project
# ---------------------------------------------------------------------------

sync_embed() {
    info "Syncing homeward-embed (Python/uv) to hub"
    EMBED_SRC="${HOME}/wintermute/homeward/homeward/embed"
    if [[ ! -d "${EMBED_SRC}" ]]; then
        warn "homeward/embed source not found at ${EMBED_SRC}; skipping embed sync"
        return 0
    fi
    ssh "${HUB_HOST}" "mkdir -p ~/wintermute/homeward/homeward/"
    rsync -av --exclude '__pycache__' --exclude '.venv' \
        "${EMBED_SRC}/" \
        "${HUB_HOST}:~/wintermute/homeward/homeward/embed/"
    # Install deps on hub
    ssh "${HUB_HOST}" "cd ~/wintermute/homeward/homeward/embed && uv sync --quiet"
    info "homeward-embed sync: done"
}

# ---------------------------------------------------------------------------
# Phase 2: install ARM binaries to hub (Option B — native hub build)
#           Call with --cross to use Option A instead.
# ---------------------------------------------------------------------------

install_binaries() {
    local mode="${1:-native}"
    info "Installing homeward-ingest / homeward-report to hub (mode=${mode})"
    HOMEWARD_SRC="${HOME}/wintermute/homeward"

    if [[ "${mode}" == "cross" ]]; then
        # Option A — cross-compile on laptop
        info "Cross-compiling for aarch64-unknown-linux-gnu"
        (cd "${HOMEWARD_SRC}" && \
            cargo build --release --target aarch64-unknown-linux-gnu \
            -p homeward-ingest -p homeward-report)
        rsync -av \
            "${HOMEWARD_SRC}/target/aarch64-unknown-linux-gnu/release/homeward-ingestd" \
            "${HOMEWARD_SRC}/target/aarch64-unknown-linux-gnu/release/homeward-reportd" \
            "${HUB_HOST}:~/.local/bin/"
    else
        # Option B — native build on hub
        info "Triggering native build on hub"
        ssh "${HUB_HOST}" bash <<'EOF'
set -eo pipefail
mkdir -p ~/src
if [[ -d ~/src/homeward ]]; then
    git -C ~/src/homeward pull --ff-only
else
    git clone https://github.com/j0yen/homeward ~/src/homeward
fi
cd ~/src/homeward
cargo build --release -p homeward-ingest -p homeward-report
mkdir -p ~/.local/bin
cp target/release/homeward-ingestd target/release/homeward-reportd ~/.local/bin/
echo "hub build: OK"
EOF
    fi
    ssh "${HUB_HOST}" "chmod +x ~/.local/bin/homeward-ingestd ~/.local/bin/homeward-reportd"
    info "Binaries installed on hub"
}

# ---------------------------------------------------------------------------
# Phase 3: migrate state (SQLite DBs)
# ---------------------------------------------------------------------------

migrate_state() {
    info "Migrating homeward SQLite databases to hub"
    DB_DIR="${HOME}/.local/share/homeward"
    if ! ls "${DB_DIR}"/*.db &>/dev/null; then
        warn "No .db files found in ${DB_DIR}; nothing to sync"
        return 0
    fi
    ssh "${HUB_HOST}" "mkdir -p ~/.local/share/homeward"
    rsync -av "${DB_DIR}/"*.db "${HUB_HOST}:~/.local/share/homeward/"
    warn "Laptop DB copies are now STALE. The hub is the canonical store."
    warn "Do not re-run this rsync after hub is live (would overwrite hub writes)."
    info "DB migration: done"
}

# ---------------------------------------------------------------------------
# Phase 4: deploy config files
# ---------------------------------------------------------------------------

deploy_config() {
    info "Deploying homeward.env config to hub"
    CONFIG_SRC="${HOME}/.config/homeward/homeward.env"
    if [[ -f "${CONFIG_SRC}" ]]; then
        ssh "${HUB_HOST}" "mkdir -p ~/.config/homeward"
        rsync -av "${CONFIG_SRC}" "${HUB_HOST}:~/.config/homeward/homeward.env"
        info "Config deployed"
    else
        warn "No homeward.env at ${CONFIG_SRC}; hub units will use defaults"
    fi
}

# ---------------------------------------------------------------------------
# Phase 5: deploy and enable systemd units on hub
# ---------------------------------------------------------------------------

deploy_units() {
    info "Deploying hub systemd units"
    HUB_UNIT_DIR="${REPO_ROOT}/cloud/systemd/hub"
    ssh "${HUB_HOST}" "mkdir -p ~/.config/systemd/user"
    rsync -av \
        "${HUB_UNIT_DIR}/homeward-ingest.service" \
        "${HUB_UNIT_DIR}/homeward-report.service" \
        "${HUB_UNIT_DIR}/homeward-embed.service" \
        "${HUB_HOST}:~/.config/systemd/user/"
    ssh "${HUB_HOST}" "systemctl --user daemon-reload"
    ssh "${HUB_HOST}" "systemctl --user enable --now homeward-ingest homeward-report homeward-embed"
    info "Hub units enabled"
}

# ---------------------------------------------------------------------------
# Phase 6: disable on laptop
# ---------------------------------------------------------------------------

disable_local() {
    info "Disabling homeward-* on laptop"
    for svc in homeward-ingest homeward-report homeward-embed; do
        if systemctl --user is-enabled "${svc}.service" &>/dev/null; then
            systemctl --user disable --now "${svc}.service"
            info "  disabled: ${svc}"
        else
            info "  already disabled: ${svc}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Phase 7: verify
# ---------------------------------------------------------------------------

verify() {
    info "Verification"
    # Hub: check services active
    ssh "${HUB_HOST}" "systemctl --user is-active homeward-ingest homeward-report" \
        && info "Hub services: active" \
        || warn "Hub services not active yet — check journalctl --user -u homeward-ingest"

    # Hub: check report API health
    HUB_IP=$(ssh "${HUB_HOST}" "tailscale ip -4 2>/dev/null || hostname -I | awk '{print \$1}'" 2>/dev/null)
    if [[ -n "${HUB_IP}" ]]; then
        if curl -sf --max-time 5 "http://${HUB_IP}:8081/healthz" &>/dev/null; then
            info "Report API at http://${HUB_IP}:8081/healthz: OK"
        else
            warn "Report API not responding at http://${HUB_IP}:8081/healthz"
            warn "Check: ssh hub journalctl --user -u homeward-report -n 20"
        fi
    fi

    # Laptop: confirm wm-busbridge and wm-tether still running
    for svc in wm-busbridge wm-tether; do
        if systemctl --user is-active "${svc}.service" &>/dev/null; then
            info "  ${svc}: still active on laptop (expected)"
        else
            warn "  ${svc}: NOT active on laptop — check it"
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 [--cross] [--skip-build] [--verify-only]

  --cross        Cross-compile ARM binaries on laptop (vs native hub build)
  --skip-build   Skip binary install (useful if hub already has binaries)
  --verify-only  Only run verification checks (no migration)
  --help         Show this help

This script migrates homeward-ingest, homeward-report, and homeward-embed
from the laptop to the fleet hub. Must run AFTER carbon-hub-access is complete.
EOF
    exit 2
}

CROSS=0
SKIP_BUILD=0
VERIFY_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cross)       CROSS=1 ;;
        --skip-build)  SKIP_BUILD=1 ;;
        --verify-only) VERIFY_ONLY=1 ;;
        --help|-h)     usage ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done

if [[ "${VERIFY_ONLY}" == "1" ]]; then
    preflight
    verify
    exit 0
fi

preflight
sync_embed
if [[ "${SKIP_BUILD}" == "0" ]]; then
    install_binaries "$([ "${CROSS}" == "1" ] && echo cross || echo native)"
fi
migrate_state
deploy_config
deploy_units
disable_local
verify

info "Migration complete. Update any clients that pointed at the laptop's :8081."
