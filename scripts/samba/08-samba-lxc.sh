#!/bin/bash
# Script:      08-samba-lxc.sh
# Description: Creates a Debian 12 LXC container and provisions it as a
#              Samba 4 Active Directory Domain Controller. Run from Proxmox host.
# Blog post:   https://abrictosecurity.com/homelab-series-domain-ssl-pihole-samba
# Usage:       sudo bash 08-samba-lxc.sh
# Dependencies: pct, pvesm, pveam (Proxmox VE host tools)
# Security:    The AD Administrator password is read interactively (silent prompt)
#              and never written to disk or shell history.
# Note:        Samba AD DC requires a PRIVILEGED LXC (--unprivileged 0).
#              It needs kernel capabilities (setuid, mknod, sys_admin) that are
#              unavailable in unprivileged containers. This is the standard
#              Proxmox/Samba recommendation for home lab Domain Controllers.

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
echo -e "${BOLD}║           Abricto HomeLab, 08-samba-lxc.sh              ║${RESET}"
echo -e "${BOLD}║   Create Debian 12 LXC and provision Samba AD DC         ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
warn "Samba AD DC runs in a PRIVILEGED container (required for kernel capabilities)."
warn "Privileged containers run as root on the host, use only in trusted lab networks."
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
echo -e "${BOLD}Samba AD DC LXC Configuration${RESET}"
echo "Press Enter to accept the default value shown in [brackets]."
echo ""

read -r -p "  Container ID (CTID) [102]: " CTID
CTID="${CTID:-102}"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID must be a number."

if pct status "${CTID}" &>/dev/null; then
    die "Container ID ${CTID} already exists.  Choose a different CTID."
fi

read -r -p "  Disk size in GB [8]: " DISK_GB
DISK_GB="${DISK_GB:-8}"
[[ "$DISK_GB" =~ ^[0-9]+$ ]] || die "Disk size must be a number."

read -r -p "  Memory in MB [1024]: " MEMORY
MEMORY="${MEMORY:-1024}"
[[ "$MEMORY" =~ ^[0-9]+$ ]] || die "Memory must be a number."

read -r -p "  CPU cores [1]: " CORES
CORES="${CORES:-1}"
[[ "$CORES" =~ ^[0-9]+$ ]] || die "Cores must be a number."

read -r -p "  IP address (CIDR) [10.10.10.3/24]: " CT_IP
CT_IP="${CT_IP:-10.10.10.3/24}"

read -r -p "  Gateway [10.10.10.1]: " CT_GW
CT_GW="${CT_GW:-10.10.10.1}"

echo ""
echo -e "${BOLD}Active Directory Settings${RESET}"
echo ""
echo "  The Kerberos realm is the full uppercase AD domain (e.g. CORP.YOURNAME-LAB.COM)."
echo "  The NetBIOS domain is the short name (max 15 chars, uppercase, e.g. YOURLAB)."
echo ""
read -r -p "  Kerberos realm (AD domain, uppercase) [CORP.YOURNAME-LAB.COM]: " REALM
REALM="${REALM:-CORP.YOURNAME-LAB.COM}"
REALM="${REALM^^}"   # force uppercase

read -r -p "  NetBIOS domain name (short, uppercase) [YOURLAB]: " NETBIOS
NETBIOS="${NETBIOS:-YOURLAB}"
NETBIOS="${NETBIOS^^}"

echo ""
warn "The AD Administrator password must meet Samba complexity requirements:"
warn "  At least 8 characters, mixed case, numbers or symbols."
echo ""
read -r -s -p "  AD Administrator password: " ADMINPASS
echo ""
[[ -z "$ADMINPASS" ]] && die "AD Administrator password cannot be empty."
echo ""

# Derive hostname from realm (e.g. CORP.YOURNAME-LAB.COM → dc01)
FQDN="dc01.${REALM,,}"   # lowercase the realm for the FQDN

# ─── Confirmation summary ─────────────────────────────────────────────────────
echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Review before creating:${RESET}"
echo ""
printf "  %-16s  %s\n" "CTID:"         "$CTID"
printf "  %-16s  %s\n" "Hostname:"     "dc01  (FQDN: ${FQDN})"
printf "  %-16s  %s\n" "Template:"     "$TEMPLATE"
printf "  %-16s  %s\n" "Storage:"      "$STORAGE"
printf "  %-16s  %s GB\n" "Disk:"      "$DISK_GB"
printf "  %-16s  %s MB\n" "Memory:"    "$MEMORY"
printf "  %-16s  %s\n" "Cores:"        "$CORES"
printf "  %-16s  %s  gw: %s\n" "Network:" "$CT_IP" "$CT_GW"
printf "  %-16s  %s\n" "Bridge:"       "vmbr2 (Internal)"
printf "  %-16s  %s\n" "AD Realm:"     "$REALM"
printf "  %-16s  %s\n" "NetBIOS:"      "$NETBIOS"
printf "  %-16s  %s\n" "Nameserver:"   "10.10.10.2 (Pi-hole, must be running)"
printf "  %-16s  %s\n" "Privileged:"   "yes (required for Samba AD DC)"
echo ""
echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
echo ""
read -r -p "Create this container? [y/N]: " CONFIRM
CONFIRM="${CONFIRM,,}"
[[ "$CONFIRM" == "y" || "$CONFIRM" == "yes" ]] \
    || { info "Aborted. No changes were made."; unset ADMINPASS; exit 0; }
echo ""

# ─── Create privileged LXC ────────────────────────────────────────────────────
# --unprivileged 0 (privileged) is required for Samba AD DC.
# Samba needs setuid, mknod, and sys_admin capabilities which are blocked in
# unprivileged containers by default. For production, restrict the container's
# network access to the Internal network only.
info "Creating Samba AD DC LXC (CTID: ${CTID}, privileged)..."
pct create "${CTID}" "${TEMPLATE}" \
    --hostname dc01 \
    --memory "${MEMORY}" \
    --cores "${CORES}" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=vmbr2,ip=${CT_IP},gw=${CT_GW}" \
    --nameserver 10.10.10.2 \
    --unprivileged 0 \
    --onboot 1
ok "LXC created."

info "Starting LXC..."
pct start "${CTID}"

info "Waiting for container to be ready (10 s)..."
sleep 10
ok "Container started."

# ─── Configure hostname and /etc/hosts ───────────────────────────────────────
CT_IP_CLEAN="${CT_IP%%/*}"
info "Configuring hostname and /etc/hosts..."
pct exec "${CTID}" -- bash -c "
  hostnamectl set-hostname ${FQDN}
  # /etc/hosts must map the DC's IP to its FQDN for Kerberos to function.
  if ! grep -q '${CT_IP_CLEAN}' /etc/hosts; then
    echo '${CT_IP_CLEAN}  ${FQDN}  dc01' >> /etc/hosts
  fi
"
ok "Hostname and /etc/hosts configured."

# ─── Install Samba and dependencies ──────────────────────────────────────────
info "Installing Samba and Kerberos packages (this may take a few minutes)..."
pct exec "${CTID}" -- bash -c "
  apt-get update -qq
  apt-get upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    samba samba-dsdb-modules samba-vfs-modules \
    winbind libpam-winbind libnss-winbind \
    krb5-config krb5-user \
    dnsutils acl attr
"
ok "Samba and dependencies installed."

# ─── Disable default Samba services ──────────────────────────────────────────
# The samba-ad-dc service manages everything. smbd/nmbd/winbind must not run
# alongside it when acting as an AD DC.
info "Disabling default Samba services (smbd, nmbd, winbind)..."
pct exec "${CTID}" -- bash -c "
  systemctl stop    smbd nmbd winbind 2>/dev/null || true
  systemctl disable smbd nmbd winbind 2>/dev/null || true
  systemctl mask    smbd nmbd winbind 2>/dev/null || true
"

# Back up the default smb.conf (samba-tool domain provision will regenerate it)
pct exec "${CTID}" -- bash -c "
  if [[ -f /etc/samba/smb.conf ]]; then
    mv /etc/samba/smb.conf \"/etc/samba/smb.conf.bak.\$(date +%Y%m%d%H%M%S)\"
  fi
"
ok "Default Samba services disabled."

# ─── Provision Samba AD domain ────────────────────────────────────────────────
info "Provisioning Samba AD domain..."
info "  Realm:   ${REALM}"
info "  NetBIOS: ${NETBIOS}"
info "  DNS:     SAMBA_INTERNAL"
echo ""

pct exec "${CTID}" -- bash -c "
  samba-tool domain provision \
    --use-rfc2307 \
    --realm='${REALM}' \
    --domain='${NETBIOS}' \
    --adminpass='${ADMINPASS}' \
    --dns-backend=SAMBA_INTERNAL \
    --server-role=dc
"
unset ADMINPASS
ok "Domain provisioned."

# ─── Configure Kerberos ──────────────────────────────────────────────────────
info "Configuring Kerberos (/etc/krb5.conf)..."
pct exec "${CTID}" -- bash -c "
  cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
"
ok "Kerberos configured."

# ─── Enable and start Samba AD DC service ────────────────────────────────────
info "Enabling and starting samba-ad-dc..."
pct exec "${CTID}" -- bash -c "
  systemctl unmask  samba-ad-dc
  systemctl enable  samba-ad-dc
  systemctl start   samba-ad-dc
"
ok "samba-ad-dc started."
echo ""

# ─── Verify domain ────────────────────────────────────────────────────────────
info "Verifying domain..."
pct exec "${CTID}" -- samba-tool domain info 127.0.0.1

echo ""
info "Verifying FSMO roles..."
pct exec "${CTID}" -- samba-tool fsmo show
echo ""

# ─── Result ───────────────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║           Samba AD DC provisioned successfully.          ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Domain:${RESET}"
printf "  %-14s  %s\n" "Realm:"     "$REALM"
printf "  %-14s  %s\n" "NetBIOS:"   "$NETBIOS"
printf "  %-14s  %s\n" "DC FQDN:"   "$FQDN"
printf "  %-14s  %s\n" "DC IP:"     "$CT_IP_CLEAN"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Add a test user to confirm AD is functional:"
echo "     pct exec ${CTID} -- samba-tool user create testuser 'Password123!'"
echo "     pct exec ${CTID} -- samba-tool user list"
echo ""
echo "  2. Configure Pi-hole to forward AD domain queries to this DC:"
echo "     pct exec 101 -- bash /opt/homelab/scripts/pihole/09-pihole-conditional-forward.sh \\"
echo "       ${REALM,,} ${CT_IP_CLEAN}"
echo ""
echo "  3. Test AD name resolution from the Internal network:"
echo "     dig dc01.${REALM,,} @10.10.10.2"
echo ""
