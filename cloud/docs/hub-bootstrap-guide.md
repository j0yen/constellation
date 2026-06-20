# Hub Bootstrap Guide

Step-by-step instructions to get SSH access to the Hetzner CAX21 hub
(`100.66.158.49`) and bring it into the constellation.

## Background

The hub is reachable at the network level (Tailscale direct path confirmed) but
SSH is currently blocked because:
- No SSH public key has been installed in the hub's `authorized_keys`
- Password authentication is not configured

The one-time fix requires the Hetzner web console to inject the SSH key. After
that, `cloud/scripts/hub-bootstrap.sh` handles everything automatically.

---

## Part 1: Inject SSH key via Hetzner Web Console

### 1.1 Get your SSH public key ready

On this laptop, generate the hub key (or display it if already created):

```bash
# Generate if missing
[[ -f ~/.ssh/id_ed25519_hub ]] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_hub -N ""

# Display the public key — copy this entire line
cat ~/.ssh/id_ed25519_hub.pub
```

It should look like:
```
ssh-ed25519 AAAA...long-string... hub-access-YYYYMMDD
```

### 1.2 Open the Hetzner console

1. Go to [https://console.hetzner.cloud](https://console.hetzner.cloud)
2. Log in and select the **wintermute** project (or whichever project hosts the hub)
3. Click on the **hub** server (CAX21)
4. Click the **Console** tab (the terminal icon)
5. A browser-based console session opens — log in as `root` when prompted

> **Note:** The initial root password was set at server creation time and may
> have been recorded in `pass constellation/hetzner/hub-root-password`.
> If unknown, use Hetzner's "Reset root password" option in the server actions
> menu, which will email a new password.

### 1.3 Add the authorized_keys entry (inside the console)

Once logged in as root in the Hetzner console:

```bash
# Switch to user jsy (create if missing)
id jsy 2>/dev/null || useradd -m -s /bin/bash jsy

# Switch to jsy and install the key
su - jsy
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Paste the PUBLIC key (the long line from step 1.1) into authorized_keys:
echo 'ssh-ed25519 AAAA...YOUR_PUBLIC_KEY... hub-access-YYYYMMDD' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Verify
cat ~/.ssh/authorized_keys
```

> Replace `ssh-ed25519 AAAA...YOUR_PUBLIC_KEY...` with the actual output of
> `cat ~/.ssh/id_ed25519_hub.pub` from the laptop.

### 1.4 Verify SSH access from the laptop

Back on the laptop (not the console):

```bash
ssh -i ~/.ssh/id_ed25519_hub jsy@100.66.158.49 hostname
```

This should print the hub's hostname without asking for a password.
If it works, proceed to Part 2.

---

## Part 2: Run the bootstrap script

```bash
cd ~/wintermute/constellation
bash cloud/scripts/hub-bootstrap.sh
```

The script will:
1. Confirm the SSH key exists
2. Add `Host hub` to `~/.ssh/config` (idempotent)
3. Run `ssh-copy-id` to ensure the key is installed
4. Verify key-based login works (`ssh hub hostname`)
5. Enable `systemd --user` linger: `loginctl enable-linger jsy`
6. Print next steps for Ansible provisioning

---

## Part 3: Full Ansible provisioning

After the bootstrap script succeeds, run the full Ansible play to configure
NATS, Tailscale, firewall, and ollama:

```bash
# From ~/wintermute/constellation:
ansible-playbook -i ansible/inventory/hosts ansible/site.yml --limit hub
```

This runs the `cloud` role which provisions:
- `nats-server` (JetStream hub, leafnode port 7422)
- `tailscale` (tag:cloud, exit node)
- `ollama` with `qwen2.5:3b` (degraded-path brain)
- `nftables` firewall

---

## Part 4: ARM binaries

The hub is `aarch64` (ARM). The cloudbuild system produces x86_64 binaries.
See `cloud/docs/arm-build-notes.md` for the ARM build path.

**Quick start — build agorabus natively on the hub:**

```bash
ssh hub

# Install rustup
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

# Clone and build
git clone https://github.com/j0yen/agorabus.git ~/src/agorabus
cd ~/src/agorabus
cargo build --release

# Install
install -Dm755 target/release/agorabus ~/.local/bin/agorabus
agorabus --version
```

---

## Part 5: Manual admin steps (Tailscale)

After Tailscale is enrolled on the hub, you may want to rename the node in the
admin panel so it appears as `hub` in MagicDNS:

1. Go to [https://login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
2. Find the new hub entry (its current name will be the hostname set at boot)
3. Click the three-dot menu → **Edit machine name** → rename to `hub`
4. Fleet nodes using `hub.tail` will resolve automatically

---

## Verification checklist

After all parts complete, verify:

```bash
# AC1: Key-based SSH access
ssh hub hostname

# AC2: Systemd linger enabled
ssh hub 'loginctl show-user jsy -p Linger'
# Expected: Linger=yes

# AC3: NATS + agorabus active (after Ansible run)
ssh hub 'systemctl --user is-active nats-hub agorabus'
# Expected: active (both lines)

# AC4: Node identity (after PRD-carbon-node-identity is applied)
ssh hub 'wm-node role hub'

# AC5: ARM binary runs
ssh hub 'agorabus --version'
```
