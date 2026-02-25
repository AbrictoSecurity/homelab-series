# Abricto Security — HomeLab Series

Scripts, configs, and automation for the **Abricto Security HomeLab Blog Series** — a practical, open source guide to building a production-grade home lab from scratch using refurbished enterprise hardware.

Every step in the blog posts has a corresponding script here. Clone the repo, customize the variables, and follow along.

---

## Series Overview

| Post | Title | Status | Blog Link |
|------|-------|--------|-----------|
| 1 | Proxmox on Refurbished Servers | Published | *(link when available)* |
| 2 | Network Architecture — Bridges & OPNsense | In Progress | *(link when available)* |
| 3 | Domain, SSL, Pi-hole & Samba AD | In Progress | *(link when available)* |
| 4 | Kali Linux VM | Planned | *(link when available)* |

---

## Prerequisites

- Dell PowerEdge R720 (or comparable enterprise server) with Proxmox VE installed
- 4 physical NICs (or a managed switch with VLANs)
- A registered domain name (Post 3 uses Porkbun + Cloudflare)
- Basic familiarity with Linux CLI and networking concepts

See [Post 1](*(link when available)*) for the full hardware setup and Proxmox installation walkthrough.

---

## Quick Start

Clone the repo to your Proxmox host:

```bash
apt install git -y
git clone https://github.com/abricto-security/homelab-series.git /opt/homelab
cd /opt/homelab
```

> **Before running any script:** Review it, understand what it does, and customize the variables at the top for your environment. These scripts are written for the reference network defined below — your IPs and hostnames will differ.

---

## Network Reference

### Bridges

| Bridge | Physical NIC | Role | Subnet | Gateway |
|--------|-------------|------|--------|---------|
| vmbr0 | NIC 1 | Management | 192.168.1.0/24 | Home router |
| vmbr1 | NIC 2 | Edge (WAN) | Home router DHCP | Home router |
| vmbr2 | NIC 3 | Internal (LAN) | 10.10.10.0/24 | OPNsense 10.10.10.1 |
| vmbr3 | NIC 4 | DMZ | 10.20.20.0/24 | OPNsense 10.20.20.1 |

### Host Allocation

| Hostname | IP | Role |
|----------|----|------|
| proxmox.yourname-lab.com | 192.168.1.100 | Proxmox hypervisor |
| edge.yourname-lab.com | 10.10.10.1 | OPNsense firewall |
| pihole.yourname-lab.com | 10.10.10.2 | Pi-hole DNS |
| dc01.corp.yourname-lab.com | 10.10.10.3 | Samba AD DC |

Full reference: [docs/ip-allocation.md](docs/ip-allocation.md)

---

## Script Reference

| Script | Post | Description | Usage |
|--------|------|-------------|-------|
| `scripts/network/01-create-bridges.sh` | 2 | Creates vmbr1/2/3 on Proxmox | `bash 01-create-bridges.sh` |
| `scripts/network/02-create-opnsense-vm.sh` | 2 | Creates OPNsense VM via `qm` | `bash 02-create-opnsense-vm.sh` |
| `scripts/network/03-opnsense-configure.sh` | 2 | Configures OPNsense interfaces and firewall rules via API | `bash 03-opnsense-configure.sh <key> <secret>` |
| `scripts/dns-ssl/04-certbot-setup.sh` | 3 | Installs Certbot and issues wildcard cert via Let's Encrypt + Cloudflare | `bash 04-certbot-setup.sh <domain> <cf_token>` |
| `scripts/dns-ssl/05-deploy-certs.sh` | 3 | Distributes certs to Proxmox, OPNsense, and Pi-hole | `bash 05-deploy-certs.sh <domain>` |
| `scripts/pihole/06-pihole-lxc.sh` | 3 | Creates and installs Pi-hole in an LXC container | `bash 06-pihole-lxc.sh` |
| `scripts/pihole/07-pihole-dns-records.sh` | 3 | Adds local DNS A records to Pi-hole | `bash 07-pihole-dns-records.sh <domain>` |
| `scripts/samba/08-samba-lxc.sh` | 3 | Creates and provisions a Samba AD DC LXC | `bash 08-samba-lxc.sh <domain> <realm> <netbios> <pass>` |
| `scripts/pihole/09-pihole-conditional-forward.sh` | 3 | Wires Pi-hole conditional forwarding to Samba DNS | `bash 09-pihole-conditional-forward.sh <ad_domain> <dc_ip>` |

---

## Open Source Stack

| Component | Tool | Cost |
|-----------|------|------|
| Hypervisor | Proxmox VE | Free |
| Firewall | OPNsense CE | Free |
| Local DNS | Pi-hole | Free |
| Domain Controller | Samba AD (Debian 12) | Free |
| SSL Certificates | Let's Encrypt + Certbot | Free |
| DNS-01 Plugin | certbot-dns-cloudflare | Free |
| DNS Management | Cloudflare (free tier) | Free |
| Domain Registrar | Porkbun | ~$10/yr |
| Version Control | Git / GitHub | Free |

---

## Security Note

**Never commit secrets.** This repo's `.gitignore` excludes API tokens, private keys, `.env` files, and certificates. Scripts that require credentials accept them as arguments or read from a `.env` file that you create locally and never commit.

If you accidentally commit a secret: rotate it immediately, then remove it from git history.

---

## License

MIT — see [LICENSE](LICENSE) for details.

Scripts are provided as-is for educational purposes. Review all scripts before running them in your environment.
