#!/usr/bin/env bash
# relocate-timers.sh — relocate fleet timers from laptop to the always-on hub.
#
# Usage: ./relocate-timers.sh [--dry-run] [--unit <name>]
#
# What it does:
#   1. Reads cloud/placement.toml to find fleet timers
#   2. Copies .timer + .service files to the hub via rsync
#   3. Enables the units on the hub
#   4. Disables the units on the laptop (no double-fire)
#
# Guards:
#   - Verifies SSH hub connectivity before touching anything
#   - ExecCondition=wm-node role hub is added to each hub service file
#     (belt-and-suspenders even if a unit ends up enabled on a non-hub node)
#
# Prerequisites (from dependent PRDs):
#   - carbon-hub-access: SSH alias "hub" must be configured and reachable
#   - carbon-node-identity: wm-node binary must be present on hub
#
# See also: cloud/docs/timer-placement.md, cloud/placement.toml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLACEMENT_TOML="$REPO_ROOT/cloud/placement.toml"
HUB_SYSTEMD_DIR="$REPO_ROOT/cloud/systemd/hub"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
HUB_REMOTE="hub"
HUB_UNIT_DIR=".config/systemd/user"
DRY_RUN=0
UNIT_FILTER=""

usage() {
    echo "Usage: $0 [--dry-run] [--unit <name>]"
    echo ""
    echo "  --dry-run    Show what would happen without making changes"
    echo "  --unit NAME  Only relocate the named timer (e.g. claude-self-review)"
    exit 1
}

log()  { echo "[relocate] $*"; }
warn() { echo "[relocate] WARN: $*" >&2; }
die()  { echo "[relocate] ERROR: $*" >&2; exit 1; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --unit)    UNIT_FILTER="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

# --- Guard: SSH hub must be reachable ---
check_hub_ssh() {
    log "Checking SSH connectivity to hub..."
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$HUB_REMOTE" true 2>/dev/null; then
        die "Cannot reach hub via SSH (alias: '$HUB_REMOTE'). " \
            "Ensure carbon-hub-access is configured and the hub is online. " \
            "Run: ssh $HUB_REMOTE true"
    fi
    log "Hub SSH OK"
}

# --- Parse fleet timers from placement.toml ---
# Simple grep-based parser (no toml library needed for this format)
get_fleet_timers() {
    grep -E '^\s*\S+\s*=\s*"hub"' "$PLACEMENT_TOML" \
        | sed 's/\s*=\s*"hub".*//' \
        | sed 's/^\s*//' \
        | sort
}

# --- Add ExecCondition to a service file ---
# Injects ExecCondition=wm-node role hub into [Service] section if not present
inject_exec_condition() {
    local src="$1"
    local dst="$2"
    local unit_name="$3"

    if grep -q 'ExecCondition=wm-node role hub' "$src" 2>/dev/null; then
        cp "$src" "$dst"
        return
    fi

    # Insert ExecCondition as first line of [Service] section
    awk '
        /^\[Service\]/ { print; print "ExecCondition=wm-node role hub"; next }
        { print }
    ' "$src" > "$dst"
    log "  Injected ExecCondition=wm-node role hub into $unit_name.service"
}

# --- Relocate a single timer ---
relocate_timer() {
    local name="$1"
    local timer_src="$SYSTEMD_USER_DIR/$name.timer"
    local service_src="$SYSTEMD_USER_DIR/$name.service"
    local hub_service_src="$HUB_SYSTEMD_DIR/$name.service"

    log "Relocating: $name"

    # Determine service source: prefer pre-modified hub version if present
    if [[ -f "$hub_service_src" ]]; then
        log "  Using pre-modified hub service: $hub_service_src"
        local effective_service="$hub_service_src"
    elif [[ -f "$service_src" ]]; then
        # Create a temp file with ExecCondition injected
        local tmp_service
        tmp_service="$(mktemp /tmp/relocate-$name.service.XXXXXX)"
        inject_exec_condition "$service_src" "$tmp_service" "$name"
        local effective_service="$tmp_service"
        trap "rm -f $tmp_service" RETURN
    else
        warn "No service file found for $name — skipping"
        return 1
    fi

    if [[ ! -f "$timer_src" ]]; then
        warn "No timer file found for $name ($timer_src) — skipping"
        return 1
    fi

    # 1. Copy units to hub
    log "  Copying $name.timer to hub:$HUB_UNIT_DIR/"
    run rsync -av "$timer_src" "$HUB_REMOTE:$HUB_UNIT_DIR/$name.timer"

    log "  Copying $name.service (with ExecCondition) to hub:$HUB_UNIT_DIR/"
    run rsync -av "$effective_service" "$HUB_REMOTE:$HUB_UNIT_DIR/$name.service"

    # 2. Enable and start on hub
    log "  Enabling $name.timer on hub"
    run ssh "$HUB_REMOTE" "systemctl --user daemon-reload && systemctl --user enable --now $name.timer"

    # 3. Disable on laptop (prevent double-fire)
    log "  Disabling $name.timer on laptop"
    run systemctl --user disable --now "$name.timer" || true

    log "  Done: $name"
}

# --- Main ---
main() {
    log "Timer relocation script"
    log "Placement config: $PLACEMENT_TOML"
    [[ $DRY_RUN -eq 1 ]] && log "DRY RUN — no changes will be made"

    check_hub_ssh

    local fleet_timers
    fleet_timers="$(get_fleet_timers)"

    if [[ -z "$fleet_timers" ]]; then
        die "No fleet timers found in $PLACEMENT_TOML"
    fi

    log "Fleet timers to relocate:"
    while IFS= read -r t; do
        log "  $t"
    done <<< "$fleet_timers"

    local failed=0
    while IFS= read -r timer; do
        if [[ -n "$UNIT_FILTER" && "$timer" != "$UNIT_FILTER" ]]; then
            continue
        fi
        relocate_timer "$timer" || ((failed++)) || true
    done <<< "$fleet_timers"

    if [[ $failed -gt 0 ]]; then
        warn "$failed timer(s) could not be relocated (see warnings above)"
        exit 1
    fi

    log ""
    log "Relocation complete."
    log "Verify on hub:  ssh hub 'systemctl --user list-timers --all'"
    log "Verify laptop:  systemctl --user list-timers --all"
}

main "$@"
