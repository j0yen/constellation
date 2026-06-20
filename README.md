# constellation

The provisioning repo for the wintermute fleet: one Ansible playbook turns a fresh Arch box into a node identical to every other node, down to the kernel and the i3 config.

## Why it exists

Run more than one machine and they drift. The laptop gets a package the desktop doesn't, a config edited on one never lands on the other, and "set up a new box" becomes a day of remembering. Constellation makes the fleet a function of source: the inventory says which hosts exist, the playbook says what a node *is*, and re-running it converges any host back to that definition. New node, recovered node, or spare — same playbook, same result.

## What's here

| Path | What it provisions |
|---|---|
| `ansible/` | The `site.yml` playbook and four roles — `base`, `desktop`, `voice`, `cloud`. |
| `chezmoi/` | Managed dotfiles — byte-identical i3, alacritty, and i3status across nodes; per-host divergence (monitors, battery) via Go templates. |
| `mesh/` | Tailscale enrollment — one private network, stable MagicDNS names, ACL-gated ports, health checks. |
| `localrepo/` | Build and serve a local pacman repo for the prebuilt `linux-wintermute` kernel — one machine builds, all nodes pull. |
| `cloud/`, `docs/cloud-hub.md` | The always-on hub node (NATS JetStream, Tailscale exit, fallback brain) and its failover script. |
| `tests/` | Offline gates — mesh ACL invariants and chezmoi/ansible schema cross-reference. |

## How a node gets built

`ansible/site.yml` applies the roles in order, each gated by what the host is:

- **base** — pacman config, the local wintermute pacman repo, the `linux-wintermute` kernel, and base packages. Every node.
- **desktop** — i3, terminal, status bar, and the authoritative tool list. Skipped on cloud nodes.
- **voice** — the `wm-*` daemons and `wintermute.target`. Only on hosts with `voice_node: true`.
- **cloud** — NATS hub, Tailscale exit, fallback brain. Only on hosts in the `[cloud]` group.

A host's identity is data, not code: shared defaults in `ansible/group_vars/all.yml`, per-host overrides in `ansible/host_vars/<hostname>.yml` (GPU type, voice toggle, pinned Arch Archive date, and so on). The playbook is idempotent — safe to re-run on a converged host.

## Provision a node

```sh
# Install the required Ansible collection
ansible-galaxy collection install -r ansible/requirements.yml

# Add the host to ansible/inventory/hosts (with ansible_host + ansible_user),
# then drop its overrides in ansible/host_vars/<hostname>.yml.

cd ansible
ansible-playbook -i inventory/hosts site.yml --check          # dry-run first
ansible-playbook -i inventory/hosts site.yml --limit laptop   # then apply to one host
```

## Appearance (dotfiles)

```sh
chezmoi init --source ~/wintermute/constellation/chezmoi && chezmoi apply
```

Every node that applies this gets the same i3 / terminal / status-bar configuration. Monitor outputs and the battery block differ by host, resolved through templates and `.chezmoidata/hosts/<hostname>.toml` rather than per-host file copies.

## Mesh

```sh
# 1. List your nodes
$EDITOR mesh/config/fleet-nodes.conf
# 2. Store a pre-authorized Tailscale auth key
pass insert constellation/tailscale/auth-key-laptop
# 3. Enroll, verify, push ACL
./mesh/constellation-mesh enroll --role laptop
./mesh/constellation-mesh status
./mesh/constellation-mesh acl --apply
```

`mesh/constellation-mesh` is the entrypoint (`enroll | names | status | acl`). For a self-hosted control plane instead of Tailscale's, see `mesh/docs/headscale.md`.

## The kernel repo

The fleet runs a custom `linux-wintermute` kernel. Rather than compile it on every host, one machine builds it into a local pacman repo and the others pull the package over the mesh:

```sh
cd localrepo
./build-repo.sh           # build from already-compiled kernel packages
./build-repo.sh --rebuild # rebuild the kernel first, then add to the repo
./serve-repo.sh           # serve over HTTP for other nodes
```

## The cloud hub

One always-on node anchors the fleet — NATS JetStream hub, Tailscale exit node, and a degraded-path fallback brain (the primary brain is the Anthropic API; the local model is the offline path only). Architecture, cost rationale, and failover are in `docs/cloud-hub.md`; `cloud/scripts/hub-failover.sh` handles promotion of the spare.

## Tests

```sh
bash tests/acl-policy-check.sh        # mesh ACL invariants, offline (no live tailnet needed)
bash tests/lint-schema-crossref.sh    # chezmoi per-host keys match ansible host_vars keys
```

## Where it fits

constellation is the fleet's substrate — it stands up the nodes the rest of wintermute runs on (mesh links the boxes; the cloud hub carries the NATS bus). Per-machine push-debt across the fleet is the job of [`consign`](https://github.com/j0yen/consign).
