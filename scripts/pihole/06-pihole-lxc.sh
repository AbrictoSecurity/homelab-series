#!/bin/bash
# Script:      06-pihole-lxc.sh
# Description: Creates a Debian 12 LXC container and installs Pi-hole unattended.
#              Attaches to vmbr2 (Internal, 10.10.10.0/24). Run from Proxmox host.
# Blog post:   https://abrictosecurity.com/homelab-series-domain-ssl-pihole-samba
# Usage:       sudo bash 06-pihole-lxc.sh
# Dependencies: pct, pvesm, pveam (Proxmox VE host tools)

set -euo pipefail

# ─── Abricto logo ─────────────────────────────────────────────────────────────
# shellcheck source=../lib/logo.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/logo.sh" 2>/dev/null || true

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Output helpers ───────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ─── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must be run as root.  Try: sudo bash $0"

# ─── Dependency checks ────────────────────────────────────────────────────────
command -v pct    &>/dev/null || die "pct not found. Is this a Proxmox VE host?"
command -v pvesm  &>/dev/null || die "pvesm not found. Is this a Proxmox VE host?"
command -v pveam  &>/dev/null || die "pveam not found. Is this a Proxmox VE host?"

# ─── Verify vmbr2 exists ──────────────────────────────────────────────────────
ip link show vmbr2 &>/dev/null \
    || die "vmbr2 not found. Run 01-create-bridges.sh first."

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║          Abricto HomeLab, 06-pihole-lxc.sh              ║${RESET}"
echo -e "${BOLD}║   Create Debian 12 LXC and install Pi-hole unattended    ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ─── Storage pool selection ───────────────────────────────────────────────────
echo -e "${BOLD}Available storage pools (LXC-capable):${RESET}"
echo ""
mapfile -t POOL_LIST < <(pvesm status --content rootdir 2>/dev/null \
    | awk 'NR>1 && $2=="active" {print $1}')

[[ ${#POOL_LIST[@]} -eq 0 ]] && die "No active storage pools found that support LXC rootfs."

for i in "${!POOL_LIST[@]}"; do
    printf "  ${CYAN}[%d]${RESET}  %s\n" "$((i+1))" "${POOL_LIST[$i]}"
done
echo ""
read -r -p "  Select storage pool [1]: " POOL_IDX
POOL_IDX="${POOL_IDX:-1}"
[[ "$POOL_IDX" =~ ^[0-9]+$ ]] && (( POOL_IDX >= 1 && POOL_IDX <= ${#POOL_LIST[@]} )) \
    || die "Invalid selection."
STORAGE="${POOL_LIST[$((POOL_IDX-1))]}"
echo ""

# ─── Template selection ───────────────────────────────────────────────────────
echo -e "${BOLD}Debian 12 LXC templates available locally:${RESET}"
echo ""
mapfile -t TMPL_LIST < <(pveam list local 2>/dev/null \
    | awk '/debian-12/ {print $1}')

if [[ ${#TMPL_LIST[@]} -eq 0 ]]; then
    info "No Debian 12 template found locally. Downloading from Proxmox repository..."
    pveam update
    REMOTE_TMPL=$(pveam available --section system 2>/dev/null \
        | awk '/debian-12-standard/ {print $2; exit}')
    [[ -z "$REMOTE_TMPL" ]] && die "Could not find a Debian 12 standard template in the Proxmox repository."
    pveam download local "$REMOTE_TMPL"
    mapfile -t TMPL_LIST < <(pveam list local 2>/dev/null | awk '/debian-12/ {print $1}')
fi

for i in "${!TMPL_LIST[@]}"; do
    printf "  ${CYAN}[%d]${RESET}  %s\n" "$((i+1))" "${TMPL_LIST[$i]}"
done
echo ""
read -r -p "  Select template [1]: " TMPL_IDX
TMPL_IDX="${TMPL_IDX:-1}"
[[ "$TMPL_IDX" =~ ^[0-9]+$ ]] && (( TMPL_IDX >= 1 && TMPL_IDX <= ${#TMPL_LIST[@]} )) \
    || die "Invalid selection."
TEMPLATE="${TMPL_LIST[$((TMPL_IDX-1))]}"
echo ""

# ─── Interactive configuration ────────────────────────────────────────────────
echo -e "${BOLD}Pi-hole LXC Configuration${RESET}"
echo "Press Enter to accept the default value shown in [brackets]."
echo ""

read -r -p "  Container ID (CTID) [101]: " CTID
CTID="${CTID:-101}"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID must be a number."

# Check for CTID collision
if pct status "${CTID}" &>/dev/null; then
    die "Container ID ${CTID} already exists.  Choose a different CTID."
fi

read -r -p "  Disk size in GB [4]: " DISK_GB
DISK_GB="${DISK_GB:-4}"
[[ "$DISK_GB" =~ ^[0-9]+$ ]] || die "Disk size must be a number."

read -r -p "  Memory in MB [512]: " MEMORY
MEMORY="${MEMORY:-512}"
[[ "$MEMORY" =~ ^[0-9]+$ ]] || die "Memory must be a number."

read -r -p "  CPU cores [1]: " CORES
CORES="${CORES:-1}"
[[ "$CORES" =~ ^[0-9]+$ ]] || die "Cores must be a number."

read -r -p "  IP address (CIDR) [10.10.10.2/24]: " CT_IP
CT_IP="${CT_IP:-10.10.10.2/24}"

read -r -p "  Gateway [10.10.10.1]: " CT_GW
CT_GW="${CT_GW:-10.10.10.1}"

echo ""
read -r -s -p "  Root password for the LXC: " CT_PASS
echo ""
[[ -z "$CT_PASS" ]] && die "Root password cannot be empty."
echo ""

# ─── Confirmation summary ─────────────────────────────────────────────────────
echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Review before creating:${RESET}"
echo ""
printf "  %-14s  %s\n" "CTID:"      "$CTID"
printf "  %-14s  %s\n" "Hostname:"  "pihole"
printf "  %-14s  %s\n" "Template:"  "$TEMPLATE"
printf "  %-14s  %s\n" "Storage:"   "$STORAGE"
printf "  %-14s  %s GB\n" "Disk:"   "$DISK_GB"
printf "  %-14s  %s MB\n" "Memory:" "$MEMORY"
printf "  %-14s  %s\n" "Cores:"     "$CORES"
printf "  %-14s  %s  gw: %s\n" "Network:" "$CT_IP" "$CT_GW"
printf "  %-14s  %s\n" "Bridge:"    "vmbr2 (Internal)"
printf "  %-14s  %s\n" "Nameserver:" "1.1.1.1 (temporary, will be self-referential after install)"
echo ""
echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
echo ""
read -r -p "Create this container? [y/N]: " CONFIRM
CONFIRM="${CONFIRM,,}"
[[ "$CONFIRM" == "y" || "$CONFIRM" == "yes" ]] \
    || { info "Aborted. No changes were made."; exit 0; }
echo ""

# ─── Create LXC ───────────────────────────────────────────────────────────────
info "Creating Pi-hole LXC (CTID: ${CTID})..."
pct create "${CTID}" "${TEMPLATE}" \
    --hostname pihole \
    --memory "${MEMORY}" \
    --cores "${CORES}" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=vmbr2,ip=${CT_IP},gw=${CT_GW}" \
    --nameserver 1.1.1.1 \
    --password "${CT_PASS}" \
    --unprivileged 1 \
    --onboot 1
unset CT_PASS
ok "LXC created."

info "Starting LXC..."
pct start "${CTID}"

info "Waiting for container to be ready (10 s)..."
sleep 10
ok "Container started."

# ─── Update packages ──────────────────────────────────────────────────────────
info "Updating packages inside LXC..."
pct exec "${CTID}" -- bash -c "apt-get update -qq && apt-get upgrade -y"
ok "Packages updated."
echo ""

# ─── Install Pi-hole (unattended) ─────────────────────────────────────────────
info "Installing Pi-hole (unattended)..."
warn "This may take 2–4 minutes. The installer downloads Pi-hole from GitHub."
echo ""

pct exec "${CTID}" -- bash -c "
  curl -sSL https://install.pi-hole.net \
    | PIHOLE_SKIP_OS_CHECK=true bash /dev/stdin --unattended
"

echo ""
ok "Pi-hole installed."
echo ""

# ─── Configure nameserver to point at itself ──────────────────────────────────
info "Updating container nameserver to use Pi-hole itself..."
pct set "${CTID}" --nameserver "127.0.0.1"
pct exec "${CTID}" -- bash -c "echo 'nameserver 127.0.0.1' > /etc/resolv.conf"
ok "Nameserver updated."
echo ""

# ─── Result ───────────────────────────────────────────────────────────────────
CT_IP_CLEAN="${CT_IP%%/*}"

echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║              Pi-hole installed successfully.             ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Access:${RESET}"
echo "  http://${CT_IP_CLEAN}/admin   (HTTP, no cert yet)"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Set the Pi-hole admin password:"
echo "     pct exec ${CTID} -- pihole -a -p"
echo "     (Pi-hole v6: pct exec ${CTID} -- pihole setpassword)"
echo ""
echo "  2. Add local DNS A records:"
echo "     pct exec ${CTID} -- bash /opt/homelab/scripts/pihole/07-pihole-dns-records.sh <domain>"
echo ""
echo "  3. Deploy the Let's Encrypt cert to enable HTTPS:"
echo "     sudo bash scripts/dns-ssl/05-deploy-certs.sh <domain>"
echo ""
echo "  4. Configure OPNsense DHCP to distribute ${CT_IP_CLEAN} as the DNS server"
echo "     for all Internal (vmbr2) clients."
echo ""
