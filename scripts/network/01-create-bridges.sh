#!/bin/bash
# Script:      01-create-bridges.sh
# Description: Interactively creates vmbr1 (Edge/WAN), vmbr2 (Internal),
#              and vmbr3 (DMZ) on a Proxmox VE host. vmbr0 (management) is
#              created by the Proxmox installer and is never modified here.
# Blog post:   https://abrictosecurity.com/homelab-series-network-architecture
# Usage:       sudo bash 01-create-bridges.sh
# Dependencies: ifreload (ifupdown2 — default on Proxmox VE), brctl (bridge-utils)

set -euo pipefail

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

# ─── Dependency check ─────────────────────────────────────────────────────────
command -v ifreload &>/dev/null || die "ifreload not found. Is this a Proxmox VE host?"
command -v brctl    &>/dev/null || die "brctl not found. Run: apt install bridge-utils -y"

# ─── Constants ────────────────────────────────────────────────────────────────
IFACES_FILE="/etc/network/interfaces"
BACKUP="${IFACES_FILE}.bak.$(date +%Y%m%d%H%M%S)"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║        Abricto HomeLab — 01-create-bridges.sh           ║${RESET}"
echo -e "${BOLD}║  Creates vmbr1 (Edge/WAN), vmbr2 (Internal), vmbr3 (DMZ)║${RESET}"
echo -e "${BOLD}║  on Proxmox VE by appending to /etc/network/interfaces  ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
warn "This script modifies ${IFACES_FILE}."
warn "A timestamped backup is created before any changes are written."
echo ""

# ─── Detect management NIC ────────────────────────────────────────────────────
# Find the NIC currently carrying the management route.
# Fall back gracefully if route is not found (e.g. non-standard setups).
MGMT_NIC=""
MGMT_IP=""
if MGMT_NIC=$(ip route show default 2>/dev/null \
    | awk '/dev/ { for(i=1;i<=NF;i++) if($i=="dev") print $(i+1) }' \
    | head -1); then
    if [[ -n "$MGMT_NIC" ]]; then
        MGMT_IP=$(ip -4 addr show "$MGMT_NIC" 2>/dev/null \
            | awk '/inet / { print $2 }' | cut -d/ -f1 | head -1)
        info "Detected management NIC: ${BOLD}${MGMT_NIC}${RESET}  IP: ${BOLD}${MGMT_IP:-unknown}${RESET} (assigned to vmbr0 — will be excluded)"
    fi
fi
echo ""

# ─── List available physical interfaces ───────────────────────────────────────
# Uses 'ip -br link show' for clean, consistent output across kernel versions.
echo -e "${BOLD}Available network interfaces:${RESET}"
echo ""
printf "  %-18s %-10s %s\n" "INTERFACE" "STATE" "NOTE"
printf "  %-18s %-10s %s\n" "─────────────────" "─────────" "───────────────────────────────"

while read -r iface state _rest; do
    # Skip loopback and all virtual/bridge interfaces
    [[ "$iface" =~ ^(lo|vmbr|veth|tap|fwbr|fwpr|fwln|tun|docker|dummy|bond|team) ]] && continue
    [[ -z "$iface" ]] && continue

    note=""
    [[ "$iface" == "$MGMT_NIC" ]] && note="${YELLOW}← management NIC (vmbr0) — do not reassign${RESET}"

    printf "  ${CYAN}%-18s${RESET} %-10s %b\n" "$iface" "$state" "$note"
done < <(ip -br link show)
echo ""

# ─── Check for pre-existing bridge definitions ────────────────────────────────
for bridge in vmbr1 vmbr2 vmbr3; do
    if grep -q "^auto ${bridge}$" "$IFACES_FILE" 2>/dev/null; then
        die "${bridge} is already defined in ${IFACES_FILE}.\n       Remove or rename the existing stanza before running this script."
    fi
done

# ─── Interactive configuration ────────────────────────────────────────────────
echo -e "${BOLD}Bridge Configuration${RESET}"
echo "Enter the physical NIC name for each bridge."
echo "Press Enter to accept the default value shown in [brackets]."
echo ""

# ── vmbr1 — Edge / WAN ────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}vmbr1 — Edge (WAN)${RESET}"
echo "  Pure Layer 2 passthrough to your home router. OPNsense's WAN interface"
echo "  (vtnet0) attaches here. No IP is assigned on the Proxmox host."
echo ""
read -r -p "  Physical NIC for vmbr1 [eno2]: " NIC_WAN
NIC_WAN="${NIC_WAN:-eno2}"
echo ""

# ── vmbr2 — Internal LAN ──────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}vmbr2 — Internal (LAN)${RESET}"
echo "  Private lab network. Pi-hole, Samba DC, Kali VM, and all lab systems"
echo "  live here. OPNsense's LAN interface (vtnet1) is the gateway."
echo ""
read -r -p "  Physical NIC for vmbr2 [eno3]: " NIC_LAN
NIC_LAN="${NIC_LAN:-eno3}"
read -r -p "  Internal subnet (for reference comments only) [10.10.10.0/24]: " INTERNAL_SUBNET
INTERNAL_SUBNET="${INTERNAL_SUBNET:-10.10.10.0/24}"
echo ""

# ── vmbr3 — DMZ ───────────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}vmbr3 — DMZ${RESET}"
echo "  Isolated from Internal at the firewall level. Reserved for future"
echo "  internet-facing services. OPNsense's DMZ interface (vtnet2) is the gateway."
echo ""
read -r -p "  Physical NIC for vmbr3 [eno4]: " NIC_DMZ
NIC_DMZ="${NIC_DMZ:-eno4}"
read -r -p "  DMZ subnet (for reference comments only) [10.20.20.0/24]: " DMZ_SUBNET
DMZ_SUBNET="${DMZ_SUBNET:-10.20.20.0/24}"
echo ""

# ─── Derive gateway IPs from subnets ─────────────────────────────────────────
# Replaces the last octet and mask (e.g. .0/24) with .1 for the comment block.
INTERNAL_GW=$(echo "$INTERNAL_SUBNET" | sed 's/\.[0-9]*\/[0-9]*$/.1/')
DMZ_GW=$(echo "$DMZ_SUBNET"      | sed 's/\.[0-9]*\/[0-9]*$/.1/')

# ─── Validate NIC names ───────────────────────────────────────────────────────
for label_nic in "vmbr1:${NIC_WAN}" "vmbr2:${NIC_LAN}" "vmbr3:${NIC_DMZ}"; do
    label="${label_nic%%:*}"
    nic="${label_nic##*:}"

    ip link show "$nic" &>/dev/null \
        || die "Interface '${nic}' (assigned to ${label}) not found.\n       Run 'ip link show' to see available interfaces."

    [[ "$nic" == "$MGMT_NIC" ]] \
        && die "Interface '${nic}' is the management NIC (vmbr0).\n       Reassigning it will cut off access to the Proxmox host."
done

# Catch duplicate NIC assignments across bridges
declare -A seen_nics
for label_nic in "vmbr1:${NIC_WAN}" "vmbr2:${NIC_LAN}" "vmbr3:${NIC_DMZ}"; do
    label="${label_nic%%:*}"
    nic="${label_nic##*:}"
    if [[ -v seen_nics["$nic"] ]]; then
        die "NIC '${nic}' is assigned to both ${seen_nics[$nic]} and ${label}.\n       Each bridge must have its own dedicated physical interface."
    fi
    seen_nics["$nic"]="$label"
done

# ─── Confirmation summary ─────────────────────────────────────────────────────
echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Review before applying:${RESET}"
echo ""
printf "  ${CYAN}%-8s${RESET}  %-16s  NIC: ${BOLD}%-8s${RESET}  %s\n" \
    "vmbr1" "Edge (WAN)"     "$NIC_WAN" "no IP — L2 passthrough to home router"
printf "  ${CYAN}%-8s${RESET}  %-16s  NIC: ${BOLD}%-8s${RESET}  gateway: ${BOLD}%s${RESET}\n" \
    "vmbr2" "Internal (LAN)" "$NIC_LAN" "$INTERNAL_GW"
printf "  ${CYAN}%-8s${RESET}  %-16s  NIC: ${BOLD}%-8s${RESET}  gateway: ${BOLD}%s${RESET}\n" \
    "vmbr3" "DMZ"            "$NIC_DMZ" "$DMZ_GW"
echo ""
echo -e "  Backup path:  ${BOLD}${BACKUP}${RESET}"
echo -e "  Apply with:   ${BOLD}ifreload -a${RESET}"
echo ""
echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
echo ""
read -r -p "Apply this configuration? [y/N]: " CONFIRM
CONFIRM="${CONFIRM,,}"
[[ "$CONFIRM" == "y" || "$CONFIRM" == "yes" ]] \
    || { info "Aborted. No changes were made."; exit 0; }
echo ""

# ─── Backup /etc/network/interfaces ──────────────────────────────────────────
info "Backing up ${IFACES_FILE} → ${BACKUP}"
cp "$IFACES_FILE" "$BACKUP"
ok "Backup created."

# ─── Write bridge stanzas ─────────────────────────────────────────────────────
info "Appending bridge definitions to ${IFACES_FILE} ..."

cat >> "$IFACES_FILE" << EOF

# ── HomeLab Series: bridges added by 01-create-bridges.sh on $(date +%Y-%m-%d) ──

# vmbr1 — Edge (WAN)
# OPNsense WAN interface (vtnet0) attaches here.
# Pure L2 passthrough — no IP assigned on the Proxmox host.
auto vmbr1
iface vmbr1 inet manual
        bridge-ports ${NIC_WAN}
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware no

# vmbr2 — Internal LAN (${INTERNAL_SUBNET})
# OPNsense LAN interface (vtnet1) attaches here — gateway: ${INTERNAL_GW}
auto vmbr2
iface vmbr2 inet manual
        bridge-ports ${NIC_LAN}
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware no

# vmbr3 — DMZ (${DMZ_SUBNET})
# OPNsense DMZ interface (vtnet2) attaches here — gateway: ${DMZ_GW}
auto vmbr3
iface vmbr3 inet manual
        bridge-ports ${NIC_DMZ}
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware no
EOF

ok "Bridge definitions written."

# ─── Apply configuration ──────────────────────────────────────────────────────
info "Applying with ifreload -a (management interface vmbr0 is not affected) ..."
ifreload -a
ok "Network configuration applied."

# ─── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Bridge state (brctl show):${RESET}"
brctl show
echo ""

echo -e "${BOLD}New bridge interfaces:${RESET}"
all_ok=true
for bridge in vmbr1 vmbr2 vmbr3; do
    state=$(ip -br link show "$bridge" 2>/dev/null | awk '{print $2}' || echo "NOT FOUND")
    if [[ "$state" == "UP" || "$state" == "UNKNOWN" ]]; then
        printf "  ${GREEN}%-8s${RESET}  %s\n" "$bridge" "$state"
    else
        printf "  ${RED}%-8s${RESET}  %s\n" "$bridge" "$state"
        all_ok=false
    fi
done
echo ""

# ─── Result ───────────────────────────────────────────────────────────────────
if $all_ok; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║   All bridges created successfully.                     ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
else
    warn "One or more bridges did not come up cleanly."
    warn "Check 'journalctl -xe' and 'ip link show' for details."
    warn "To revert: cp ${BACKUP} ${IFACES_FILE} && ifreload -a"
fi

echo ""
echo -e "${BOLD}Backup saved at:${RESET}"
echo "  ${BACKUP}"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Verify Proxmox web UI is still accessible at https://${MGMT_IP:-<management-ip>}:8006"
echo "     (vmbr0 was not modified — management access is unchanged)"
echo ""
echo "  2. Download the OPNsense installer ISO:"
echo "     cd /var/lib/vz/template/iso/"
echo "     wget -O opnsense.iso <URL from https://opnsense.org/download/>"
echo ""
echo "  3. Run the next script:"
echo "     bash scripts/network/02-create-opnsense-vm.sh"
echo ""
