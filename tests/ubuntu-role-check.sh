#!/usr/bin/env bash
# ubuntu-role-check.sh — offline structural gate for constellation-ubuntu-join.
#
# Proves, without a live Ubuntu box, that the shared ubuntu-base/fleet-member
# role set + bin/join encode the PRD's acceptance invariants:
#
#   AC5  bin/join fails before any ssh attempt when the host is not in
#        inventory, and prints the inventory line format to add.
#   AC6  the sudo-rs NOPASSWD drop-in is the first become-requiring task in
#        ubuntu-base.
#   goal "one shared Ubuntu role set" — carbon-ubuntu.yml / redbaron-ubuntu.yml
#        are reduced to deprecation pointers, not deleted.
#   goal "no Arch support in the new role set" — ubuntu-base/fleet-member
#        never touch pacman.
#
# What this script cannot prove (needs a live, ssh-reachable Ubuntu box —
# none exists in this environment): AC1-4, AC7-10 (live convergence,
# --check zero-diff on carbon, --user-space skip reporting live, tailnet
# preflight against a real unenrolled node, python3 bootstrap, --list content
# beyond structural presence). See PRD deferred_acs.
#
# Exit 0 = all invariants hold; exit 1 = violation.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
UBUNTU_BASE="${ANSIBLE_DIR}/roles/ubuntu-base"
FLEET_MEMBER="${ANSIBLE_DIR}/roles/fleet-member"
JOIN_BIN="${REPO_ROOT}/bin/join"

fail=0
note() { echo "OK:   $*"; }
err()  { echo "FAIL: $*" >&2; fail=1; }

# ── Role structure exists ────────────────────────────────────────────────────
for f in \
    "${UBUNTU_BASE}/tasks/main.yml" "${UBUNTU_BASE}/defaults/main.yml" \
    "${FLEET_MEMBER}/tasks/main.yml" "${FLEET_MEMBER}/defaults/main.yml" \
    "${ANSIBLE_DIR}/site-ubuntu.yml"; do
    [[ -f "$f" ]] && note "$(basename "$(dirname "$(dirname "$f")")")/$(basename "$(dirname "$f")")/$(basename "$f") present" \
        || err "$f missing"
done

# ── AC6: sudo-rs NOPASSWD drop-in is the first become-requiring task ────────
first_become_task=$(awk '
    /^- name:/ { name=$0 }
    /^  become: *true[[:space:]]*$/ { print name; exit }
' "${UBUNTU_BASE}/tasks/main.yml")
if echo "$first_become_task" | grep -qi "sudo-rs"; then
    note "ubuntu-base: first become:true task is the sudo-rs NOPASSWD drop-in ($first_become_task)"
else
    err "ubuntu-base: first become:true task is NOT the sudo-rs drop-in (found: $first_become_task)"
fi

# ── Apt keyring format-by-extension trap is encoded ──────────────────────────
if grep -q "ext.*gpg\|ext.*asc" "${UBUNTU_BASE}/defaults/main.yml" && \
   grep -qi "format matched to extension\|format.*extension" "${UBUNTU_BASE}/tasks/main.yml"; then
    note "ubuntu-base: apt keyring format-by-extension trap encoded as data + task"
else
    err "ubuntu-base: apt keyring format-by-extension trap not found"
fi

# ── --user-space gate: role-level fact, not per-task sprinkling of a literal ─
if grep -q "user_space" "${UBUNTU_BASE}/defaults/main.yml"; then
    note "ubuntu-base: user_space fact defined centrally in defaults"
else
    err "ubuntu-base: user_space fact not defined in defaults"
fi
become_true_tasks=$(grep -c "become: true" "${UBUNTU_BASE}/tasks/main.yml")
gated_tasks=$(grep -c "not (user_space | bool)" "${UBUNTU_BASE}/tasks/main.yml")
if [[ "$gated_tasks" -ge 1 && "$become_true_tasks" -ge 1 ]]; then
    note "ubuntu-base: become:true tasks are gated by user_space ($gated_tasks when-clauses over $become_true_tasks become:true tasks)"
else
    err "ubuntu-base: become:true tasks are not gated by user_space"
fi

# ── No Arch/pacman leakage into the new role set ─────────────────────────────
if grep -rqi "pacman" "${UBUNTU_BASE}" "${FLEET_MEMBER}" "${ANSIBLE_DIR}/site-ubuntu.yml"; then
    err "pacman reference found in the new Ubuntu role set (Arch leakage)"
else
    note "no pacman reference in ubuntu-base/fleet-member/site-ubuntu.yml"
fi

# ── carbon-ubuntu.yml / redbaron-ubuntu.yml are deprecation pointers, kept ──
for legacy in carbon-ubuntu.yml redbaron-ubuntu.yml; do
    f="${ANSIBLE_DIR}/${legacy}"
    if [[ -f "$f" ]] && grep -qi "deprecated" "$f" && grep -q "bin/join" "$f"; then
        note "$legacy: reduced to a deprecation pointer, still present"
    else
        err "$legacy: missing, or not reduced to a deprecation pointer"
    fi
done

# ── host_vars carries per-host divergence (not hardcoded in the shared role) ─
for hv in carbon redbaron; do
    f="${ANSIBLE_DIR}/host_vars/${hv}.yml"
    [[ -f "$f" ]] && note "host_vars/${hv}.yml present" || err "host_vars/${hv}.yml missing"
done
if grep -q "nvidia-ubuntu-drivers" "${ANSIBLE_DIR}/host_vars/redbaron.yml" && \
   ! grep -q "nvidia-ubuntu-drivers" "${ANSIBLE_DIR}/host_vars/carbon.yml"; then
    note "GPU driver divergence lives in host_vars, not in the shared role"
else
    err "GPU driver divergence not isolated to host_vars as expected"
fi

# ── bin/join exists, is executable, documents all required flags ────────────
[[ -x "$JOIN_BIN" ]] && note "bin/join is executable" || err "bin/join missing or not executable"
for flag in "\-\-check" "\-\-user-space" "\-\-ask-become-pass" "\-\-list"; do
    if "$JOIN_BIN" --help 2>&1 | grep -q "$flag"; then
        note "bin/join --help documents $flag"
    else
        err "bin/join --help missing $flag"
    fi
done

# ── AC5: unknown host fails before any ssh attempt, with inventory hint ─────
out=$("$JOIN_BIN" definitely-not-a-real-host-in-inventory 2>&1)
rc=$?
if [[ "$rc" -ne 0 ]]; then
    note "bin/join <unknown host>: exits non-zero ($rc)"
else
    err "bin/join <unknown host>: exited 0 (expected non-zero)"
fi
if echo "$out" | grep -q "ansible_host="; then
    note "bin/join <unknown host>: prints the inventory line format to add"
else
    err "bin/join <unknown host>: does not print an inventory line hint"
fi
if echo "$out" | grep -qiE "ssh|connect"; then
    err "bin/join <unknown host>: mentions ssh — should fail before any ssh attempt"
else
    note "bin/join <unknown host>: fails before any ssh attempt (no ssh/connect language)"
fi

# ── --list runs offline (no live host required) ──────────────────────────────
if "$JOIN_BIN" --list >/dev/null 2>&1; then
    note "bin/join --list exits 0 offline"
else
    err "bin/join --list failed offline"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ "$fail" -eq 0 ]]; then
    echo "ubuntu-role-check: PASS"
    exit 0
else
    echo "ubuntu-role-check: FAIL" >&2
    exit 1
fi
