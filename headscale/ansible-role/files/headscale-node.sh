#!/usr/bin/env bash
# headscale-node — manage node lifecycle (register / list / expire / delete).
#
# A deleted node no longer appears in the roster (AC7).
#
# Usage:
#   headscale-node.sh list                    — list all registered nodes
#   headscale-node.sh register <name> <key>   — register node by machine key
#   headscale-node.sh expire <name|id>        — expire a node (prevents reconnect)
#   headscale-node.sh delete <name|id>        — delete node from roster entirely
#   headscale-node.sh show <name|id>          — show details for a single node
set -uo pipefail
trap '' PIPE

HEADSCALE_BIN="${HEADSCALE_BIN:-headscale}"
HS_USER="${HEADSCALE_USER:-constellation}"

usage() {
    grep '^#[^!]' "$0" | head -18 | sed 's/^# \?//'
    exit 0
}

log() { echo "[headscale-node] $*"; }
die() { echo "[headscale-node] ERROR: $*" >&2; exit 1; }

if [[ $# -eq 0 ]]; then usage; fi

# ── Binary check ──────────────────────────────────────────────────────────────
if ! command -v "$HEADSCALE_BIN" &>/dev/null; then
    die "headscale binary not found: $HEADSCALE_BIN"
fi

SUBCMD="$1"
shift

case "$SUBCMD" in
    list)
        log "Registered nodes:"
        if command -v jq &>/dev/null; then
            "$HEADSCALE_BIN" nodes list -o json \
                | jq -r '.[] | "\(.id)\t\(.name)\t\(.ip_addresses[0] // "?")\tonline=\(.online)\texpiry=\(.expiry // "never")"'
        else
            "$HEADSCALE_BIN" nodes list
        fi
        ;;

    register)
        NAME="${1:-}"
        KEY="${2:-}"
        [[ -z "$NAME" ]] && die "Usage: register <name> <machine-key>"
        [[ -z "$KEY" ]]  && die "Usage: register <name> <machine-key>"
        log "Registering node '$NAME' with key $KEY (user: $HS_USER)..."
        "$HEADSCALE_BIN" nodes register \
            --user "$HS_USER" \
            --key "$KEY"
        log "Registration submitted for '$NAME'. Verify with: headscale-node.sh list"
        ;;

    expire)
        TARGET="${1:-}"
        [[ -z "$TARGET" ]] && die "Usage: expire <name|id>"
        log "Expiring node: $TARGET..."
        # Try by name first, then by numeric ID
        if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
            "$HEADSCALE_BIN" nodes expire --identifier "$TARGET"
        else
            # Look up by name
            NODE_ID="$("$HEADSCALE_BIN" nodes list -o json 2>/dev/null \
                | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
for n in nodes:
    if n.get('name') == '$TARGET':
        print(n['id'])
        break
" 2>/dev/null || true)"
            if [[ -z "$NODE_ID" ]]; then
                die "Node not found: $TARGET"
            fi
            "$HEADSCALE_BIN" nodes expire --identifier "$NODE_ID"
        fi
        log "Node '$TARGET' expired."
        log "Verify with: headscale-node.sh list"
        ;;

    delete)
        TARGET="${1:-}"
        [[ -z "$TARGET" ]] && die "Usage: delete <name|id>"
        log "Deleting node: $TARGET..."

        # Resolve by name to ID if needed
        NODE_ID=""
        if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
            NODE_ID="$TARGET"
        else
            NODE_ID="$("$HEADSCALE_BIN" nodes list -o json 2>/dev/null \
                | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
for n in nodes:
    if n.get('name') == '$TARGET':
        print(n['id'])
        break
" 2>/dev/null || true)"
            if [[ -z "$NODE_ID" ]]; then
                die "Node not found: $TARGET"
            fi
        fi

        "$HEADSCALE_BIN" nodes delete --identifier "$NODE_ID" --output json

        # Assert it no longer appears in the roster (AC7)
        log "Verifying deletion..."
        ROSTER_AFTER="$("$HEADSCALE_BIN" nodes list -o json 2>/dev/null)"
        if echo "$ROSTER_AFTER" | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
ids = {str(n['id']) for n in nodes}
names = {n.get('name','') for n in nodes}
target = '$TARGET'
if target in ids or target in names:
    sys.exit(1)
" 2>/dev/null; then
            log "PASS: Node '$TARGET' no longer in roster."
        else
            log "WARN: Node '$TARGET' may still appear in roster — check manually."
            exit 1
        fi
        ;;

    show)
        TARGET="${1:-}"
        [[ -z "$TARGET" ]] && die "Usage: show <name|id>"
        "$HEADSCALE_BIN" nodes list -o json 2>/dev/null \
            | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
for n in nodes:
    if str(n.get('id','')) == '$TARGET' or n.get('name') == '$TARGET':
        import pprint; pprint.pprint(n)
        sys.exit(0)
print('Node not found: $TARGET', file=sys.stderr)
sys.exit(1)
"
        ;;

    -h|--help|help)
        usage
        ;;

    *)
        echo "Unknown subcommand: $SUBCMD" >&2
        usage
        ;;
esac
