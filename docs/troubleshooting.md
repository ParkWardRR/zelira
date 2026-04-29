# Troubleshooting

## Pi-hole Web UI Not Loading

**Symptom:** `http://<IP>/admin` returns connection refused.

**Check:**
```bash
sudo podman logs pihole | tail -20
ss -tlnp | grep :80
```

**Common causes:**
- Port 80 conflict — another web server (nginx, apache) is already bound. Stop it or change Pi-hole's port.
- Container failed to start — check `systemctl status container-pihole`

## DNS Not Resolving

**Symptom:** `dig google.com @<IP>` returns no answer.

**Debug chain (work backwards):**
```bash
# 1. Is Unbound working?
dig google.com @127.0.0.1 -p 5335 +short

# 2. Is Pi-hole forwarding to Unbound?
dig google.com @127.0.0.1 +short

# 3. Is the host resolving at all?
dig google.com @1.1.1.1 +short
```

If step 1 fails → Unbound is broken. Check:
```bash
sudo podman logs unbound
systemctl status container-unbound
```

If step 1 works but step 2 fails → Pi-hole isn't forwarding correctly:
```bash
cat /srv/pihole/etc-dnsmasq.d/99-zelira-upstream.conf
# Should contain: server=127.0.0.1#5335
```

If step 3 fails → your host has no internet connectivity.

## DHCP Not Handing Out Leases

**Symptom:** Clients aren't getting IPs from Kea.

**Check:**
```bash
sudo podman logs kea-dhcp4 | tail -20
cat /srv/kea/lib-kea/kea-leases4.csv
```

**Common causes:**
- Wrong interface in config — verify `ZELIRA_INTERFACE` in `.env` matches your actual NIC name (`ip link show`)
- Another DHCP server on the network — your router is probably still running DHCP. Disable it first.
- Firewall blocking port 67 — `sudo ufw allow 67/udp` or equivalent

## Pi-hole → Unbound TCP Errors

**Symptom:** Pi-hole logs show:
```
WARNING: Connection error (127.0.0.1#5335): TCP connection failed while receiving 
payload length from upstream (Connection prematurely closed by remote server)
```

**Cause:** Unbound's `tcp-idle-timeout` is too low. Pi-hole holds idle TCP connections; Unbound closes them.

**Fix:** The default Zelira `unbound.conf` already has this fixed (`tcp-idle-timeout: 120000`). If you modified it, ensure:
```yaml
tcp-idle-timeout: 120000    # 2 minutes, not 10 seconds
incoming-num-tcp: 20
outgoing-num-tcp: 20
```

Then restart: `sudo systemctl restart container-unbound`

## Unbound Stuck in SERVFAIL

**Symptom:** Unbound returns SERVFAIL for all queries after a power outage or network disruption.

**Cause:** Unbound's infrastructure cache marked all upstream servers as "down" and won't retry for 15 minutes (default `infra-host-ttl`).

**Fix:** Zelira's config sets `infra-host-ttl: 60` (1 minute) and the `dns-healthcheck.timer` auto-restarts Unbound after 3 consecutive failures. Manual fix:
```bash
sudo podman restart unbound
```

## Checking Logs

```bash
# All container logs
sudo podman logs pihole
sudo podman logs unbound
sudo podman logs kea-dhcp4

# DNS health check history
journalctl -t dns-healthcheck --since "1 hour ago"

# Systemd service status
systemctl status container-pihole
systemctl status container-unbound
systemctl status container-kea-dhcp4
```
