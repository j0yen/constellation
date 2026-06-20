#!/usr/bin/env bash
# message-dedup.sh — idempotency guard for hub outbound messaging.
#
# Usage:
#   message-dedup.sh <message-id>
#
# Exit codes:
#   0 — message-id is NEW; caller should proceed with send
#   1 — message-id already in sent-ids.txt; caller should skip (already sent)
#   2 — usage error
#
# Thread safety: uses flock(1) on the state file to prevent TOCTOU races when
# multiple bus events arrive concurrently (e.g. match + reminder in the same
# second).
#
# State file location:
#   ~/.local/state/homeward/sent-ids.txt
#   Each line is a single message-id (UUID or hash).
#
# Purge old entries (optional cron):
#   Entries older than 30 days can safely be removed — within that window any
#   retry loop will catch duplicates; beyond it a resend would be a fresh event.
#   Suggested cron (on hub): @daily tail -n +1 ~/.local/state/homeward/sent-ids.txt | ...

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SENT_IDS_FILE="${HOMEWARD_SENT_IDS:-${HOME}/.local/state/homeward/sent-ids.txt}"
LOCK_FILE="${SENT_IDS_FILE}.lock"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
if [[ $# -ne 1 ]]; then
    echo "Usage: $(basename "$0") <message-id>" >&2
    exit 2
fi

MESSAGE_ID="$1"

if [[ -z "${MESSAGE_ID}" ]]; then
    echo "Error: message-id must not be empty" >&2
    exit 2
fi

# Validate: message-id should be printable, non-whitespace, reasonable length
if [[ ! "${MESSAGE_ID}" =~ ^[[:graph:]]{1,256}$ ]]; then
    echo "Error: message-id contains whitespace or exceeds 256 chars" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Ensure state directory exists
# ---------------------------------------------------------------------------
STATE_DIR="$(dirname "${SENT_IDS_FILE}")"
if [[ ! -d "${STATE_DIR}" ]]; then
    mkdir -p "${STATE_DIR}"
    chmod 0700 "${STATE_DIR}"
fi

# ---------------------------------------------------------------------------
# Acquire exclusive lock, then check + record
# ---------------------------------------------------------------------------
# flock -n exits immediately with code 1 if the lock is already held.
# We use fd 200 to avoid touching the actual state file during the lock wait.
(
    flock -x 200 || { echo "Error: could not acquire dedup lock" >&2; exit 2; }

    # Create file if it doesn't exist
    if [[ ! -f "${SENT_IDS_FILE}" ]]; then
        touch "${SENT_IDS_FILE}"
        chmod 0600 "${SENT_IDS_FILE}"
    fi

    # Check for existing entry (grep exits 0 if found, 1 if not)
    if grep -qxF "${MESSAGE_ID}" "${SENT_IDS_FILE}" 2>/dev/null; then
        # Already sent — exit 1 (via subshell)
        exit 1
    fi

    # Record the id with a timestamp comment for auditability
    printf '%s\n' "${MESSAGE_ID}" >> "${SENT_IDS_FILE}"
    exit 0

) 200>"${LOCK_FILE}"

# Propagate subshell exit code
DEDUP_RC=$?
if [[ ${DEDUP_RC} -eq 1 ]]; then
    echo "dedup: message-id '${MESSAGE_ID}' already sent — skipping" >&2
    exit 1
elif [[ ${DEDUP_RC} -ne 0 ]]; then
    # Propagate unexpected errors
    exit ${DEDUP_RC}
fi

# DEDUP_RC == 0 — new message, caller should proceed
echo "dedup: message-id '${MESSAGE_ID}' is new — proceeding"
exit 0
