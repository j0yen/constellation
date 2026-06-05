# Headscale: self-hosted Tailscale control plane

Headscale replaces Tailscale's coordination server with one you run on your
own cloud node. The WireGuard data plane and MagicDNS remain identical; only
the control plane moves onto `hub`.

## When to choose Headscale

| Concern | Tailscale | Headscale |
|---|---|---|
| Zero operational overhead | ✓ | — |
| Full sovereignty over control plane | — | ✓ |
| MagicDNS stable names | ✓ | ✓ (via headscale's DNS) |
| DERP relay for NAT traversal | Tailscale-hosted | Self-hosted DERP (optional) |
| Free for personal fleet | ✓ | ✓ |

## Installing Headscale on the cloud node

```bash
# On hub (Arch / Debian / RPM — adjust to your distro)
# Official docs: https://headscale.net/running-headscale-linux/

# Arch (AUR)
paru -S headscale-bin

# Or binary release
VERSION=0.23.0
curl -fsSL "https://github.com/juanfont/headscale/releases/download/v${VERSION}/headscale_${VERSION}_linux_amd64" \
    -o /usr/local/bin/headscale && chmod +x /usr/local/bin/headscale

# Configuration
mkdir -p /etc/headscale
curl -fsSL https://raw.githubusercontent.com/juanfont/headscale/main/config-example.yaml \
    -o /etc/headscale/config.yaml

# Edit /etc/headscale/config.yaml:
#   server_url: https://hub.<your-domain>:8080
#   listen_addr: 0.0.0.0:8080
#   magic_dns: true
#   base_domain: constellation.internal   # local suffix for MagicDNS names

systemctl enable --now headscale
```

## Enrolling nodes against Headscale

Pass `--headscale` to the enroll script with your Headscale server URL:

```bash
# On any node
./mesh/scripts/enroll.sh --role laptop --headscale https://hub.yourdomain.com:8080
```

The enroll script passes `--login-server=<url>` to `tailscale up`, which is
the standard Tailscale mechanism to redirect enrollment to any control server.

## Creating an auth key in Headscale

```bash
# On hub
headscale preauthkeys create --user constellation --reusable --expiration 90d
# Store the output key in pass: constellation/tailscale/auth-key-<role>
```

## MagicDNS name differences

With Headscale, node names are `<hostname>.<base_domain>` (e.g.
`nomad.constellation.internal`) rather than the Tailscale-hosted
`<hostname>.<tailnet>.ts.net` suffix. Update `fleet-nodes.conf` and set
`CONSTELLATION_TAILNET=constellation.internal` in your environment.

## DERP relay

Headscale supports custom DERP maps. For a personal fleet the default
Tailscale DERP servers usually still work. To run your own DERP on the
cloud node, see: https://headscale.net/ref/acls/#derp-servers
