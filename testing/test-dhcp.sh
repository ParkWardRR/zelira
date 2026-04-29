#!/usr/bin/env bash
# Zelira — DHCP Integration Test
# Tests Kea DHCP inside an isolated podman network (no LAN exposure)
#
# Usage: sudo ./testing/test-dhcp.sh
#
# This creates a private podman network (10.89.0.0/24), runs Kea inside it,
# then spins up a test client that requests a DHCP lease. Zero packets
# touch your real network.
set -euo pipefail

# ─── Config ────────────────────────────────────────────
TEST_NET="zelira-test"
TEST_SUBNET="10.89.0.0/24"
TEST_GATEWAY="10.89.0.1"
KEA_IP="10.89.0.2"
POOL_START="10.89.0.100"
POOL_END="10.89.0.200"
DOMAIN="zelira.test"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }

cleanup() {
    info "Cleaning up..."
    podman rm -f zelira-kea-test 2>/dev/null || true
    podman rm -f zelira-dhcp-client 2>/dev/null || true
    podman network rm "$TEST_NET" 2>/dev/null || true
    rm -rf /tmp/zelira-test-kea
    info "Cleanup complete"
}

trap cleanup EXIT

echo "╔══════════════════════════════════════════╗"
echo "║       Zelira DHCP Integration Test       ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Network:  ${TEST_NET} (isolated)        ║"
echo "║  Subnet:   ${TEST_SUBNET}               ║"
echo "║  Pool:     ${POOL_START}–${POOL_END}     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── Step 1: Create isolated podman network ────────────
echo "Step 1: Creating isolated network..."
podman network rm "$TEST_NET" 2>/dev/null || true
podman network create \
    --subnet "$TEST_SUBNET" \
    --gateway "$TEST_GATEWAY" \
    --internal \
    "$TEST_NET"
pass "Network '$TEST_NET' created (--internal = no external access)"

# ─── Step 2: Generate test Kea config ─────────────────
echo ""
echo "Step 2: Generating Kea config..."
mkdir -p /tmp/zelira-test-kea/etc-kea
mkdir -p /tmp/zelira-test-kea/lib-kea
mkdir -p /tmp/zelira-test-kea/sockets
chmod 750 /tmp/zelira-test-kea/sockets

# Export vars for envsubst
export ZELIRA_IP="$KEA_IP"
export ZELIRA_GATEWAY="$TEST_GATEWAY"
export ZELIRA_SUBNET="$TEST_SUBNET"
export ZELIRA_POOL_START="$POOL_START"
export ZELIRA_POOL_END="$POOL_END"
export ZELIRA_DOMAIN="$DOMAIN"
export ZELIRA_INTERFACE="eth0"

if [[ -f "${REPO_DIR}/config/kea-dhcp4.conf.template" ]]; then
    envsubst < "${REPO_DIR}/config/kea-dhcp4.conf.template" > /tmp/zelira-test-kea/etc-kea/kea-dhcp4.conf
    pass "Kea config generated from template"
else
    # Fallback: create a minimal config
    cat > /tmp/zelira-test-kea/etc-kea/kea-dhcp4.conf << KEAEOF
{
    "Dhcp4": {
        "interfaces-config": {
            "interfaces": ["eth0"],
            "dhcp-socket-type": "raw"
        },
        "valid-lifetime": 600,
        "renew-timer": 300,
        "rebind-timer": 450,
        "subnet4": [{
            "id": 1,
            "subnet": "${TEST_SUBNET}",
            "pools": [{"pool": "${POOL_START} - ${POOL_END}"}],
            "option-data": [
                {"name": "routers", "data": "${TEST_GATEWAY}"},
                {"name": "domain-name-servers", "data": "${KEA_IP}"},
                {"name": "domain-name", "data": "${DOMAIN}"}
            ]
        }],
        "lease-database": {
            "type": "memfile",
            "persist": true,
            "name": "/kea/leases/kea-leases4.csv"
        },
        "control-socket": {
            "socket-type": "unix",
            "socket-name": "/kea/sockets/kea.socket"
        },
        "loggers": [{
            "name": "kea-dhcp4",
            "severity": "INFO",
            "output-options": [{"output": "stdout"}]
        }]
    }
}
KEAEOF
    pass "Kea config generated (fallback minimal)"
fi

# ─── Step 3: Start Kea in the isolated network ────────
echo ""
echo "Step 3: Starting Kea DHCP server..."
podman run -d \
    --name zelira-kea-test \
    --network "$TEST_NET" \
    --ip "$KEA_IP" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    -v /tmp/zelira-test-kea/etc-kea:/etc/kea:Z \
    -v /tmp/zelira-test-kea/lib-kea:/kea/leases:Z \
    -v /tmp/zelira-test-kea/sockets:/kea/sockets:Z \
    docker.io/jonasal/kea-dhcp4:2.6 \
    -c /etc/kea/kea-dhcp4.conf

sleep 3

if podman ps --filter name=zelira-kea-test --format '{{.Status}}' | grep -qi "up"; then
    pass "Kea container running"
else
    fail "Kea container failed to start"
    echo ""
    echo "Kea logs:"
    podman logs zelira-kea-test 2>&1 | tail -20
    exit 1
fi

# ─── Step 4: Request DHCP lease from test client ──────
echo ""
echo "Step 4: Requesting DHCP lease from test client..."

# Run a lightweight alpine container that uses dhclient/udhcpc
podman run -d \
    --name zelira-dhcp-client \
    --network "$TEST_NET" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    docker.io/alpine:latest \
    sleep 60

sleep 2

# Install and run udhcpc inside the client
podman exec zelira-dhcp-client sh -c '
    # Remove any pre-assigned IP so we can test DHCP properly
    ip addr flush dev eth0 2>/dev/null || true
    
    # Request DHCP lease
    udhcpc -i eth0 -n -q -f -s /usr/share/udhcpc/default.script 2>&1
    
    echo "=== ASSIGNED IP ==="
    ip -4 addr show eth0
    echo "=== ROUTES ==="
    ip route show
    echo "=== RESOLV.CONF ==="
    cat /etc/resolv.conf 2>/dev/null || echo "no resolv.conf"
'

RESULT=$?

echo ""
if [[ $RESULT -eq 0 ]]; then
    # Verify the client got an IP in our test range
    CLIENT_IP=$(podman exec zelira-dhcp-client sh -c "ip -4 addr show eth0 | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1" 2>/dev/null)
    
    if [[ -n "$CLIENT_IP" && "$CLIENT_IP" == 10.89.0.* ]]; then
        pass "Client received DHCP lease: ${CLIENT_IP}"
    else
        fail "Client IP not in expected range (got: ${CLIENT_IP:-none})"
    fi
else
    fail "DHCP request failed (exit code: $RESULT)"
fi

# ─── Step 5: Check Kea lease file ─────────────────────
echo ""
echo "Step 5: Verifying lease file..."
LEASES=$(cat /tmp/zelira-test-kea/lib-kea/kea-leases4.csv 2>/dev/null | grep -v "^address" | grep -v "^$" | wc -l)

if [[ $LEASES -gt 0 ]]; then
    pass "Lease file has ${LEASES} active lease(s)"
    echo ""
    echo "  Lease contents:"
    cat /tmp/zelira-test-kea/lib-kea/kea-leases4.csv 2>/dev/null | head -5 | sed 's/^/    /'
else
    fail "No leases found in lease file"
fi

# ─── Step 6: Check Kea logs ───────────────────────────
echo ""
echo "Step 6: Kea server logs (last 10 lines):"
podman logs zelira-kea-test 2>&1 | tail -10 | sed 's/^/    /'

# ─── Summary ──────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          DHCP Test Complete              ║"
echo "╠══════════════════════════════════════════╣"
if [[ $RESULT -eq 0 && $LEASES -gt 0 ]]; then
    echo "║  Status: ✅ PASSED                      ║"
    echo "║  Kea successfully handed out a lease     ║"
    echo "║  inside an isolated podman network.      ║"
    echo "║  No packets touched your real LAN.       ║"
else
    echo "║  Status: ❌ FAILED                      ║"
    echo "║  Check the logs above for details.       ║"
fi
echo "╚══════════════════════════════════════════╝"
