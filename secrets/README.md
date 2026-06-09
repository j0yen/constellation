# constellation/secrets/

This tree holds `sops`-encrypted YAML files. **Only ciphertext is committed.**
Plaintext is NEVER stored here, in `$HOME` dotfiles, or any world-readable path.

## Structure

```
secrets/
  shared/            # secrets readable by all roles
    nats.creds.yaml              # NATS leaf+hub user credentials
    WM_ANTHROPIC_API_KEY.yaml    # Anthropic cloud brain key
  laptop/            # secrets only the laptop role can decrypt
    tailscale_authkey.yaml       # Tailscale / Headscale pre-auth enrollment key
  cloud/             # secrets only the cloud node can decrypt
    tailscale_authkey.yaml       # cloud node's separate enrollment key
    nats.creds.yaml              # cloud-specific NATS hub credentials
  canary.yaml        # decryptable by ALL keys; used by 'bootstrap' to verify delivery
```

## Creating / editing a secret

```bash
# Create a new secret (sops picks recipients from .sops.yaml creation-rules)
sops secrets/shared/my-new-secret.yaml

# Edit an existing secret
sops secrets/shared/WM_ANTHROPIC_API_KEY.yaml

# Re-encrypt after adding a new host key to .sops.yaml
sops updatekeys secrets/shared/WM_ANTHROPIC_API_KEY.yaml
```

## Secret format

Each secret file holds a single YAML document with at least a `value` key:

```yaml
# Example — do NOT put this in the repo unencrypted
value: "the-actual-secret-here"
description: "WM_ANTHROPIC_API_KEY — cloud brain Anthropic API key"
role: shared
last_rotated: "2026-06-01"
```

After `sops` encryption the file will look like:

```yaml
value: ENC[AES256_GCM,data:...,tag:...,type:str]
description: ENC[...]
...
sops:
    age:
        - ...
    lastmodified: ...
    mac: ENC[...]
    version: 3.x.x
```

## Bootstrapping a new host

See `constellation-secrets help` and `../docs/secrets-bootstrap.md`.

Short version:
1. Generate a host age keypair: `age-keygen -o /tmp/host.key`
2. Add the public key (`age-keygen -y /tmp/host.key`) to `.sops.yaml` under the right role.
3. Re-encrypt secrets: `sops updatekeys secrets/<role>/<name>.yaml` for each affected file.
4. Deliver the private key out-of-band: `constellation-secrets bootstrap --key-file /tmp/host.key`
5. Shred the temporary key file: `shred -u /tmp/host.key`

## Audit

```bash
constellation-secrets audit
```

Asserts: no plaintext secrets in the tree, every declared secret is decryptable.
