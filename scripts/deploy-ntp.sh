#!/usr/bin/env bash
# Zelira Add-on — Deploy NTP Time Server (Chrony)
# Run as root: sudo ./scripts/deploy-ntp.sh
# Idempotent — safe to run multiple times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/config/.env"

# ─── Colors ────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; }
step()  { echo -e "\n${CYAN}→${NC} $1"; }

# ─── Preflight ─────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo ./scripts/deploy-ntp.sh)"
    exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

# Determine LAN subnet for client access
NTP_ALLOW="${ZELIRA_SUBNET:-192.168.1.0/24}"
# Strip CIDR to network address for allow directive
NTP_ALLOW_NET="${NTP_ALLOW}"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     Zelira Add-on: NTP (Chrony)          ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Allow:  ${NTP_ALLOW_NET}"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── Install Chrony ───────────────────────────────────
step "Installing Chrony..."
if command -v chronyc &>/dev/null; then
    info "Chrony already installed ($(chronyc --version 2>/dev/null | head -1 || echo 'unknown'))"
else
    if command -v apt &>/dev/null; then
        apt-get install -y chrony
    elif command -v zypper &>/dev/null; then
        zypper install -y chrony
    elif command -v dnf &>/dev/null; then
        dnf install -y chrony
    else
        fail "No supported package manager found (apt, zypper, dnf)"
        exit 1
    fi
    info "Chrony installed"
fi

# ─── Configure Chrony ─────────────────────────────────
step "Configuring Chrony..."

# Detect chrony config location
if [[ -d /etc/chrony ]]; then
    CHRONY_CONF="/etc/chrony/chrony.conf"
elif [[ -f /etc/chrony.conf ]]; then
    CHRONY_CONF="/etc/chrony.conf"
else
    CHRONY_CONF="/etc/chrony.conf"
fi

# Back up existing config
if [[ -f "$CHRONY_CONF" ]] && [[ ! -f "${CHRONY_CONF}.zelira-backup" ]]; then
    cp "$CHRONY_CONF" "${CHRONY_CONF}.zelira-backup"
    info "Backed up existing config → ${CHRONY_CONF}.zelira-backup"
fi

# Check if our config block already exists
if grep -q "Zelira NTP Configuration" "$CHRONY_CONF" 2>/dev/null; then
    info "Chrony already configured by Zelira (skipping)"
else
    # Append Zelira config to existing (preserve distro defaults)
    cat >> "$CHRONY_CONF" <<EOF

# ─── Zelira NTP Configuration ─────────────────────────
# Allow LAN clients to query this NTP server
allow ${NTP_ALLOW_NET}

# Step the clock if off by more than 1 second (first 3 updates)
makestep 1 3

# Sync the hardware clock
rtcsync

# Max allowed frequency uncertainty
maxupdateskew 100.0
EOF
    info "Added LAN access (allow ${NTP_ALLOW_NET}) to $CHRONY_CONF"
fi

# ─── Detect Chrony service name ───────────────────────
if systemctl list-unit-files chronyd.service &>/dev/null; then
    CHRONY_SVC="chronyd"
elif systemctl list-unit-files chrony.service &>/dev/null; then
    CHRONY_SVC="chrony"
else
    CHRONY_SVC="chronyd"
fi

# ─── Open Firewall Port ──────────────────────────────
step "Configuring firewall..."
if command -v firewall-cmd &>/dev/null; then
    if ! firewall-cmd --list-ports 2>/dev/null | grep -q "123/udp"; then
        firewall-cmd --permanent --add-port=123/udp
        firewall-cmd --reload
        info "Opened port 123/UDP (firewalld)"
    else
        info "Port 123/UDP already open (firewalld)"
    fi
elif command -v ufw &>/dev/null; then
    if ! ufw status 2>/dev/null | grep -q "123/udp"; then
        ufw allow 123/udp
        info "Opened port 123/UDP (ufw)"
    else
        info "Port 123/UDP already open (ufw)"
    fi
else
    warn "No firewall manager detected — ensure port 123/UDP is open"
fi

# ─── Inject NTP option into Kea (if deployed) ─────────
step "Checking Kea DHCP integration..."
KEA_CONF="/srv/kea/etc-kea/kea-dhcp4.conf"
ZELIRA_NTP_IP="${ZELIRA_IP:-}"

if [[ -f "$KEA_CONF" ]] && [[ -n "$ZELIRA_NTP_IP" ]]; then
    if grep -q "ntp-servers" "$KEA_CONF" 2>/dev/null; then
        info "Kea already has NTP option 42 (skipping)"
    else
        # Inject NTP option into the global option-data array
        # Insert before the closing ] of the first option-data block
        python3 -c "
import json, sys
with open('$KEA_CONF', 'r') as f:
    conf = json.load(f)
opts = conf['Dhcp4'].get('option-data', [])
opts.append({'name': 'ntp-servers', 'data': '$ZELIRA_NTP_IP'})
conf['Dhcp4']['option-data'] = opts
with open('$KEA_CONF', 'w') as f:
    json.dump(conf, f, indent=2)
" 2>/dev/null && {
            info "Injected NTP option 42 (${ZELIRA_NTP_IP}) into Kea config"
            # Restart Kea to pick up changes
            if systemctl is-active --quiet container-kea-dhcp4 2>/dev/null; then
                systemctl restart container-kea-dhcp4
                info "Restarted Kea DHCP to apply NTP option"
            fi
        } || warn "Could not inject NTP option into Kea (manual edit needed)"
    fi
else
    if [[ ! -f "$KEA_CONF" ]]; then
        warn "Kea not deployed yet — deploy core stack first, then re-run this script"
    fi
fi

# ─── Enable & Start ──────────────────────────────────
step "Starting Chrony..."
systemctl enable --now "$CHRONY_SVC"
sleep 2

# ─── Verify ──────────────────────────────────────────
step "Verifying NTP..."
SOURCES=$(chronyc sources 2>/dev/null | grep -c '^\^' || echo "0")
if [[ "$SOURCES" -gt 0 ]]; then
    info "$SOURCES upstream NTP sources configured"
else
    warn "No NTP sources detected yet (may take a few seconds)"
fi

STRATUM=$(chronyc tracking 2>/dev/null | grep "Stratum" | awk '{print $3}' || echo "?")
OFFSET=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4, $5}' || echo "?")
info "Stratum: $STRATUM, Offset: $OFFSET"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       ✓ NTP Server Deployed              ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Service:  $CHRONY_SVC"
echo "║  Port:     123/UDP"
echo "║  Allow:    ${NTP_ALLOW_NET}"
echo "║  Stratum:  $STRATUM"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Verify with: chronyc sources && chronyc tracking"
