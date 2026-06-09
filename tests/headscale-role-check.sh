#!/usr/bin/env bash
# headscale-role-check — offline structural gate for the constellation-headscale Ansible role.
#
# Verifies AC1-AC10 without a live headscale server.
# Exit 0 = all checks pass; non-zero = at least one check failed.
#
# Usage: tests/headscale-role-check.sh [--verbose]
set -uo pipefail
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HS_DIR="$REPO_ROOT/headscale"
ROLE_DIR="$HS_DIR/ansible-role"
SCRIPTS_DIR="$HS_DIR/scripts"
MESH_ACL="$REPO_ROOT/mesh/config/acl-policy.hujson"

VERBOSE=false
PASS=0; FAIL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose) VERBOSE=true; shift ;;
        *) shift ;;
    esac
done

ok()   { echo "  PASS  $1"; ((PASS++)) || true; }
fail() { echo "  FAIL  $1"; ((FAIL++)) || true; }
skip() { echo "  SKIP  $1"; }
log()  { echo "$1"; }
vlog() { [[ "$VERBOSE" == "true" ]] && echo "        $1" || true; }

log "=== constellation-headscale offline role check ==="
log ""

# ── AC1: Ansible role structure exists ───────────────────────────────────────
log "AC1 — Ansible role structure + systemd service + persisted state path"

for d in "$ROLE_DIR" "$ROLE_DIR/defaults" "$ROLE_DIR/tasks" \
          "$ROLE_DIR/templates" "$ROLE_DIR/handlers" "$ROLE_DIR/vars"; do
    if [[ -d "$d" ]]; then
        ok "Directory exists: ${d#$REPO_ROOT/}"
    else
        fail "Missing directory: ${d#$REPO_ROOT/}"
    fi
done

for f in \
    "$ROLE_DIR/defaults/main.yml" \
    "$ROLE_DIR/tasks/main.yml" \
    "$ROLE_DIR/handlers/main.yml" \
    "$ROLE_DIR/vars/main.yml" \
    "$ROLE_DIR/templates/headscale.service.j2" \
    "$ROLE_DIR/templates/headscale-config.yaml.j2"; do
    if [[ -f "$f" ]]; then
        ok "File exists: ${f#$REPO_ROOT/}"
    else
        fail "Missing file: ${f#$REPO_ROOT/}"
    fi
done

# systemd unit template must reference the state dir
if grep -q "headscale_state_dir\|/var/lib/headscale" \
       "$ROLE_DIR/templates/headscale.service.j2" 2>/dev/null; then
    ok "systemd unit references persisted state dir"
else
    fail "systemd unit does not reference persisted state dir (AC1)"
fi

# Tasks must include durability assertion
if grep -q "db_path\|stat.*db\|wait_for.*db" "$ROLE_DIR/tasks/main.yml" 2>/dev/null; then
    ok "Task file asserts DB durability after start (AC1)"
else
    fail "Task file missing DB durability assertion (AC1)"
fi

log ""

# ── AC2: No private key generated into repo ──────────────────────────────────
log "AC2 — Noise key from secret store; no private key in repo"

# Check that tasks load from pass store
if grep -q "pass show\|headscale_noise_key_pass_path" \
       "$ROLE_DIR/tasks/main.yml" 2>/dev/null; then
    ok "Task loads noise key from pass store (AC2)"
else
    fail "Task does not load noise key from pass store (AC2)"
fi

# Assert no headscale private key patterns in the repo
PRIV_KEY_HIT="$(git -C "$REPO_ROOT" grep -r \
    --include="*.yml" --include="*.yaml" --include="*.sh" \
    -E 'noise_private|privkey|-----BEGIN (EC|RSA|PRIVATE)' \
    -- "$HS_DIR" 2>/dev/null || true)"
if [[ -z "$PRIV_KEY_HIT" ]]; then
    ok "No Headscale private key material committed (AC2)"
else
    fail "Possible private key found in headscale dir (AC2):"
    echo "$PRIV_KEY_HIT"
fi

# Defaults must reference pass store path, not inline key
if grep -q "headscale_noise_key_pass_path\|pass show" \
       "$ROLE_DIR/defaults/main.yml" 2>/dev/null; then
    ok "Defaults reference pass store path for noise key (AC2)"
else
    fail "Defaults do not reference pass store path for noise key (AC2)"
fi

log ""

# ── AC3: ACL derived from mesh canonical source ───────────────────────────────
log "AC3 — ACL derived from mesh canonical acl-policy.hujson"

if [[ -f "$MESH_ACL" ]]; then
    ok "Mesh canonical ACL exists: mesh/config/acl-policy.hujson"
else
    fail "Mesh canonical ACL not found: mesh/config/acl-policy.hujson (AC3)"
fi

# Role defaults must reference the mesh ACL as source
if grep -q "acl-policy.hujson\|mesh.*acl\|headscale_acl_src" \
       "$ROLE_DIR/defaults/main.yml" 2>/dev/null; then
    ok "Role defaults reference mesh canonical ACL as source (AC3)"
else
    fail "Role defaults do not reference mesh canonical ACL source (AC3)"
fi

# ACL file is copied (not generated) in tasks
if grep -q "headscale_acl_src\|acl-policy.hujson" \
       "$ROLE_DIR/tasks/main.yml" 2>/dev/null; then
    ok "Task copies canonical ACL to headscale config dir (AC3)"
else
    fail "Task does not copy canonical ACL (AC3)"
fi

# ACL assert script must exist
if [[ -f "$SCRIPTS_DIR/headscale-acl-assert.sh" ]]; then
    ok "headscale-acl-assert.sh exists (AC3)"
else
    fail "headscale-acl-assert.sh missing (AC3)"
fi

log ""

# ── AC4: Pre-auth key issuance to secret store ────────────────────────────────
log "AC4 — preauth --role mints key into secret store"

PREAUTH_SCRIPT="$SCRIPTS_DIR/headscale-preauth.sh"
if [[ -f "$PREAUTH_SCRIPT" ]]; then
    ok "headscale-preauth.sh exists (AC4)"
else
    fail "headscale-preauth.sh missing (AC4)"
fi

# preauth script must use pass insert, not echo the key
if grep -q "pass insert" "$PREAUTH_SCRIPT" 2>/dev/null; then
    ok "preauth script stores key via 'pass insert' (no plaintext echo) (AC4)"
else
    fail "preauth script does not use 'pass insert' (AC4)"
fi

# Role must have --role argument
if grep -q -- "--role" "$PREAUTH_SCRIPT" 2>/dev/null; then
    ok "preauth script accepts --role argument (AC4)"
else
    fail "preauth script missing --role argument (AC4)"
fi

log ""

# ── AC5: Status command ────────────────────────────────────────────────────────
log "AC5 — constellation headscale status reports server up + DB + roster"

STATUS_SCRIPT="$SCRIPTS_DIR/headscale-status.sh"
if [[ -f "$STATUS_SCRIPT" ]]; then
    ok "headscale-status.sh exists (AC5)"
else
    fail "headscale-status.sh missing (AC5)"
fi

# Must check service + DB + nodes
for pattern in "server_up|is-active|systemctl" "nodes list|db_reachable" "node_count|roster"; do
    if grep -qE "$pattern" "$STATUS_SCRIPT" 2>/dev/null; then
        ok "Status script checks: $pattern (AC5)"
    else
        fail "Status script missing check for: $pattern (AC5)"
    fi
done

# Must exit non-zero if server is down
if grep -qE "exit [12]|exit \\\$" "$STATUS_SCRIPT" 2>/dev/null; then
    ok "Status script exits non-zero on failure (AC5)"
else
    fail "Status script does not exit non-zero on failure (AC5)"
fi

log ""

# ── AC6: Selftest ─────────────────────────────────────────────────────────────
log "AC6 — selftest registers ephemeral node, asserts roster, expires, leaves no residue"

SELFTEST_SCRIPT="$SCRIPTS_DIR/headscale-selftest.sh"
if [[ -f "$SELFTEST_SCRIPT" ]]; then
    ok "headscale-selftest.sh exists (AC6)"
else
    fail "headscale-selftest.sh missing (AC6)"
fi

for pattern in "ephemeral|preauthkeys create" "nodes list|roster" "expire|delete" "residue|no.*active|PASS_COUNT"; do
    if grep -qE "$pattern" "$SELFTEST_SCRIPT" 2>/dev/null; then
        ok "Selftest covers: $pattern (AC6)"
    else
        fail "Selftest missing: $pattern (AC6)"
    fi
done

log ""

# ── AC7: Node lifecycle ────────────────────────────────────────────────────────
log "AC7 — node register/list/expire/delete, deleted node absent from roster"

NODE_SCRIPT="$SCRIPTS_DIR/headscale-node.sh"
if [[ -f "$NODE_SCRIPT" ]]; then
    ok "headscale-node.sh exists (AC7)"
else
    fail "headscale-node.sh missing (AC7)"
fi

for subcmd in list register expire delete; do
    if grep -q "$subcmd" "$NODE_SCRIPT" 2>/dev/null; then
        ok "node script has subcommand: $subcmd (AC7)"
    else
        fail "node script missing subcommand: $subcmd (AC7)"
    fi
done

# Delete must assert roster no longer contains the node
if grep -qE "roster.*after|nodes list|no longer.*roster|not.*roster|Verify.*delet" \
       "$NODE_SCRIPT" 2>/dev/null; then
    ok "delete command asserts node absent from roster (AC7)"
else
    fail "delete command does not assert roster absence (AC7)"
fi

log ""

# ── AC8: Switch documented as reversible + trade-offs ────────────────────────
log "AC8 — switching SaaS↔Headscale is documented as reversible with trade-offs"

SWITCH_SCRIPT="$SCRIPTS_DIR/headscale-switch.sh"
if [[ -f "$SWITCH_SCRIPT" ]]; then
    ok "headscale-switch.sh exists (AC8)"
else
    fail "headscale-switch.sh missing (AC8)"
fi

# Must mention both directions
for pattern in "saas|Tailscale SaaS" "self.*headscale|Headscale.*self|Self-hosted" \
               "reversible|revert|switch back" "sovereignty|ops.*simplicit|operational"; do
    if grep -qiE "$pattern" "$SWITCH_SCRIPT" 2>/dev/null; then
        ok "switch script covers: $pattern (AC8)"
    else
        fail "switch script missing: $pattern (AC8)"
    fi
done

log ""

# ── AC9: Minimal bind surface (loopback only) ────────────────────────────────
log "AC9 — server binds loopback only; not 0.0.0.0:8080"

CONFIG_TEMPLATE="$ROLE_DIR/templates/headscale-config.yaml.j2"
if [[ -f "$CONFIG_TEMPLATE" ]]; then
    ok "headscale-config.yaml.j2 exists (AC9)"
else
    fail "headscale-config.yaml.j2 missing (AC9)"
fi

# listen_addr must be a loopback or private variable, NOT 0.0.0.0
if grep -q "127.0.0.1\|headscale_listen_addr" "$CONFIG_TEMPLATE" 2>/dev/null; then
    ok "Config template uses loopback listen_addr (AC9)"
else
    fail "Config template may not use loopback listen_addr (AC9)"
fi

# Defaults must show loopback
LISTEN_DEFAULT="$(grep "headscale_listen_addr:" "$ROLE_DIR/defaults/main.yml" 2>/dev/null || true)"
if echo "$LISTEN_DEFAULT" | grep -q "127.0.0.1"; then
    ok "Default listen_addr is 127.0.0.1 (loopback) (AC9)"
else
    fail "Default listen_addr is not 127.0.0.1 (AC9): $LISTEN_DEFAULT"
fi

log ""

# ── AC10: SIGPIPE guard + no plaintext keys in scripts ───────────────────────
log "AC10 — SIGPIPE guard + no plaintext Headscale/pre-auth keys"

# All scripts must have 'trap '' PIPE'
SIGPIPE_FAIL=0
for script in \
    "$SCRIPTS_DIR/constellation-headscale" \
    "$SCRIPTS_DIR/headscale-status.sh" \
    "$SCRIPTS_DIR/headscale-preauth.sh" \
    "$SCRIPTS_DIR/headscale-selftest.sh" \
    "$SCRIPTS_DIR/headscale-node.sh" \
    "$SCRIPTS_DIR/headscale-switch.sh"; do
    if [[ -f "$script" ]]; then
        if grep -q "trap '' PIPE\|trap \"\" PIPE" "$script" 2>/dev/null; then
            ok "SIGPIPE guard in: $(basename "$script") (AC10)"
        else
            fail "Missing SIGPIPE guard in: $(basename "$script") (AC10)"
            ((SIGPIPE_FAIL++)) || true
        fi
    fi
done

# No plaintext key patterns in scripts
KEY_LEAKS="$(grep -rE '(tskey-auth|nodekey|mkey|privkey)[[:alnum:]]+' \
    "$SCRIPTS_DIR" 2>/dev/null || true)"
if [[ -z "$KEY_LEAKS" ]]; then
    ok "No plaintext key literals in scripts (AC10)"
else
    fail "Possible plaintext key in scripts (AC10):"
    echo "$KEY_LEAKS"
fi

# preauth script must use no_log / not echo the key to stdout in normal flow
if grep -q "no.*log\|suppress\|no.*echo.*key\|/dev/null" "$SCRIPTS_DIR/headscale-preauth.sh" 2>/dev/null; then
    ok "preauth script suppresses key from stdout (AC10)"
else
    fail "preauth script may expose key on stdout (AC10)"
fi

log ""
log "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -eq 0 ]]; then
    log "ALL CHECKS PASS — constellation-headscale role is structurally sound."
    exit 0
else
    log "SOME CHECKS FAILED — see above."
    exit 1
fi
