#!/usr/bin/env bash
# tests/carbon-rename-idempotent.sh
# Asserts that running carbon-rename.sh twice produces no changes on the second run.
# This test focuses on the node.toml and WM_NODE steps (the hostname step is
# user-gated sudo and must be skipped in automated testing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENAME_SCRIPT="$SCRIPT_DIR/../bin/carbon-rename.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

echo "=== carbon-rename idempotency test ==="

# Stub: override HOME to a temp dir so we don't touch real config
export HOME="$TMPDIR_TEST"
mkdir -p "$HOME/.config/systemd/user" "$HOME/.config/environment.d"

# Stub: fake hostname command that returns "carbon" so the sudo step is a no-op
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo "carbon"
EOF
chmod +x "$TMPDIR_TEST/bin/hostname"
export PATH="$TMPDIR_TEST/bin:$PATH"

# Stub: fake sudo that is a no-op (so the hostnamectl line doesn't fail)
cat > "$TMPDIR_TEST/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# no-op stub for testing
EOF
chmod +x "$TMPDIR_TEST/bin/sudo"

echo "--- Run 1 ---"
output1=$(bash "$RENAME_SCRIPT" 2>&1)
echo "$output1"

echo ""
echo "--- Run 2 (should be all no-ops) ---"
output2=$(bash "$RENAME_SCRIPT" 2>&1)
echo "$output2"

echo ""
echo "--- Assertions ---"

PASS=0
FAIL=0

# Assert node.toml was created after run 1
if [ -f "$HOME/.config/wintermute/node.toml" ]; then
  echo "PASS: node.toml created"
  PASS=$((PASS+1))
else
  echo "FAIL: node.toml missing after first run"
  FAIL=$((FAIL+1))
fi

# Assert node.toml content is correct
expected_name='name = "carbon"'
if grep -q "$expected_name" "$HOME/.config/wintermute/node.toml" 2>/dev/null; then
  echo "PASS: node.toml has name = \"carbon\""
  PASS=$((PASS+1))
else
  echo "FAIL: node.toml missing expected name"
  FAIL=$((FAIL+1))
fi

# Assert second run says "no-op" for node.toml
if echo "$output2" | grep -q "node.toml: already exists (no-op)"; then
  echo "PASS: second run was no-op for node.toml"
  PASS=$((PASS+1))
else
  echo "FAIL: second run did not say no-op for node.toml"
  FAIL=$((FAIL+1))
fi

# Assert second run says "no-op" for hostname
if echo "$output2" | grep -q "hostname: already carbon (no-op)"; then
  echo "PASS: second run was no-op for hostname"
  PASS=$((PASS+1))
else
  echo "FAIL: second run did not say no-op for hostname"
  FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "All assertions passed."
