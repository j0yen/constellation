# constellation

Multi-machine fleet coordination for the wintermute ecosystem.

## Recent

- **cloud (2026-06-04):** offline structural gate `tests/cloud-role-check.sh` added — asserts the cloud-hub acceptance invariants (headless guardrail, JetStream domain `hub` + leafnode :7422 TLS, `WM_WORK`/`WM_NODES` idempotent creation, `tag:cloud` exit node, ollama fallback brain with Anthropic-API-primary rationale, no persistent GPU) without a live Hetzner box. Mutation-verified; complements the `ansible-lint`/`--syntax-check` gate.
- **appearance (2026-06-04):** chezmoi source tree added (`chezmoi/`) — byte-identical i3, alacritty, and i3status configs across all fleet nodes; per-host monitor/battery divergence handled via Go templates. Run `chezmoi init --source ~/wintermute/constellation/chezmoi && chezmoi apply` on any new node.

## mesh/

Tailscale mesh setup — enrolls every node into one private network with
stable MagicDNS names, ACL-controlled port access, and health checking.

```
mesh/
  constellation-mesh          # entrypoint: enroll | names | status | acl
  scripts/
    enroll.sh                 # tailscale up with role-tagged auth key
    names.sh                  # print fleet name map (table/json/env)
    status.sh                 # ping every expected node; exit 1 if incomplete
  config/
    fleet-nodes.conf          # role → hostname mapping (edit to match your fleet)
    acl-policy.hujson         # Tailscale ACL: fleet tags + port restrictions
  docs/
    headscale.md              # self-hosted control plane sovereignty option
```

### Quick start

1. Edit `mesh/config/fleet-nodes.conf` with your node hostnames.
2. Store a pre-authorized Tailscale auth key: `pass insert constellation/tailscale/auth-key-laptop`
3. Enroll: `./mesh/constellation-mesh enroll --role laptop`
4. Verify: `./mesh/constellation-mesh status`
5. Push ACL: `./mesh/constellation-mesh acl --apply`

See `mesh/docs/headscale.md` for the self-hosted Headscale option.
