#!/usr/bin/env bash
# Zelira — Deploy DNS/DHCP Stack
# Run as root: sudo ./deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/config/.env"

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

source "$ENV_FILE"

# Validate required vars
for var in ZELIRA_IP ZELIRA_GATEWAY ZELIRA_SUBNET ZELIRA_POOL_START ZELIRA_POOL_END ZELIRA_DOMAIN ZELIRA_TZ ZELIRA_PIHOLE_PASSWORD ZELIRA_INTERFACE; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: $var is not set in config/.env"
        exit 1
    fi
done

echo "╔══════════════════════════════════════════╗"
echo "║            Zelira Deploy                 ║"
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

# ─── Check Dependencies ───────────────────────────────
echo "→ Checking dependencies..."
for cmd in podman dig; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' not found. Install it first."
        echo "  apt install podman dnsutils"
        exit 1
    fi
done
echo "  ✓ podman $(podman --version | awk '{print $3}')"
echo "  ✓ dig available"

# ─── Create Data Directories ──────────────────────────
echo "→ Creating data directories..."
mkdir -p /srv/pihole/etc-pihole
mkdir -p /srv/pihole/etc-dnsmasq.d
mkdir -p /srv/unbound
mkdir -p /srv/kea/etc-kea
mkdir -p /srv/kea/lib-kea
mkdir -p /srv/kea/sockets
echo "  ✓ /srv/{pihole,unbound,kea}"

# ─── Deploy Configs ───────────────────────────────────
echo "→ Deploying configs..."

# Unbound — copy directly (no templating needed)
cp "${SCRIPT_DIR}/config/unbound.conf" /srv/unbound/unbound.conf
echo "  ✓ /srv/unbound/unbound.conf"

# Kea — substitute env vars into template
envsubst < "${SCRIPT_DIR}/config/kea-dhcp4.conf.template" > /srv/kea/etc-kea/kea-dhcp4.conf
echo "  ✓ /srv/kea/etc-kea/kea-dhcp4.conf"

# Pi-hole upstream — point at Unbound
mkdir -p /srv/pihole/etc-dnsmasq.d
cat > /srv/pihole/etc-dnsmasq.d/99-zelira-upstream.conf <<EOF
# Zelira: Pi-hole forwards exclusively to local Unbound
# Do NOT use any third-party upstream DNS
server=127.0.0.1#5335
EOF
echo "  ✓ Pi-hole upstream → Unbound (127.0.0.1#5335)"

# ─── Pull Images ──────────────────────────────────────
echo "→ Pulling container images..."
podman pull docker.io/pihole/pihole:latest
podman pull docker.io/klutchell/unbound:latest
podman pull docker.io/jonasal/kea-dhcp4:2.6
echo "  ✓ All images pulled"

# ─── Stop Existing Services (if upgrading) ────────────
for svc in container-unbound container-pihole container-kea-dhcp4; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "→ Stopping existing $svc..."
        systemctl stop "$svc"
    fi
done

# ─── Install Systemd Services ─────────────────────────
echo "→ Installing systemd services..."

# Unbound (must start first — Pi-hole depends on it)
cat > /etc/systemd/system/container-unbound.service <<EOF
[Unit]
Description=Zelira — Unbound Recursive DNS
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
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

echo "  ✓ container-unbound.service"
echo "  ✓ container-pihole.service"
echo "  ✓ container-kea-dhcp4.service"

# ─── DNS Health Check ─────────────────────────────────
echo "→ Installing DNS health check..."
cp "${SCRIPT_DIR}/scripts/dns-healthcheck.sh" /usr/local/bin/dns-healthcheck.sh
chmod +x /usr/local/bin/dns-healthcheck.sh

cp "${SCRIPT_DIR}/systemd/dns-healthcheck.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/systemd/dns-healthcheck.timer" /etc/systemd/system/
echo "  ✓ dns-healthcheck (runs every 2 min)"

# ─── Enable & Start ───────────────────────────────────
echo "→ Starting services..."
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
