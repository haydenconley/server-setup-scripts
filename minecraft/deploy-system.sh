#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
usage() { echo "Usage: bash $0 CONFIG [--apply]"; }
[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
[[ ${2:-} == '' || ${2:-} == --apply ]] || { usage; exit 2; }
config=$1
source "$config"
: "${SSH_SOURCE_CIDR:?Set SSH_SOURCE_CIDR}"
: "${TIMEZONE:?Set TIMEZONE}"
: "${LOCALE:?Set LOCALE}"
CONFIGURE_NETWORK=${CONFIGURE_NETWORK:-0}
CONFIGURE_SSH=${CONFIGURE_SSH:-0}
[[ $CONFIGURE_NETWORK =~ ^[01]$ && $CONFIGURE_SSH =~ ^[01]$ ]]
[[ $LOCALE == en_US.UTF-8 ]] || { echo 'This baseline supports LOCALE=en_US.UTF-8.' >&2; exit 1; }
[[ -f /usr/share/zoneinfo/$TIMEZONE && $TIMEZONE != *..* ]]
python3 - "$SSH_SOURCE_CIDR" "${SSH_CONNECTION:-}" <<'PY'
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
if network.version != 4:
    raise SystemExit('SSH_SOURCE_CIDR must be IPv4')
if sys.argv[2] and ipaddress.ip_address(sys.argv[2].split()[0]) not in network:
    raise SystemExit('Current SSH client is outside SSH_SOURCE_CIDR. Use the VM console.')
PY
if [[ $CONFIGURE_SSH == 1 ]]; then
    : "${SSH_USER:?Set SSH_USER}" "${SSH_SOURCE_HOST:?Set SSH_SOURCE_HOST}"
    [[ $SSH_USER =~ ^[a-z_][a-z0-9_-]*$ ]]
    id "$SSH_USER" >/dev/null
    if grep -E '^[[:space:]]*(AllowUsers|Match)[[:space:]]' /etc/ssh/sshd_config >/dev/null ||
       find /etc/ssh/sshd_config.d -name '*.conf' ! -name 00-conleylabs.conf -type f -exec grep -El '^[[:space:]]*(AllowUsers|Match)[[:space:]]' {} + | grep -q .; then
        echo 'Existing SSH AllowUsers/Match settings need review before adding this restriction.' >&2
        exit 1
    fi
    python3 - "$SSH_SOURCE_HOST" "$SSH_SOURCE_CIDR" <<'PY'
import ipaddress, sys
if ipaddress.ip_address(sys.argv[1]) not in ipaddress.ip_network(sys.argv[2], strict=False):
    raise SystemExit('SSH_SOURCE_HOST must be in SSH_SOURCE_CIDR')
PY
fi
if [[ $CONFIGURE_NETWORK == 1 ]]; then
    : "${INTERFACE:?}" "${ADDRESS_CIDR:?Choose a unique target address}" "${GATEWAY:?}" "${DNS_SERVERS:?}" "${DNS_SEARCH:?}" "${HOSTNAME:?Choose a target hostname}"
    [[ $INTERFACE =~ ^[a-zA-Z0-9_.:-]+$ && $HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ && $DNS_SEARCH =~ ^[a-zA-Z0-9.-]+$ ]]
    python3 - "$ADDRESS_CIDR" "$GATEWAY" "$DNS_SERVERS" <<'PY'
import ipaddress, sys
interface = ipaddress.IPv4Interface(sys.argv[1])
if ipaddress.IPv4Address(sys.argv[2]) not in interface.network:
    raise SystemExit('Gateway must be in the target subnet')
for address in sys.argv[3].split():
    ipaddress.ip_address(address)
PY
fi
cat <<EOF
Target: this Debian 13 VM
Packages: iptables, openssh-server, qemu-guest-agent, curl, wget, ca-certificates, sudo, vim, locales, tzdata, openjdk-25-jdk-headless
Timezone: $TIMEZONE; locale: $LOCALE
IPv4: drop inbound TCP 25/465/587; allow SSH from $SSH_SOURCE_CIDR, drop other SSH
Persist the custom IPv4 rules through a dedicated systemd service.
Create minecraft user/group, home /home/minecraft, shell /bin/bash.
Ensure /opt/minecraft is owned by minecraft:minecraft with mode 0750.
Download the specified Mojang JAR to /opt/minecraft/server.jar (SHA-1 verified).
Enable minecraft.service at boot (4 GB heap), launch, accept EULA, then restart.
Configure SSH account restriction: $CONFIGURE_SSH
Stage static networking and hostname for next boot: $CONFIGURE_NETWORK
EOF
[[ ${2:-} == --apply ]] || { echo 'Preview only. Add --apply to configure this VM.'; exit 0; }
[[ $EUID == 0 ]] || { echo 'Run --apply as root.' >&2; exit 1; }
source /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]] || { echo 'Requires Debian 13.' >&2; exit 1; }
[[ $(dpkg --print-architecture) == amd64 ]] || { echo 'This Java service baseline requires amd64.' >&2; exit 1; }
backup_dir=/var/backups/conleylabs/$(date +%Y%m%dT%H%M%S)-$$
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"
backup() { if [[ -e $1 ]]; then cp -a --parents -- "$1" "$backup_dir/"; fi; }
for path in /etc/conleylabs /usr/local/sbin/conleylabs-firewall /etc/systemd/system/conleylabs-firewall.service /etc/systemd/system/minecraft.service; do backup "$path"; done
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y iptables openssh-server qemu-guest-agent curl wget ca-certificates sudo vim locales tzdata openjdk-25-jdk-headless
iptables --version | grep -q nf_tables || { echo 'Expected iptables nft backend.' >&2; exit 1; }
iptables -S INPUT | head -n 1 | grep -qx -- '-P INPUT ACCEPT' || {
    echo 'Expected INPUT policy ACCEPT, as on the example. Review existing firewall first.' >&2; exit 1;
}
backup /etc/localtime
backup /etc/timezone
backup /etc/locale.gen
backup /etc/default/locale
timedatectl set-timezone "$TIMEZONE"
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG="$LOCALE"
# Match the example's account layout without pinning host-specific UID/GID 1001.
if [[ -L /opt/minecraft || ( -e /opt/minecraft && ! -d /opt/minecraft ) ]]; then
    echo '/opt/minecraft must be a directory, not a symlink or other file.' >&2
    exit 1
fi
if ! getent group minecraft >/dev/null; then
    groupadd minecraft
fi
if ! getent passwd minecraft >/dev/null; then
    useradd --create-home --home-dir /home/minecraft --shell /bin/bash --gid minecraft minecraft
elif [[ $(id -gn minecraft) != minecraft ||
        $(getent passwd minecraft | cut -d: -f6-7) != /home/minecraft:/bin/bash ]]; then
    echo 'Existing minecraft account differs from expected primary group, home, or shell; review it before deployment.' >&2
    exit 1
fi
# Do not recursively change existing worlds or other application files.
install -d -o minecraft -g minecraft -m 0750 /opt/minecraft
server_url=https://piston-data.mojang.com/v1/objects/33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c/server.jar
server_sha1=33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c
server_jar=/opt/minecraft/server.jar
if [[ -L $server_jar || ( -e $server_jar && ! -f $server_jar ) ]]; then
    echo 'server.jar must be a regular file, not a symlink or other file.' >&2
    exit 1
fi
if [[ ! -f $server_jar ]] || ! printf '%s  %s\n' "$server_sha1" "$server_jar" | sha1sum --check --status; then
    download_dir=$(mktemp -d)
    trap 'rm -rf -- "$download_dir"' EXIT
    wget --https-only --timeout=30 --tries=3 -O "$download_dir/server.jar" "$server_url"
    printf '%s  %s\n' "$server_sha1" "$download_dir/server.jar" | sha1sum --check --status || {
        echo 'Minecraft JAR checksum verification failed; existing server.jar preserved.' >&2
        exit 1
    }
    backup "$server_jar"
    install -o minecraft -g minecraft -m 0664 "$download_dir/server.jar" "$server_jar"
else
    chown minecraft:minecraft "$server_jar"
    chmod 0664 "$server_jar"
fi
install -m 644 "$base/minecraft.service" /etc/systemd/system/minecraft.service
install -d -m 755 /etc/conleylabs
printf 'SSH_SOURCE_CIDR=%q\n' "$SSH_SOURCE_CIDR" > /etc/conleylabs/firewall.conf
chmod 644 /etc/conleylabs/firewall.conf
install -m 755 "$base/host-firewall.sh" /usr/local/sbin/conleylabs-firewall
cat > /etc/systemd/system/conleylabs-firewall.service <<'EOF'
[Unit]
Description=Conley Labs custom IPv4 host rules
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conleylabs-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
if [[ $CONFIGURE_SSH == 1 ]]; then
    backup /etc/ssh/sshd_config.d/00-conleylabs.conf
    install -d -m 755 /etc/ssh/sshd_config.d
    printf 'AllowUsers %s@%s\n' "$SSH_USER" "$SSH_SOURCE_HOST" > /etc/ssh/sshd_config.d/00-conleylabs.conf
    if ! /usr/sbin/sshd -t; then
        if [[ -e $backup_dir/etc/ssh/sshd_config.d/00-conleylabs.conf ]]; then
            cp -a "$backup_dir/etc/ssh/sshd_config.d/00-conleylabs.conf" /etc/ssh/sshd_config.d/00-conleylabs.conf
        else
            unlink /etc/ssh/sshd_config.d/00-conleylabs.conf
        fi
        echo 'SSH validation failed; restored the previous drop-in.' >&2
        exit 1
    fi
    systemctl reload ssh
fi
if [[ $CONFIGURE_NETWORK == 1 ]]; then
    # Stage only: do not bounce the interface underneath the active connection.
    backup /etc/network/interfaces
    backup /etc/hostname
    backup /etc/hosts
    cat > /etc/network/interfaces <<EOF
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
allow-hotplug $INTERFACE
iface $INTERFACE inet static
    address $ADDRESS_CIDR
    gateway $GATEWAY
    dns-nameservers $DNS_SERVERS
    dns-search $DNS_SEARCH
EOF
    printf '%s\n' "$HOSTNAME" > /etc/hostname
    # Replace the old host's mapping while preserving unrelated entries.
    python3 - "$HOSTNAME" "$ADDRESS_CIDR" "$DNS_SEARCH" <<'PY'
from pathlib import Path
import sys
name, address, domain = sys.argv[1:]
old = Path('/proc/sys/kernel/hostname').read_text().strip().split('.')[0]
lines = []
for line in Path('/etc/hosts').read_text().splitlines():
    fields = line.split('#', 1)[0].split()
    if len(fields) > 1 and any(x.split('.')[0] in (old, name) for x in fields[1:]):
        continue
    lines.append(line)
lines.append(f'{address.split("/")[0]}\t{name}.{domain}\t{name}')
Path('/etc/hosts').write_text('\n'.join(lines) + '\n')
PY
    echo 'Static networking and hostname staged; reboot from the Proxmox console when ready.'
    echo 'dns-* settings require a resolver integration; configure DNS separately if none is installed.'
fi
systemctl daemon-reload
systemctl enable conleylabs-firewall.service
systemctl restart conleylabs-firewall.service
if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
    systemctl start qemu-guest-agent
else
    echo 'QEMU guest agent installed; enable its channel in Proxmox to use it.'
fi
systemctl enable minecraft.service
eula=/opt/minecraft/eula.txt
if [[ -L $eula || ( -e $eula && ! -f $eula ) ]]; then
    echo 'eula.txt must be a regular file, not a symlink or other file.' >&2
    exit 1
fi
if ! grep -Eq $'^eula=true\r?$' "$eula" 2>/dev/null; then
    # The initial launch generates eula.txt and normally exits until accepted.
    systemctl start minecraft.service
    for ((attempt=0; attempt<90; attempt++)); do
        if [[ -f $eula ]] && grep -Eq $'^eula=(false|true)\r?$' "$eula"; then
            break
        fi
        sleep 1
    done
    systemctl stop minecraft.service
    if [[ -L $eula ]] || ! grep -Eq $'^eula=(false|true)\r?$' "$eula" 2>/dev/null; then
        echo 'Minecraft did not generate a valid eula.txt within 90 seconds; service stopped.' >&2
        journalctl -u minecraft.service -n 30 --no-pager >&2
        exit 1
    fi
    backup "$eula"
    sed -i 's/^eula=false\r\?$/eula=true/' "$eula"
    chown minecraft:minecraft "$eula"
fi
systemctl restart minecraft.service
echo 'Minecraft service started and enabled at boot; EULA accepted.'
echo 'Check startup progress with: journalctl -u minecraft.service -f'
echo "System configuration applied. File backups: $backup_dir"
