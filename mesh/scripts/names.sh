#!/usr/bin/env bash
# constellation mesh names — print the canonical fleet name map (role → MagicDNS name).
# Usage: names.sh [--format <table|json|env>] [--tailnet <name>]
#
# Reads from the live tailscale status (if available) and falls back to the
# config/fleet-nodes.conf file. Downstream layers (bus, brain, dispatch) source
# the "env" format to get stable endpoint variables.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$REPO_ROOT/mesh/config"

FORMAT="${1:-table}"
TAILNET="${CONSTELLATION_TAILNET:-}"

# ── Helpers ──────────────────────────────────────────────────────────────────
die() { echo "[constellation-mesh] ERROR: $*" >&2; exit 1; }

# ── Parse --format and --tailnet flags if given ───────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --format)  FORMAT="$2"; shift 2 ;;
        --tailnet) TAILNET="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -10 | sed 's/^# \?//'
            exit 0
            ;;
        *) shift ;;  # ignore positional args already consumed
    esac
done

# ── Load fleet node config ────────────────────────────────────────────────────
# Config format:  role <TAB> hostname [<TAB> description]
# e.g.:
#   cloud     hub              cloud VPS / NATS hub
#   desktop   forge            home desktop / GPU node
#   laptop    nomad            roaming dev machine
FLEET_CONF="$CONFIG_DIR/fleet-nodes.conf"
[[ -f "$FLEET_CONF" ]] || die "Fleet config not found: $FLEET_CONF"

declare -A ROLE_HOST=()
declare -A ROLE_DESC=()

while IFS=$'\t' read -r role hostname desc; do
    [[ "$role" =~ ^#|^[[:space:]]*$ ]] && continue
    ROLE_HOST["$role"]="$hostname"
    ROLE_DESC["$role"]="${desc:-}"
done < "$FLEET_CONF"

# ── Resolve MagicDNS names ────────────────────────────────────────────────────
# If tailscale is running, confirm live hostnames match. Otherwise just
# compute them from the config.
resolve_magicDNS() {
    local hostname="$1"
    if [[ -n "$TAILNET" ]]; then
        # Explicit tailnet suffix
        echo "${hostname}.${TAILNET}"
    elif command -v tailscale &>/dev/null 2>&1; then
        # Ask tailscale what our tailnet domain is
        local domain
        domain="$(tailscale status --json 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MagicDNSSuffix',''))" 2>/dev/null || true)"
        if [[ -n "$domain" ]]; then
            echo "${hostname}.${domain}"
        else
            echo "$hostname"   # fallback: bare hostname
        fi
    else
        echo "$hostname"
    fi
}

# ── Output ────────────────────────────────────────────────────────────────────
case "$FORMAT" in
    table)
        printf "%-12s  %-30s  %s\n" "ROLE" "MAGICDNS NAME" "DESCRIPTION"
        printf "%-12s  %-30s  %s\n" "----" "-------------" "-----------"
        for role in cloud desktop laptop; do
            [[ -n "${ROLE_HOST[$role]:-}" ]] || continue
            fqdn="$(resolve_magicDNS "${ROLE_HOST[$role]}")"
            printf "%-12s  %-30s  %s\n" "$role" "$fqdn" "${ROLE_DESC[$role]:-}"
        done
        ;;
    json)
        echo "{"
        first=true
        for role in cloud desktop laptop; do
            [[ -n "${ROLE_HOST[$role]:-}" ]] || continue
            fqdn="$(resolve_magicDNS "${ROLE_HOST[$role]}")"
            [[ "$first" == "true" ]] || echo ","
            first=false
            printf '  "%s": {"hostname": "%s", "fqdn": "%s", "description": "%s"}' \
                "$role" "${ROLE_HOST[$role]}" "$fqdn" "${ROLE_DESC[$role]:-}"
        done
        echo ""
        echo "}"
        ;;
    env)
        for role in cloud desktop laptop; do
            [[ -n "${ROLE_HOST[$role]:-}" ]] || continue
            fqdn="$(resolve_magicDNS "${ROLE_HOST[$role]}")"
            upper_role="${role^^}"
            echo "CONSTELLATION_${upper_role}_HOST=${ROLE_HOST[$role]}"
            echo "CONSTELLATION_${upper_role}_FQDN=$fqdn"
        done
        ;;
    *)
        die "Unknown format '$FORMAT'. Choose: table, json, env"
        ;;
esac
