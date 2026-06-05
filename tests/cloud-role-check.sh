#!/usr/bin/env bash
# cloud-role-check.sh — offline structural gate for the constellation cloud role.
#
# Proves, without a live Hetzner box or NATS server, that the Ansible `cloud`
# role + its templates encode the constellation-cloud acceptance invariants.
# This is the honest verification path for a paid-infra PRD: the role cannot be
# LIVE-provisioned without a real Hetzner CAX21 + API token, so the gate is
# structural correctness (compile/lint/--check cleanliness is run separately by
# ansible-lint; this asserts the AC-specific contract on top).
#
#   AC1  cloud node is headless — the role asserts voice_node:false + gpu:none,
#        site.yml skips the desktop role for [cloud] hosts.
#   AC2  NATS runs JetStream domain "hub" with a leafnode listener on :7422.
#   AC3  durable JetStream assets WM_WORK (work-queue stream) + WM_NODES (KV)
#        are defined and created idempotently by the role.
#   AC4  the node enrols as a tag:cloud Tailscale exit node.
#   AC5  an offline-fallback small brain (ollama) is installed, AND the role
#        documents the Anthropic API as the PRIMARY latency brain (not GPU).
#   AC7  no persistent GPU resource is provisioned (cost guardrail).
#
# Exit 0 = all invariants hold; exit 1 = violation.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
ROLE_DIR="${ANSIBLE_DIR}/roles/cloud"

fail=0
note() { echo "OK:   $*"; }
err()  { echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# 0. The role and its key files must exist.
# ---------------------------------------------------------------------------
for f in \
    "${ROLE_DIR}/tasks/main.yml" \
    "${ROLE_DIR}/defaults/main.yml" \
    "${ROLE_DIR}/templates/nats-hub.conf.j2" \
    "${ROLE_DIR}/templates/nats-assets.sh.j2" \
    "${ANSIBLE_DIR}/site.yml" \
    "${ANSIBLE_DIR}/host_vars/hub.yml" ; do
    if [[ ! -f "$f" ]]; then
        err "expected file missing: ${f#"$REPO_ROOT/"}"
    fi
done
[[ "$fail" -eq 0 ]] || { echo "cloud-role-check: FAIL (missing files)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Every YAML/Jinja file in the role must parse (YAML safe_load).
#    Templates are not pure YAML; we only structurally parse the .yml files.
# ---------------------------------------------------------------------------
python3 - "$ANSIBLE_DIR" <<'PY' || fail=1
import glob, os, sys
try:
    import yaml
except Exception as e:
    print(f"FAIL: pyyaml unavailable: {e}", file=sys.stderr); sys.exit(1)
ans = sys.argv[1]
bad = 0
for path in glob.glob(os.path.join(ans, "**", "*.yml"), recursive=True):
    try:
        with open(path, encoding="utf-8") as fh:
            list(yaml.safe_load_all(fh))
    except Exception as e:
        print(f"FAIL: YAML parse error in {os.path.relpath(path, ans)}: {e}", file=sys.stderr)
        bad += 1
if bad:
    sys.exit(1)
print(f"OK:   all ansible/**/*.yml parse as YAML")
PY

# ---------------------------------------------------------------------------
# 2. Assertions on file contents (grep-level contract checks).
# ---------------------------------------------------------------------------
TASKS="${ROLE_DIR}/tasks/main.yml"
DEFAULTS="${ROLE_DIR}/defaults/main.yml"
HUBCONF="${ROLE_DIR}/templates/nats-hub.conf.j2"
ASSETS="${ROLE_DIR}/templates/nats-assets.sh.j2"
SITE="${ANSIBLE_DIR}/site.yml"
HUBVARS="${ANSIBLE_DIR}/host_vars/hub.yml"

has() { grep -Eq "$1" "$2"; }

# --- AC1: headless guardrail ---------------------------------------------
if has 'voice_node.*default\(false\).*bool' "$TASKS" && has 'gpu == "none"' "$TASKS"; then
    note "AC1 role asserts headless (voice_node:false, gpu:none)"
else
    err "AC1 role does not assert voice_node:false + gpu:none guardrail"
fi
if has "'cloud' not in group_names" "$SITE"; then
    note "AC1 site.yml skips desktop role for [cloud] hosts"
else
    err "AC1 site.yml does not skip the desktop role on cloud hosts"
fi
if has '^voice_node:\s*false' "$HUBVARS" && has '^gpu:\s*none' "$HUBVARS"; then
    note "AC1 host_vars/hub.yml pins voice_node:false + gpu:none"
else
    err "AC1 host_vars/hub.yml does not pin headless profile"
fi

# --- AC2: JetStream domain hub + leafnode :7422 --------------------------
if has 'domain:\s*\{\{\s*nats_js_domain\s*\}\}' "$HUBCONF" && has '^nats_js_domain:\s*hub' "$DEFAULTS"; then
    note "AC2 JetStream domain resolves to \"hub\""
else
    err "AC2 JetStream domain is not \"hub\""
fi
if has 'leafnodes\s*\{' "$HUBCONF" && has 'listen:.*nats_leaf_port' "$HUBCONF" && has '^nats_leaf_port:\s*7422' "$DEFAULTS"; then
    note "AC2 leafnode listener bound to :7422"
else
    err "AC2 leafnode listener on :7422 not configured"
fi
if has 'tls\s*\{' "$HUBCONF" && has 'cert_file' "$HUBCONF"; then
    note "AC2 leafnode listener is TLS-enabled"
else
    err "AC2 leafnode listener lacks TLS"
fi

# --- AC3: WM_WORK stream + WM_NODES KV ------------------------------------
if has '^nats_stream_wm_work:' "$DEFAULTS" && has 'name:\s*WM_WORK' "$DEFAULTS" && has 'retention:\s*workqueue' "$DEFAULTS"; then
    note "AC3 WM_WORK work-queue stream defined in defaults"
else
    err "AC3 WM_WORK work-queue stream not defined"
fi
if has '^nats_kv_wm_nodes:' "$DEFAULTS" && has 'bucket:\s*WM_NODES' "$DEFAULTS"; then
    note "AC3 WM_NODES KV bucket defined in defaults"
else
    err "AC3 WM_NODES KV bucket not defined"
fi
if has 'stream (add|info) WM_WORK' "$ASSETS" && has 'kv (add|info) WM_NODES' "$ASSETS"; then
    note "AC3 nats-assets script creates WM_WORK + WM_NODES idempotently"
else
    err "AC3 nats-assets script does not create both assets"
fi
# idempotency: each asset gated by an existence check
if has 'if ! nats_cmd stream info WM_WORK' "$ASSETS" && has 'if ! nats_cmd kv info WM_NODES' "$ASSETS"; then
    note "AC3 asset creation is guarded by existence checks (idempotent)"
else
    err "AC3 asset creation is not guarded by existence checks"
fi

# --- AC4: tag:cloud exit node ---------------------------------------------
if has 'advertise-tags=.*tag:cloud' "$TASKS" || has 'tailscale_tags.*tag:cloud' "$TASKS"; then
    note "AC4 enrols with tag:cloud"
else
    # fall back to defaults wiring
    if has 'tag:cloud' "$DEFAULTS"; then
        note "AC4 tag:cloud wired via defaults/main.yml"
    else
        err "AC4 node not enrolled as tag:cloud"
    fi
fi
if has 'advertise-exit-node' "$TASKS"; then
    note "AC4 advertises as a Tailscale exit node"
else
    err "AC4 node does not advertise as an exit node"
fi

# --- AC5: fallback brain + API-primary rationale --------------------------
if has 'ollama' "$TASKS" && has '^fallback_brain_model:' "$DEFAULTS"; then
    note "AC5 offline-fallback brain (ollama) installed"
else
    err "AC5 offline-fallback brain not installed"
fi
if grep -Eqi 'anthropic api.*(primary|not.*self-hosted|not.*gpu)|primary.*anthropic api' "$TASKS"; then
    note "AC5 role documents Anthropic API as the primary latency brain"
else
    err "AC5 role does not document the API-primary cost rationale"
fi

# --- AC7: no persistent GPU resource --------------------------------------
# The role must NOT install GPU drivers / provision a GPU, and must assert
# gpu == none. Flag any GPU-driver package or always-on GPU provisioning.
if grep -Eqi 'nvidia|cuda|rocm|gpu-operator|--gpu|amdgpu-dkms' "$TASKS"; then
    err "AC7 role appears to provision a persistent GPU resource"
else
    note "AC7 role provisions no persistent GPU resource"
fi
if grep -Eq 'gpu_burst_only_assertion|burst-only' "$TASKS"; then
    note "AC7 role asserts GPU is burst-only / out-of-band"
else
    err "AC7 role lacks the burst-only GPU cost guardrail"
fi

# ---------------------------------------------------------------------------
# 3. Secret hygiene — no auth-key / token material committed in the role.
# ---------------------------------------------------------------------------
if grep -REqi 'tskey-[0-9a-z]|-----BEGIN .*PRIVATE KEY-----' "$ROLE_DIR" "$HUBVARS"; then
    err "secret material (tailscale key / private key) committed in cloud role"
else
    note "no secret material committed in the cloud role"
fi

# ---------------------------------------------------------------------------
if [[ "$fail" -eq 0 ]]; then
    echo "cloud-role-check: PASS"
    exit 0
else
    echo "cloud-role-check: FAIL" >&2
    exit 1
fi
