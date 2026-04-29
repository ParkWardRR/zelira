# Zelira — Test Environment

## Test Host

| | |
|---|---|
| **Hostname** | `zeliratest` |
| **IP** | `172.16.6.142` |
| **OS** | openSUSE Leap 16.0 (x86_64) |
| **Kernel** | 6.12.0-160000.28-default |
| **CPU** | x86_64 |
| **RAM** | 4 GB |
| **Disk** | 318 GB |
| **Interface** | `ens18` |
| **Podman** | 5.4.2 |
| **SSH** | `ssh -o PubkeyAuthentication=no alfa@172.16.6.142` |

## Firewall Safety

> **DHCP is firewalled.** The test host has `firewalld` direct rules that DROP all DHCP traffic on `ens18` so Kea cannot interfere with the production homelab network.

### Active Firewall Rules

**DHCP Blocks (direct rules, persistent):**
```
ipv4 filter OUTPUT 0 -p udp --dport 68 -j DROP       # Block DHCP replies to clients
ipv4 filter OUTPUT 0 -p udp --sport 67 -j DROP        # Block all outbound from DHCP server port
ipv4 filter OUTPUT 0 -d 255.255.255.255 --sport 67 -j DROP  # Block DHCP broadcast
ipv4 filter INPUT  0 -p udp --dport 67 -i ens18 -j DROP     # Block inbound DHCP requests
```

**Open ports for testing:**
```
53/tcp   — DNS (Pi-hole)
53/udp   — DNS (Pi-hole)
80/tcp   — Pi-hole Web UI
123/udp  — NTP (Chrony)
443/tcp  — HTTPS (Caddy)
```

### Verifying Firewall

```bash
# Check direct rules are active
sudo firewall-cmd --permanent --direct --get-all-rules

# Check open ports
sudo firewall-cmd --list-ports
```

## DHCP Testing (Isolated Podman Network)

Instead of testing DHCP on the real LAN, we use an **isolated podman network** to validate Kea end-to-end. Zero packets touch your homelab.

```
┌──────────────────────────────────────────┐
│     podman network: zelira-test          │
│     subnet: 10.89.0.0/24 (--internal)   │
│                                          │
│  ┌─────────────┐    ┌─────────────────┐  │
│  │ Kea DHCP    │    │ Alpine Client   │  │
│  │ 10.89.0.2   │◄──►│ (requests DHCP) │  │
│  │ :67         │    │                 │  │
│  └─────────────┘    └─────────────────┘  │
│                                          │
│  ⚠️  --internal flag = NO external access │
└──────────────────────────────────────────┘
```

### Run the DHCP test:

```bash
sudo ./testing/test-dhcp.sh
```

This will:
1. Create an isolated `zelira-test` podman network (`--internal`)
2. Start Kea DHCP inside it with the repo's config template
3. Spin up an Alpine client that requests a DHCP lease via `udhcpc`
4. Verify the client received an IP in the test pool
5. Check the Kea lease file for the active lease
6. Clean up everything on exit

### Temporarily Enabling LAN DHCP (danger zone)

```bash
# Remove DHCP blocks (DANGER: will interfere with LAN)
sudo firewall-cmd --direct --remove-rule ipv4 filter OUTPUT 0 -p udp --dport 68 -j DROP
sudo firewall-cmd --direct --remove-rule ipv4 filter OUTPUT 0 -p udp --sport 67 -j DROP
sudo firewall-cmd --direct --remove-rule ipv4 filter OUTPUT 0 -d 255.255.255.255 -p udp --sport 67 -j DROP
sudo firewall-cmd --direct --remove-rule ipv4 filter INPUT 0 -p udp --dport 67 -i ens18 -j DROP

# Re-enable when done
sudo firewall-cmd --reload
```

## Quick Start

```bash
# SSH in
ssh -o PubkeyAuthentication=no alfa@172.16.6.142

# Deploy Zelira (DNS + health check only, DHCP firewalled)
cd ~/zelira
sudo ./deploy.sh

# Run isolated DHCP test
sudo ./testing/test-dhcp.sh

# Health check
./scripts/health-check.sh
```

## Notes

- The test host gets its own IP via DHCP from the production network (Kea on rubrica).
- DNS queries from the test host's Pi-hole/Unbound will work normally — only DHCP server traffic is blocked on the LAN.
- The DHCP test uses a fully isolated podman internal network — no LAN packets.
- The firewall rules are persistent across reboots (`--permanent` flag).
