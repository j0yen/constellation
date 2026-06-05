# constellation

Multi-machine fleet coordination for the wintermute ecosystem.

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
