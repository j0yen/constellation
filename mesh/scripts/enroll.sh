#!/usr/bin/env bash
# constellation mesh enroll — enroll this node into the Tailscale mesh.
# Usage: enroll.sh [--role <laptop|desktop|cloud>] [--headscale <url>] [--dry-run]
#
# Auth key is read from the encrypted secret store (pass or age-encrypted file).
# No plaintext key is ever written to the repo or to disk.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MESH_DIR="$REPO_ROOT/mesh"
CONFIG_DIR="$MESH_DIR/config"

# ── Defaults ────────────────────────────────────────────────────────────────
ROLE=""
HEADSCALE_URL=""
DRY_RUN=false
AUTH_KEY_PATH="${CONSTELLATION_AUTH_KEY_PATH:-}"    # override: path in pass store
TAILSCALE_FLAGS=""

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)       ROLE="$2";            shift 2 ;;
        --headscale)  HEADSCALE_URL="$2";   shift 2 ;;
        --dry-run)    DRY_RUN=true;         shift   ;;
        --auth-key)   AUTH_KEY_PATH="$2";   shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[constellation-mesh] $*"; }
die()  { echo "[constellation-mesh] ERROR: $*" >&2; exit 1; }
run()  {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# ── Detect role if not specified ─────────────────────────────────────────────
detect_role() {
    local hostname
    hostname="$(hostname -s)"
    case "$hostname" in
        *cloud*|*hub*|*server*)  echo "cloud"   ;;
        *desktop*|*tower*)       echo "desktop" ;;
        *laptop*|*book*|*mobile*)echo "laptop"  ;;
        *)
            # Fall back to config file
            local role_file="$CONFIG_DIR/node-role"
            if [[ -f "$role_file" ]]; then
                cat "$role_file"
            else
                echo "laptop"   # safe default
            fi
            ;;
    esac
}

[[ -z "$ROLE" ]] && ROLE="$(detect_role)"
log "Enrolling node as role: $ROLE"

# ── Validate role ─────────────────────────────────────────────────────────────
case "$ROLE" in
    laptop|desktop|cloud) ;;
    *) die "Unknown role '$ROLE'. Must be one of: laptop, desktop, cloud" ;;
esac

# ── Check tailscale is installed ─────────────────────────────────────────────
if ! command -v tailscale &>/dev/null; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log "tailscale not found — dry-run mode, continuing without it."
    else
        die "tailscale not found. Install via: https://tailscale.com/download or your package manager."
    fi
fi

# ── Resolve auth key ─────────────────────────────────────────────────────────
resolve_auth_key() {
    # 1. Environment variable (CI / ephemeral)
    if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
        echo "$TAILSCALE_AUTH_KEY"
        return 0
    fi

    # 2. pass(1) password store
    local pass_path="${AUTH_KEY_PATH:-constellation/tailscale/auth-key-${ROLE}}"
    if command -v pass &>/dev/null && pass show "$pass_path" &>/dev/null 2>&1; then
        pass show "$pass_path"
        return 0
    fi

    # 3. age-encrypted file alongside this repo
    local age_file="$CONFIG_DIR/auth-key-${ROLE}.age"
    if [[ -f "$age_file" ]] && command -v age &>/dev/null; then
        local identity="${AGE_IDENTITY:-$HOME/.config/constellation/identity.txt}"
        if [[ -f "$identity" ]]; then
            age --decrypt --identity "$identity" "$age_file"
            return 0
        fi
    fi

    die "No auth key found. Set TAILSCALE_AUTH_KEY, or store in pass at 'constellation/tailscale/auth-key-${ROLE}', or provide an age-encrypted file at $age_file"
}

if [[ "$DRY_RUN" == "true" && -z "${TAILSCALE_AUTH_KEY:-}" ]]; then
    # In dry-run mode with no live key, use a placeholder so the rest of
    # the script can show the full command that would run.
    AUTH_KEY="<auth-key-from-pass>"
    log "(dry-run) Using placeholder auth key — no secret store lookup performed."
else
    AUTH_KEY="$(resolve_auth_key)"
    [[ -z "$AUTH_KEY" ]] && die "Auth key resolved to empty string."
fi

# ── Build tailscale up flags ──────────────────────────────────────────────────
TAILSCALE_FLAGS="--authkey=$AUTH_KEY"
TAILSCALE_FLAGS+=" --advertise-tags=tag:fleet,tag:$ROLE"
TAILSCALE_FLAGS+=" --accept-routes"

# Cloud node advertises itself as an exit node
if [[ "$ROLE" == "cloud" ]]; then
    TAILSCALE_FLAGS+=" --advertise-exit-node"
fi

# Headscale (self-hosted control plane) override
if [[ -n "$HEADSCALE_URL" ]]; then
    TAILSCALE_FLAGS+=" --login-server=$HEADSCALE_URL"
    log "Using Headscale control server: $HEADSCALE_URL"
fi

# ── Enroll ────────────────────────────────────────────────────────────────────
log "Running: tailscale up $TAILSCALE_FLAGS"
# shellcheck disable=SC2086
run tailscale up $TAILSCALE_FLAGS

if [[ "$DRY_RUN" == "false" ]]; then
    log "Enrollment complete. Verifying status..."
    sleep 2
    tailscale status
fi

log "Node enrolled as '$ROLE' in the constellation mesh."
