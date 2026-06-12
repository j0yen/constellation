# Secrets Bootstrap Guide

This document explains how to deliver the root `age` key to a new constellation node
and verify it can decrypt the service-secret store.

## Overview

Every node needs exactly **one** root `age` identity at `~/.config/sops/age/keys.txt`
before it can decrypt any service secret (NATS creds, Tailscale authkey,
`WM_ANTHROPIC_API_KEY`). This document covers the three supported delivery channels.

The `constellation-secrets bootstrap` command:
1. Reads the private key from `--key-file` or stdin.
2. Validates it looks like a real `age` private key (`AGE-SECRET-KEY-` prefix).
3. Verifies it can decrypt the committed canary (`secrets/canary.yaml`) — fails
   loud before installing if the canary fails.
4. Appends the key to `~/.config/sops/age/keys.txt` (mode `0600`, created if absent).
5. Is idempotent — re-running with the same key already present is a no-op.

## Delivery Channels

### Option 1 — Manual paste over SSH (recommended default)

Suitable for any host reachable by SSH, including the initial provision of a
fresh cloud node or desktop.

```bash
# 1. Generate a host age keypair on a trusted machine (not the target host):
age-keygen -o /tmp/new-host.key
# Record the public key printed to stderr: age1...

# 2. Add the public key to .sops.yaml under the correct role, then
#    re-encrypt any secrets that should be readable by the new host:
#    sops updatekeys secrets/<role>/<name>.yaml

# 3. Deliver the private key via SSH:
ssh user@newhost 'mkdir -p ~/.config/sops/age'
ssh user@newhost 'cat > /tmp/age.key' < /tmp/new-host.key
ssh user@newhost 'constellation-secrets bootstrap --key-file /tmp/age.key && shred -u /tmp/age.key'

# 4. Shred the temporary keypair on the source machine:
shred -u /tmp/new-host.key
```

### Option 2 — USB stick (air-gapped first boot)

Suitable for nodes with no network access during initial provision.

```bash
# 1. Generate the host age keypair:
age-keygen -o /path/to/usb/age-host.key

# 2. Update .sops.yaml + re-encrypt secrets (same as above).

# 3. On the fresh host, mount the USB and bootstrap:
mount /dev/sdX1 /mnt/usb
constellation-secrets bootstrap --key-file /mnt/usb/age-host.key

# 4. Eject the USB and physically destroy (or securely erase) the key copy.
umount /mnt/usb
```

### Option 3 — Tunnel (once mesh is running)

Once a node is enrolled in the Tailscale mesh, you can use the tunnel to deliver
keys to new nodes or rotate existing ones.

```bash
tailscale ssh user@newhost 'mkdir -p ~/.config/sops/age'
tailscale ssh user@newhost 'cat > /tmp/age.key' < /path/to/new-host.key
tailscale ssh user@newhost 'constellation-secrets bootstrap --key-file /tmp/age.key && shred -u /tmp/age.key'
```

## What NOT to do

- **Never email or chat the private key** — treat it like an SSH private key.
- **Never commit the private key** — only public keys go in `.sops.yaml`.
- **Never leave the key in `$HOME`** — use a tmpfs path or USB mount.
- **Never skip the canary check** — if bootstrap prints `Canary verification FAILED`,
  the delivered key is wrong; investigate before proceeding.

## Verifying bootstrap

After bootstrap, confirm the host can decrypt its secrets:

```bash
# Check all declared secrets for the host role:
constellation-secrets audit

# Decrypt one secret to verify end-to-end:
constellation-secrets get WM_ANTHROPIC_API_KEY
```

## Key rotation

To rotate a host's root key:

1. Generate a new age keypair: `age-keygen -o /tmp/new.key`
2. Extract the public key: `age-keygen -y /tmp/new.key`
3. Update `.sops.yaml` to include the new public key alongside the old one.
4. Re-encrypt all secrets: `sops updatekeys secrets/<role>/<name>.yaml` for each file.
5. Deliver the new private key: `constellation-secrets bootstrap --key-file /tmp/new.key`
6. Remove the old public key from `.sops.yaml` and re-encrypt again to revoke.
7. Shred the old key file on the host (remove the old `AGE-SECRET-KEY-` block from
   `~/.config/sops/age/keys.txt`).

## Canary initialisation (new fleet setup)

The `secrets/canary.yaml` starts as a plaintext template. Before your first real
node provision, encrypt it with all role keys so bootstrap can verify delivery:

```bash
# After adding real public keys to .sops.yaml:
sops --encrypt --in-place secrets/canary.yaml
git add secrets/canary.yaml && git commit -m "chore(secrets): encrypt canary for bootstrap verification"
```
