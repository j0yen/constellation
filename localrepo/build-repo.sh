#!/usr/bin/env bash
# build-repo.sh — build or refresh the local wintermute pacman repo.
#
# USAGE:
#   ./build-repo.sh [--rebuild] [--repo-dir DIR]
#
# Default repo dir: /srv/constellation/pkgs
# (matches localrepo_url in ansible/group_vars/all.yml)
#
# What it does:
#   1. Optionally rebuilds linux-wintermute via makepkg (--rebuild)
#   2. Copies the latest .pkg.tar.zst files from the kernel PKGBUILDs dir
#   3. Runs repo-add to update the database
#   4. Prints the repo URL to use in pacman.conf
#
# The built kernel packages are checked in at:
#   ~/wintermute/wintermute-kernel/pkg/linux-wintermute-*.pkg.tar.zst
#   ~/wintermute/wintermute-kernel/pkg/linux-wintermute-headers-*.pkg.tar.zst
#
# No per-host rebuild: only the control machine builds the kernel once.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PKGBUILD_DIR="${HOME}/wintermute/wintermute-kernel/pkg"
REPO_DIR="/srv/constellation/pkgs"
REPO_NAME="wintermute-local"
REBUILD=false

usage() {
    echo "Usage: $0 [--rebuild] [--repo-dir DIR]"
    echo ""
    echo "  --rebuild     Run makepkg in the PKGBUILD dir before updating the repo"
    echo "  --repo-dir    Directory to serve the repo from (default: ${REPO_DIR})"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)  REBUILD=true; shift ;;
        --repo-dir) REPO_DIR="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *)          echo "Unknown arg: $1" >&2; usage ;;
    esac
done

echo "[localrepo] repo-dir : ${REPO_DIR}"
echo "[localrepo] repo-name: ${REPO_NAME}"
echo "[localrepo] pkgbuild : ${PKGBUILD_DIR}"
echo ""

# ---------------------------------------------------------------------------
# 1. Optional rebuild
# ---------------------------------------------------------------------------
if [[ "${REBUILD}" == "true" ]]; then
    echo "[localrepo] rebuilding linux-wintermute via makepkg..."
    (cd "${PKGBUILD_DIR}" && makepkg -sr --noconfirm --noprogressbar)
    echo "[localrepo] rebuild done."
fi

# ---------------------------------------------------------------------------
# 2. Collect the latest kernel packages
# ---------------------------------------------------------------------------
# Pick the newest linux-wintermute and linux-wintermute-headers packages
kernel_pkg=$(ls -t "${PKGBUILD_DIR}"/linux-wintermute-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)
headers_pkg=$(ls -t "${PKGBUILD_DIR}"/linux-wintermute-headers-*.pkg.tar.zst 2>/dev/null | head -1)

if [[ -z "${kernel_pkg}" ]]; then
    echo "ERROR: no linux-wintermute-*.pkg.tar.zst found in ${PKGBUILD_DIR}" >&2
    echo "       Run with --rebuild, or build the PKGBUILD manually first." >&2
    exit 1
fi

echo "[localrepo] kernel pkg : $(basename "${kernel_pkg}")"
if [[ -n "${headers_pkg}" ]]; then
    echo "[localrepo] headers pkg: $(basename "${headers_pkg}")"
fi

# ---------------------------------------------------------------------------
# 3. Install into repo dir
# ---------------------------------------------------------------------------
sudo mkdir -p "${REPO_DIR}/x86_64"
sudo cp -v "${kernel_pkg}" "${REPO_DIR}/x86_64/"
if [[ -n "${headers_pkg}" ]]; then
    sudo cp -v "${headers_pkg}" "${REPO_DIR}/x86_64/"
fi

# ---------------------------------------------------------------------------
# 4. Build/update the pacman database
# ---------------------------------------------------------------------------
echo "[localrepo] running repo-add..."
(cd "${REPO_DIR}/x86_64" && sudo repo-add "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst)

echo ""
echo "[localrepo] done. Repo is ready at: file://${REPO_DIR}"
echo ""
echo "Add to /etc/pacman.conf (or let ansible manage it):"
echo "  [${REPO_NAME}]"
echo "  SigLevel = Optional TrustAll"
echo "  Server = file://${REPO_DIR}/\$arch"
