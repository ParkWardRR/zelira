#!/usr/bin/env bash
# Zelira — Health Check
# Validates all services are running and DNS/DHCP are functional
set -euo pipefail

PASS=0
FAIL=0
WARN=0

check() {
    local label="$1"
    local result="$2"
    if [[ "$result" == "0" ]]; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label"
        FAIL=$((FAIL + 1))
    fi
}

warn() {
    local label="$1"
    echo "  ⚠ $label"
    WARN=$((WARN + 1))
}

echo "Zelira Health Check"
echo "═══════════════════"
echo ""

# ─── Container Status ─────────────────────────────────
echo "Containers:"
for name in unbound pihole kea-dhcp4; do
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        uptime=$(podman ps --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null)
        check "$name ($uptime)" "0"
    elif sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        uptime=$(sudo podman ps --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null)
        check "$name ($uptime)" "0"
    else
        check "$name — NOT RUNNING" "1"
    fi
done
echo ""

# ─── Systemd Services ─────────────────────────────────
echo "Systemd:"
for svc in container-unbound container-pihole container-kea-dhcp4 dns-healthcheck.timer; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        check "$svc" "0"
    else
        check "$svc" "1"
    fi
done
echo ""

# ─── DNS Resolution ───────────────────────────────────
echo "DNS:"

# Test Unbound directly
unbound_result=$(dig +short +time=3 +tries=1 google.com @127.0.0.1 -p 5335 2>/dev/null || true)
if [[ -n "$unbound_result" ]]; then
    check "Unbound (127.0.0.1:5335) → $unbound_result" "0"
else
    check "Unbound (127.0.0.1:5335) — FAILED" "1"
fi

# Test Pi-hole (full chain)
pihole_result=$(dig +short +time=3 +tries=1 google.com @127.0.0.1 2>/dev/null || true)
if [[ -n "$pihole_result" ]]; then
    check "Pi-hole (127.0.0.1:53) → $pihole_result" "0"
else
    check "Pi-hole (127.0.0.1:53) — FAILED" "1"
fi

# Test DNSSEC
dnssec_result=$(dig +short +time=3 +tries=1 +dnssec sigok.verteiltesysteme.net @127.0.0.1 -p 5335 2>/dev/null || true)
if [[ -n "$dnssec_result" ]]; then
    check "DNSSEC validation working" "0"
else
    warn "DNSSEC test inconclusive"
fi

# Test ad-blocking
ad_result=$(dig +short +time=3 +tries=1 ads.google.com @127.0.0.1 2>/dev/null || true)
if [[ "$ad_result" == "0.0.0.0" ]] || [[ -z "$ad_result" ]]; then
    check "Ad-blocking active (ads.google.com → blocked)" "0"
else
    warn "Ad-blocking may not be configured yet (ads.google.com → $ad_result)"
fi
echo ""

# ─── Ports ─────────────────────────────────────────────
echo "Ports:"
for port_check in "53:DNS" "80:Pi-hole Web" "5335:Unbound" "67:DHCP"; do
    port="${port_check%%:*}"
    label="${port_check##*:}"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        check "Port $port ($label)" "0"
    else
        check "Port $port ($label) — NOT LISTENING" "1"
    fi
done
echo ""

# ─── Summary ──────────────────────────────────────────
echo "═══════════════════"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
if [[ $FAIL -gt 0 ]]; then
    echo "Status: UNHEALTHY"
    exit 1
else
    echo "Status: HEALTHY"
    exit 0
fi
