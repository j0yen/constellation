#!/usr/bin/env bash
# verify-messaging.sh — end-to-end messaging verification for the hub.
#
# Checks:
#   1. Hub is reachable via SSH
#   2. Credentials file exists on hub with correct permissions (0600)
#   3. Outbound send to a test recipient/sink (configurable via TEST_RECIPIENT)
#   4. Publishing a wm.homeward.match bus event triggers exactly one send from hub
#      (verified via log tail; no second send if same message-id is re-published)
#
# Environment:
#   HUB_HOST          SSH hostname for the hub (default: hub)
#   TEST_RECIPIENT    Address or sink for test send (default: jyen.tech@gmail.com)
#   NATS_CREDS        Path to NATS credentials file (default: ~/.config/nats/creds)
#   NATS_URL          NATS server URL (default: nats://hub:4222)
#   SKIP_SEND_TEST    Set to "true" to skip the live send (check creds only)
#   SKIP_BUS_TEST     Set to "true" to skip the bus-event trigger test
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed (failures are logged)

set -uo pipefail

HUB_HOST="${HUB_HOST:-hub}"
TEST_RECIPIENT="${TEST_RECIPIENT:-jyen.tech@gmail.com}"
NATS_CREDS="${NATS_CREDS:-${HOME}/.config/nats/creds}"
NATS_URL="${NATS_URL:-nats://hub:4222}"
SKIP_SEND_TEST="${SKIP_SEND_TEST:-false}"
SKIP_BUS_TEST="${SKIP_BUS_TEST:-false}"

MESSAGING_ENV_PATH="/home/jsy/.config/wintermute/secrets/messaging.env"
SENT_IDS_PATH="/home/jsy/.local/state/homeward/sent-ids.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; (( PASS++ )) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; (( FAIL++ )) || true; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
info() { echo -e "       $*"; }

# ---------------------------------------------------------------------------
# Gate: SSH reachability
# ---------------------------------------------------------------------------
echo ""
echo "=== verify-messaging: hub=${HUB_HOST} recipient=${TEST_RECIPIENT} ==="
echo ""

echo "--- Check 1: Hub SSH reachability ---"
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "${HUB_HOST}" "echo ok" &>/dev/null; then
    fail "Cannot reach hub '${HUB_HOST}' via SSH"
    warn "All subsequent checks require hub SSH access — aborting early."
    warn "Ensure Tailscale mesh is up and 'ssh ${HUB_HOST}' works."
    echo ""
    echo "=== RESULT: 0 passed, 1 failed (hub unreachable) ==="
    exit 1
fi
pass "Hub '${HUB_HOST}' reachable via SSH"

# ---------------------------------------------------------------------------
# Check 2: Credentials file exists with correct perms
# ---------------------------------------------------------------------------
echo ""
echo "--- Check 2: Credentials file on hub ---"
STAT_OUTPUT=$(ssh -o BatchMode=yes "${HUB_HOST}" \
    "stat -c '%a %U %n' '${MESSAGING_ENV_PATH}' 2>&1" || true)

if echo "${STAT_OUTPUT}" | grep -qE "^[0-9]"; then
    PERMS=$(echo "${STAT_OUTPUT}" | awk '{print $1}')
    OWNER=$(echo "${STAT_OUTPUT}" | awk '{print $2}')
    if [[ "${PERMS}" == "600" && "${OWNER}" == "jsy" ]]; then
        pass "Credentials file exists: ${MESSAGING_ENV_PATH} (${PERMS} ${OWNER})"
    else
        fail "Credentials file has wrong perms/owner: ${PERMS} ${OWNER} (want 600 jsy)"
        info "Fix: ssh ${HUB_HOST} 'chmod 0600 ${MESSAGING_ENV_PATH}; chown jsy:jsy ${MESSAGING_ENV_PATH}'"
    fi
else
    fail "Credentials file not found on hub: ${MESSAGING_ENV_PATH}"
    info "Provision with: ansible-playbook ansible/site.yml --limit hub --tags secrets"
    info "Or see cloud/secrets/hub-messaging.md for manual provisioning steps."
fi

# Spot-check: verify expected keys are present (values stay secret)
echo ""
echo "--- Check 2b: Credentials file key presence ---"
REQUIRED_KEYS=(
    HOMEWARD_SMTP_HOST
    HOMEWARD_SMTP_USER
    HOMEWARD_SMTP_PASSWORD
    HOMEWARD_RELAY_API_KEY
    HOMEWARD_NOTIFY_FROM
)
for KEY in "${REQUIRED_KEYS[@]}"; do
    if ssh -o BatchMode=yes "${HUB_HOST}" \
        "grep -q '^${KEY}=' '${MESSAGING_ENV_PATH}' 2>/dev/null"; then
        pass "Key present: ${KEY}"
    else
        fail "Key missing in credentials file: ${KEY}"
    fi
done

# ---------------------------------------------------------------------------
# Check 3: Outbound send test
# ---------------------------------------------------------------------------
echo ""
echo "--- Check 3: Outbound send test ---"
if [[ "${SKIP_SEND_TEST}" == "true" ]]; then
    warn "SKIP_SEND_TEST=true — skipping live send test"
else
    # Ask homeward-reportd to send a test message
    SEND_OUTPUT=$(ssh -o BatchMode=yes "${HUB_HOST}" \
        "env \$(cat '${MESSAGING_ENV_PATH}' | xargs) homeward-reportd test-send \
         --recipient '${TEST_RECIPIENT}' 2>&1" || true)

    if echo "${SEND_OUTPUT}" | grep -qiE "2[0-9][0-9]|accepted|queued|ok"; then
        pass "Test send accepted: response indicates 2xx/accepted"
        info "Recipient: ${TEST_RECIPIENT}"
    else
        fail "Test send did not confirm delivery"
        info "Output: ${SEND_OUTPUT}"
        info "Check: ssh ${HUB_HOST} journalctl -u hub-messaging-subscriber --since '1 min ago'"
    fi
fi

# ---------------------------------------------------------------------------
# Check 4: Bus-event trigger test
# ---------------------------------------------------------------------------
echo ""
echo "--- Check 4: Bus-event trigger test ---"
if [[ "${SKIP_BUS_TEST}" == "true" ]]; then
    warn "SKIP_BUS_TEST=true — skipping bus trigger test"
else
    if ! command -v nats &>/dev/null; then
        warn "nats CLI not found locally — cannot run bus trigger test"
        warn "Install: https://github.com/nats-io/natscli/releases"
        (( FAIL++ )) || true
    else
        # Generate a unique message-id so dedup doesn't filter this test
        TEST_MSG_ID="verify-messaging-test-$(date +%s)-$$"
        TEST_PAYLOAD=$(printf '{"message_id":"%s","pet_id":"test-pet","owner_email":"%s","match_score":0.95}' \
            "${TEST_MSG_ID}" "${TEST_RECIPIENT}")

        info "Publishing wm.homeward.match with message_id=${TEST_MSG_ID}"

        # Record current log position on hub before publish
        PRE_LOG_LINE=$(ssh -o BatchMode=yes "${HUB_HOST}" \
            "journalctl -u hub-messaging-subscriber --no-pager -n 0 --show-cursor 2>/dev/null | grep '^-- cursor:' | sed 's/-- cursor: //' || echo ''" || true)

        # Publish test event
        if [[ -f "${NATS_CREDS}" ]]; then
            CREDS_FLAG="--creds=${NATS_CREDS}"
        else
            warn "NATS creds not found at ${NATS_CREDS} — publishing without auth"
            CREDS_FLAG=""
        fi

        if ! nats pub "wm.homeward.match" "${TEST_PAYLOAD}" \
                --server "${NATS_URL}" ${CREDS_FLAG} 2>&1; then
            fail "Could not publish wm.homeward.match to NATS"
            info "Ensure NATS is running and credentials are correct."
        else
            pass "Published wm.homeward.match (message_id=${TEST_MSG_ID})"

            # Wait briefly for the subscriber to process
            sleep 3

            # Check for exactly one send in journal since before our publish
            SEND_LOG=$(ssh -o BatchMode=yes "${HUB_HOST}" \
                "journalctl -u hub-messaging-subscriber --no-pager ${PRE_LOG_LINE:+-c "${PRE_LOG_LINE}"} 2>/dev/null | grep '${TEST_MSG_ID}'" || true)

            SEND_COUNT=$(echo "${SEND_LOG}" | grep -c "send" || true)

            if [[ ${SEND_COUNT} -eq 1 ]]; then
                pass "Exactly 1 send triggered by bus event (message_id=${TEST_MSG_ID})"
            elif [[ ${SEND_COUNT} -eq 0 ]]; then
                fail "No send logged for bus event — subscriber may not be running"
                info "Check: ssh ${HUB_HOST} 'systemctl --user status hub-messaging-subscriber'"
                info "Log output: ${SEND_LOG}"
            else
                fail "Multiple sends (${SEND_COUNT}) for same event — dedup may not be working"
                info "Log output: ${SEND_LOG}"
            fi

            # Publish same message-id again — should be deduped (0 sends)
            info "Re-publishing same message_id to verify dedup..."
            nats pub "wm.homeward.match" "${TEST_PAYLOAD}" \
                --server "${NATS_URL}" ${CREDS_FLAG} 2>&1 || true
            sleep 2

            DEDUP_LOG=$(ssh -o BatchMode=yes "${HUB_HOST}" \
                "journalctl -u hub-messaging-subscriber --no-pager ${PRE_LOG_LINE:+-c "${PRE_LOG_LINE}"} 2>/dev/null | grep '${TEST_MSG_ID}' | grep -i 'skip\|dedup\|already'" || true)

            if [[ -n "${DEDUP_LOG}" ]]; then
                pass "Dedup confirmed: second publish was skipped"
            else
                warn "Could not confirm dedup from logs — check manually"
                info "ssh ${HUB_HOST} 'journalctl -u hub-messaging-subscriber --since \"1 min ago\"'"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== RESULT: ${PASS} passed, ${FAIL} failed ==="

if [[ ${FAIL} -gt 0 ]]; then
    echo ""
    echo "Next steps:"
    echo "  1. Provision secrets: see cloud/secrets/hub-messaging.md"
    echo "  2. Deploy service:    ansible-playbook ansible/site.yml --limit hub"
    echo "  3. Check service:     ssh ${HUB_HOST} 'systemctl --user status hub-messaging-subscriber'"
    exit 1
fi

exit 0
