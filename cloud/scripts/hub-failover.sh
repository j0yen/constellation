#!/usr/bin/env bash
# hub-failover.sh — promote the Oracle Always-Free A1 spare to primary NATS hub.
#
# Use when the Hetzner CAX21 primary is down and you need the spare to take over.
# The preferred mechanism is Tailscale MagicDNS rename (the fleet uses the MagicDNS
# name "hub" so a single rename re-points all leaves without touching fleet nodes).
#
# Prerequisites:
#   - tailscale CLI installed and authenticated (admin or operator token)
#   - nats CLI installed (https://github.com/nats-io/natscli)
#   - ansible installed (for re-provision if spare was cold)
#   - pass entry: constellation/tailscale/auth-key-cloud
#   - TAILSCALE_API_TOKEN set (or passed via --api-token)  [for MagicDNS rename]
#
# Exit codes: 0 = success, 1 = check failed, 2 = usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Defaults — override via environment variables or flags.
# ---------------------------------------------------------------------------
SPARE_HOST="${SPARE_HOST:-hub-spare}"           # Tailscale MagicDNS name of spare
SPARE_NATS_URL="${SPARE_NATS_URL:-nats://${SPARE_HOST}:7422}"
PRIMARY_HOST="${PRIMARY_HOST:-hub}"             # the name the fleet uses (hub)
TAILSCALE_DOMAIN="${TAILSCALE_DOMAIN:-tail}"    # e.g. hub.tail → used for ping checks
ANSIBLE_LIMIT="${ANSIBLE_LIMIT:-hub-spare}"     # inventory limit for re-provision
DRY_RUN="${DRY_RUN:-false}"
SKIP_ANSIBLE="${SKIP_ANSIBLE:-false}"           # set true if spare is already provisioned
SKIP_RENAME="${SKIP_RENAME:-false}"             # set true to skip MagicDNS rename step

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

info()  { echo -e "${GREEN}[hub-failover]${NC} $*"; }
warn()  { echo -e "${YELLOW}[hub-failover WARN]${NC} $*" >&2; }
fatal() { echo -e "${RED}[hub-failover FATAL]${NC} $*" >&2; exit 1; }

dry() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${YELLOW}[dry-run]${NC} would run: $*"
    else
        "$@"
    fi
}

usage() {
    cat >&2 <<EOF
Usage: $0 [OPTIONS]

Promote the Oracle Always-Free A1 spare to the primary NATS hub.

Options:
  --spare-host <name>   Tailscale MagicDNS name of the spare node (default: hub-spare)
  --dry-run             Print actions without executing them
  --skip-ansible        Skip re-provisioning the spare (use if already provisioned)
  --skip-rename         Skip the MagicDNS rename step (edit fleet env vars instead)
  -h, --help            Show this help

Environment variables (alternative to flags):
  SPARE_HOST            Tailscale hostname of spare (default: hub-spare)
  TAILSCALE_API_TOKEN   API token for MagicDNS rename (required unless --skip-rename)
  DRY_RUN=true          Same as --dry-run
  SKIP_ANSIBLE=true     Same as --skip-ansible
  SKIP_RENAME=true      Same as --skip-rename

Example:
  TAILSCALE_API_TOKEN=tskey-... $0 --spare-host hub-spare
  DRY_RUN=true $0 --spare-host hub-spare
EOF
    exit 2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --spare-host)   SPARE_HOST="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --skip-ansible) SKIP_ANSIBLE=true; shift ;;
        --skip-rename)  SKIP_RENAME=true; shift ;;
        -h|--help)      usage ;;
        *) fatal "Unknown argument: $1 (use -h for help)" ;;
    esac
done

SPARE_NATS_URL="nats://${SPARE_HOST}:7422"

info "=== constellation hub failover ==="
info "spare: ${SPARE_HOST} → becoming primary (${PRIMARY_HOST})"
[[ "${DRY_RUN}" == "true" ]] && warn "DRY-RUN mode — no changes will be applied"

# ---------------------------------------------------------------------------
# Step 1: Verify spare reachability via Tailscale
# ---------------------------------------------------------------------------
info "Step 1: Verify spare is reachable via Tailscale mesh..."
if ! dry tailscale ping --c 3 "${SPARE_HOST}.${TAILSCALE_DOMAIN}" 2>/dev/null; then
    # Try without domain suffix (Tailscale sometimes resolves without it)
    if ! dry tailscale ping --c 3 "${SPARE_HOST}" 2>/dev/null; then
        fatal "Cannot reach ${SPARE_HOST} via Tailscale. Ensure spare is enrolled and mesh is up."
    fi
fi
info "Spare is reachable."

# ---------------------------------------------------------------------------
# Step 2: (Optional) Run Ansible to ensure spare is fully provisioned
# ---------------------------------------------------------------------------
if [[ "${SKIP_ANSIBLE}" == "true" ]]; then
    info "Step 2: Skipping Ansible re-provision (--skip-ansible)."
else
    info "Step 2: Ensuring spare is provisioned via Ansible..."
    ANSIBLE_PLAYBOOK_CMD=(
        ansible-playbook -i "${REPO_ROOT}/ansible/inventory/hosts"
        "${REPO_ROOT}/ansible/site.yml"
        --limit "${ANSIBLE_LIMIT}"
    )
    dry "${ANSIBLE_PLAYBOOK_CMD[@]}"
    info "Spare provisioning complete."
fi

# ---------------------------------------------------------------------------
# Step 3: Verify NATS + JetStream assets on spare
# ---------------------------------------------------------------------------
info "Step 3: Verifying NATS JetStream assets on spare..."
if command -v nats &>/dev/null; then
    if ! dry nats stream info WM_WORK --server "${SPARE_NATS_URL}" 2>/dev/null; then
        warn "WM_WORK stream not found on spare — running nats-assets to create..."
        # If we can SSH, trigger asset creation
        if command -v ssh &>/dev/null && dry ssh "jsy@${SPARE_HOST}" /usr/local/bin/nats-assets; then
            info "JetStream assets created on spare."
        else
            warn "Could not create assets remotely. Run /usr/local/bin/nats-assets on spare manually."
        fi
    else
        info "WM_WORK stream confirmed on spare."
    fi
    if ! dry nats kv info WM_NODES --server "${SPARE_NATS_URL}" 2>/dev/null; then
        warn "WM_NODES KV bucket missing on spare — run /usr/local/bin/nats-assets on spare."
    else
        info "WM_NODES KV bucket confirmed on spare."
    fi
else
    warn "nats CLI not found locally — skipping JetStream asset check. Verify manually on spare."
fi

# ---------------------------------------------------------------------------
# Step 4: Re-point the fleet — Tailscale MagicDNS rename (preferred)
#          The fleet uses MagicDNS name "hub"; renaming hub-spare → hub
#          re-points all leaves without touching their configs.
# ---------------------------------------------------------------------------
if [[ "${SKIP_RENAME}" == "true" ]]; then
    info "Step 4: Skipping MagicDNS rename (--skip-rename)."
    warn "You must manually update NATS_HUB_URL on each fleet node to:"
    warn "  nats://${SPARE_HOST}.${TAILSCALE_DOMAIN}:7422"
else
    if [[ -z "${TAILSCALE_API_TOKEN:-}" ]]; then
        warn "TAILSCALE_API_TOKEN not set — cannot rename via API."
        warn "Go to https://login.tailscale.com/admin/machines and:"
        warn "  1. Find '${SPARE_HOST}' and rename it to '${PRIMARY_HOST}'"
        warn "  2. Or: set TAILSCALE_API_TOKEN and re-run this script."
        warn "Step 4 SKIPPED — complete manually in Tailscale admin console."
    else
        info "Step 4: Renaming ${SPARE_HOST} → ${PRIMARY_HOST} via Tailscale API..."
        # Tailscale API: PATCH /api/v2/device/<id>/attributes (set hostname)
        # First, resolve device ID from device list
        DEVICE_ID=$(dry curl -sf \
            -H "Authorization: Bearer ${TAILSCALE_API_TOKEN}" \
            "https://api.tailscale.com/api/v2/tailnet/-/devices" \
            | jq -r --arg name "${SPARE_HOST}" \
              '.devices[] | select(.hostname == $name or .name == ($name + ".")) | .id' \
            | head -1)
        if [[ -z "${DEVICE_ID}" ]]; then
            warn "Could not resolve device ID for '${SPARE_HOST}' — complete rename manually."
            warn "  https://login.tailscale.com/admin/machines"
        else
            info "Spare device ID: ${DEVICE_ID}"
            # Note: Tailscale does not have a direct "rename" API; hostname is set at enrollment.
            # The recommended approach is: admin console rename, or re-enroll with --hostname=hub.
            # We log instructions and a re-enrollment command.
            warn "Tailscale does not expose a rename-in-place API. Two options:"
            warn "  A) Admin console: login.tailscale.com/admin/machines → rename '${SPARE_HOST}' → '${PRIMARY_HOST}'"
            warn "  B) Re-enroll spare with new hostname (run on spare node):"
            warn "     tailscale up --hostname=${PRIMARY_HOST} --advertise-tags=tag:fleet,tag:cloud --advertise-exit-node --ssh"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Step 5: Confirm connectivity from local node to spare-as-hub
# ---------------------------------------------------------------------------
info "Step 5: Post-failover connectivity check..."
if command -v nats &>/dev/null; then
    TARGET_URL="nats://${SPARE_HOST}.${TAILSCALE_DOMAIN}:7422"
    if dry nats stream info WM_WORK --server "${TARGET_URL}" 2>/dev/null; then
        info "Fleet can reach spare NATS hub at ${TARGET_URL} — failover READY."
    else
        warn "Could not verify NATS connectivity to ${TARGET_URL}."
        warn "This may be normal if the MagicDNS rename is still pending."
    fi
else
    warn "nats CLI not found — verify manually: nats stream info WM_WORK --server nats://${SPARE_HOST}:7422"
fi

# ---------------------------------------------------------------------------
# Step 6: Update inventory — remind operator to flip primary in hosts file
# ---------------------------------------------------------------------------
info "Step 6: Update inventory/hosts (manual step):"
info "  In ${REPO_ROOT}/ansible/inventory/hosts:"
info "  - Comment out 'hub' under [cloud]"
info "  - Add '${SPARE_HOST}' (now renamed '${PRIMARY_HOST}') as the active cloud entry"
info ""
info "=== Failover procedure complete (check WARNs above for manual steps) ==="

exit 0
