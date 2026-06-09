#!/usr/bin/env bash
# headscale-switch — switch mesh enrollment between Tailscale SaaS and self-hosted Headscale.
#
# This is a documentation + validation helper, not a live-network modifier.
# The actual switch is performed by re-running `constellation mesh enroll`
# with or without the --headscale flag (AC8).
#
# Usage:
#   headscale-switch.sh saas             — print switch-to-SaaS instructions
#   headscale-switch.sh self [--url URL] — print switch-to-Headscale instructions
#   headscale-switch.sh status           — print current enrollment target
set -uo pipefail
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENROLL_SCRIPT="$REPO_ROOT/mesh/scripts/enroll.sh"

DEFAULT_HS_URL="${HEADSCALE_URL:-https://hub.constellation.internal}"

usage() {
    grep '^#[^!]' "$0" | head -15 | sed 's/^# \?//'
    exit 0
}

if [[ $# -eq 0 ]]; then usage; fi

SUBCMD="$1"; shift

print_tradeoffs() {
    cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SOVEREIGNTY vs OPERATIONAL SIMPLICITY — choose consciously
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Tailscale SaaS (default)
  ─────────────────────────
  + Zero ops overhead — Tailscale runs the control plane
  + Automatic DERP relay globally distributed
  + Instant key rotation via Tailscale admin panel
  + Free for personal use (up to 3 users, 100 devices)
  - Control plane is third-party (Tailscale Inc.)
  - Node roster / ACLs visible to Tailscale

  Headscale (self-hosted, this fleet)
  ─────────────────────────────────────
  + Full sovereignty — you own the control plane
  + No dependency on external SaaS availability
  + Keys and roster never leave the fleet
  + ACL policy is a committed file in this repo
  - Requires the cloud node to be up and healthy
  - You operate and upgrade Headscale
  - DERP relay: Tailscale's public relays still work (or run your own)

DECISION: if the cloud node is the single point of failure you care about
most, use Tailscale SaaS. If control-plane sovereignty matters more than
ops simplicity for this fleet, use Headscale.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF
}

case "$SUBCMD" in
    saas)
        print_tradeoffs
        cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SWITCH TO: Tailscale SaaS (remove --headscale flag)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

On each fleet node, run:

  # 1. Leave the current network
  sudo tailscale logout

  # 2. Re-enroll via Tailscale SaaS (no --headscale flag)
  $ENROLL_SCRIPT --role <laptop|desktop|cloud>

  # The auth key for SaaS re-enrollment must be in the pass store at:
  #   constellation/tailscale/auth-key-<role>
  # Get it from: https://login.tailscale.com/admin/settings/keys

  # 3. Verify
  $REPO_ROOT/mesh/scripts/status.sh

This is reversible at any time by switching back to Headscale (see below).
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;

    self)
        HS_URL="$DEFAULT_HS_URL"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --url) HS_URL="$2"; shift 2 ;;
                *) shift ;;
            esac
        done

        print_tradeoffs
        cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SWITCH TO: Self-hosted Headscale at $HS_URL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Prerequisites:
  1. Headscale is provisioned on the cloud node:
       ansible-playbook -i inventory/hosts headscale.yml
  2. Pre-auth keys are minted for each role:
       constellation headscale preauth --role laptop
       constellation headscale preauth --role desktop
       constellation headscale preauth --role cloud
  3. The cloud node is reachable from each enrolling node.

On each fleet node, run:

  # 1. Leave the current network
  sudo tailscale logout

  # 2. Re-enroll via the self-hosted Headscale control plane
  $ENROLL_SCRIPT --role <laptop|desktop|cloud> --headscale $HS_URL

  # The --headscale flag passes --login-server=<url> to 'tailscale up',
  # which is the standard Tailscale mechanism to redirect to any control server.

  # 3. Verify
  $REPO_ROOT/mesh/scripts/status.sh
  constellation headscale status

Notes:
- MagicDNS names change from *.ts.net to *.constellation.internal (see mesh docs).
- DERP relay: Tailscale's public relays continue to work under Headscale by default.
- This switch is reversible: run 'constellation headscale switch saas' to revert.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;

    status)
        # Check which control server tailscale is currently pointed at
        if ! command -v tailscale &>/dev/null; then
            echo "[headscale-switch] tailscale not installed on this node."
            exit 0
        fi

        TS_BACKEND="$(tailscale status --json 2>/dev/null \
            | python3 -c "
import sys, json
d = json.load(sys.stdin)
cs = d.get('CurrentTailnet', {}).get('MagicDNSSuffix', '')
# Check for headscale: headscale uses a custom base domain
if 'ts.net' in cs or not cs:
    print('tailscale-saas')
else:
    print('headscale (' + cs + ')')
" 2>/dev/null || echo "unknown")"

        echo "Current enrollment target: $TS_BACKEND"
        echo "To switch: constellation headscale switch [saas|self]"
        ;;

    -h|--help|help)
        usage
        ;;

    *)
        echo "Unknown subcommand: $SUBCMD" >&2
        usage
        ;;
esac
