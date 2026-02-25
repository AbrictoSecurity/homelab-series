# HomeLab IP Allocation

Reference for all networks, hosts, and IP assignments used throughout the Abricto Security HomeLab Series.
Update this file whenever a new service is added.

---

## Networks

| Network | Bridge | Physical NIC | Subnet | Gateway | Purpose |
|---------|--------|-------------|--------|---------|---------|
| Management | vmbr0 | NIC 1 | 192.168.1.0/24 | Home router | Proxmox UI, SSH, IPMI |
| Edge (WAN) | vmbr1 | NIC 2 | Home router DHCP | Home router | OPNsense WAN interface |
| Internal (LAN) | vmbr2 | NIC 3 | 10.10.10.0/24 | 10.10.10.1 | VMs and LXCs behind firewall |
| DMZ | vmbr3 | NIC 4 | 10.20.20.0/24 | 10.20.20.1 | Internet-facing services |

---

## Hosts

| Hostname | IP | Network | Role | Post |
|----------|----|---------|------|------|
| proxmox.yourname-lab.com | 192.168.1.100 | Management | Proxmox VE hypervisor | 1 |
| edge.yourname-lab.com | 10.10.10.1 | Internal | OPNsense firewall (LAN interface) | 2 |
| edge.yourname-lab.com | 10.20.20.1 | DMZ | OPNsense firewall (DMZ interface) | 2 |
| pihole.yourname-lab.com | 10.10.10.2 | Internal | Pi-hole DNS resolver | 3 |
| dc01.corp.yourname-lab.com | 10.10.10.3 | Internal | Samba Active Directory DC | 3 |

---

## OPNsense VM Interfaces

| VM Interface | Bridge | Network | IP |
|-------------|--------|---------|-----|
| vtnet0 | vmbr1 | Edge (WAN) | DHCP from home router |
| vtnet1 | vmbr2 | Internal (LAN) | 10.10.10.1/24 |
| vtnet2 | vmbr3 | DMZ | 10.20.20.1/24 |

---

## Active Directory

| Setting | Value |
|---------|-------|
| AD Domain | corp.yourname-lab.com |
| NetBIOS Name | CORP |
| Realm | CORP.YOURNAME-LAB.COM |
| DC Hostname | dc01 |
| DC IP | 10.10.10.3 |

> **Note on `.local` TLD:** Do not use `.local` for internal domains. It conflicts with mDNS (Bonjour/Avahi) and causes resolution failures in mixed environments. Use a real subdomain of your registered domain instead (e.g., `corp.yourname-lab.com`).

---

## DNS Records (Pi-hole Custom DNS)

| Hostname | IP | Type |
|----------|----|------|
| proxmox.yourname-lab.com | 192.168.1.100 | A |
| edge.yourname-lab.com | 10.10.10.1 | A |
| pihole.yourname-lab.com | 10.10.10.2 | A |
| dc01.corp.yourname-lab.com | 10.10.10.3 | A |

---

## Wildcard SSL Certificate

| Domain | Cert Type | Tool | Renewal |
|--------|-----------|------|---------|
| *.yourname-lab.com | Wildcard DV | Let's Encrypt + Certbot | Auto (cron/systemd) |

Cert storage path: `/etc/letsencrypt/live/yourname-lab.com/`
