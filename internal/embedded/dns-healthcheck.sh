#!/usr/bin/env bash
# Zelira — DNS Health Check (Auto-Recovery)
# Installed to /usr/local/bin/dns-healthcheck.sh
# Triggered by dns-healthcheck.timer every 2 minutes
set -euo pipefail

LOG_TAG="dns-healthcheck"
TEST_DOMAIN="google.com"
UNBOUND_PORT=5335
MAX_ATTEMPTS=3

fail_count=0

for attempt in $(seq 1 $MAX_ATTEMPTS); do
    result=$(dig +short +time=3 +tries=1 "$TEST_DOMAIN" @127.0.0.1 -p "$UNBOUND_PORT" 2>/dev/null || true)
    if [[ -n "$result" ]]; then
        # DNS working — exit silently
        exit 0
    fi
    fail_count=$((fail_count + 1))
    sleep 2
done

# All attempts failed — restart Unbound
logger -t "$LOG_TAG" "Unbound failed $MAX_ATTEMPTS consecutive DNS lookups, restarting container"
podman restart unbound 2>&1 | logger -t "$LOG_TAG"

# Wait for restart, then verify
sleep 5
result=$(dig +short +time=3 +tries=1 "$TEST_DOMAIN" @127.0.0.1 -p "$UNBOUND_PORT" 2>/dev/null || true)
if [[ -n "$result" ]]; then
    logger -t "$LOG_TAG" "Unbound recovered successfully after restart"
else
    logger -t "$LOG_TAG" "WARNING: Unbound still failing after restart — manual intervention needed"
fi
