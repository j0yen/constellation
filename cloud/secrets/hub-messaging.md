# hub-messaging secrets

This document describes the secrets required by the hub messaging subsystem
(outbound owner-notify + relay email sends) and how to provision them via the
constellation sops/secrets infrastructure.

## Required secrets

| Secret name                          | Role    | Purpose                                              |
|--------------------------------------|---------|------------------------------------------------------|
| `HOMEWARD_SMTP_HOST`                 | cloud   | SMTP server hostname (e.g. smtp.mailgun.org)         |
| `HOMEWARD_SMTP_PORT`                 | cloud   | SMTP port (usually 587 for STARTTLS)                 |
| `HOMEWARD_SMTP_USER`                 | cloud   | SMTP username / sender address                       |
| `HOMEWARD_SMTP_PASSWORD`             | cloud   | SMTP password or app-specific password               |
| `HOMEWARD_RELAY_API_KEY`             | cloud   | API key for the relay email provider (Mailgun, etc.) |
| `HOMEWARD_RELAY_DOMAIN`              | cloud   | Sending domain registered with relay provider        |
| `HOMEWARD_NOTIFY_FROM`              | cloud   | "From" address for owner-notify emails               |
| `HOMEWARD_NOTIFY_REPLY_TO`          | cloud   | Optional reply-to address                            |

All of these land in `~/.config/wintermute/secrets/messaging.env` on the hub
(see §Path on hub below).

## Creating secrets via sops

Secrets are scoped to the `cloud` role (only the hub can decrypt them).
The `.sops.yaml` at repo root controls encryption recipients.

### Step 1 — create the sops file

```bash
# Run from repo root
sops secrets/cloud/messaging.yaml
```

This opens `$EDITOR` with a template. Fill in:

```yaml
HOMEWARD_SMTP_HOST: "smtp.mailgun.org"
HOMEWARD_SMTP_PORT: "587"
HOMEWARD_SMTP_USER: "postmaster@mg.yourdomain.com"
HOMEWARD_SMTP_PASSWORD: "YOUR_SMTP_PASSWORD_HERE"
HOMEWARD_RELAY_API_KEY: "YOUR_RELAY_API_KEY_HERE"
HOMEWARD_RELAY_DOMAIN: "mg.yourdomain.com"
HOMEWARD_NOTIFY_FROM: "noreply@yourdomain.com"
HOMEWARD_NOTIFY_REPLY_TO: "support@yourdomain.com"
description: "Homeward outbound messaging credentials for hub"
role: cloud
last_rotated: "2026-06-20"
```

Save and exit — sops encrypts the values in-place. Only ciphertext is committed.

### Step 2 — verify encryption

```bash
# Should show only ENC[...] values
cat secrets/cloud/messaging.yaml
```

### Step 3 — commit the encrypted file

```bash
git add secrets/cloud/messaging.yaml
git commit -m "secrets: add hub messaging credentials (encrypted)"
```

### Step 4 — wire into Ansible delivery

In `ansible/roles/cloud/tasks/main.yml`, add a task that decrypts the secret
and writes the env file on the hub:

```yaml
- name: Decrypt and deploy messaging credentials
  community.sops.load_vars:
    file: "{{ playbook_dir }}/../secrets/cloud/messaging.yaml"
    expressions: evaluate-on-load
  no_log: true

- name: Write messaging env file
  ansible.builtin.template:
    src: messaging.env.j2
    dest: /home/jsy/.config/wintermute/secrets/messaging.env
    owner: jsy
    group: jsy
    mode: "0600"
  no_log: true
```

The corresponding `ansible/roles/cloud/templates/messaging.env.j2`:

```
HOMEWARD_SMTP_HOST={{ HOMEWARD_SMTP_HOST }}
HOMEWARD_SMTP_PORT={{ HOMEWARD_SMTP_PORT }}
HOMEWARD_SMTP_USER={{ HOMEWARD_SMTP_USER }}
HOMEWARD_SMTP_PASSWORD={{ HOMEWARD_SMTP_PASSWORD }}
HOMEWARD_RELAY_API_KEY={{ HOMEWARD_RELAY_API_KEY }}
HOMEWARD_RELAY_DOMAIN={{ HOMEWARD_RELAY_DOMAIN }}
HOMEWARD_NOTIFY_FROM={{ HOMEWARD_NOTIFY_FROM }}
HOMEWARD_NOTIFY_REPLY_TO={{ HOMEWARD_NOTIFY_REPLY_TO }}
```

## Path on hub

After Ansible runs, the credentials are at:

```
~/.config/wintermute/secrets/messaging.env   (mode 0600, owner jsy)
```

The `hub-messaging-subscriber.service` and `homeward-reportd` source this file
at start-up via `EnvironmentFile=`.

## Verification

```bash
# On the hub: confirm file exists with correct perms
ssh hub "stat -c '%a %U' ~/.config/wintermute/secrets/messaging.env"
# Expected output: 600 jsy

# Check no plaintext is in git
git diff HEAD -- secrets/cloud/messaging.yaml | grep -v 'ENC\[' | grep '^\+' || echo "OK — no plaintext"
```

## Rotation

```bash
# Edit secret in-place (sops decrypts, opens editor, re-encrypts on save)
sops secrets/cloud/messaging.yaml

# Re-deliver to hub
ansible-playbook ansible/site.yml --limit hub --tags secrets
```

## Emergency fallback

If sops is unavailable and a send is urgent, the env file can be placed
manually on the hub:

```bash
ssh hub "install -m 0700 -d ~/.config/wintermute/secrets"
ssh hub "cat > ~/.config/wintermute/secrets/messaging.env" <<'EOF'
HOMEWARD_SMTP_HOST=smtp.mailgun.org
# ... etc
EOF
ssh hub "chmod 0600 ~/.config/wintermute/secrets/messaging.env"
```

**Remove the ad-hoc file and replace with the sops path as soon as possible.**
Do NOT commit plaintext to git.
