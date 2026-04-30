# Zelira vs. Alternatives

> How Zelira compares to other self-hosted DNS/DHCP solutions.

Zelira isn't trying to be everything. It's an opinionated deployment kit that prioritizes resilience and simplicity over feature count. Here's how it stacks up.

---

## At a Glance

| | **Zelira** | **Pi-hole (standalone)** | **AdGuard Home** | **Technitium DNS** |
|---|---|---|---|---|
| **Philosophy** | Production-hardened deployment kit | Modular DNS sinkhole | All-in-one convenience | Enterprise DNS server |
| **DNS Resolver** | Unbound (recursive, DNSSEC) | None — needs upstream or add-on | Built-in forwarder (DoH/DoT/DoQ) | Built-in recursive + authoritative |
| **Ad Blocking** | Pi-hole (180K+ domains) | Pi-hole (180K+ domains) | Built-in (similar lists) | Built-in (similar lists) |
| **DHCP** | Kea DHCPv4 (ISC's modern replacement) | Pi-hole's built-in DHCP (dnsmasq) | Built-in DHCP | Built-in DHCP |
| **DNSSEC** | Full validation (Unbound) | Requires Unbound add-on | Limited (forwards DNSSEC, doesn't validate) | Full validation |
| **Auto-Recovery** | systemd timer + 3-strike restart | None | None | None |
| **Boot Ordering** | systemd `Requires` + `After` | Not applicable | Not applicable | Not applicable |
| **NTP** | Chrony add-on + DHCP Option 42 | Not included | Not included | Not included |
| **Encrypted DNS** | Not needed (recursive, no upstream) | Requires external setup | Native DoH/DoT/DoQ | Native DoH/DoT/DoQ |
| **Container Runtime** | Podman + systemd (no daemon) | Docker or bare metal | Single binary / Docker | .NET binary / Docker |
| **Config Format** | `.env` → envsubst → JSON | Web UI + flat files | YAML + Web UI | Web UI + JSON API |
| **Clustering / HA** | Not supported (single-box) | Manual (Gravity Sync) | Manual | Native multi-node sync |
| **Setup Effort** | `sudo zelira deploy` | Install script + manual Unbound | Single binary, wizard UI | Install + web UI config |

---

## Detailed Comparison

### Zelira vs. Pi-hole (Standalone)

Pi-hole is the most popular DNS ad-blocker, and Zelira is built *on top of* Pi-hole. The key differences are what Zelira adds:

| Concern | Pi-hole Standalone | Zelira |
|---------|-------------------|--------|
| **Upstream DNS** | Forwards to Google/Cloudflare (trusts a third party) | Unbound resolves recursively from root servers (no third party) |
| **DNSSEC** | Forwards DNSSEC flag, doesn't validate locally | Unbound performs full cryptographic DNSSEC validation |
| **DHCP** | dnsmasq-based DHCP (legacy) | Kea DHCPv4 — ISC's modern replacement, JSON config, REST API |
| **Failure Recovery** | `restart: unless-stopped` and hope for the best | `dns-healthcheck.timer`: 3-strike detection, auto-restart, journald logging |
| **Power Outage** | Unbound SERVFAIL death spiral (15-min blackout) | `serve-expired + infra-host-ttl: 60` — stale cache, fast recovery |
| **TCP Connection Storms** | Default `tcp-idle-timeout: 10s` → 105 errors/hr | Tuned to `120000` with `20` TCP connections — zero errors |
| **Boot Ordering** | Unbound and Pi-hole start whenever | systemd `Requires` + `After` + 3s init delay |
| **Config Management** | Scattered across web UI, files, TOML | Single `.env` file → automated templating |
| **NTP** | Not included | Chrony add-on with auto DHCP Option 42 injection |
| **Deployment** | Manual multi-step install | `sudo zelira deploy` (one command, idempotent) |

**Bottom line:** If you're running Pi-hole + Unbound manually with Docker Compose, you're solving the same problems Zelira already solved — just without the auto-recovery, boot ordering, and Kea DHCP.

### Zelira vs. AdGuard Home

AdGuard Home is a polished all-in-one DNS solution. It's excellent for "set and forget" but takes a different approach.

| Concern | AdGuard Home | Zelira |
|---------|-------------|--------|
| **Setup** | Single binary, web wizard — very easy | `zelira init` + `zelira deploy` — slightly more config, but still two commands |
| **DNS Resolution** | Forwards to upstream (Cloudflare, Google, etc.) | Recursive from root servers (no upstream dependency) |
| **Encrypted DNS** | Native DoH/DoT/DoQ | Not needed — Zelira talks to root servers directly |
| **Parental Controls** | Built-in per-client rules, safe search | Not included (use Pi-hole groups + custom blocklists) |
| **DHCP** | Built-in (basic) | Kea DHCPv4 — static reservations, JSON config, REST API |
| **DNSSEC** | Forwards DNSSEC, doesn't validate locally | Full Unbound DNSSEC validation |
| **Resilience** | No auto-recovery, no boot ordering | Production-grade auto-recovery timer + systemd dependencies |
| **Power Outage** | Depends on upstream availability | Stale cache + auto-restart — survives gracefully |
| **NTP / Time Sync** | Not included | Chrony add-on for LAN-wide time sync |
| **Community** | Growing, backed by AdGuard (commercial) | Newer, community-driven |

**Bottom line:** Choose AdGuard Home if you want built-in DoH/DoT and per-client parental controls with zero configuration. Choose Zelira if you want recursive DNS (no upstream dependency), production-grade resilience, and a proper DHCP server.

### Zelira vs. Technitium DNS Server

Technitium is the most feature-rich option — it's a full authoritative + recursive DNS server with DHCP and ad-blocking built in.

| Concern | Technitium | Zelira |
|---------|-----------|--------|
| **Architecture** | Monolithic .NET application | Composable: Pi-hole + Unbound + Kea (each best-in-class) |
| **DNS** | Recursive + authoritative + ad-blocking in one binary | Pi-hole (ad-blocking) + Unbound (recursive + DNSSEC) |
| **DHCP** | Built-in, auto-creates DNS records | Kea DHCPv4 — more configurable, but no auto-DNS sync |
| **HA / Clustering** | Native multi-node sync (standout feature) | Not supported (single-box design) |
| **Ad-Blocking UI** | Good, but less mature than Pi-hole's | Pi-hole — industry standard, massive community blocklists |
| **Complexity** | High — many features to configure | Low — opinionated defaults, `.env` config |
| **Resilience** | No auto-recovery timer, relies on process monitoring | `dns-healthcheck.timer`, stale cache, boot ordering |
| **Runtime** | .NET runtime (heavier) | Podman containers + systemd (lighter) |
| **Community** | Active but smaller | Built on Pi-hole + Unbound (huge communities) |
| **Encrypted DNS** | Native DoH/DoT/DoQ | Not needed (recursive, no upstream) |

**Bottom line:** Choose Technitium if you need authoritative DNS zones, native clustering, or a single-binary all-in-one solution. Choose Zelira if you want best-in-class components (Pi-hole + Unbound + Kea), production-hardened resilience, and a simpler deployment model.

---

## When to Choose Zelira

Zelira is the right choice when:

- ✅ You want **zero third-party DNS dependency** — your queries go to root servers, not Google or Cloudflare
- ✅ You need **production-grade resilience** — auto-recovery, stale cache, correct boot ordering
- ✅ You want **Kea DHCP** instead of legacy dnsmasq or basic built-in DHCP
- ✅ You prefer **Podman + systemd** over Docker + Compose or monolithic binaries
- ✅ You want **one command to deploy** and one command to verify
- ✅ You value **documented failure modes** — every config value traces back to a real incident

## When NOT to Choose Zelira

Zelira is *not* the right choice when:

- ❌ You need **encrypted upstream DNS** (DoH/DoT) — Zelira resolves recursively, so there's no upstream to encrypt to. If your threat model requires encrypted DNS to an upstream resolver, use AdGuard Home or Technitium.
- ❌ You need **HA / clustering** — Zelira is single-box. For multi-node DNS, use Technitium or run two Zelira instances with keepalived.
- ❌ You need **per-client parental controls** — Pi-hole has groups, but AdGuard Home's per-device rules are more intuitive.
- ❌ You want **authoritative DNS zones** — Zelira is a resolver and ad-blocker, not a nameserver for your own domains. Use Technitium or BIND for that.
- ❌ You want a **single binary** with no containers — use AdGuard Home or Technitium.

---

## Feature Matrix

| Feature | Zelira | Pi-hole | AdGuard Home | Technitium |
|---------|--------|---------|--------------|------------|
| Ad-blocking | ✅ | ✅ | ✅ | ✅ |
| Recursive DNS | ✅ | ❌ (add-on) | ❌ (forwarder) | ✅ |
| DNSSEC validation | ✅ | ❌ (add-on) | ⚠️ (forward only) | ✅ |
| DHCP server | ✅ (Kea) | ✅ (dnsmasq) | ✅ (basic) | ✅ |
| NTP server | ✅ (add-on) | ❌ | ❌ | ❌ |
| Dynamic DNS | ✅ (add-on) | ❌ | ❌ | ❌ |
| Dashboard / TLS | ✅ (add-on) | ✅ (HTTP) | ✅ (HTTPS) | ✅ (HTTPS) |
| Auto-recovery | ✅ | ❌ | ❌ | ❌ |
| Boot ordering | ✅ | ❌ | N/A | N/A |
| Stale cache | ✅ | ❌ | ❌ | ✅ |
| DoH/DoT/DoQ | ❌ (not needed) | ❌ | ✅ | ✅ |
| Clustering / HA | ❌ | ❌ | ❌ | ✅ |
| Parental controls | ⚠️ (Pi-hole groups) | ⚠️ (groups) | ✅ | ❌ |
| Authoritative DNS | ❌ | ❌ | ❌ | ✅ |
| One-command deploy | ✅ | ⚠️ (script) | ✅ | ⚠️ |
| Idempotent deploys | ✅ | ❌ | N/A | N/A |
| Multi-distro support | ✅ (apt/zypper/dnf) | ⚠️ (Debian-focused) | ✅ | ✅ |
| ARM64 support | ✅ | ✅ | ✅ | ✅ |
