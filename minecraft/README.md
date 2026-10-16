# Debian guest system deployment

Reproduces the system settings inspected on `suminecappqa001.conleylabs.com` on
2026-10-15. Run inside an existing Debian 13 VM. The Minecraft user/group and
directory, specified Mojang server JAR, Java 25, and boot-enabled Minecraft service
are included. Proxmox VM creation and Tailscale installation/configuration are
outside this script's scope. This baseline targets Debian 13 on amd64.

```bash
cp deployment.conf.example deployment.conf
# Edit deployment.conf for the target VM.
bash deploy-system.sh deployment.conf
sudo bash deploy-system.sh deployment.conf --apply
```

The first invocation previews the selected settings. The configuration is Bash
code, so use a trusted file. Python 3 must already be installed (it was present
on the example). Copy both scripts, `minecraft.service`, and the configuration to
the target together.
No changes have been applied to the example server during development.

## Captured settings

| Setting | Example | Deployment behavior |
| --- | --- | --- |
| IPv4 inbound SMTP | Drop TCP 25, 465, 587 | Reproduced |
| IPv4 inbound SSH | Accept TCP 22 from 192.168.30.1; drop other sources | Source CIDR configurable |
| IPv4 policies | INPUT, FORWARD, OUTPUT ACCEPT | Existing policies preserved; INPUT ACCEPT required |
| IPv6 | No custom port restrictions | Preserved without adding restrictions |
| SSH account restriction | hayden@192.168.30.1 | Optional; existing account required |
| Temporary inspection access | root@192.168.30.1 and an authorized key | Excluded from deployment |
| Timezone / locale | America/New_York / en_US.UTF-8 | Reproduced |
| Network | ens18, 192.168.30.2/24, gateway 192.168.30.1 | Optional; unique target address required |
| DNS hints | 192.168.30.1, search conleylabs.com | Written to optional interfaces configuration |
| Guest utilities | qemu-guest-agent, curl, sudo, vim | Installed alongside firewall/SSH/locale tools |
| Minecraft account | minecraft, primary group minecraft, /home/minecraft, /bin/bash | Created if absent; existing account must match |
| Minecraft directory | /opt/minecraft, minecraft:minecraft, mode 0750 | Created or ownership/mode corrected |
| Minecraft JAR | User-specified Mojang object | Downloaded with wget to /opt/minecraft/server.jar, minecraft:minecraft, mode 0664 |
| Minecraft service | Java 25, 4 GB initial/max heap | Enabled at boot and started after EULA acceptance |

New Minecraft accounts have no usable password until one is explicitly set.
UID/GID values are allocated on the target rather than forcing the example's
1001 IDs. Existing matching accounts are reused. Only `/opt/minecraft` and the
managed `server.jar` have ownership and mode enforced; other contents are untouched.
Mode 0750 gives the owner full access, the group read/traverse access, and others
no access.

The JAR URL is pinned to Mojang object
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. Downloads are checked against that
SHA-1 before installation; a matching existing JAR skips the download. A different
existing JAR is backed up before replacement. A failed download or checksum leaves
the existing JAR untouched.

`minecraft.service` runs as `minecraft:minecraft` in `/opt/minecraft`, using
OpenJDK 25 with `-Xms4G -Xmx4G`. Allocate VM memory above the 4 GB heap to leave
room for Java overhead and the OS. Deployment enables the service at boot.
On the first launch it waits up to 90 seconds for `eula.txt`, stops the service,
backs up the file, changes the `eula=false` setting to `eula=true`, and restarts
the service. This implements the explicitly requested EULA acceptance. If the
file is already accepted, it skips that first-launch step and restarts the service.
Other EULA file content is preserved. A timeout leaves the service stopped and
prints recent logs. Subsequent script runs restart Minecraft as well.

Check startup progress with `journalctl -u minecraft.service -f`. Systemd starting
the process does not by itself confirm that world initialization has completed.

The SMTP rules affect incoming traffic; they do not block outbound mail.
No custom forwarding settings were found: IPv4 and IPv6 forwarding were both 0.
No custom root cron jobs were found. The guest agent was installed but inactive;
deployment starts it when the Proxmox guest-agent channel is available.
Package versions follow the target's configured APT repositories.

## Firewall persistence and ordering

The example had live custom iptables rules, but no `/etc/iptables` saved rules,
no netfilter-persistent service, and a disabled nftables service. This deployment
adds persistence through `conleylabs-firewall.service` before networking starts.
It updates only `CONLEY-HOST-IN` and appends one INPUT jump. Repeated runs replace
that chain's rules without duplicating the jump. It never flushes the full
ruleset or copies runtime counters, NAT rules, marks, or machine-specific VPN IPs.

On the example, Tailscale's INPUT hook precedes the custom rules and accepts
Tailscale-interface traffic first. The appended custom chain preserves that
ordering when such a hook exists. Tailscale manages its own dynamic rules when
you install/configure it later; its configuration is deliberately excluded.
Earlier ACCEPT rules on other target systems can likewise bypass this chain.
Use this on a fresh Debian guest or review its existing firewall first.

Backups of overwritten files go under `/var/backups/conleylabs/`. An SSH session
outside the configured IPv4 source range is rejected before applying changes;
use the Proxmox console when changing the permitted source. Keep console access
available while verifying a new VM. Live firewall behavior and boot persistence
still need validation on a disposable VM; local tests mock the firewall tools.

## Optional networking and SSH

Set `CONFIGURE_NETWORK=1` and fill in the target hostname and unique address to
stage `/etc/network/interfaces`, `/etc/hostname` and the host's `/etc/hosts` entry.
The script does not restart networking or reboot. This option replaces the main
interfaces file; use it with the example's single-interface ifupdown layout.
Existing snippets in `interfaces.d` remain and must not define the same interface.

The `dns-*` lines require resolver integration. The example's actual
`resolv.conf` was managed by Tailscale, so this script leaves resolver state alone.
Provide the target's DNS configuration through your chosen resolver or later
Tailscale procedure before relying on hostname resolution.

Set `CONFIGURE_SSH=1` to write and validate an SSH drop-in, then reload SSH.
The account and its password or authorized keys must already exist. The script
refuses existing `AllowUsers` or `Match` directives elsewhere rather than merging
potentially conflicting access rules. Temporary inspection root access is not
included. This means the SSH option intentionally refuses the current example
until its existing restriction is reviewed.

After the inspection is complete, remove the temporary `root@192.168.30.1`
allow-list entry and the `minecraft-deployment` authorized key from root on the
example, validate with `sshd -t`, and reload SSH. Those cleanup changes have not
been performed automatically.

## Local checks

```bash
bash -n deploy-system.sh host-firewall.sh
python3 tests/test_firewall.py
```
