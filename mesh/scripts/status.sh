#!/usr/bin/env bash
# constellation mesh status — verify every expected fleet node is present,
# reachable by MagicDNS name, and within ACL.
# Exits 0 if fleet is complete, non-zero if any node is absent/unreachable.
#
# Usage: status.sh [--quiet] [--json]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$REPO_ROOT/mesh/config"

QUIET=false
JSON_OUTPUT=false
EXIT_CODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) QUIET=true;       shift ;;
        --json)  JSON_OUTPUT=true; shift ;;
        -h|--help)
            grep '^#' "$0" | head -10 | sed 's/^# \?//'
            exit 0
            ;;
        *) shift ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
log()    { [[ "$QUIET" == "false" ]] && echo "[constellation-mesh] $*"; }
ok()     { log "  OK      $*"; }
warn()   { log "  WARN    $*"; EXIT_CODE=1; }
fail()   { log "  MISSING $*"; EXIT_CODE=1; }

# ── Require tailscale ─────────────────────────────────────────────────────────
if ! command -v tailscale &>/dev/null; then
    echo "[constellation-mesh] ERROR: tailscale not installed." >&2
    exit 2
fi

# ── Load fleet config ─────────────────────────────────────────────────────────
FLEET_CONF="$CONFIG_DIR/fleet-nodes.conf"
if [[ ! -f "$FLEET_CONF" ]]; then
    echo "[constellation-mesh] ERROR: Fleet config not found: $FLEET_CONF" >&2
    exit 2
fi

declare -A ROLE_HOST=()
while IFS=$'\t' read -r role hostname _; do
    [[ "$role" =~ ^#|^[[:space:]]*$ ]] && continue
    ROLE_HOST["$role"]="$hostname"
done < "$FLEET_CONF"

# ── Get live tailscale status ─────────────────────────────────────────────────
TS_STATUS_JSON="$(tailscale status --json 2>/dev/null)" || {
    echo "[constellation-mesh] ERROR: tailscale status failed (daemon not running?)" >&2
    exit 2
}

MAGIC_SUFFIX="$(echo "$TS_STATUS_JSON" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MagicDNSSuffix',''))" 2>/dev/null || true)"

# Build a set of online hostnames from tailscale status
ONLINE_HOSTS="$(echo "$TS_STATUS_JSON" | \
    python3 -c "
import sys, json
d = json.load(sys.stdin)
peers = d.get('Peer', {})
self_node = d.get('Self', {})
names = set()
# Self
if self_node.get('HostName'):
    names.add(self_node['HostName'].lower())
# Peers
for p in peers.values():
    if p.get('HostName'):
        names.add(p['HostName'].lower())
print('\n'.join(sorted(names)))
" 2>/dev/null || true)"

# ── Check each expected node ──────────────────────────────────────────────────
declare -A NODE_STATUS=()

log "Constellation mesh status (tailnet suffix: ${MAGIC_SUFFIX:-unknown})"
log "---"

for role in cloud desktop laptop; do
    hostname="${ROLE_HOST[$role]:-}"
    if [[ -z "$hostname" ]]; then
        log "  SKIP    $role (not in fleet config)"
        NODE_STATUS["$role"]="not_configured"
        continue
    fi

    fqdn="${hostname}"
    [[ -n "$MAGIC_SUFFIX" ]] && fqdn="${hostname}.${MAGIC_SUFFIX}"

    # 1. Check if node appears in tailscale status
    if echo "$ONLINE_HOSTS" | grep -qi "^${hostname}$"; then
        # 2. Ping by MagicDNS name (1 packet, 3s timeout)
        if ping -c1 -W3 "$fqdn" &>/dev/null 2>&1 || ping -c1 -W3 "$hostname" &>/dev/null 2>&1; then
            ok "$role → $fqdn (reachable)"
            NODE_STATUS["$role"]="ok"
        else
            warn "$role → $fqdn (visible in tailscale but ping failed — ACL or relay issue?)"
            NODE_STATUS["$role"]="visible_not_reachable"
        fi
    else
        fail "$role → $hostname (absent from tailscale status)"
        NODE_STATUS["$role"]="absent"
    fi
done

log "---"

# ── JSON output ───────────────────────────────────────────────────────────────
if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "{"
    echo "  \"tailnet_suffix\": \"${MAGIC_SUFFIX:-}\","
    echo "  \"nodes\": {"
    first=true
    for role in cloud desktop laptop; do
        hostname="${ROLE_HOST[$role]:-}"
        status="${NODE_STATUS[$role]:-not_configured}"
        [[ "$first" == "true" ]] || echo ","
        first=false
        printf '    "%s": {"hostname": "%s", "status": "%s"}' \
            "$role" "$hostname" "$status"
    done
    echo ""
    echo "  },"
    echo "  \"fleet_complete\": $([ $EXIT_CODE -eq 0 ] && echo true || echo false)"
    echo "}"
fi

if [[ $EXIT_CODE -eq 0 ]]; then
    log "Fleet complete — all expected nodes reachable."
else
    log "Fleet INCOMPLETE — some nodes absent or unreachable."
fi

exit $EXIT_CODE
