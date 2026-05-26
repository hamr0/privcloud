# PRD: Self-hosted VPN control plane (Headscale)

Status: **Evaluated — not adopting (2026-05-26).** Staying on hosted Tailscale. Revisit only if a
trigger in [Revisit when](#revisit-when) fires.

## Goal

Replace Tailscale's proprietary coordination server with a self-hosted, open-source one
([Headscale](https://github.com/juanfont/headscale), via the
[hwdsl2/docker-headscale](https://github.com/hwdsl2/docker-headscale) image) so the whole stack is
OSS top to bottom, with no dependency on Tailscale Inc.'s SaaS.

## Background

- The Tailscale **client** is already open source. The only proprietary piece we use is the
  **coordination server** — it brokers keys, pushes DNS/ACL config, and hands out the DERP relay
  map. So Headscale's gain is narrow: it removes the SaaS dependency, not "closed-source code."
- With Headscale you keep the official Tailscale apps on every device and just point them at your
  own server (`tailscale up --login-server=https://hs.example.com`).
- The hwdsl2 image bundles `headscale` + a `hs_manage` helper. It listens on 8080 and **requires a
  separate reverse proxy (Caddy/nginx) in front for TLS on 443**. No DERP server bundled.

## Why this is a non-trivial change *for this setup*

Our entire security posture is **"expose nothing to the internet, tunnel everything through the
tailnet."** federver sits behind Ziggo NAT, unreachable from outside.

A coordination server **must be publicly reachable over HTTPS by every client, including phones on
cellular.** Self-hosting it therefore *introduces a public internet endpoint* — that's the real
cost (attack surface + operational burden, not money). Where it lives is the whole decision:

- **On federver (at home):** needs 443 port-forwarded on the Ziggo Connect Box, DDNS for the
  dynamic residential IP, and accepts that the control plane lives behind the same home internet it
  gates access to. An outage stops new connections, re-auth, and DNS-config pushes across the
  tailnet. Same Ziggo firmware that already broke our DNS rollout (see `[[privcloud LAN topology]]`).
- **On a VPS:** the cleaner answer — keeps home unexposed, gives the control plane its own static
  IP and uptime. But adds a paid third-party host, arguably trading one external dependency for
  another.

## Load-bearing interaction: AdGuard DNS

AdGuard routing only works through Tailscale's **"Override local DNS"** global setting; every other
path (Ziggo DHCP, per-device, IPv6-RA) is broken (`[[privcloud LAN topology]]`). Headscale *can*
reproduce this — `dns.nameservers.global` + `dns.override_local_dns: true` in its config YAML — so
the path survives a migration, but it moves from a console toggle to a YAML edit + restart, and the
iPhones honoring it would need verifying **before** decommissioning anything.

## Other costs weighed

- **iOS re-auth friction.** Pointing the official iOS/macOS app at a custom login server is fiddlier
  than on Linux; budget time for the two iPhones.
- **DERP / NAT traversal.** The hwdsl2 setup runs no DERP of its own, so by default it still uses
  *Tailscale's* public DERP relays — not actually infra-independent unless we also run a DERP, which
  then becomes the single fallback for any connection that can't go direct (e.g. phones on CGNAT).
- **We own uptime.** Existing direct connections survive a control-server outage, but re-auth, new
  nodes, and DNS changes don't, and default key expiry eventually bites.
- **More moving parts** — Headscale container + reverse proxy + TLS + DDNS/VPS + a new setup.sh
  management path — which cuts against the CLAUDE.md "lightweight over complex" rule.

## Decision

**Not adopting. Staying on hosted Tailscale.** No substantial driver exists: the free tier
(100 devices / 3 users) isn't a constraint we're near, the OSS gain is narrow (client is already
OSS), and self-hosting the control plane is a net increase in attack surface, failure modes, and
maintenance for that narrow gain. It also conflicts with our "expose nothing at home" invariant and
the lightweight-over-complex rule.

## Revisit when

Reconsider only if one of these becomes true — and if so, prefer **Headscale on a VPS**, never on
federver, to preserve "nothing at home is public":

- We hit Tailscale's free-tier limits, or its pricing/terms change materially.
- A hard requirement to eliminate the Tailscale account/SaaS appears (e.g. compliance, principle
  upgraded from "nice to have" to "must").
- We already run a public, TLS-terminated endpoint for another reason, so the marginal cost of
  hosting the control plane there drops to near zero.
