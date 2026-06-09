#!/usr/bin/env bash
# headscale-acl-assert — assert that the deployed Headscale ACL is derived from
# the mesh canonical policy (AC3).
#
# Verifies byte-equivalence between:
#   mesh/config/acl-policy.hujson  (source of truth)
#   /etc/headscale/acl.hujson      (deployed copy on this node)
#
# Usage: headscale-acl-assert.sh [--deployed-path /etc/headscale/acl.hujson]
set -uo pipefail
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MESH_ACL="$REPO_ROOT/mesh/config/acl-policy.hujson"
DEPLOYED_ACL="${HEADSCALE_ACL_PATH:-/etc/headscale/acl.hujson}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deployed-path) DEPLOYED_ACL="$2"; shift 2 ;;
        -h|--help)
            grep '^#[^!]' "$0" | head -12 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

log()  { echo "[headscale-acl-assert] $*"; }
die()  { echo "[headscale-acl-assert] FAIL: $*" >&2; exit 1; }

# ── Source file must exist ────────────────────────────────────────────────────
if [[ ! -f "$MESH_ACL" ]]; then
    die "Canonical mesh ACL not found: $MESH_ACL"
fi

# ── Deployed file must exist ─────────────────────────────────────────────────
if [[ ! -f "$DEPLOYED_ACL" ]]; then
    die "Deployed headscale ACL not found: $DEPLOYED_ACL"
fi

# ── Byte-equivalence check ───────────────────────────────────────────────────
if diff -q "$MESH_ACL" "$DEPLOYED_ACL" > /dev/null; then
    log "PASS: Deployed ACL is byte-equivalent to mesh canonical policy."
    log "  Source:   $MESH_ACL"
    log "  Deployed: $DEPLOYED_ACL"
    exit 0
else
    log "FAIL: Deployed ACL differs from mesh canonical policy!"
    log "  Source:   $MESH_ACL"
    log "  Deployed: $DEPLOYED_ACL"
    log ""
    log "Diff:"
    diff "$MESH_ACL" "$DEPLOYED_ACL" || true
    log ""
    log "Fix: Re-run the headscale Ansible role to sync the ACL:"
    log "  ansible-playbook -i inventory/hosts headscale.yml"
    exit 1
fi
