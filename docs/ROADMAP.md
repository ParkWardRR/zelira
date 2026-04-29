# Zelira — Roadmap

> History, current state, and where this project is headed.

---

## Origin Story

Zelira was extracted from a production home network called **Alpina** — a 40+ client deployment spanning 7 APs, managed MikroTik and EnGenius switches, an NVR with 5 camera streams, IoT devices, and multiple hypervisors. The DNS/DHCP stack ran on a Raspberry Pi 5 node called **Rubrica** (`172.16.1.69`).

Every config value, every auto-recovery mechanism, and every pitfall documented in this repo exists because something actually broke on that network — usually at 2 AM.

The decision to extract Rubrica's stack into a standalone public project came from realizing that every "Pi-hole + Unbound" guide on the internet stops at `docker-compose up` and never addresses what happens when the power goes out, when Unbound's infrastructure cache poisons itself, or when Pi-hole's FTL engine silently drops TCP connections 105 times per hour.

---

## Timeline

### Phase 0 — Production Hardening (pre-release)

*Running on the Alpina network for months before Zelira existed as a project.*

| Date | Event |
|------|-------|
| Early 2026 | Pi-hole + Unbound deployed on Rubrica (Raspberry Pi 5, arm64) |
| — | First incident: Unbound SERVFAIL death spiral after power outage. Root cause: `infra-host-ttl` default of 900s |
| — | Fix: `infra-host-ttl: 60` + `serve-expired: yes` + auto-recovery timer |
| — | Second incident: Pi-hole FTL TCP connection storms — 105 errors/hour. Root cause: Unbound `tcp-idle-timeout` default of 10s |
| — | Fix: `tcp-idle-timeout: 120000` + `incoming-num-tcp: 20` |
| — | Migrated from ISC DHCP (`dhcpd`) to Kea DHCPv4 after ISC EOL announcement |
| — | Hit DHCP Snooping issue on EnGenius ECS2512FP — Kea DHCPOFFER packets silently dropped by managed switch |
| — | Migrated from Docker + Compose to Podman + systemd — eliminated daemon dependency |
| — | Discovered Pi-hole v6 dual DNS source gotcha (`custom.list` vs `pihole.toml`) the hard way |
| — | Added Chrony NTP — resolved DNSSEC timestamp validation failures caused by clock drift |
| — | Added Caddy with Namecheap DNS-01 challenge for local HTTPS |
| — | Added Dynamic DNS updater for public IP tracking |

### Phase 1 — Public Release *(current)*

*Extracted from Alpina, generalized, documented, and published.*

| Date | Milestone |
|------|-----------|
| 2026-04-29 | `fbd6f98` — Initial release: core stack (Pi-hole, Unbound, Kea), deploy script, health check, uninstall |
| 2026-04-29 | `2eb4429` — Mermaid diagrams: DNS flow, ad-blocking, auto-recovery, file layout, boot chain |
| 2026-04-29 | `490b8c7` — Add-on documentation: NTP (Chrony), Dynamic DNS, Landing Page (Caddy) |
| 2026-04-29 | `6be7d5d` — Testing framework: isolated podman DHCP test, firewall safety docs, README expanded with full stack diagrams |

### Phase 2 — Validation *(in progress)*

| Status | Item |
|--------|------|
| ✅ | Test host provisioned (`zeliratest`, openSUSE Leap 16.0, Podman 5.4.2) |
| ✅ | Firewall safety: DHCP blocked on LAN via `firewalld` direct rules |
| ✅ | Isolated DHCP test: Kea hands out leases inside podman internal network |
| ⬜ | Full `deploy.sh` end-to-end run on test host |
| ⬜ | DNS validation: Pi-hole → Unbound → root servers (DNSSEC verified) |
| ⬜ | Health check timer validation: simulate Unbound failure, confirm auto-recovery |
| ⬜ | Boot ordering test: cold reboot, verify Unbound → Pi-hole → Kea sequence |
| ⬜ | Add-on validation: Chrony NTP on test host |

---

## Forward Roadmap

### Phase 3 — Hardening

| Priority | Item | Description |
|----------|------|-------------|
| 🔴 High | **`deploy.sh` idempotency** | Running `deploy.sh` twice should be safe — detect existing state, skip redundant work |
| 🔴 High | **openSUSE compatibility** | Currently tested on Debian/Ubuntu. Validate and fix for zypper-based distros (Leap, Tumbleweed) |
| 🟡 Medium | **Config validation** | Pre-flight check in `deploy.sh` that validates `.env` values (valid IPs, subnet math, interface exists) |
| 🟡 Medium | **`uninstall.sh` completeness** | Verify clean removal on all tested platforms |
| 🟡 Medium | **Kea config validation** | `envsubst` silently produces broken JSON if a var is missing — add JSON syntax check after templating |

### Phase 4 — Add-on Integration

| Priority | Item | Description |
|----------|------|-------------|
| 🔴 High | **Add-on deploy scripts** | `deploy-ntp.sh`, `deploy-ddns.sh`, `deploy-dashboard.sh` — same one-command pattern as core |
| 🟡 Medium | **Unified `.env`** | Add-on config (NTP, DDNS, Caddy) in the same `.env` with optional sections |
| 🟡 Medium | **Health check expansion** | Include NTP sync status, DDNS update age, and Caddy cert expiry in `health-check.sh` |
| 🟢 Low | **Add-on: Prometheus metrics** | Export Pi-hole, Unbound, Kea, and Chrony metrics for Grafana dashboards |

### Phase 5 — Multi-Platform

| Priority | Item | Description |
|----------|------|-------------|
| 🟡 Medium | **Fedora/RHEL support** | Test and document on Fedora 40+, AlmaLinux 9 |
| 🟡 Medium | **Docker fallback** | Optional Docker-compatible mode for users who don't have Podman |
| 🟢 Low | **NixOS module** | Declarative deployment via NixOS configuration |

### Phase 6 — Community

| Priority | Item | Description |
|----------|------|-------------|
| 🟡 Medium | **CI/CD** | GitHub Actions: lint configs, run isolated DHCP test, validate deploy script syntax |
| 🟡 Medium | **Contributing guide** | `CONTRIBUTING.md` with issue templates, PR standards |
| 🟢 Low | **Example configs** | Pre-built `.env` examples for common setups (apartment, house, homelab) |
| 🟢 Low | **Migration guide** | Step-by-step from existing Pi-hole Docker Compose → Zelira |

---

## Non-Goals

Things Zelira will **not** do:

| Non-Goal | Why |
|----------|-----|
| **Web-based configuration UI** | The `.env` file is the single source of truth. A UI adds complexity and another failure point |
| **IPv6 DHCP (DHCPv6)** | Most homelabs are IPv4-only. IPv6 RA/SLAAC works fine without a managed DHCPv6 server |
| **Multi-node clustering** | Zelira is a single-box deployment. If you need HA, run two instances with keepalived |
| **DNS-over-HTTPS (DoH) / DNS-over-TLS (DoT)** | Zelira resolves recursively — there's no upstream to encrypt to. DoH/DoT for clients is better handled at the router level |
| **Container orchestration** | No Kubernetes, no Compose, no Swarm. systemd is the orchestrator |

---

## Design Principles

These guide every decision:

1. **Every config value has a reason.** No defaults for the sake of defaults. If a value is set, there's a production incident behind it.
2. **One command to deploy, one command to verify.** `sudo ./deploy.sh` and `./scripts/health-check.sh`.
3. **No external dependencies at runtime.** DNS resolves from root servers. DHCP is local. NTP syncs to pool.ntp.org. Nothing phones home.
4. **Survive power outages gracefully.** Stale cache, auto-recovery timers, correct boot ordering.
5. **Podman + systemd, not Docker + Compose.** Fewer moving parts, no daemon, native restart policies.
