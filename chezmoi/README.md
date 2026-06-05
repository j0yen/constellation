# constellation/chezmoi — appearance source tree

Managed dotfiles for the constellation fleet. Every node running
`chezmoi apply` gets **byte-identical** i3, terminal, and status-bar
configuration — per-host divergence (monitor outputs, battery block) is
handled via Go templates, not per-host file copies.

## Layout

```
chezmoi/
  .chezmoi.toml.tmpl                 # per-host config template (rendered once)
  .chezmoidata/hosts/<hostname>.toml # per-host data (gpu, monitors, role, …)
  dot_config/
    i3/config.tmpl                   # i3 window manager config
    i3status/config.tmpl             # status bar config (battery block gated)
    alacritty/alacritty.toml.tmpl    # terminal emulator config
```

## Per-host data schema

Each host file under `.chezmoidata/hosts/<hostname>.toml` must provide:

| Key            | Type    | Description                                      |
|----------------|---------|--------------------------------------------------|
| `gpu`          | string  | `intel` or `amd` — matches ansible host_vars     |
| `voice_node`   | bool    | Is this the STT/wake-word node?                  |
| `role`         | string  | `workstation`, `compute`, or `hub`               |
| `has_battery`  | bool    | Show battery block in i3status?                  |
| `monitors_raw` | string  | Comma-sep `name:resolution:primary` monitor list |

The `gpu`, `voice_node`, `role`, and `monitors` keys match
`ansible/host_vars/<hostname>.yml` exactly (cross-reference enforced by
`tests/lint-schema-crossref.sh`).

## Adding a new node

1. Create `constellation/chezmoi/.chezmoidata/hosts/<new-hostname>.toml`
   with the five required keys.
2. Add matching `ansible/host_vars/<new-hostname>.yml`.
3. Run `tests/lint-schema-crossref.sh` — must exit 0.
4. On the new node: `chezmoi init --source /path/to/constellation/chezmoi && chezmoi apply`.

## Applying on this laptop

```bash
chezmoi init --source ~/wintermute/constellation/chezmoi
chezmoi diff     # verify no surprises
chezmoi apply
```

## Secrets

Any token that must live in a dotfile is stored age-encrypted in the source
tree. `chezmoi apply` decrypts with the host's age key (never stored in the
repo). See [chezmoi age docs](https://www.chezmoi.io/user-guide/encryption/age/).
