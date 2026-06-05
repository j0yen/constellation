#!/usr/bin/env bash
# acl-policy-check.sh — offline semantic gate for the constellation mesh ACL.
#
# Proves, without a live tailnet, that mesh/config/acl-policy.hujson enforces
# the constellation security invariants:
#   AC5  the brain/bus ports are mesh-only — every rule that reaches them is
#        sourced ONLY from fleet tags, never from a public / wildcard source.
#   AC7  the bus/brain ports are restricted to fleet tags; an untagged or
#        out-of-policy source is denied (default-deny, no wildcard accept).
#  AC10  no mesh private key / auth key material is embedded in the policy.
#
# The HuJSON policy is parsed by stripping // and /* */ comments to JSON, then
# inspected with python3. Exit 0 = all invariants hold; exit 1 = violation.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACL_FILE="${REPO_ROOT}/mesh/config/acl-policy.hujson"

fail=0
note() { echo "OK:   $*"; }
err()  { echo "FAIL: $*" >&2; fail=1; }

if [[ ! -f "$ACL_FILE" ]]; then
    echo "FAIL: ACL policy not found: $ACL_FILE" >&2
    exit 1
fi

# The protected ports that MUST be fleet-only.
PROTECTED_PORTS="4222 7422 8080 22"

python3 - "$ACL_FILE" "$PROTECTED_PORTS" <<'PY'
import json, re, sys

acl_path = sys.argv[1]
protected = set(sys.argv[2].split())

raw = open(acl_path, encoding="utf-8").read()

# Strip /* ... */ block comments, then // line comments, to get plain JSON.
no_block = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
lines = []
for line in no_block.splitlines():
    # remove // comments not inside strings (policy uses no // inside strings)
    lines.append(re.sub(r"//.*$", "", line))
text = "\n".join(lines)
# drop trailing commas before } or ]
text = re.sub(r",(\s*[}\]])", r"\1", text)

try:
    policy = json.loads(text)
except Exception as e:
    print(f"FAIL: could not parse HuJSON as JSON: {e}", file=sys.stderr)
    sys.exit(1)

violations = 0
def err(msg):
    global violations
    print(f"FAIL: {msg}", file=sys.stderr); violations += 1
def ok(msg):
    print(f"OK:   {msg}")

acls = policy.get("acls", [])
if not acls:
    err("policy has no acls[] rules")

# Sources we consider "public / not fleet-restricted".
PUBLIC_SRCS = {"*", "0.0.0.0/0", "::/0", "autogroup:internet"}

def is_fleet_src(srcs):
    # every source must be a tag:* (fleet membership), never wildcard/public.
    for s in srcs:
        if s in PUBLIC_SRCS:
            return False
        if not s.startswith("tag:"):
            return False
    return True

# AC5 / AC7: every accept rule touching a protected port must be fleet-tagged src.
protected_rules_seen = 0
for rule in acls:
    if rule.get("action") != "accept":
        continue
    dsts = rule.get("dst", [])
    srcs = rule.get("src", [])
    for d in dsts:
        # dst form is "tag:x:port" or "host:port"
        port = d.rsplit(":", 1)[-1]
        if port in protected:
            protected_rules_seen += 1
            if not is_fleet_src(srcs):
                err(f"protected port {port} reachable from non-fleet src {srcs} "
                    f"(rule dst={d}) — violates mesh-only invariant")
            else:
                ok(f"port {port} reachable only from fleet tags {srcs}")

if protected_rules_seen == 0:
    err("no accept rule references any protected port — policy is suspect")

# AC5/AC7: there must be NO blanket wildcard-accept that would open everything.
for rule in acls:
    if rule.get("action") == "accept":
        srcs = rule.get("src", [])
        dsts = rule.get("dst", [])
        if any(s in PUBLIC_SRCS for s in srcs):
            # a public src is only tolerable for a deliberately public port,
            # which this fleet has none of — flag it.
            err(f"accept rule has public src {srcs} dst={dsts} — fleet has no public ports")
        if any(d in ("*", "*:*") for d in dsts) and any(s in PUBLIC_SRCS for s in srcs):
            err(f"wildcard public accept rule found: src={srcs} dst={dsts}")

ok("default-deny relied upon (no public wildcard accept rule present)" )

# AC10: no secret/key material embedded.
SECRET_HINTS = ["tskey-", "authkey", "auth_key", "PRIVATE KEY", "preauthkey"]
low = raw.lower()
for hint in SECRET_HINTS:
    if hint.lower() in low:
        err(f"possible secret material '{hint}' present in ACL file")
ok("no auth-key / private-key material embedded in ACL")

# tagOwners must exist for every fleet tag used.
declared = set(policy.get("tagOwners", {}).keys())
used = set()
for rule in acls:
    for s in rule.get("src", []):
        if s.startswith("tag:"):
            used.add(s)
    for d in rule.get("dst", []):
        if d.startswith("tag:"):
            used.add(d.rsplit(":", 1)[0])
missing = used - declared
if missing:
    err(f"tags used in acls but never declared in tagOwners: {sorted(missing)}")
else:
    ok(f"all {len(used)} tags used in acls are declared in tagOwners")

if violations:
    print(f"acl-policy-check: FAILED with {violations} violation(s)", file=sys.stderr)
    sys.exit(1)
print("acl-policy-check: all ACL invariants hold")
sys.exit(0)
PY
rc=$?
[[ $rc -ne 0 ]] && fail=1

if [[ "$fail" -eq 0 ]]; then
    echo "acl-policy-check: PASS"
    exit 0
else
    echo "acl-policy-check: FAIL" >&2
    exit 1
fi
