#!/usr/bin/env bash
# Zelira — Deploy DNS/DHCP Stack
# Run as root: sudo ./deploy.sh
# Idempotent — safe to run multiple times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/config/.env"
ZELIRA_VERSION="1.1.0"

# ─── Colors ────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; }
step()  { echo -e "\n${CYAN}→${NC} $1"; }

# ─── Preflight ─────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo ./deploy.sh)"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: config/.env not found. Copy the template first:"
    echo "  cp config/env.example config/.env"
    echo "  vi config/.env"
    exit 1
fi

set -a  # Export all vars so envsubst can see them
source "$ENV_FILE"
set +a

# ─── Validate Required Vars ───────────────────────────
step "Validating config/.env..."
MISSING=0
for var in ZELIRA_IP ZELIRA_GATEWAY ZELIRA_SUBNET ZELIRA_POOL_START ZELIRA_POOL_END ZELIRA_DOMAIN ZELIRA_TZ ZELIRA_PIHOLE_PASSWORD ZELIRA_INTERFACE; do
    if [[ -z "${!var:-}" ]]; then
        fail "$var is not set in config/.env"
        MISSING=$((MISSING + 1))
    fi
done
[[ $MISSING -gt 0 ]] && exit 1

# ─── Validate IP Addresses ────────────────────────────
validate_ip() {
    local ip="$1" label="$2"
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "$label ($ip) is not a valid IPv4 address"
        return 1
    fi
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet > 255 )); then
            fail "$label ($ip) has octet > 255"
            return 1
        fi
    done
    return 0
}

IP_ERRORS=0
for check in "ZELIRA_IP:Host IP" "ZELIRA_GATEWAY:Gateway" "ZELIRA_POOL_START:DHCP Pool Start" "ZELIRA_POOL_END:DHCP Pool End"; do
    var="${check%%:*}"
    label="${check##*:}"
    validate_ip "${!var}" "$label" || IP_ERRORS=$((IP_ERRORS + 1))
done

# Validate CIDR subnet
if [[ ! "${ZELIRA_SUBNET}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    fail "ZELIRA_SUBNET ($ZELIRA_SUBNET) is not valid CIDR notation (e.g. 192.168.1.0/24)"
    IP_ERRORS=$((IP_ERRORS + 1))
else
    CIDR_MASK="${ZELIRA_SUBNET##*/}"
    if (( CIDR_MASK < 8 || CIDR_MASK > 30 )); then
        fail "ZELIRA_SUBNET mask /$CIDR_MASK is out of range (expected /8 – /30)"
        IP_ERRORS=$((IP_ERRORS + 1))
    fi
fi

[[ $IP_ERRORS -gt 0 ]] && { echo ""; fail "Fix the IP errors above in config/.env"; exit 1; }
info "IP addresses and subnet valid"

# ─── Validate Network Interface ───────────────────────
if ! ip link show "${ZELIRA_INTERFACE}" &>/dev/null; then
    fail "Interface '${ZELIRA_INTERFACE}' does not exist on this host"
    echo "  Available interfaces:"
    ip -o link show | awk -F': ' '{print "    " $2}' | grep -v lo
    exit 1
fi
info "Interface ${ZELIRA_INTERFACE} exists"

# ─── Detect systemd-resolved ──────────────────────────
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "systemd-resolved is running and may conflict with Pi-hole on port 53"
    if ss -tlnp 2>/dev/null | grep -q ":53 .*systemd-resolve"; then
        warn "systemd-resolved IS listening on port 53 — this WILL conflict"
        echo ""
        echo "  To fix, run one of:"
        echo "    sudo systemctl disable --now systemd-resolved"
        echo "    or set DNSStubListener=no in /etc/systemd/resolved.conf"
        echo ""
        read -p "  Continue anyway? [y/N] " -n 1 -r
        echo ""
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    else
        warn "systemd-resolved is running but not on port 53 — probably fine"
    fi
fi

# ─── Check Port Conflicts ─────────────────────────────
step "Checking port conflicts..."
PORT_ISSUES=0
for port_check in "53:DNS (Pi-hole)" "5335:Unbound" "67:DHCP (Kea)" "80:Pi-hole Web"; do
    port="${port_check%%:*}"
    label="${port_check##*:}"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        # Check if it's already a Zelira container
        owner=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'users:\(\("([^"]+)"' | head -1 || true)
        if [[ "$owner" == *pihole* ]] || [[ "$owner" == *unbound* ]] || [[ "$owner" == *kea* ]]; then
            info "Port $port ($label) — Zelira already running (will restart)"
        else
            warn "Port $port ($label) — already in use by: $owner"
            PORT_ISSUES=$((PORT_ISSUES + 1))
        fi
    else
        info "Port $port ($label) — available"
    fi
done
if [[ $PORT_ISSUES -gt 0 ]]; then
    warn "$PORT_ISSUES port conflict(s) detected — services may fail to start"
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         Zelira Deploy v${ZELIRA_VERSION}            ║"
echo "╠══════════════════════════════════════════╣"
echo "║  IP:       ${ZELIRA_IP}"
echo "║  Gateway:  ${ZELIRA_GATEWAY}"
echo "║  Subnet:   ${ZELIRA_SUBNET}"
echo "║  DHCP:     ${ZELIRA_POOL_START} – ${ZELIRA_POOL_END}"
echo "║  Domain:   ${ZELIRA_DOMAIN}"
echo "║  TZ:       ${ZELIRA_TZ}"
echo "║  NIC:      ${ZELIRA_INTERFACE}"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── Check Dependencies (multi-distro) ────────────────
step "Checking dependencies..."

# Podman
if ! command -v podman &>/dev/null; then
    fail "'podman' not found."
    # Detect distro and suggest install
    if command -v apt &>/dev/null; then
        echo "  Install: sudo apt install podman"
    elif command -v zypper &>/dev/null; then
        echo "  Install: sudo zypper install podman"
    elif command -v dnf &>/dev/null; then
        echo "  Install: sudo dnf install podman"
    fi
    exit 1
fi
info "podman $(podman --version | awk '{print $3}')"

# dig (different package names per distro)
if ! command -v dig &>/dev/null; then
    fail "'dig' not found."
    if command -v apt &>/dev/null; then
        echo "  Install: sudo apt install dnsutils"
    elif command -v zypper &>/dev/null; then
        echo "  Install: sudo zypper install bind-utils"
    elif command -v dnf &>/dev/null; then
        echo "  Install: sudo dnf install bind-utils"
    fi
    exit 1
fi
info "dig available"

# envsubst
if ! command -v envsubst &>/dev/null; then
    fail "'envsubst' not found."
    if command -v apt &>/dev/null; then
        echo "  Install: sudo apt install gettext-base"
    elif command -v zypper &>/dev/null; then
        echo "  Install: sudo zypper install gettext-runtime"
    elif command -v dnf &>/dev/null; then
        echo "  Install: sudo dnf install gettext"
    fi
    exit 1
fi
info "envsubst available"

# python3 (for JSON validation)
if ! command -v python3 &>/dev/null; then
    warn "'python3' not found — skipping Kea config JSON validation"
    SKIP_JSON_CHECK=1
else
    SKIP_JSON_CHECK=0
    info "python3 available"
fi

# ─── Create Data Directories ──────────────────────────
step "Creating data directories..."
mkdir -p /srv/pihole/etc-pihole
mkdir -p /srv/pihole/etc-dnsmasq.d
mkdir -p /srv/unbound
mkdir -p /srv/kea/etc-kea
mkdir -p /srv/kea/lib-kea
mkdir -p /srv/kea/sockets
chmod 750 /srv/kea/sockets
info "/srv/{pihole,unbound,kea}"

# ─── Deploy Configs (idempotent) ──────────────────────
step "Deploying configs..."

# Unbound — always overwrite (template-managed)
cp "${SCRIPT_DIR}/config/unbound.conf" /srv/unbound/unbound.conf
info "/srv/unbound/unbound.conf"

# Kea — substitute env vars into template
envsubst < "${SCRIPT_DIR}/config/kea-dhcp4.conf.template" > /tmp/kea-dhcp4.conf.tmp
# Strip JSON comments (// ...) — Kea's parser rejects them
sed -i'' -e 's|//.*$||' /tmp/kea-dhcp4.conf.tmp

if [[ $SKIP_JSON_CHECK -eq 0 ]]; then
    if python3 -m json.tool /tmp/kea-dhcp4.conf.tmp > /dev/null 2>&1; then
        cp /tmp/kea-dhcp4.conf.tmp /srv/kea/etc-kea/kea-dhcp4.conf
        rm -f /tmp/kea-dhcp4.conf.tmp
        info "/srv/kea/etc-kea/kea-dhcp4.conf (JSON valid)"
    else
        fail "Kea config JSON is invalid after templating!"
        echo "    Check your .env vars — a missing value produces broken JSON."
        python3 -m json.tool /tmp/kea-dhcp4.conf.tmp 2>&1 | head -5
        rm -f /tmp/kea-dhcp4.conf.tmp
        exit 1
    fi
else
    cp /tmp/kea-dhcp4.conf.tmp /srv/kea/etc-kea/kea-dhcp4.conf
    rm -f /tmp/kea-dhcp4.conf.tmp
    warn "/srv/kea/etc-kea/kea-dhcp4.conf (JSON not validated — no python3)"
fi

# Pi-hole upstream — point at Unbound
mkdir -p /srv/pihole/etc-dnsmasq.d
cat > /srv/pihole/etc-dnsmasq.d/99-zelira-upstream.conf <<EOF
# Zelira: Pi-hole forwards exclusively to local Unbound
# Do NOT use any third-party upstream DNS
server=127.0.0.1#5335
EOF
info "Pi-hole upstream → Unbound (127.0.0.1#5335)"

# ─── Pull Images ──────────────────────────────────────
step "Pulling container images..."
IMAGES=("docker.io/pihole/pihole:latest" "docker.io/klutchell/unbound:latest" "docker.io/jonasal/kea-dhcp4:2.6")
for img in "${IMAGES[@]}"; do
    # Only pull if not already present or if --force-pull is passed
    if podman image exists "$img" 2>/dev/null && [[ "${1:-}" != "--force-pull" ]]; then
        info "$img (cached)"
    else
        podman pull "$img"
        info "$img (pulled)"
    fi
done

# ─── Stop Existing Services (if upgrading) ────────────
step "Managing services..."
for svc in container-unbound container-pihole container-kea-dhcp4; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        warn "Stopping existing $svc for upgrade..."
        systemctl stop "$svc"
    fi
done

# ─── Install Systemd Services ─────────────────────────
step "Installing systemd services..."

# Unbound (must start first — Pi-hole depends on it)
cat > /etc/systemd/system/container-unbound.service <<EOF
[Unit]
Description=Zelira — Unbound Recursive DNS
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=30
ExecStartPre=-/usr/bin/podman rm -f unbound
ExecStart=/usr/bin/podman run \\
    --rm \\
    --name unbound \\
    --network host \\
    -v /srv/unbound/unbound.conf:/etc/unbound/unbound.conf:ro,Z \\
    docker.io/klutchell/unbound:latest \\
    -d -c /etc/unbound/unbound.conf
ExecStop=/usr/bin/podman stop -t 10 unbound
Type=simple

[Install]
WantedBy=multi-user.target
EOF

# Pi-hole
cat > /etc/systemd/system/container-pihole.service <<EOF
[Unit]
Description=Zelira — Pi-hole DNS Ad-Blocker
Wants=network-online.target
After=network-online.target container-unbound.service
Requires=container-unbound.service

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=30
ExecStartPre=-/usr/bin/podman rm -f pihole
ExecStart=/usr/bin/podman run \\
    --rm \\
    --name pihole \\
    --network host \\
    --cap-add NET_ADMIN \\
    --cap-add NET_RAW \\
    -e TZ=${ZELIRA_TZ} \\
    -e FTLCONF_webserver_api_password=${ZELIRA_PIHOLE_PASSWORD} \\
    -v /srv/pihole/etc-pihole:/etc/pihole:Z \\
    -v /srv/pihole/etc-dnsmasq.d:/etc/dnsmasq.d:Z \\
    --dns 127.0.0.1 \\
    --dns ${ZELIRA_FALLBACK_DNS:-1.1.1.1} \\
    docker.io/pihole/pihole:latest
ExecStop=/usr/bin/podman stop -t 10 pihole
Type=simple

[Install]
WantedBy=multi-user.target
EOF

# Kea DHCP
cat > /etc/systemd/system/container-kea-dhcp4.service <<EOF
[Unit]
Description=Zelira — Kea DHCPv4 Server
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=30
ExecStartPre=-/usr/bin/podman rm -f kea-dhcp4
ExecStart=/usr/bin/podman run \\
    --rm \\
    --name kea-dhcp4 \\
    --network host \\
    --pid host \\
    --cap-add=NET_ADMIN \\
    --cap-add=NET_RAW \\
    -v /srv/kea/etc-kea:/etc/kea:Z \\
    -v /srv/kea/lib-kea:/kea/leases:Z \\
    -v /srv/kea/sockets:/kea/sockets:Z \\
    docker.io/jonasal/kea-dhcp4:2.6 \\
    -c /etc/kea/kea-dhcp4.conf
ExecStop=/usr/bin/podman stop -t 10 kea-dhcp4
Type=simple

[Install]
WantedBy=multi-user.target
EOF

info "container-unbound.service"
info "container-pihole.service"
info "container-kea-dhcp4.service"

# ─── DNS Health Check ─────────────────────────────────
step "Installing DNS health check..."
cp "${SCRIPT_DIR}/scripts/dns-healthcheck.sh" /usr/local/bin/dns-healthcheck.sh
chmod +x /usr/local/bin/dns-healthcheck.sh

cp "${SCRIPT_DIR}/systemd/dns-healthcheck.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/systemd/dns-healthcheck.timer" /etc/systemd/system/
info "dns-healthcheck (runs every 2 min)"

# ─── Enable & Start ───────────────────────────────────
step "Starting services..."
systemctl daemon-reload
systemctl enable --now container-unbound.service
sleep 3  # Let Unbound initialize before Pi-hole tries to connect
systemctl enable --now container-pihole.service
systemctl enable --now container-kea-dhcp4.service
systemctl enable --now dns-healthcheck.timer

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          ✓ Zelira Deployed               ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Pi-hole UI:  http://${ZELIRA_IP}/admin"
echo "║  DNS:         ${ZELIRA_IP}:53"
echo "║  DHCP:        ${ZELIRA_POOL_START}–${ZELIRA_POOL_END}"
echo "║  Unbound:     127.0.0.1:5335"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Open http://${ZELIRA_IP}/admin (password: ${ZELIRA_PIHOLE_PASSWORD})"
echo "  2. Point your router's DNS at ${ZELIRA_IP}"
echo "  3. Or disable your router's DHCP and let Kea handle it"
echo ""
echo "Verify with: ./scripts/health-check.sh"
