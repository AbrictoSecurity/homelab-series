#!/bin/bash
# Script:      02-create-opnsense-vm.sh
# Description: Interactively creates the OPNsense edge firewall VM on Proxmox VE
#              using the qm CLI. Discovers available ISOs and storage pools
#              from the host — nothing is hardcoded.
# Blog post:   https://abrictosecurity.com/homelab-series-network-architecture
# Usage:       sudo bash 02-create-opnsense-vm.sh
# Dependencies: Proxmox VE (qm, pvesm), OPNsense ISO in /var/lib/vz/template/iso/

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

# ─── Dependency check ─────────────────────────────────────────────────────────
command -v qm    &>/dev/null || die "qm not found. Is this a Proxmox VE host?"
command -v pvesm &>/dev/null || die "pvesm not found. Is this a Proxmox VE host?"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║      Abricto HomeLab — 02-create-opnsense-vm.sh         ║${RESET}"
echo -e "${BOLD}║  Creates the OPNsense edge firewall VM via Proxmox qm   ║${RESET}"
echo -e "${BOLD}║  WAN → vmbr1   Internal → vmbr2   DMZ → vmbr3          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ─── Prerequisite: bridges must exist ─────────────────────────────────────────
info "Checking prerequisites..."
missing_bridges=()
for bridge in vmbr1 vmbr2 vmbr3; do
    ip link show "$bridge" &>/dev/null || missing_bridges+=("$bridge")
done

if [[ ${#missing_bridges[@]} -gt 0 ]]; then
    die "Missing bridge(s): ${missing_bridges[*]}\n       Run 01-create-bridges.sh first."
fi
ok "Bridges vmbr1, vmbr2, vmbr3 are present."
echo ""

# ─── ISO discovery ────────────────────────────────────────────────────────────
ISO_DIR="/var/lib/vz/template/iso"
echo -e "${BOLD}Available ISOs in ${ISO_DIR}:${RESET}"
echo ""

mapfile -t iso_files < <(find "$ISO_DIR" -maxdepth 1 -name "*.iso" 2>/dev/null | sort)

if [[ ${#iso_files[@]} -eq 0 ]]; then
    echo -e "  ${YELLOW}No ISO files found in ${ISO_DIR}.${RESET}"
    echo ""
    echo "  Download OPNsense CE (amd64, dvd) from https://opnsense.org/download/"
    echo "  then run:"
    echo ""
    echo "    cd ${ISO_DIR}"
    echo "    wget -O opnsense.iso.bz2 <URL>"
    echo "    bunzip2 opnsense.iso.bz2"
    echo ""
    die "No ISO available. Add an ISO to ${ISO_DIR} and re-run this script."
fi

printf "  %-4s  %-40s  %s\n" "NUM" "FILENAME" "SIZE"
printf "  %-4s  %-40s  %s\n" "───" "───────────────────────────────────────" "────────"
for i in "${!iso_files[@]}"; do
    fname=$(basename "${iso_files[$i]}")
    fsize=$(du -sh "${iso_files[$i]}" 2>/dev/null | cut -f1)
    printf "  ${CYAN}%-4s${RESET}  %-40s  %s\n" "$((i+1))" "$fname" "$fsize"
done
echo ""

# Prompt for ISO selection
if [[ ${#iso_files[@]} -eq 1 ]]; then
    ISO_PATH="${iso_files[0]}"
    ISO_NAME=$(basename "$ISO_PATH")
    info "Auto-selected: ${BOLD}${ISO_NAME}${RESET}"
else
    while true; do
        read -r -p "  Select ISO number [1]: " iso_choice
        iso_choice="${iso_choice:-1}"
        if [[ "$iso_choice" =~ ^[0-9]+$ ]] \
            && (( iso_choice >= 1 && iso_choice <= ${#iso_files[@]} )); then
            ISO_PATH="${iso_files[$((iso_choice-1))]}"
            ISO_NAME=$(basename "$ISO_PATH")
            break
        fi
        warn "Invalid selection. Enter a number between 1 and ${#iso_files[@]}."
    done
fi

# Build the pvesm reference path: storage:iso/filename
ISO_REF="local:iso/${ISO_NAME}"
echo ""

# ─── Storage pool discovery ───────────────────────────────────────────────────
echo -e "${BOLD}Available storage pools (for VM disk):${RESET}"
echo ""
printf "  %-20s  %-12s  %-10s  %s\n" "NAME" "TYPE" "STATUS" "AVAILABLE"
printf "  %-20s  %-12s  %-10s  %s\n" "───────────────────" "───────────" "─────────" "─────────"

mapfile -t storage_lines < <(pvesm status 2>/dev/null | awk 'NR>1 { print $1, $2, $3, $5 }')

for line in "${storage_lines[@]}"; do
    read -r sname stype sstatus savail <<< "$line"
    # Only show storage that can hold VM images (exclude iso/backup-only stores)
    stype_lower="${stype,,}"
    [[ "$stype_lower" =~ ^(dir|lvm|lvmthin|zfspool|rbd|cephfs|nfs|cifs|btrfs|glusterfs|iscsi|iscsidirect|zfs) ]] || continue
    [[ "$sstatus" == "active" ]] || continue

    status_col="${GREEN}active${RESET}"
    printf "  ${CYAN}%-20s${RESET}  %-12s  %b  %s\n" \
        "$sname" "$stype" "$status_col" "${savail:-n/a}"
done
echo ""

# ─── Interactive configuration ────────────────────────────────────────────────
echo -e "${BOLD}VM Configuration${RESET}"
echo "Press Enter to accept the default value shown in [brackets]."
echo ""

# ── VM ID ─────────────────────────────────────────────────────────────────────
while true; do
    read -r -p "  VM ID [100]: " VMID
    VMID="${VMID:-100}"
    [[ "$VMID" =~ ^[0-9]+$ ]] || { warn "VM ID must be a number."; continue; }
    if qm status "$VMID" &>/dev/null; then
        warn "VM ID ${VMID} already exists ($(qm status "$VMID" | awk '{print $2}'))."
        read -r -p "  Choose a different VM ID: " VMID
        continue
    fi
    break
done
echo ""

# ── VM name ───────────────────────────────────────────────────────────────────
read -r -p "  VM name [opnsense-edge]: " VM_NAME
VM_NAME="${VM_NAME:-opnsense-edge}"
echo ""

# ── Memory ────────────────────────────────────────────────────────────────────
read -r -p "  Memory in MB [2048]: " VM_MEM
VM_MEM="${VM_MEM:-2048}"
[[ "$VM_MEM" =~ ^[0-9]+$ ]] || die "Memory must be a number in MB."
echo ""

# ── CPU cores ─────────────────────────────────────────────────────────────────
read -r -p "  CPU cores [2]: " VM_CORES
VM_CORES="${VM_CORES:-2}"
[[ "$VM_CORES" =~ ^[0-9]+$ ]] || die "CPU cores must be a number."
echo ""

# ── Storage pool ──────────────────────────────────────────────────────────────
read -r -p "  Storage pool for VM disk [local-lvm]: " VM_STORAGE
VM_STORAGE="${VM_STORAGE:-local-lvm}"

# Validate the selected storage exists and is active
if ! pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^${VM_STORAGE}$"; then
    die "Storage pool '${VM_STORAGE}' not found or not active.\n       Run 'pvesm status' to see available pools."
fi
echo ""

# ── Disk size ─────────────────────────────────────────────────────────────────
read -r -p "  Disk size in GB [16]: " VM_DISK_GB
VM_DISK_GB="${VM_DISK_GB:-16}"
[[ "$VM_DISK_GB" =~ ^[0-9]+$ ]] || die "Disk size must be a number in GB."
echo ""

# ─── Confirmation summary ─────────────────────────────────────────────────────
echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Review before applying:${RESET}"
echo ""
printf "  %-18s  %s\n" "VM ID:"        "$VMID"
printf "  %-18s  %s\n" "Name:"         "$VM_NAME"
printf "  %-18s  %s\n" "Memory:"       "${VM_MEM} MB"
printf "  %-18s  %s\n" "CPU cores:"    "$VM_CORES"
printf "  %-18s  %s\n" "CPU type:"      "host"
printf "  %-18s  %s\n" "OS type:"       "other (FreeBSD/HardenedBSD)"
printf "  %-18s  %s\n" "Disk:"          "${VM_STORAGE}:${VM_DISK_GB}G  (virtio-scsi)"
printf "  %-18s  %s\n" "ISO:"           "$ISO_NAME"
printf "  %-18s  %s\n" "Serial:"        "socket  (enables qm terminal after install)"
printf "  %-18s  %s\n" "VGA:"           "std  (noVNC via web UI — use for installation)"
printf "  %-18s  %s\n" "Boot:"          "scsi0 (disk) → ide2 (CDROM fallback)"
printf "  %-18s  %s\n" "Start on boot:" "yes"
echo ""
printf "  ${CYAN}%-18s${RESET}  %s\n" "net0 (vtnet0):" "virtio → vmbr1  [WAN]"
printf "  ${CYAN}%-18s${RESET}  %s\n" "net1 (vtnet1):" "virtio → vmbr2  [Internal]"
printf "  ${CYAN}%-18s${RESET}  %s\n" "net2 (vtnet2):" "virtio → vmbr3  [DMZ]"
echo ""
echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
echo ""
read -r -p "Create this VM? [y/N]: " CONFIRM
CONFIRM="${CONFIRM,,}"
[[ "$CONFIRM" == "y" || "$CONFIRM" == "yes" ]] \
    || { info "Aborted. No VM was created."; exit 0; }
echo ""

# ─── Create VM ────────────────────────────────────────────────────────────────
info "Creating VM ${VMID} (${VM_NAME}) ..."

qm create "$VMID" \
    --name        "$VM_NAME" \
    --memory      "$VM_MEM" \
    --cores       "$VM_CORES" \
    --cpu         host \
    --ostype      other \
    --scsihw      virtio-scsi-pci \
    --serial0     socket \
    --vga         std \
    --cdrom       "${ISO_REF}" \
    --boot        "order=scsi0;ide2" \
    --net0        "virtio,bridge=vmbr1,firewall=0" \
    --net1        "virtio,bridge=vmbr2,firewall=0" \
    --net2        "virtio,bridge=vmbr3,firewall=0" \
    --onboot      1

ok "VM created."

# ─── Add disk ─────────────────────────────────────────────────────────────────
info "Adding ${VM_DISK_GB}G disk on ${VM_STORAGE} ..."
qm set "$VMID" --scsi0 "${VM_STORAGE}:${VM_DISK_GB}"
ok "Disk added."

# ─── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}VM list (qm list):${RESET}"
qm list | awk 'NR==1 || $1=='"$VMID"
echo ""

echo -e "${BOLD}VM config (qm config ${VMID}):${RESET}"
qm config "$VMID"
echo ""

# ─── Result ───────────────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   VM ${VMID} created successfully.                        ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo ""
echo "  1. Start the VM:"
echo "       qm start ${VMID}"
echo ""
echo "  2. Open the console to run the OPNsense installer:"
echo "       Proxmox web UI → VM ${VMID} → Console  (noVNC)"
echo "       Do NOT use 'qm terminal' during installation — use the web UI console."
echo "       After OPNsense is installed it outputs to serial, so"
echo "       'qm terminal ${VMID}' will work for ongoing administration."
echo ""
echo "  3. Complete the OPNsense installer:"
echo "       - Select 'Auto (UFS)' when prompted for the partition method"
echo "       - NOTE: If Auto (UFS) fails with a partition error, the disk has no"
echo "         partition table. Fix: choose 'Manual', select the disk, create a GPT,"
echo "         write it, then go back and select 'Auto (UFS)' — it will succeed."
echo "       - Set a root password when prompted"
echo "       - Reboot when prompted"
echo ""
echo "  4. After reboot — assign interfaces at the console prompt:"
echo "       WAN  → vtnet0   (connected to vmbr1)"
echo "       LAN  → vtnet1   (connected to vmbr2)"
echo "       OPT1 → vtnet2   (connected to vmbr3 — DMZ)"
echo ""
echo "  5. Set the LAN IP at the console:"
echo "       10.10.10.1/24   (no DHCP server — Pi-hole handles DHCP later)"
echo ""
echo "  6. Remove the ISO after install (boot order already favours the disk — no"
echo "     separate boot order change needed):"
echo "       qm set ${VMID} --cdrom none"
echo ""
echo "  7. Run the next script (after OPNsense is installed and running):"
echo "       bash scripts/network/03-opnsense-configure.sh <api_key> <api_secret>"
echo ""
