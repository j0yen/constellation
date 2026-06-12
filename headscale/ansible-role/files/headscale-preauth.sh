#!/usr/bin/env bash
# headscale-preauth — mint a tagged, expiring pre-auth key and store it encrypted.
#
# The key is written to the pass(1) store so mesh enrollment reads it.
# No plaintext key is ever committed to the repo (AC10 / AC4).
#
# Usage:
#   headscale-preauth.sh --role <tag>
#                        [--reusable]              (default: true)
#                        [--expiration <duration>] (default: 90d)
#                        [--user <headscale-user>] (default: constellation)
#                        [--dry-run]
#
# Requires: headscale, pass (password-store)
set -uo pipefail
trap '' PIPE

ROLE=""
REUSABLE=true
EXPIRATION="90d"
HS_USER="${HEADSCALE_USER:-constellation}"
DRY_RUN=false
HEADSCALE_BIN="${HEADSCALE_BIN:-headscale}"
PASS_KEY_PREFIX="${HEADSCALE_PREAUTH_PASS_PREFIX:-constellation/headscale/preauth-key}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)        ROLE="$2";        shift 2 ;;
        --reusable)    REUSABLE=true;    shift   ;;
        --no-reusable) REUSABLE=false;   shift   ;;
        --expiration)  EXPIRATION="$2";  shift 2 ;;
        --user)        HS_USER="$2";     shift 2 ;;
        --dry-run)     DRY_RUN=true;     shift   ;;
        -h|--help)
            grep '^#[^!]' "$0" | head -20 | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

log()  { echo "[headscale-preauth] $*"; }
die()  { echo "[headscale-preauth] ERROR: $*" >&2; exit 1; }
run()  {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# ── Validate ──────────────────────────────────────────────────────────────────
[[ -z "$ROLE" ]] && die "--role is required (e.g. laptop, desktop, cloud)"

# Sanitize role: alphanumeric + hyphen only
if [[ ! "$ROLE" =~ ^[a-z0-9-]+$ ]]; then
    die "Role must be alphanumeric + hyphens only; got: $ROLE"
fi

# ── Binary checks ─────────────────────────────────────────────────────────────
if ! command -v "$HEADSCALE_BIN" &>/dev/null; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log "WARN: headscale binary not found at: $HEADSCALE_BIN (dry-run continues)"
    else
        die "headscale binary not found: $HEADSCALE_BIN"
    fi
fi

if ! command -v pass &>/dev/null; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log "WARN: pass (password-store) not found (dry-run continues)"
    else
        die "pass (password-store) not found; install it first"
    fi
fi

# ── Build headscale command ───────────────────────────────────────────────────
HS_ARGS=(
    preauthkeys create
    --user "$HS_USER"
    --expiration "$EXPIRATION"
    --tags "tag:fleet,tag:$ROLE"
)
[[ "$REUSABLE" == "true" ]] && HS_ARGS+=(--reusable)

PASS_KEY_PATH="${PASS_KEY_PREFIX}-${ROLE}"

log "Minting pre-auth key for role=$ROLE user=$HS_USER expiry=$EXPIRATION reusable=$REUSABLE"
log "Key will be stored at pass path: $PASS_KEY_PATH"

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would run: $HEADSCALE_BIN ${HS_ARGS[*]}"
    echo "[DRY-RUN] Would store result at pass path: $PASS_KEY_PATH"
    exit 0
fi

# ── Mint the key (no_log equivalent: we never echo the key to stdout) ─────────
PREAUTH_KEY="$("$HEADSCALE_BIN" "${HS_ARGS[@]}" 2>&1)"
if [[ $? -ne 0 ]]; then
    die "headscale preauthkeys create failed: $PREAUTH_KEY"
fi

# Strip any leading/trailing whitespace
PREAUTH_KEY="$(echo "$PREAUTH_KEY" | tr -d '[:space:]')"

if [[ -z "$PREAUTH_KEY" ]]; then
    die "headscale returned an empty pre-auth key"
fi

# ── Store in pass — the key is piped in; it never appears on the terminal ─────
# pass insert --force reads from stdin when given a -
if echo "$PREAUTH_KEY" | pass insert --force "$PASS_KEY_PATH" > /dev/null; then
    log "Pre-auth key for role=$ROLE stored at: $PASS_KEY_PATH"
    log "Key expires in $EXPIRATION."
    log ""
    log "To use during enrollment:"
    log "  constellation mesh enroll --role $ROLE --headscale <URL>"
    log "  (The enroll script reads the key from pass automatically)"
else
    die "Failed to store pre-auth key in pass at: $PASS_KEY_PATH"
fi
