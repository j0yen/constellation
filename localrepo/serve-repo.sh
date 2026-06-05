#!/usr/bin/env bash
# serve-repo.sh — serve the local wintermute pacman repo over HTTP via darkhttpd.
#
# USAGE:
#   ./serve-repo.sh [--port PORT] [--repo-dir DIR] [--daemonize]
#
# The repo is served on all interfaces at the given port. Other constellation
# nodes point their pacman.conf Server= line at http://<control-node-ip>:<port>/$arch
#
# Requirements:
#   - darkhttpd (or any static file server)
#   - The repo dir must already be populated by build-repo.sh
#
# For file:// access on the same machine, this script is optional — set:
#   Server = file:///srv/constellation/pkgs/$arch
#
# For mesh-wide access (multiple nodes), run this on the node that holds the
# prebuilt kernel packages, or deploy it as a systemd service with:
#   systemctl --user enable --now constellation-localrepo.service
# (see constellation-localrepo.service in this directory)

set -euo pipefail

REPO_DIR="/srv/constellation/pkgs"
PORT=7878
DAEMONIZE=false

usage() {
    echo "Usage: $0 [--port PORT] [--repo-dir DIR] [--daemonize]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)      PORT="$2"; shift 2 ;;
        --repo-dir)  REPO_DIR="$2"; shift 2 ;;
        --daemonize) DAEMONIZE=true; shift ;;
        -h|--help)   usage ;;
        *)           echo "Unknown arg: $1" >&2; usage ;;
    esac
done

if [[ ! -d "${REPO_DIR}" ]]; then
    echo "ERROR: repo dir does not exist: ${REPO_DIR}" >&2
    echo "       Run build-repo.sh first." >&2
    exit 1
fi

if ! command -v darkhttpd &>/dev/null; then
    echo "ERROR: darkhttpd not found. Install with: sudo pacman -S darkhttpd" >&2
    exit 1
fi

echo "[serve-repo] serving ${REPO_DIR} on port ${PORT}"
echo "[serve-repo] Other nodes can use:"
echo "             Server = http://$(hostname -I | awk '{print $1}'):${PORT}/\$arch"

if [[ "${DAEMONIZE}" == "true" ]]; then
    exec darkhttpd "${REPO_DIR}" --port "${PORT}" --daemon
else
    exec darkhttpd "${REPO_DIR}" --port "${PORT}"
fi
