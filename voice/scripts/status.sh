#!/usr/bin/env bash
# constellation voice status — report expected vs actual voice front-end state.
#
# Reads the per-host role flag from Ansible host_vars (or the local hostname)
# and compares it to the live systemd unit states.
#
# Exit codes:
#   0  state matches expectation (voice up on voice node, down on compute node)
#   1  mismatch (voice running where it shouldn't, or absent where it should run)
#   2  usage / argument error
#
# Options:
#   --json          emit JSON instead of human-readable output
#   --host <name>   check a specific host_vars/<name>.yml instead of localhost
#   --ansible-dir <path>  path to the ansible directory (default: auto-detected)
#   --dry-run       alias for offline inspection (reads files only, no systemctl)
#
# SIGPIPE-safe: stdout writes are checked so a `| head` pipeline never panics.
set -uo pipefail

# SIGPIPE safety: ignore broken pipe rather than dying with a non-zero exit
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"

JSON=false
HOST=""
DRY_RUN=false

usage() {
    cat <<'EOF'
constellation voice status — check per-host voice front-end state

Usage:
  constellation-voice status [options]

Options:
  --json              emit JSON output
  --host <name>       check host_vars/<name>.yml instead of localhost
  --ansible-dir <dir> path to ansible directory (auto-detected by default)
  --dry-run           offline: read role flag from host_vars only, skip systemctl

Exit codes:
  0  expected state matches actual state
  1  mismatch (voice running where not expected, or absent where expected)
  2  usage / missing host_vars
EOF
}

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)       JSON=true;             shift ;;
        --dry-run)    DRY_RUN=true;          shift ;;
        --host)       HOST="${2:-}";         shift 2 ;;
        --ansible-dir) ANSIBLE_DIR="${2:-}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# ── Resolve hostname ────────────────────────────────────────────────────────
if [[ -z "$HOST" ]]; then
    HOST="$(hostname -s 2>/dev/null || hostname)"
fi

HOST_VARS="${ANSIBLE_DIR}/host_vars/${HOST}.yml"
GROUP_VARS_ALL="${ANSIBLE_DIR}/group_vars/all.yml"

# ── Read voice_node flag from host_vars or group_vars/all ──────────────────
voice_node_expected=false
flag_source="group_vars/all.yml (default)"

if [[ -f "$HOST_VARS" ]]; then
    raw="$(grep -E '^\s*voice_node\s*:' "$HOST_VARS" | head -1 | awk -F: '{print $2}' | tr -d ' ')"
    if [[ -n "$raw" ]]; then
        if [[ "$raw" == "true" ]]; then
            voice_node_expected=true
        else
            voice_node_expected=false
        fi
        flag_source="host_vars/${HOST}.yml"
    fi
elif [[ -f "$GROUP_VARS_ALL" ]]; then
    raw="$(grep -E '^\s*voice_node\s*:' "$GROUP_VARS_ALL" | head -1 | awk -F: '{print $2}' | tr -d ' ')"
    if [[ "$raw" == "true" ]]; then
        voice_node_expected=true
    fi
else
    printf 'ERROR: neither host_vars/%s.yml nor group_vars/all.yml found under %s\n' \
        "$HOST" "$ANSIBLE_DIR" >&2
    exit 2
fi

# ── Voice front-end units to check ─────────────────────────────────────────
VOICE_UNITS=(
    wm-audio.service
    wm-stt.service
    wm-wake.service
    wm-vad.service
)

# ── Check actual unit states ────────────────────────────────────────────────
declare -A unit_enabled
declare -A unit_active

for unit in "${VOICE_UNITS[@]}"; do
    if $DRY_RUN; then
        unit_enabled["$unit"]="unknown (dry-run)"
        unit_active["$unit"]="unknown (dry-run)"
    else
        enabled_state="$(systemctl --user is-enabled "$unit" 2>/dev/null || true)"
        active_state="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
        unit_enabled["$unit"]="${enabled_state:-unknown}"
        unit_active["$unit"]="${active_state:-unknown}"
    fi
done

# ── Determine mismatch ──────────────────────────────────────────────────────
mismatch=false

if $DRY_RUN; then
    # Offline mode: trust the flag only
    mismatch=false
else
    for unit in "${VOICE_UNITS[@]}"; do
        active="${unit_active[$unit]}"
        if $voice_node_expected; then
            # voice node: units should be active (or at least enabled)
            enabled="${unit_enabled[$unit]}"
            if [[ "$enabled" == "disabled" ]]; then
                mismatch=true
                break
            fi
        else
            # compute/cloud node: units should NOT be active
            if [[ "$active" == "active" ]]; then
                mismatch=true
                break
            fi
        fi
    done
fi

# ── Coordination stack (always-on, unaffected by voice_node) ───────────────
COORD_UNITS=(
    agorabus.service
)

declare -A coord_active
for unit in "${COORD_UNITS[@]}"; do
    if $DRY_RUN; then
        coord_active["$unit"]="unknown (dry-run)"
    else
        coord_active["$unit"]="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
    fi
done

# ── Output ──────────────────────────────────────────────────────────────────
if $JSON; then
    # Build JSON output — SIGPIPE-safe printf approach
    printf '{\n'
    printf '  "host": "%s",\n' "$HOST"
    printf '  "voice_node_expected": %s,\n' "$voice_node_expected"
    printf '  "flag_source": "%s",\n' "$flag_source"
    printf '  "mismatch": %s,\n' "$mismatch"
    printf '  "voice_frontend_units": {\n'
    count=0
    total=${#VOICE_UNITS[@]}
    for unit in "${VOICE_UNITS[@]}"; do
        count=$((count + 1))
        comma=""
        [[ $count -lt $total ]] && comma=","
        printf '    "%s": {"enabled": "%s", "active": "%s"}%s\n' \
            "$unit" "${unit_enabled[$unit]}" "${unit_active[$unit]}" "$comma"
    done
    printf '  },\n'
    printf '  "coordination_units": {\n'
    count=0
    total=${#COORD_UNITS[@]}
    for unit in "${COORD_UNITS[@]}"; do
        count=$((count + 1))
        comma=""
        [[ $count -lt $total ]] && comma=","
        printf '    "%s": {"active": "%s"}%s\n' \
            "$unit" "${coord_active[$unit]}" "$comma"
    done
    printf '  }\n'
    printf '}\n'
else
    printf '=== constellation voice status: %s ===\n' "$HOST"
    printf 'voice_node (expected): %s  [%s]\n' "$voice_node_expected" "$flag_source"
    printf '\nVoice front-end units:\n'
    for unit in "${VOICE_UNITS[@]}"; do
        printf '  %-28s  enabled=%-12s  active=%s\n' \
            "$unit" "${unit_enabled[$unit]}" "${unit_active[$unit]}"
    done
    printf '\nCoordination stack (always-on, not gated by voice_node):\n'
    for unit in "${COORD_UNITS[@]}"; do
        printf '  %-28s  active=%s\n' "$unit" "${coord_active[$unit]}"
    done
    printf '\n'
    if $mismatch; then
        if $voice_node_expected; then
            printf 'STATUS: MISMATCH — voice front-end expected UP but one or more units are disabled.\n'
        else
            printf 'STATUS: MISMATCH — voice front-end expected DOWN but one or more units are active.\n'
        fi
    else
        if $DRY_RUN; then
            printf 'STATUS: OK (dry-run — unit states not checked)\n'
        else
            printf 'STATUS: OK — actual state matches expectation\n'
        fi
    fi
fi

$mismatch && exit 1 || exit 0
