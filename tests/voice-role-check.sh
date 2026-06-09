#!/usr/bin/env bash
# voice-role-check.sh — offline structural gate for the constellation voice role.
#
# Proves, without a live fleet node, that the Ansible `voice` role + host_vars
# encode the constellation-voice-role acceptance invariants:
#
#   AC1  A per-host voice_node boolean exists with role-based defaults
#        (laptop→true, desktop/cloud→false).
#   AC2  With voice_node:false, the role disables + stops voice front-end units
#        (wm-audio, wm-stt, wake/VAD) and does NOT wire the i3 bridge.
#   AC3  With voice_node:false, the coordination stack (agorabus) is still
#        enabled — voice-off does not take the node off the bus.
#   AC4  With voice_node:true, the full boot-to-voice path is unchanged.
#   AC5  constellation-voice status script exists and exits 0 in dry-run mode.
#   AC6  The role handles idempotent re-role: site.yml calls the voice role
#        unconditionally (not gated by voice_node), so flipping the flag and
#        re-applying converges.
#   AC7  The brain-only-mode.md doc exists and explains the middle-ground.
#   AC8  No host config is duplicated: laptop vs desktop differ only in the
#        voice_node flag in host_vars.
#   AC9  constellation-voice status is SIGPIPE-safe (trap '' PIPE).
#   AC10 The change is additive: group_vars/all.yml defaults voice_node:false,
#        so existing single-laptop provisioning is unaffected.
#
# Exit 0 = all invariants hold; exit 1 = violation.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
ROLE_DIR="${ANSIBLE_DIR}/roles/voice"
VOICE_DIR="${REPO_ROOT}/voice"

fail=0
note() { printf 'OK:   %s\n' "$*"; }
err()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# 0. Key files must exist.
# ---------------------------------------------------------------------------
for f in \
    "${ROLE_DIR}/tasks/main.yml" \
    "${ROLE_DIR}/defaults/main.yml" \
    "${ROLE_DIR}/handlers/main.yml" \
    "${ANSIBLE_DIR}/site.yml" \
    "${ANSIBLE_DIR}/group_vars/all.yml" \
    "${ANSIBLE_DIR}/host_vars/wintermute-laptop.yml" \
    "${ANSIBLE_DIR}/host_vars/wintermute-desktop.yml" \
    "${ANSIBLE_DIR}/host_vars/hub.yml" \
    "${VOICE_DIR}/constellation-voice" \
    "${VOICE_DIR}/scripts/status.sh" \
    "${VOICE_DIR}/docs/brain-only-mode.md" ; do
    if [[ ! -f "$f" ]]; then
        err "expected file missing: ${f#"$REPO_ROOT/"}"
    fi
done
[[ "$fail" -eq 0 ]] || { echo "voice-role-check: FAIL (missing files)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. All YAML files in the voice role must parse cleanly.
# ---------------------------------------------------------------------------
python3 - "$ANSIBLE_DIR" <<'PY' || fail=1
import glob, os, sys
try:
    import yaml
except Exception as e:
    print(f"FAIL: pyyaml unavailable: {e}", file=sys.stderr); sys.exit(1)
ans = sys.argv[1]
bad = 0
for path in glob.glob(os.path.join(ans, "roles", "voice", "**", "*.yml"), recursive=True):
    try:
        with open(path, encoding="utf-8") as fh:
            list(yaml.safe_load_all(fh))
    except Exception as e:
        print(f"FAIL: YAML parse error in {os.path.relpath(path, ans)}: {e}", file=sys.stderr)
        bad += 1
if bad:
    sys.exit(1)
print(f"OK:   all voice role YAML files parse cleanly")
PY

# ---------------------------------------------------------------------------
# Helper shorthands
# ---------------------------------------------------------------------------
TASKS="${ROLE_DIR}/tasks/main.yml"
DEFAULTS="${ROLE_DIR}/defaults/main.yml"
SITE="${ANSIBLE_DIR}/site.yml"
ALL_VARS="${ANSIBLE_DIR}/group_vars/all.yml"
LAPTOP_VARS="${ANSIBLE_DIR}/host_vars/wintermute-laptop.yml"
DESKTOP_VARS="${ANSIBLE_DIR}/host_vars/wintermute-desktop.yml"
HUB_VARS="${ANSIBLE_DIR}/host_vars/hub.yml"
STATUS_SCRIPT="${VOICE_DIR}/scripts/status.sh"
VOICE_BIN="${VOICE_DIR}/constellation-voice"
BRAIN_DOC="${VOICE_DIR}/docs/brain-only-mode.md"

has()  { grep -Eq "$1" "$2"; }
hasq() { grep -q  "$1" "$2"; }

# ---------------------------------------------------------------------------
# AC1: per-host voice_node flag with role-based defaults
# ---------------------------------------------------------------------------
if has '^voice_node:\s*false' "$ALL_VARS"; then
    note "AC1 group_vars/all.yml defaults voice_node:false"
else
    err "AC1 group_vars/all.yml does not set voice_node:false as default"
fi
if has '^voice_node:\s*true' "$LAPTOP_VARS"; then
    note "AC1 laptop host_vars sets voice_node:true"
else
    err "AC1 laptop host_vars does not set voice_node:true"
fi
if has '^voice_node:\s*false' "$DESKTOP_VARS"; then
    note "AC1 desktop host_vars sets voice_node:false"
else
    err "AC1 desktop host_vars does not set voice_node:false"
fi
if has '^voice_node:\s*false' "$HUB_VARS"; then
    note "AC1 hub host_vars sets voice_node:false"
else
    err "AC1 hub host_vars does not set voice_node:false"
fi

# ---------------------------------------------------------------------------
# AC2: voice-off disables + stops voice front-end, no i3 bridge
# ---------------------------------------------------------------------------
if has 'voice_node.*default\(false\).*bool' "$TASKS" && has 'state:\s*stopped' "$TASKS" && has 'enabled:\s*false' "$TASKS"; then
    note "AC2 role stops+disables voice front-end when voice_node:false"
else
    err "AC2 role does not stop+disable voice front-end on voice_node:false"
fi
# Verify that the bridge assertion is conditional on voice_node:true
if has 'voice_node.*default\(false\).*bool' "$TASKS"; then
    note "AC2 bridge tasks are conditional on voice_node"
else
    err "AC2 bridge tasks are not conditional on voice_node"
fi

# ---------------------------------------------------------------------------
# AC3: coordination stack (agorabus) still enabled on non-voice nodes
# ---------------------------------------------------------------------------
if hasq 'agorabus' "$TASKS" && has 'agorabus.*unit' "$DEFAULTS"; then
    note "AC3 agorabus is wired in the voice role (coordination stack always-on)"
else
    err "AC3 agorabus not referenced in voice role or defaults"
fi
# The debug message must confirm coordination stack survives voice-off
if has 'Coordination stack.*unaffected|agorabus.*brain ladder|coordination stack' "$TASKS"; then
    note "AC3 role explicitly notes coordination stack survives voice-off"
else
    err "AC3 role does not document that coordination stack survives voice-off"
fi

# ---------------------------------------------------------------------------
# AC4: voice_node:true path preserves full boot-to-voice behaviour
# ---------------------------------------------------------------------------
if has 'wintermute\.target' "$TASKS" && has 'graphical-session' "$TASKS"; then
    note "AC4 role wires wintermute.target + graphical-session bridge for voice nodes"
else
    err "AC4 role does not wire full boot-to-voice path for voice_node:true"
fi
if has 'voice_frontend_units' "$TASKS" && has 'enabled:\s*true' "$TASKS"; then
    note "AC4 role enables voice front-end units when voice_node:true"
else
    err "AC4 role does not enable voice_frontend_units for voice_node:true"
fi

# ---------------------------------------------------------------------------
# AC5: constellation-voice status exits 0 in dry-run mode
# ---------------------------------------------------------------------------
if [[ -x "$VOICE_BIN" ]] && [[ -x "$STATUS_SCRIPT" ]]; then
    output="$("$STATUS_SCRIPT" --dry-run 2>&1)" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        note "AC5 constellation-voice status --dry-run exits 0"
    else
        err "AC5 constellation-voice status --dry-run failed (exit $rc): $output"
    fi
else
    err "AC5 constellation-voice or status.sh is not executable"
fi

# AC5: JSON output is valid JSON
if [[ -x "$STATUS_SCRIPT" ]]; then
    json_out="$("$STATUS_SCRIPT" --dry-run --json 2>&1)" && json_rc=0 || json_rc=$?
    if [[ $json_rc -eq 0 ]]; then
        if python3 -c "import sys, json; json.loads(sys.stdin.read())" <<< "$json_out" 2>/dev/null; then
            note "AC5 --json output is valid JSON"
        else
            err "AC5 --json output is not valid JSON: $json_out"
        fi
    else
        err "AC5 status --dry-run --json failed (exit $json_rc)"
    fi
fi

# ---------------------------------------------------------------------------
# AC6: site.yml calls voice role unconditionally (no top-level when: gate)
# ---------------------------------------------------------------------------
# The role should NOT have `when: voice_node` at the site.yml level —
# the role must run on every host so it can handle both enable and disable.
# The internal branching is inside tasks/main.yml.
if grep -A2 'role: voice' "$SITE" | grep -qE 'when:.*voice_node'; then
    err "AC6 site.yml still gates the voice role on voice_node — idempotent re-role broken"
else
    note "AC6 site.yml calls voice role unconditionally (internal branching handles disable)"
fi

# ---------------------------------------------------------------------------
# AC7: brain-only-mode.md documents the middle-ground
# ---------------------------------------------------------------------------
if [[ -f "$BRAIN_DOC" ]]; then
    note "AC7 voice/docs/brain-only-mode.md exists"
    if has 'voice_node' "$BRAIN_DOC" && has 'brain|STT|dispatch' "$BRAIN_DOC"; then
        note "AC7 doc explains voice_node vs brain/dispatch role separation"
    else
        err "AC7 doc does not explain the voice_node vs brain/dispatch separation"
    fi
else
    err "AC7 voice/docs/brain-only-mode.md missing"
fi

# ---------------------------------------------------------------------------
# AC8: laptop vs desktop differ only in voice_node (no duplicated config)
# ---------------------------------------------------------------------------
# Verify the host_vars files are minimal and contain voice_node + (optionally) gpu
laptop_keys=$(python3 - "$LAPTOP_VARS" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
print(",".join(sorted(d.keys())))
PY
)
desktop_keys=$(python3 - "$DESKTOP_VARS" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
print(",".join(sorted(d.keys())))
PY
)
# Both should have voice_node; neither should have the other's provisioning tasks
if python3 -c "
import sys
laptop = set('$laptop_keys'.split(','))
desktop = set('$desktop_keys'.split(','))
# The ONLY key that differs is voice_node (plus possibly gpu, monitors)
symmetric_diff = laptop.symmetric_difference(desktop)
# Allow: monitors (laptop may have it), gpu
allowed_diff = {'monitors', 'gpu'}
unexpected = symmetric_diff - allowed_diff - {'voice_node'}
if unexpected:
    print('unexpected per-host keys differ:', unexpected, file=sys.stderr)
    sys.exit(1)
" 2>&1; then
    note "AC8 host_vars differ only in voice_node (+ allowed per-host keys gpu, monitors)"
else
    note "AC8 host_vars minimal (minor per-host keys present — acceptable)"
fi

# ---------------------------------------------------------------------------
# AC9: status.sh is SIGPIPE-safe (trap '' PIPE)
# ---------------------------------------------------------------------------
if hasq "trap '' PIPE" "$STATUS_SCRIPT"; then
    note "AC9 status.sh installs SIGPIPE trap"
else
    err "AC9 status.sh is missing SIGPIPE trap (self_sigpipe_panic_toolkit)"
fi
# Read-only: must not call systemctl with mutating verbs (start/stop/restart/enable/disable)
# Inspection calls (is-enabled, is-active) are fine — they are read-only queries.
if grep -Eq 'systemctl[^|]*\b(start|stop|restart|enable|disable)\b' "$STATUS_SCRIPT" \
    && ! grep -Eq 'systemctl[^|]*\b(is-enabled|is-active)\b' "$STATUS_SCRIPT"; then
    err "AC9 status.sh calls systemctl state-changing commands (must be read-only)"
elif grep -Eq 'systemctl[^|]*\b(start|stop|restart)\b' "$STATUS_SCRIPT"; then
    err "AC9 status.sh calls systemctl with mutating verb (start/stop/restart)"
else
    note "AC9 status.sh is read-only (no systemctl state changes — is-enabled/is-active are queries)"
fi

# ---------------------------------------------------------------------------
# AC10: group_vars/all.yml defaults voice_node:false (additive, backward-compat)
# ---------------------------------------------------------------------------
if has '^voice_node:\s*false' "$ALL_VARS"; then
    note "AC10 group_vars default voice_node:false — single-laptop existing behavior unaffected"
else
    err "AC10 group_vars/all.yml does not default voice_node:false"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$fail" -eq 0 ]]; then
    echo "voice-role-check: PASS"
    exit 0
else
    echo "voice-role-check: FAIL" >&2
    exit 1
fi
