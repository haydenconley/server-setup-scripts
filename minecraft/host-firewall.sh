#!/usr/bin/env bash
# Manage only our IPv4 chain; leave Tailscale, NAT, IPv6 and policies alone.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
source "${FIREWALL_CONFIG:-/etc/conleylabs/firewall.conf}"
: "${SSH_SOURCE_CIDR:?Missing SSH_SOURCE_CIDR}"
python3 - "$SSH_SOURCE_CIDR" <<'PY'
import ipaddress, sys
if ipaddress.ip_network(sys.argv[1], strict=False).version != 4:
    raise SystemExit('SSH_SOURCE_CIDR must be IPv4')
PY
chain=CONLEY-HOST-IN
if ! iptables -w 10 -nL "$chain" >/dev/null 2>&1; then
    iptables -w 10 -N "$chain"
fi
# One transaction updates just this chain. Never restore a full runtime dump.
iptables-restore --wait 10 --noflush <<EOF
*filter
-F $chain
-A $chain -p tcp --dport 25 -j DROP
-A $chain -p tcp --dport 465 -j DROP
-A $chain -p tcp --dport 587 -j DROP
-A $chain -s $SSH_SOURCE_CIDR -p tcp --dport 22 -j ACCEPT
-A $chain -p tcp --dport 22 -j DROP
-A $chain -j RETURN
COMMIT
EOF
# Append so existing Tailscale INPUT hooks retain their original precedence.
if ! iptables -w 10 -C INPUT -j "$chain" 2>/dev/null; then
    iptables -w 10 -A INPUT -j "$chain"
fi
