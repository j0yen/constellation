# ARM Build Notes — Hetzner CAX21 Hub

The hub runs **aarch64** (ARM64). The cloudbuild burst system
(`cloud/scripts/cloudbuild.sh`) provisions Hetzner x86_64 boxes and produces
x86_64 binaries — these will not run on the hub.

---

## Selected approach: native build on hub (Option A)

For bootstrap, the recommended approach is **native build on the hub**.
The CAX21 has 4 vCPUs and 8GB RAM — enough for a Rust release build, though
cold builds of heavy crates (e.g. `fastembed`) may take 10-20 minutes.

```bash
# 1. SSH into the hub
ssh hub

# 2. Install rustup (first time only)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env

# 3. Clone and build any wintermute crate
git clone https://github.com/j0yen/agorabus.git ~/src/agorabus
cd ~/src/agorabus
cargo build --release

# 4. Install
install -Dm755 target/release/agorabus ~/.local/bin/agorabus
agorabus --version
```

### sccache acceleration (optional)

To avoid cold rebuilds when iterating, install `sccache` on the hub:

```bash
cargo install sccache
echo 'export RUSTC_WRAPPER=sccache' >> ~/.bashrc
```

---

## Alternative: cross-compile from this laptop (Option B)

Cross-compilation avoids running Rust on the hub but requires the
`aarch64-unknown-linux-gnu` cross toolchain on the laptop.

```bash
# On the laptop:

# 1. Add the Rust target
rustup target add aarch64-unknown-linux-gnu

# 2. Install cross (Docker-based cross-compilation)
cargo install cross --git https://github.com/cross-rs/cross

# 3. Build
cd ~/wintermute/agorabus
cross build --target aarch64-unknown-linux-gnu --release

# 4. Copy to hub
scp target/aarch64-unknown-linux-gnu/release/agorabus hub:~/.local/bin/agorabus
ssh hub 'agorabus --version'
```

**Requirement:** Docker must be running on the laptop.
`cross` uses a pre-built Docker image with the correct sysroot and linker.

---

## Alternative: burst ARM builder (Option C — future)

A future PRD (`PRD-carbon-arm-builder`) could provision an on-demand ARM
Hetzner CAX11 for cross-compiles, analogous to the x86 cloudbuild pattern.
This would be transparent to the developer — `wm-armbuild` wrapper, same
interface as `cloudbuild`.

---

## wm-armbuild helper

The wrapper below documents the intended interface for Option C once built.
For now it falls back to Option A (SSH into hub and build natively).

```bash
# cloud/scripts/wm-armbuild — not yet a burst builder; ssh-based native build
#!/usr/bin/env bash
set -euo pipefail
CRATE="${1:?Usage: wm-armbuild <crate-name>}"
HUB_REPO="${HUB_REPO:-~/src/${CRATE}}"
echo "[wm-armbuild] Building ${CRATE} natively on hub ..."
ssh hub "bash -lc 'cd ${HUB_REPO} && cargo build --release'"
echo "[wm-armbuild] Done. Binary at ${HUB_REPO}/target/release/${CRATE}"
```

---

## Arch decision record

| Option | Chosen? | Reason |
|---|---|---|
| A — native on hub | **YES (default)** | Simple; hub has RAM; no Docker dependency |
| B — cross-compile (`cross`) | Fallback | Faster iteration; needs Docker on laptop |
| C — burst ARM builder | Future | Burst cost savings; worth PRD when queue grows |

Update this file when the ARM build approach changes.
