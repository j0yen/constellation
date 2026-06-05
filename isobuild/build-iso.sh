#!/usr/bin/env bash
# build-iso.sh — build the constellation golden ISO with mkarchiso.
#
# USAGE:
#   sudo ./build-iso.sh [--work-dir DIR] [--out-dir DIR] [--validate-only]
#
# Produces:  <out-dir>/wintermute-<YYYY.MM.DD>-x86_64.iso
#
# Requirements (on the BUILD host, not the target):
#   - archiso (provides mkarchiso)            pacman -S archiso
#   - root (mkarchiso needs it for the squashfs / loop mounts)
#   - the local wintermute repo built first:  ../localrepo/build-repo.sh
#
# --validate-only runs every check that does NOT require root or archiso, so it
# can run in CI / on the dev laptop to prove the profile is well-formed (AC4
# build-script-completes gate, minus the actual mkarchiso invocation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK_DIR="/tmp/constellation-iso-work"
OUT_DIR="${SCRIPT_DIR}/out"
VALIDATE_ONLY=false
LOCALREPO_DIR="/srv/constellation/pkgs"

usage() {
  sed -n '2,20p' "$0"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir)      WORK_DIR="$2"; shift 2 ;;
    --out-dir)       OUT_DIR="$2"; shift 2 ;;
    --localrepo-dir) LOCALREPO_DIR="$2"; shift 2 ;;
    --validate-only) VALIDATE_ONLY=true; shift ;;
    -h|--help)       usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

# ---------------------------------------------------------------------------
# 1. Validate the profile shape (no root / no archiso needed)
# ---------------------------------------------------------------------------
echo "[isobuild] validating profile at ${PROFILE_DIR}"

required_files=(
  "profiledef.sh"
  "pacman.conf"
  "packages.x86_64"
  "airootfs/etc/pacman.conf"
  "airootfs/root/archinstall.json"
  "airootfs/usr/local/bin/constellation-firstboot"
  "airootfs/etc/systemd/system/constellation-firstboot.service"
)
for f in "${required_files[@]}"; do
  [[ -e "${PROFILE_DIR}/${f}" ]] || fail "missing required profile file: ${f}"
  ok "${f}"
done

# profiledef.sh must source cleanly and set the key vars.
# shellcheck source=/dev/null
( set -e; source "${PROFILE_DIR}/profiledef.sh"
  [[ -n "${iso_name:-}" ]]   || { echo "iso_name unset" >&2; exit 1; }
  [[ -n "${arch:-}" ]]       || { echo "arch unset" >&2; exit 1; }
  [[ "${arch}" == "x86_64" ]] || { echo "arch must be x86_64" >&2; exit 1; }
) || fail "profiledef.sh is malformed"
ok "profiledef.sh sources cleanly"

# packages.x86_64 must carry the wintermute kernel (the whole point of the ISO).
grep -qxF "linux-wintermute" "${PROFILE_DIR}/packages.x86_64" \
  || fail "packages.x86_64 does not include linux-wintermute"
ok "packages.x86_64 includes linux-wintermute"

# the local repo must be wired into BOTH the build pacman.conf and the airootfs one.
grep -q "\[wintermute-local\]" "${PROFILE_DIR}/pacman.conf" \
  || fail "build pacman.conf is missing [wintermute-local]"
grep -q "\[wintermute-local\]" "${PROFILE_DIR}/airootfs/etc/pacman.conf" \
  || fail "airootfs pacman.conf is missing [wintermute-local]"
ok "local wintermute repo wired into pacman.conf (build + airootfs)"

# archinstall answer file must be valid JSON and pin the wintermute kernel.
if command -v jq >/dev/null 2>&1; then
  jq -e '.kernels | index("linux-wintermute")' \
    "${PROFILE_DIR}/airootfs/root/archinstall.json" >/dev/null \
    || fail "archinstall.json does not pin linux-wintermute as the kernel"
  ok "archinstall.json valid JSON, pins linux-wintermute"
else
  echo "  warn: jq not found; skipping archinstall.json JSON check"
fi

# firstboot script must be syntactically valid bash.
bash -n "${PROFILE_DIR}/airootfs/usr/local/bin/constellation-firstboot" \
  || fail "constellation-firstboot has a syntax error"
ok "constellation-firstboot parses"

echo "[isobuild] profile validation PASSED"

if [[ "${VALIDATE_ONLY}" == "true" ]]; then
  echo "[isobuild] --validate-only set; not invoking mkarchiso."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Preconditions for the real build
# ---------------------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || fail "mkarchiso requires root; re-run with sudo."
command -v mkarchiso >/dev/null 2>&1 \
  || fail "mkarchiso not found; install archiso (pacman -S archiso)."

if [[ ! -f "${LOCALREPO_DIR}/x86_64/wintermute-local.db.tar.gz" ]]; then
  fail "local repo db not found at ${LOCALREPO_DIR}/x86_64/. Run ../localrepo/build-repo.sh first."
fi
ok "local wintermute repo present at ${LOCALREPO_DIR}"

# ---------------------------------------------------------------------------
# 3. Build
# ---------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"
echo "[isobuild] running mkarchiso (work=${WORK_DIR} out=${OUT_DIR})"
mkarchiso -v -w "${WORK_DIR}" -o "${OUT_DIR}" "${PROFILE_DIR}"

iso="$(ls -t "${OUT_DIR}"/wintermute-*.iso 2>/dev/null | head -1)"
[[ -n "${iso}" ]] || fail "build finished but no wintermute-*.iso found in ${OUT_DIR}"

echo ""
echo "[isobuild] DONE: ${iso}"
echo "[isobuild] boot it in a VM:  qemu-system-x86_64 -m 4096 -cdrom ${iso} -bios /usr/share/edk2/x64/OVMF.4m.fd"
