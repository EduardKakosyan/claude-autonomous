#!/bin/bash
set -e

iptables -F OUTPUT

# Allow loopback and established connections
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT

# ── BLOCK dangerous destinations ──────────────────────────
# Cloud metadata endpoints (container escape / credential leak)
iptables -A OUTPUT -d 169.254.169.254 -j DROP
iptables -A OUTPUT -d 100.100.100.200 -j DROP

# Private/internal networks (no lateral movement to host)
iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
iptables -A OUTPUT -d 192.168.0.0/16 -j DROP

# ── ALLOW all public web traffic ──────────────────────────
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT    # HTTP
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT   # HTTPS
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT    # Git over SSH

# Block remaining (non-web ports)
iptables -A OUTPUT -j DROP

echo "Firewall initialized: full web access, internal networks blocked"
