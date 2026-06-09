#!/usr/bin/env bash
# headscale-status — report server up + DB reachable + registered node roster.
#
# Exits 0 if all checks pass.
# Exits 1 if server is unreachable or DB unreadable.
# Exits 2 if headscale binary not found.
#
# Usage: headscale-status.sh [--json] [--quiet]
set -uo pipefail
trap '' PIPE

QUIET=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) QUIET=true;       shift ;;
        --json)  JSON_OUTPUT=true; shift ;;
        -h|--help)
            grep '^#[^!]' "$0" | head -10 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

log()  { [[ "$QUIET" == "false" ]] && echo "[headscale-status] $*" || true; }
ok()   { log "  OK    $*"; }
fail() { log "  FAIL  $*"; }

HEADSCALE_BIN="${HEADSCALE_BIN:-headscale}"

# ── 1. Binary check ───────────────────────────────────────────────────────────
if ! command -v "$HEADSCALE_BIN" &>/dev/null; then
    echo "[headscale-status] ERROR: headscale binary not found at: $HEADSCALE_BIN" >&2
    exit 2
fi

# ── 2. Service alive check ────────────────────────────────────────────────────
server_up=false
service_status=""
if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet headscale 2>/dev/null; then
        server_up=true
        service_status="active"
    else
        service_status="$(systemctl is-active headscale 2>/dev/null || echo 'unknown')"
    fi
else
    # Fallback: try talking to headscale via CLI
    if "$HEADSCALE_BIN" version &>/dev/null 2>&1; then
        server_up=true
        service_status="running"
    else
        service_status="unknown"
    fi
fi

if [[ "$server_up" == "true" ]]; then
    ok "headscale service ($service_status)"
else
    fail "headscale service ($service_status)"
fi

# ── 3. DB reachability — try listing nodes (exercises DB) ────────────────────
db_reachable=false
nodes_json=""
if [[ "$server_up" == "true" ]]; then
    if nodes_json="$("$HEADSCALE_BIN" nodes list -o json 2>/dev/null)"; then
        db_reachable=true
        ok "DB reachable"
    else
        fail "DB unreachable (headscale nodes list failed)"
    fi
else
    fail "DB check skipped (service not running)"
fi

# ── 4. Node roster ────────────────────────────────────────────────────────────
node_count=0
roster_text=""
if [[ "$db_reachable" == "true" && -n "$nodes_json" ]]; then
    # Parse node list; headscale outputs JSON array of node objects.
    # Each node has: id, machine_key, node_key, name, user, ip_addresses, online, etc.
    if command -v jq &>/dev/null; then
        node_count="$(echo "$nodes_json" | jq 'length')"
        roster_text="$(echo "$nodes_json" | jq -r '.[] | "    \(.name)\t\(.ip_addresses[0] // "?")\tonline=\(.online)"' 2>/dev/null || true)"
    else
        # Fallback without jq
        node_count="$(echo "$nodes_json" | grep -o '"name"' | wc -l)"
        roster_text="(install jq for detailed roster)"
    fi
    log "Registered nodes: $node_count"
    if [[ -n "$roster_text" ]]; then
        log "$roster_text"
    fi
fi

# ── 5. Determine exit code ────────────────────────────────────────────────────
overall_ok=false
if [[ "$server_up" == "true" && "$db_reachable" == "true" ]]; then
    overall_ok=true
fi

# ── 6. JSON output ────────────────────────────────────────────────────────────
if [[ "$JSON_OUTPUT" == "true" ]]; then
    printf '{\n'
    printf '  "server_up": %s,\n' "$server_up"
    printf '  "service_status": "%s",\n' "$service_status"
    printf '  "db_reachable": %s,\n' "$db_reachable"
    printf '  "node_count": %d,\n' "$node_count"
    if [[ "$db_reachable" == "true" && -n "$nodes_json" ]]; then
        printf '  "nodes": %s,\n' "$nodes_json"
    else
        printf '  "nodes": [],\n'
    fi
    printf '  "healthy": %s\n' "$overall_ok"
    printf '}\n'
fi

if [[ "$overall_ok" == "true" ]]; then
    log "Headscale healthy."
    exit 0
else
    log "Headscale UNHEALTHY — check above."
    exit 1
fi
