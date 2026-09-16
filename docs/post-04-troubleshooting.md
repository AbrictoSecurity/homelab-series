# Post 4 Troubleshooting: Docker VM, Kali VM & DVWA

Reference for [HomeLab Series Post 4](https://abrictosecurity.com/homelab-series-docker-kali-dvwa/).

Grouped by component. Several of these share a trait worth calling out: **the symptom points at the
wrong layer**. A database that will not start is a container permissions problem. A connection that
times out while ARP resolves is a routing problem. Those are flagged below.

---

## Kali VM: import and boot

**Boots to an initramfs prompt.**
The disk is on the wrong controller. Kali's prebuilt QEMU image is built for virtio-blk and its
initramfs does not reliably carry `virtio_scsi`.

```bash
qm set 200 --delete scsi0
qm set 200 --virtio0 STORAGE:vm-200-disk-0
qm set 200 --boot order=virtio0
```

**Does not boot at all, no output.**
BIOS must be SeaBIOS, not OVMF. The image is MBR-partitioned. VM 200 → Options → BIOS.

**Only one Ethernet device appears.**
The second NIC was not added. Check VM 200 → Hardware for both `net0` (vmbr2) and `net1` (vmbr3),
then reboot the guest.

**`gpg --verify` fails, or reports an unexpected key.**
Do not continue. Delete the download and retry. The script pins Kali's primary key fingerprint
`827C8569F2518CC677FECA1AED65462EC8D5E4C5` and compares the *primary* key, not the signing subkey.
Cross-check it against
[Kali's documentation](https://www.kali.org/docs/introduction/download-official-kali-linux-images/).

**Import fails on free space.**
The archive plus the extracted qcow2 need roughly 45 GB transient. `df -h /var/lib/vz`. Most is
released once the import completes.

---

## Networking and policy routing

**Kali cannot reach another DMZ host, but ARP works.**
*Symptom points at the wrong layer.* This is the one that wastes an afternoon: ARP resolves, the
neighbour shows `REACHABLE`, the target is listening, no firewall is in the way, and TCP still times
out. Table 100 is missing the on-link subnet route.

Plain `ip route get` consults the main table and looks correct either way. You have to pass `from`
to exercise the policy rule:

```bash
ip route get 10.20.20.30 from 10.20.20.20
```

```text
# Broken: sent to the gateway, which will not hairpin it back
10.20.20.30 from 10.20.20.20 via 10.20.20.1 dev eth1 table 100

# Correct: direct, on-link
10.20.20.30 from 10.20.20.20 dev eth1 table 100
```

Fix:

```bash
nmcli connection modify dmz ipv4.routes "10.20.20.0/24 0.0.0.0 table=100, 0.0.0.0/0 10.20.20.1 table=100"
nmcli connection up dmz
```

**The DMZ gateway "fails" a ping test but everything works.**
*Symptom points at the wrong layer.* OPNsense answers ARP while dropping ICMP on its DMZ interface
by default, so `ping 10.20.20.1` proves nothing either way. Test layer 2:

```bash
arping -c2 -I eth1 10.20.20.1
```

A reply means the gateway is present and the segment is fine.

**Two default routes in the main table.**
The DMZ profile is contributing one. It should have no `ipv4.gateway` and `ipv4.never-default yes`.

```bash
ip route show default    # expect exactly one line, via 10.10.10.1
nmcli connection show dmz | grep -E "never-default|gateway"
```

**Interfaces came out backwards.**
`12-kali-network.sh` assigns the first Ethernet device to Internal and the second to DMZ. Re-run with
the order reversed:

```bash
sudo bash 12-kali-network.sh eth1 eth0
```

**Rolling back the network configuration.**
The script backs up NetworkManager profiles before touching anything and prints the path:

```bash
nmcli connection delete internal dmz
cp -a /root/nm-backup-TIMESTAMP/. /etc/NetworkManager/system-connections/
systemctl restart NetworkManager
```

---

## RDP

**`ss` shows xrdp on `*:3389` even though you set an address.**
*Symptom points at the wrong layer.* xrdp 0.10 removed the `address=` key. An `address=` line is now
silently ignored — no warning, no error, the service starts and listens on everything. Binding is a
URI in `port=`:

```text
# /etc/xrdp/xrdp.ini, [Globals] section
port=tcp://10.20.20.20:3389
```

Only the `port=` inside `[Globals]`. Later sections carry their own `port=` keys (`port=-1`,
`port=ask3389`) that mean something different, so a find-and-replace across the file breaks the
session backends.

Verify against the socket, not the config file. `ss` renders a wildcard bind as `*:3389`,
`0.0.0.0:3389` or `[::]:3389` depending on address family — all three mean every interface:

```bash
ss -tlnp | grep 3389
```

**Connects then immediately disconnects.**
Almost always the `ssl-cert` group. xrdp reads `/etc/ssl/private/ssl-cert-snakeoil.key`, mode 640
`root:ssl-cert`. Without membership the service starts normally and drops every connection at the
TLS handshake.

```bash
id -nG xrdp
adduser xrdp ssl-cert && systemctl restart xrdp
```

**Grey screen after login.**
`~/.xsession` is missing or wrongly owned. It should contain `xfce4-session` and belong to the
connecting user.

**xrdp fails to start after setting a specific address.**
Every interface named in `port=` must be up when xrdp starts, or the service aborts. Run
`12-kali-network.sh` before `13-kali-rdp.sh`. After a reboot, confirm NetworkManager brings both
profiles up before xrdp.

**Reaches the VM but hangs after the login prompt.**
Policy routing is not applied. Check for the rule:

```bash
ip rule show | grep 10.20.20.20
```

If missing, re-run `12-kali-network.sh`.

---

## Firewall and access from the management network

**RDP to 10.20.20.20 times out from your workstation.**
*Symptom points at the wrong layer.* Kali and xrdp are fine; the traffic never gets through OPNsense.
From the management network it enters OPNsense on **WAN**, and four things must all be true:

1. The workstation, or the home router, routes 10.10.10.0/24 and 10.20.20.0/24 via OPNsense's WAN
   address. Reserve that address on the home router; WAN takes it from DHCP.
2. **Interfaces → [WAN] → Block private networks** is unticked. Otherwise every RFC 1918 source is
   dropped before any rule is read.
3. The pass rule is on **WAN**, not DMZ. Rules match on the interface a packet enters.
4. **Firewall → Settings → Advanced → Disable reply-to on WAN rules** is ticked. Otherwise replies
   are sent via the home router instead of straight back to a client on WAN's subnet.

Find which one with a capture on the Proxmox host while retrying:

```bash
tcpdump -ni tap100i0 tcp port 3389   # OPNsense WAN NIC: SYNs should arrive here
tcpdump -ni tap100i2 tcp port 3389   # OPNsense DMZ NIC: nothing here means OPNsense dropped them
```

No SYNs on the WAN NIC means item 1. SYNs on WAN but none on DMZ means items 2 or 3.

**Internal hosts reach the DMZ despite "Block Internal to DMZ".**
OPNsense applies the first matching rule. `03-opnsense-configure.sh` creates *HomeLab: Allow Internal
to WAN* (destination any) before *HomeLab: Block Internal to DMZ*; if the allow sorts first, the block
never fires. In **Firewall → Rules [new]**, give the block a lower Sequence number, apply, and confirm:

```bash
pct exec 101 -- timeout 3 bash -c "echo > /dev/tcp/10.20.20.30/80" && echo REACHABLE || echo BLOCKED
```

**Home devices reach lab addresses without passing through OPNsense.**
The physical NICs behind vmbr2 or vmbr3 are cabled to the home switch, which joins those bridges to
the home network at layer 2. Unplug them unless they go to a dedicated switch. On the Proxmox host
this should print nothing:

```bash
bridge fdb show br vmbr3 | grep -v -e permanent -e tap -e veth
```

**The OPNsense web UI does not load from your workstation.**
It listens on the Internal address, 10.10.10.1, which the management network cannot reach until the
routes and rules above exist. Tunnel through the Proxmox host, which has a leg on vmbr2:

```bash
ssh -N -L 8443:10.10.10.1:443 root@192.168.1.100
```

Then browse to `https://localhost:8443`.

**The OPNsense dashboard renders blank, or the console reports "write failed, filesystem is full".**
Check disk before anything else, from the console shell: `df -h /`. Proxmox showing OPNsense's memory
as fully used is not the cause: without a guest agent it reports the whole allocation. To grow the
disk, `qm resize 100 scsi0 +16G` on the host; inside OPNsense the swap partition sits after rootfs, so
swap must be deleted and recreated at the end before `gpart resize` and `growfs /`. Then find what
filled it, or the extra space goes the same way:

```bash
du -xhd 1 /var 2>/dev/null | sort -h | tail -8
```

---

## Docker VM

**Docker installs but containers will not start.**
You are on an LXC, not a VM:

```text
OCI runtime create failed: runc create failed: unable to start container process:
open sysctl net.ipv4.ip_unprivileged_port_start file: reopen fd 8: permission denied
```

runc 1.2+ writes `net.ipv4.ip_unprivileged_port_start` into the new network namespace and Proxmox's
AppArmor profile blocks it. The two published fixes are downgrading `containerd.io` to get a runc
without the CVE-2025-52881 hardening, or `lxc.apparmor.profile: unconfined`. Neither is acceptable on
a host sitting next to your domain controller. Use `vm/docker-vm.sh` instead. See Post 4, Section 3.

**The VM landed on vmbr0.**
Default mode in `docker-vm.sh` hardcodes `vmbr0`. Choose **Advanced** to place it on vmbr2. If it is
already built, cloud-init makes relocation cheap — no rebuild needed:

```bash
qm stop 103
qm set 103 --net0 virtio,bridge=vmbr2
qm set 103 --ipconfig0 ip=10.10.10.4/24,gw=10.10.10.1 --nameserver 10.10.10.2
qm start 103
```

Grow the disk at the same time if Default mode gave you 10 GB. Cloud-init extends the root
filesystem on the next boot:

```bash
qm resize 103 scsi0 +10G
```

**Portainer says the instance timed out.**
You waited more than five minutes to create the admin user. Restarting reopens the window:

```bash
qm guest exec 103 -- /bin/bash -lc "docker restart portainer"
```

**Cloud-init credentials left in `/tmp`.**
`docker-vm.sh` writes them to `/tmp/docker-103-cloud-init-credentials.txt` and tells you to delete
the file. Move it somewhere root-only first if you still need the password:

```bash
umask 077
mv /tmp/docker-103-cloud-init-credentials.txt /root/docker-vm-103-cloudinit.txt
```

---

## DVWA

**MariaDB will not start: `status=226/NAMESPACE`.**
*Symptom points at the wrong layer.* Apache starts fine, so this reads as a database fault. It is a
container permissions problem.

```text
mariadb.service: Failed to set up mount namespacing: /run/systemd/unit-root/proc: Permission denied
mariadb.service: Control process exited, code=exited, status=226/NAMESPACE
```

MariaDB's packaged unit uses systemd sandboxing — `ProtectSystem=full`, `ProtectHome=true` and, the
one that actually bites, `ProtectControlGroups=true`. Each needs mount-namespace operations an
unprivileged LXC is not permitted to make. `15-dvwa-lxc.sh` handles this automatically; to fix by
hand:

```bash
pct exec 104 -- mkdir -p /etc/systemd/system/mariadb.service.d
pct exec 104 -- bash -c 'printf "%s\n" "[Service]" "ProtectSystem=false" "ProtectHome=false" "ProtectControlGroups=false" "PrivateDevices=false" "ProtectProc=default" "ProcSubset=all" > /etc/systemd/system/mariadb.service.d/override.conf'
pct exec 104 -- systemctl daemon-reload
pct exec 104 -- systemctl restart mariadb
```

Relaxing systemd hardening on a database is not something to do casually. It is acceptable *here*
precisely because this host exists to be compromised and holds nothing of value. Do not carry this
drop-in onto a real database server.

**`Could not execute systemctl` during package installation.**
Harmless in itself. `deb-systemd-invoke` cannot reach systemd while dpkg runs under `pct exec`, so
packages install but their services never start. The script starts them explicitly afterwards. If
installing by hand, run `systemctl restart mariadb apache2` once apt finishes.

**"Database not found" banner.**
Schema not initialised. Browse to `http://10.20.20.30/DVWA/setup.php` and click Create / Reset
Database. Confirm the credentials match:

```bash
pct exec 104 -- grep db_password /var/www/html/DVWA/config/config.inc.php
pct exec 104 -- cat /root/dvwa-credentials.txt
```

**HTTP 500.**
Usually a missing PHP module:

```bash
pct exec 104 -- apt install -y php-mysqli php-gd
pct exec 104 -- systemctl restart apache2
```

The specific error is in `/var/log/apache2/error.log`.

**File Inclusion (RFI) exercises do not work.**
`allow_url_include` did not get set. Verify through the web server, not `php -i` on the CLI — they
read different ini files. The Apache one is `/etc/php/8.2/apache2/php.ini`.

**Cannot reach the internet during provisioning.**
DVWA needs outbound access exactly once, to install itself. If your DMZ has no outbound path, either
allow DMZ to WAN for the length of the build, or build it on the Internal network and relocate:

```bash
pct stop 104
pct set 104 --net0 name=eth0,bridge=vmbr3,ip=10.20.20.30/24,gw=10.20.20.1
pct set 104 --nameserver 10.20.20.1
pct start 104
```

The container keeps everything installed; only its network attachment changes. Once in the DMZ it has
no working resolver, which is fine for a web target and mildly useful — a shell on DVWA cannot
resolve an external callback domain.

**`pct snapshot 104` fails.**
The storage pool is thick `lvm`, which does not support snapshots. `lvmthin`, `zfspool` and `dir`
do. Check with `pct config 104 | grep rootfs` and `pvesm status`. Use `vzdump` instead:

```bash
pct stop 104
vzdump 104 --storage local --mode stop --compress zstd
pct start 104
```

---

## Helper scripts

**"No active storage pools found."**
Check the pool actually accepts the content type you need:

```bash
pvesm status --content rootdir    # containers
pvesm status --content images     # VMs
```

**`unable to create CT NNN - unsupported debian version '13.6'`**
A version gate in `/usr/share/perl5/PVE/LXC/Setup/Debian.pm`:

```perl
die "unsupported debian version '$version'\n" if !($version >= 4 && $version <= 13);
```

`$version` comes from the template's `/etc/debian_version`, and `13.6 <= 13` is false — so every
Debian 13 point release above 13.0 is rejected. Use Debian 12, or update `pve-container`. Containers
only; VMs never touch `pve-container`.

Worth checking while you are there, since an empty result means the host is not receiving Proxmox
updates at all:

```bash
ls -la /etc/apt/sources.list.d/
apt-cache policy pve-container
```

**`docker-vm.sh` will not run unattended.**
It cannot. `select_os()` calls whiptail regardless of any flag, there is no CLI argument handling,
and Default mode hardcodes `vmbr0`. Run it interactively and choose Advanced.

---

## See also

| | |
|---|---|
| Post 4 | https://abrictosecurity.com/homelab-series-docker-kali-dvwa/ |
| IP allocation | [docs/ip-allocation.md](ip-allocation.md) |
| Scripts | `scripts/docker/`, `scripts/kali/`, `scripts/targets/` |
