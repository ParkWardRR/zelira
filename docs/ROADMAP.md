# Zelira — Roadmap

> History, current state, and where this project is headed.

---

## Origin Story

Zelira was extracted from a production home network stack that ran for months before being generalized. The original deployment served 40+ clients across managed switches, WiFi APs, cameras, IoT devices, and hypervisors — all depending on a single Raspberry Pi 5 for DNS and DHCP.

Every config value and auto-recovery mechanism in this repo exists because something broke in production. The decision to publish came from realizing that every "Pi-hole + Unbound" guide online stops at `docker-compose up` and never addresses real failure modes: power outages, TCP connection storms, silent config conflicts, or wrong boot ordering.

---

## Timeline

### Phase 0 — Production Hardening (pre-release)

| Event | Impact |
|-------|--------|
| Pi-hole + Unbound deployed on RPi5 (arm64, 8 GB) | Core DNS operational |
| Migrated Docker + Compose → Podman + systemd | Eliminated daemon as single point of failure |
| Migrated ISC DHCP (`dhcpd`) → Kea DHCPv4 | ISC DHCP end-of-life; Kea has JSON config + REST API |
| DHCP Snooping on managed switch silently dropped Kea packets | Documented as Pitfall #4 |
| **Incident:** Unbound SERVFAIL death spiral after power outage | `infra-host-ttl` default (900s) caused 15-min blackout; fixed with `60` + `serve-expired` |
| Deployed `dns-healthcheck.timer` | Auto-restarts Unbound after 3 consecutive failures |
| **Incident:** Pi-hole FTL TCP connection storms — 105 errors/hr | Unbound `tcp-idle-timeout` default 10s; fixed with `120000` |
| **Incident:** Device unreachable by hostname after DHCP migration | Pi-hole v6 dual DNS source (`custom.list` vs `pihole.toml`); TOML wins silently |
| Kea exporter crash loop | Control socket missing from config; fixed with `chmod 666` on socket |
| Added Caddy + DNS-01 challenge for local HTTPS | Landing page and Pi-hole admin behind TLS |
| Added Dynamic DNS updater container | Auto-updates public A record every 5 min |
| Added Chrony NTP | Local time server for all LAN devices; critical for DNSSEC |

### Phase 1 — Public Release *(current)*

| Date | Commit | Milestone |
|------|--------|-----------|
| 2026-04-29 | `fbd6f98` | Initial release: core stack, deploy script, health check, uninstall |
| 2026-04-29 | `2eb4429` | Mermaid diagrams: DNS flow, ad-blocking, auto-recovery, boot chain |
| 2026-04-29 | `490b8c7` | Add-on docs: NTP (Chrony), Dynamic DNS, Landing Page (Caddy) |
| 2026-04-29 | `6be7d5d` | Testing framework: isolated DHCP test, firewall safety, expanded README |

### Phase 2 — Validation *(in progress)*

| Status | Item |
|--------|------|
| ✅ | Test host provisioned (openSUSE Leap 16.0, Podman 5.4.2) |
| ✅ | Firewall safety: DHCP blocked on LAN via `firewalld` direct rules |
| ✅ | Isolated DHCP test: Kea hands out leases inside podman internal network |
| ⬜ | Full `deploy.sh` end-to-end on clean Debian 12 |
| ⬜ | DNS validation: Pi-hole → Unbound → root servers (DNSSEC verified) |
| ⬜ | Health check timer: simulate Unbound failure, confirm auto-recovery |
| ⬜ | Boot ordering: cold reboot, verify Unbound → Pi-hole → Kea sequence |
| ⬜ | Add-on validation: Chrony NTP |

---

## Forward Roadmap

### Phase 3 — Hardening

| Priority | Item | Description |
|----------|------|-------------|
| 🔴 High | **`deploy.sh` idempotency** | Run twice safely — detect existing state, skip redundant work |
| 🔴 High | **openSUSE compatibility** | Fix package name differences (`dnsutils` → `bind-utils`, etc.) |
| 🟡 Medium | **Config validation** | Pre-flight: valid IPs, CIDR math, interface exists, port conflicts |
| 🟡 Medium | **Kea config validation** | `envsubst` silently produces broken JSON if a var is missing — add JSON syntax check |
| 🟡 Medium | **systemd-resolved detection** | Auto-detect and disable on Ubuntu/Debian to prevent port 53 conflicts |

### Phase 4 — Add-on Integration

| Priority | Item | Description |
|----------|------|-------------|
| 🔴 High | **Add-on deploy scripts** | `deploy-ntp.sh`, `deploy-ddns.sh`, `deploy-dashboard.sh` |
| 🟡 Medium | **Unified `.env`** | Add-on config in the same `.env` with optional sections |
| 🟡 Medium | **Health check expansion** | NTP sync, DDNS update age, Caddy cert expiry in `health-check.sh` |
| 🟡 Medium | **Kea Option 42** | Auto-inject NTP server IP into Kea config if Chrony is deployed |
| 🟢 Low | **Prometheus metrics** | Export Pi-hole, Unbound, Kea, Chrony metrics for Grafana |

### Phase 5 — Multi-Platform

| Priority | Item | Description |
|----------|------|-------------|
| 🟡 Medium | **Fedora/RHEL support** | Test on Fedora 40+, AlmaLinux 9 |
| 🟡 Medium | **Docker fallback** | Optional Docker-compatible mode |
| 🟢 Low | **NixOS module** | Declarative deployment |
| 🟢 Low | **Ansible playbook** | Config management alternative to shell scripts |

### Phase 6 — Community

| Priority | Item | Description |
|----------|------|-------------|
| 🟡 Medium | **CI/CD** | GitHub Actions: lint, ShellCheck, isolated DHCP test |
| 🟡 Medium | **Contributing guide** | `CONTRIBUTING.md` with issue templates, PR standards |
| 🟢 Low | **Example configs** | Pre-built `.env` for common setups (apartment, house, homelab) |
| 🟢 Low | **Migration guide** | Pi-hole Docker Compose → Zelira |

---

## Incident → Feature Map

Every Zelira feature traces back to a real failure:

| Incident | Zelira Feature |
|----------|----------------|
| Unbound SERVFAIL after power outage (15-min blackout) | `serve-expired=yes`, `infra-host-ttl=60`, `dns-healthcheck.timer` |
| Pi-hole TCP storms (105 errors/hr) | `tcp-idle-timeout=120000`, `incoming/outgoing-num-tcp=20` |
| Pi-hole v6 dual DNS source conflict | Documented in Pitfall #3 |
| DHCP Snooping dropping Kea packets | Documented in Pitfall #4 |
| Kea exporter crash (missing control socket) | `control-socket` in default Kea template |
| Pi-hole started before Unbound was ready | `Requires=container-unbound.service` + 3s sleep |
| Port 53 conflict with systemd-resolved | Documented in Pitfall #6 |

---

## Non-Goals

| Non-Goal | Why |
|----------|-----|
| **Web-based config UI** | `.env` is the single source of truth. A UI adds complexity |
| **IPv6 DHCP (DHCPv6)** | IPv6 RA/SLAAC works without managed DHCPv6 |
| **Multi-node clustering** | Single-box deployment. Use keepalived for HA |
| **DoH / DoT** | Zelira resolves recursively — no upstream to encrypt to |
| **Container orchestration** | No Kubernetes, no Compose. systemd is the orchestrator |
| **VPN integration** | DNS/DHCP concern only; VPN belongs on the router |

---

## Design Principles

1. **Every config value has a reason.** If a value is set, there's a production incident behind it.
2. **One command to deploy, one command to verify.** `sudo ./deploy.sh` and `./scripts/health-check.sh`.
3. **No external dependencies at runtime.** DNS from root servers. DHCP is local. NTP from pool.ntp.org.
4. **Survive power outages gracefully.** Stale cache, auto-recovery timers, correct boot ordering.
5. **Podman + systemd, not Docker + Compose.** Fewer moving parts, no daemon.
6. **Document the failures, not just the successes.**
