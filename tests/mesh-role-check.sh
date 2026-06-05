#!/usr/bin/env bash
# mesh-role-check.sh — offline structural gate for the constellation-mesh Ansible role.
#
# Proves, without a live Tailscale network, that the mesh/roles/tailscale role
# encodes the correct enrollment invariants:
#
#   AC1  An Ansible role enrolls a node using an auth key from the encrypted
#        pass store (no plaintext key in the repo or in defaults).
#   AC7  Role tags nodes with tag:fleet,tag:<role> (fleet-only ACL policy).
#   AC10 No auth key or private key material is committed in the role.
#
# Also validates that the CLI scripts and config files exist (AC8, AC10).
#
# Exit 0 = all invariants hold; exit 1 = violation.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE_DIR="$REPO_ROOT/mesh/roles/tailscale"
SCRIPTS_DIR="$REPO_ROOT/mesh/scripts"
CONFIG_DIR="$REPO_ROOT/mesh/config"
MESH_BIN="$REPO_ROOT/mesh/constellation-mesh"

fail=0
note() { echo "OK:   $*"; }
err()  { echo "FAIL: $*" >&2; fail=1; }

# ── AC1: Ansible role structure exists ───────────────────────────────────────
[[ -f "$ROLE_DIR/tasks/main.yml" ]]    && note "role tasks/main.yml present" \
    || err "role tasks/main.yml missing"

[[ -f "$ROLE_DIR/defaults/main.yml" ]] && note "role defaults/main.yml present" \
    || err "role defaults/main.yml missing"

# ── AC1: Auth key read from pass store, not hardcoded ────────────────────────
if [[ -f "$ROLE_DIR/tasks/main.yml" ]]; then
    if grep -q "pass show" "$ROLE_DIR/tasks/main.yml"; then
        note "tasks/main.yml reads auth key via pass(1)"
    else
        err "tasks/main.yml does not use pass(1) to fetch auth key"
    fi

    if grep -q "no_log: true" "$ROLE_DIR/tasks/main.yml"; then
        note "tasks/main.yml sets no_log:true on secret-handling tasks"
    else
        err "tasks/main.yml missing no_log:true on secret tasks"
    fi
fi

# ── AC1: defaults must not contain a hardcoded auth key value ────────────────
if [[ -f "$ROLE_DIR/defaults/main.yml" ]]; then
    if grep -qiE 'auth.?key\s*:\s*"ts[a-zA-Z0-9_-]{10,}"' "$ROLE_DIR/defaults/main.yml"; then
        err "defaults/main.yml contains what looks like a hardcoded Tailscale auth key"
    else
        note "defaults/main.yml: no hardcoded auth key"
    fi
fi

# ── AC7: Role advertises fleet tags ──────────────────────────────────────────
if [[ -f "$ROLE_DIR/tasks/main.yml" ]]; then
    if grep -q "tag:fleet" "$ROLE_DIR/tasks/main.yml"; then
        note "tasks/main.yml advertises tag:fleet"
    else
        err "tasks/main.yml does not advertise tag:fleet"
    fi

    if grep -q "tag:.*tailscale_role" "$ROLE_DIR/tasks/main.yml"; then
        note "tasks/main.yml uses dynamic role tag (tag:\$tailscale_role)"
    else
        err "tasks/main.yml does not set a dynamic role tag"
    fi
fi

# ── AC8: CLI entrypoint and scripts exist ────────────────────────────────────
[[ -x "$MESH_BIN" ]] && note "constellation-mesh entrypoint is executable" \
    || err "constellation-mesh entrypoint missing or not executable"

for s in enroll.sh names.sh status.sh; do
    [[ -f "$SCRIPTS_DIR/$s" ]] && note "scripts/$s present" \
        || err "scripts/$s missing"
done

# ── AC8: names and status subcommands exit 0 ─────────────────────────────────
if [[ -x "$MESH_BIN" ]]; then
    # names should exit 0 without tailscale (falls back to config)
    output="$("$MESH_BIN" names --format table 2>&1)" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        note "constellation-mesh names exits 0 (offline)"
    else
        err "constellation-mesh names failed offline (exit $rc): $output"
    fi

    # enroll --dry-run should exit 0 without tailscale
    output="$("$MESH_BIN" enroll --dry-run --role laptop 2>&1)" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        note "constellation-mesh enroll --dry-run exits 0"
    else
        err "constellation-mesh enroll --dry-run failed (exit $rc): $output"
    fi
fi

# ── AC10: No key material in the role ────────────────────────────────────────
key_pattern='tskey-[a-zA-Z0-9_-]{10,}'
found_keys=$(grep -rE "$key_pattern" "$ROLE_DIR/" 2>/dev/null | grep -v "\.pyc" || true)
if [[ -n "$found_keys" ]]; then
    err "Possible Tailscale key material committed in role: $found_keys"
else
    note "no Tailscale key material found in role tree"
fi

# ── AC10: No key material in config (only ACL) ───────────────────────────────
found_keys=$(grep -rE "$key_pattern" "$CONFIG_DIR/" 2>/dev/null || true)
if [[ -n "$found_keys" ]]; then
    err "Possible Tailscale key material committed in config: $found_keys"
else
    note "no key material in mesh/config/"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ "$fail" -eq 0 ]]; then
    echo "mesh-role-check: PASS"
    exit 0
else
    echo "mesh-role-check: FAIL" >&2
    exit 1
fi
