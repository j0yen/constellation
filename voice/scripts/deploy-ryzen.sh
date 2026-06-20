#!/usr/bin/env bash
# deploy-ryzen.sh — Deploy wintermute voice daemons to ryzen-work
#
# Rsyncs binaries from wintermute:~/.local/bin/ to ryzen-work and deploys
# systemd user units. Audio-stack (wm-audio, wm-stt) excluded:
#   - wm-audio: requires GLIBC_2.43 (Arch Linux), ryzen-work is Ubuntu 24.04 (GLIBC_2.42)
#   - wm-stt: whisper.cpp compiled with AVX-512; Ryzen 5825U has no AVX-512
# Brain stack (wmd, wm-tts, wm-dialog, agorabus) deploys and runs correctly.
#
# Usage:
#   bash deploy-ryzen.sh             # deploy brain-stack daemons
#   bash deploy-ryzen.sh --status    # check service status on ryzen-work
#
# Limitations (future work):
#   - wm-audio + wm-stt require rebuilding with --target-cpu=znver3 (no AVX-512)
#   - TTS model pre-staged at ryzen-work:~/.local/share/wintermute/tts/models/
#   - Whisper model pre-staged at ryzen-work:~/.local/share/wintermute/models/
#
# First deployed: 2026-06-20 by Claude (constellation-wm-daemons-ryzen PRD)
set -euo pipefail

TARGET=ryzen-work
BINARIES=(wm-dialog wm-tts wmd wmd-init agorabus)

if [[ "${1:-}" == "--status" ]]; then
    echo "=== ryzen-work wintermute daemon status ==="
    ssh "$TARGET" "systemctl --user is-active agorabus.service wm-dialog.service wm-tts.service wmd.service 2>&1"
    echo "--- agorabus peers ---"
    ssh "$TARGET" "~/.local/bin/agorabus peers 2>&1 | python3 -m json.tool" 2>&1 | head -40
    exit 0
fi

echo "Deploying binaries to $TARGET..."
ssh "$TARGET" "mkdir -p ~/.local/bin"
rsync -avz "${BINARIES[@]/#/$HOME/.local/bin/}" "$TARGET:~/.local/bin/"

echo "Deploying service files..."
ssh "$TARGET" "mkdir -p ~/.config/systemd/user"

deploy_service() {
    local name="$1"
    local content="$2"
    ssh "$TARGET" "cat > ~/.config/systemd/user/${name}" <<< "$content"
}

# agorabus service (already managed by its own PRD, just ensure it's enabled)
deploy_service "wm-dialog.service" '[Unit]
Description=wintermute dialog (conversational FSM, turn-taker, barge-in)
PartOf=wintermute.target
After=agorabus.service
Wants=agorabus.service

[Service]
Type=simple
EnvironmentFile=%h/.config/wintermute/conf.d/00-bootstrap.env
ExecStart=%h/.local/bin/wm-dialog start
Restart=on-failure
RestartSec=5
TimeoutStartSec=30
Environment=RUST_LOG=info

[Install]
WantedBy=wintermute.target'

deploy_service "wm-tts.service" '[Unit]
Description=wintermute text-to-speech (wm-tts)
PartOf=wintermute.target
After=agorabus.service
Wants=agorabus.service

[Service]
Type=simple
EnvironmentFile=%h/.config/wintermute/conf.d/00-bootstrap.env
Environment=RUST_LOG=info
ExecStart=%h/.local/bin/wm-tts --cache-config %h/.config/wintermute/tts-cache.yaml start
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=wintermute.target'

deploy_service "wmd.service" '[Unit]
Description=wintermute brain (Claude API loop)
PartOf=wintermute.target
After=wm-dialog.service agorabus.service
Wants=agorabus.service

[Service]
Type=simple
EnvironmentFile=%h/.config/wintermute/conf.d/00-bootstrap.env
Environment=RUST_LOG=info
ExecStart=%h/.local/bin/wmd start
Restart=on-failure
RestartSec=5
TimeoutStartSec=30

[Install]
WantedBy=wintermute.target'

deploy_service "wintermute.target" '[Unit]
Description=wintermute voice AI stack (ryzen-work node)
Wants=agorabus.service wm-tts.service wm-dialog.service wmd.service
After=agorabus.service wm-tts.service wm-dialog.service wmd.service'

echo "Enabling services..."
ssh "$TARGET" "systemctl --user daemon-reload"
ssh "$TARGET" "systemctl --user enable wm-dialog.service wm-tts.service wmd.service wintermute.target"
ssh "$TARGET" "systemctl --user start wintermute.target"

echo "Done. Run with --status to verify."
