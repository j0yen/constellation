#!/usr/bin/env bash
# deploy-ryzen.sh — Deploy wintermute voice daemons to ryzen-work
#
# Rsyncs brain-stack binaries from wintermute:~/.local/bin/ to ryzen-work.
# Audio-stack (wm-audio, wm-stt) are built natively on ryzen-work:
#   - Built from source on ryzen-work (Ubuntu 25.10, GLIBC 2.42, no AVX-512)
#   - RUSTFLAGS='-C target-cpu=native' ensures Ryzen 5825U compatibility
#   - Source: ~/wintermute/wintermute-audio/ and ~/wintermute/wintermute-stt/
#
# Usage:
#   bash deploy-ryzen.sh                 # deploy brain-stack daemons
#   bash deploy-ryzen.sh --build-audio   # (re)build wm-audio + wm-stt natively on ryzen-work
#   bash deploy-ryzen.sh --status        # check service status on ryzen-work
#   bash deploy-ryzen.sh --greetd        # install/configure greetd on ryzen-work
#
# Requirements:
#   - ryzen-work must have Rust 1.88+ (installed via rustup)
#   - ryzen-work must have cmake in ~/.local/bin/ (installed from upstream binary)
#   - ryzen-work must have jsy-nopasswd sudoers entry (written via docker)
#
# First deployed: 2026-06-20 by Claude (constellation-wm-daemons-ryzen PRD)
# Audio fix:      2026-06-20 by Claude (constellation-voice-boot-ryzen PRD)
set -euo pipefail

TARGET=ryzen-work
BINARIES=(wm-dialog wm-tts wmd wmd-init agorabus)

if [[ "${1:-}" == "--status" ]]; then
    echo "=== ryzen-work wintermute daemon status ==="
    ssh "$TARGET" "systemctl --user is-active agorabus.service wm-audio.service wm-stt.service wm-dialog.service wm-tts.service wmd.service wintermute.target 2>&1"
    echo "--- greetd status ---"
    ssh "$TARGET" "systemctl is-active greetd 2>&1"
    echo "--- agorabus peers ---"
    ssh "$TARGET" "~/.local/bin/agorabus peers 2>&1 | python3 -m json.tool" 2>&1 | head -40
    exit 0
fi

if [[ "${1:-}" == "--build-audio" ]]; then
    echo "Building wm-audio and wm-stt natively on ryzen-work..."
    # Ensure cmake is in PATH (installed to ~/.local/bin/cmake from upstream binary)
    ssh "$TARGET" "
        export PATH=\$HOME/.local/bin:\$PATH
        git -C ~/wintermute clone https://github.com/j0yen/wintermute-audio.git 2>/dev/null || git -C ~/wintermute/wintermute-audio pull
        git -C ~/wintermute clone https://github.com/j0yen/wintermute-stt.git 2>/dev/null || git -C ~/wintermute/wintermute-stt pull
        cd ~/wintermute/wintermute-audio && RUSTFLAGS='-C target-cpu=native' ~/.cargo/bin/cargo build --release
        install -m755 ~/wintermute/wintermute-audio/target/release/wm-audio ~/.local/bin/wm-audio
        cd ~/wintermute/wintermute-stt && RUSTFLAGS='-C target-cpu=native' ~/.cargo/bin/cargo build --features whisper --release
        install -m755 ~/wintermute/wintermute-stt/target/release/wm-stt ~/.local/bin/wm-stt
        systemctl --user restart wm-audio.service wm-stt.service
        echo 'Audio stack rebuilt and restarted'
    "
    exit 0
fi

if [[ "${1:-}" == "--greetd" ]]; then
    echo "Installing and configuring greetd on ryzen-work..."
    # Write sudoers NOPASSWD via docker (jsy is in docker group)
    ssh "$TARGET" "docker run --rm -v /etc:/hostfs/etc ubuntu:25.10 bash -c '
        echo \"jsy ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg, /usr/bin/tee, /bin/cp, /bin/mv, /usr/bin/systemctl\" > /hostfs/etc/sudoers.d/jsy-nopasswd
        chmod 440 /hostfs/etc/sudoers.d/jsy-nopasswd
    '"
    ssh "$TARGET" "sudo -n apt-get install -y greetd"
    ssh "$TARGET" "sudo -n tee /etc/greetd/config.toml" << 'EOF'
[terminal]
vt = 2

[default_session]
command = "agreety --cmd i3"
user = "jsy"

[initial_session]
command = "i3"
user = "jsy"
EOF
    ssh "$TARGET" "sudo -n systemctl disable gdm 2>/dev/null || true"
    ssh "$TARGET" "sudo -n systemctl enable greetd"
    ssh "$TARGET" "sudo -n systemctl reset-failed greetd.service 2>/dev/null || true"
    ssh "$TARGET" "sudo -n systemctl start greetd"
    echo "greetd configured and started"
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

deploy_service "wm-audio.service" '[Unit]
Description=wintermute mic pipeline (wm-audio)
PartOf=wintermute.target
After=agorabus.service
Wants=agorabus.service

[Service]
Type=simple
EnvironmentFile=%h/.config/wintermute/conf.d/00-bootstrap.env
Environment=RUST_LOG=info
ExecStart=%h/.local/bin/wm-audio start
Restart=on-failure
RestartSec=5
TimeoutStartSec=30

[Install]
WantedBy=wintermute.target'

deploy_service "wm-stt.service" '[Unit]
Description=wintermute speech-to-text (wm-stt)
PartOf=wintermute.target
After=agorabus.service wm-audio.service
Wants=agorabus.service

[Service]
Type=simple
EnvironmentFile=%h/.config/wintermute/conf.d/00-bootstrap.env
Environment=RUST_LOG=info
Environment=WM_STT_MODELS_ROOT=%h/.local/share/wintermute/models
ExecStart=%h/.local/bin/wm-stt start
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=wintermute.target'

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
Documentation=https://github.com/j0yen/wintermute-platform
Wants=agorabus.service wm-audio.service wm-stt.service wm-tts.service wm-dialog.service wmd.service
After=agorabus.service wm-audio.service wm-stt.service wm-tts.service wm-dialog.service wmd.service

[Install]
WantedBy=gnome-session-initialized.target'

echo "Enabling services..."
ssh "$TARGET" "systemctl --user daemon-reload"
ssh "$TARGET" "systemctl --user enable wm-audio.service wm-stt.service wm-dialog.service wm-tts.service wmd.service wintermute.target"
ssh "$TARGET" "systemctl --user start wintermute.target"

echo "Done. Run with --status to verify."
