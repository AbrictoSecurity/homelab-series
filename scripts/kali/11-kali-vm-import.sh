#!/bin/bash
# Script: 11-kali-vm-import.sh
# Description: Verify and import Kali's official prebuilt QEMU image as a dual-homed Proxmox VM
# Blog post: https://abrictosecurity.com/homelab-series-docker-kali-dvwa/
# Usage: bash 11-kali-vm-import.sh
# Dependencies: curl, gpg, sha256sum, 7z (p7zip-full or 7zip), qm (Proxmox VE)

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# Kali Linux official signing key. Primary key fingerprint, no spaces.
# Cross-check at https://www.kali.org/docs/introduction/download-official-kali-linux-images/
KALI_FPR="827C8569F2518CC677FECA1AED65462EC8D5E4C5"
KALI_KEY_URL="https://archive.kali.org/archive-key.asc"
KALI_BASE="https://cdimage.kali.org/current"

WORK_DIR="/var/lib/vz/template/kali"
MIN_FREE_GB=45

CLEANUP_PATHS=()
cleanup() {
    for p in "${CLEANUP_PATHS[@]:-}"; do
        [[ -n "${p:-}" && -d "$p" ]] && rm -rf "$p"
    done
}
trap cleanup EXIT

[[ $EUID -ne 0 ]] && die "Must be run as root on the Proxmox host. Try: sudo bash $0"
command -v qm &>/dev/null || die "qm not found. Is this a Proxmox VE host?"
command -v curl &>/dev/null || die "curl not found. Install it: apt install -y curl"
command -v gpg &>/dev/null || die "gpg not found. Install it: apt install -y gnupg"

# Debian 12 ships 7z via p7zip-full, Debian 13 via the 7zip package as 7zz.
SEVENZIP=""
for candidate in 7z 7zz 7za; do
    if command -v "$candidate" &>/dev/null; then SEVENZIP="$candidate"; break; fi
done
[[ -z "$SEVENZIP" ]] && die "No 7-Zip binary found. Install it: apt install -y p7zip-full"

echo ""
echo -e "${BOLD}Abricto HomeLab - Kali Linux VM Import${RESET}"
echo -e "${BOLD}Dual-homed: vmbr2 (Internal) + vmbr3 (DMZ)${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------

read -rp "  VMID [200]: " VMID
VMID="${VMID:-200}"
[[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be a number"
qm status "$VMID" &>/dev/null && die "VMID $VMID already exists. Choose another or destroy it first."

read -rp "  VM name [kali]: " VMNAME
VMNAME="${VMNAME:-kali}"

read -rp "  CPU cores [4]: " CORES
CORES="${CORES:-4}"
[[ "$CORES" =~ ^[0-9]+$ ]] || die "Cores must be a number"

read -rp "  Memory in MB [8192]: " RAM
RAM="${RAM:-8192}"
[[ "$RAM" =~ ^[0-9]+$ ]] || die "Memory must be a number"

read -rp "  Internal bridge [vmbr2]: " BR_INTERNAL
BR_INTERNAL="${BR_INTERNAL:-vmbr2}"
ip link show "$BR_INTERNAL" &>/dev/null || die "Bridge $BR_INTERNAL not found. Complete Post 2 first."

read -rp "  DMZ bridge [vmbr3]: " BR_DMZ
BR_DMZ="${BR_DMZ:-vmbr3}"
ip link show "$BR_DMZ" &>/dev/null || die "Bridge $BR_DMZ not found. Complete Post 2 first."

# Storage discovery, images content type (VM disks), not rootdir.
info "Discovering storage pools that accept VM disks"
STORAGE_NAMES=()
while IFS= read -r sname; do
    [[ -n "$sname" ]] && STORAGE_NAMES+=("$sname")
done < <(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')

[[ ${#STORAGE_NAMES[@]} -eq 0 ]] && die "No active storage pools with 'images' content found"

echo ""
printf "  %-4s  %-20s  %-10s  %-14s\n" "NUM" "NAME" "TYPE" "AVAILABLE"
printf "  %-4s  %-20s  %-10s  %-14s\n" "---" "--------------------" "----------" "--------------"
idx=1
for storage in "${STORAGE_NAMES[@]}"; do
    stype=$(pvesm status 2>/dev/null | awk -v s="$storage" '$1==s {print $2}')
    # pvesm status columns: Name Type Status Total Used Available %
    savail=$(pvesm status 2>/dev/null | awk -v s="$storage" '$1==s {print $6}')
    printf "  %-4d  %-20s  %-10s  %-14s\n" "$idx" "$storage" "$stype" "${savail:-n/a}"
    ((idx++))
done
echo ""

storage_choice=1
if [[ ${#STORAGE_NAMES[@]} -gt 1 ]]; then
    read -rp "  Select storage number [1]: " storage_choice
    storage_choice="${storage_choice:-1}"
fi
[[ "$storage_choice" =~ ^[0-9]+$ ]] || die "Invalid selection"
# Validate before decrementing. Under set -e, ((x--)) on a value of 1 yields
# status 1 and would abort the script instead of reaching the error message.
[[ "$storage_choice" -ge 1 && "$storage_choice" -le ${#STORAGE_NAMES[@]} ]] \
    || die "Invalid storage selection: choose 1 to ${#STORAGE_NAMES[@]}"
STORAGE="${STORAGE_NAMES[$((storage_choice - 1))]}"

mkdir -p "$WORK_DIR"
FREE_GB=$(df -BG --output=avail "$WORK_DIR" | tail -1 | tr -dc '0-9')
if [[ "${FREE_GB:-0}" -lt "$MIN_FREE_GB" ]]; then
    warn "Only ${FREE_GB}GB free at $WORK_DIR. The archive plus the extracted"
    warn "qcow2 need roughly ${MIN_FREE_GB}GB during import."
    read -rp "  Continue anyway? [y/N]: " CONT
    [[ "${CONT,,}" == "y" ]] || die "Aborted. Free up space or change WORK_DIR."
fi

# ---------------------------------------------------------------------------
# Resolve the current Kali QEMU image, do not hardcode a release
# ---------------------------------------------------------------------------

info "Resolving the current Kali QEMU image"
ARCHIVE=$(curl -fsSL "${KALI_BASE}/" \
    | grep -oE 'kali-linux-[0-9.]+-qemu-amd64\.7z' \
    | sort -u | head -1)
[[ -n "$ARCHIVE" ]] || die "Could not determine the current Kali QEMU image name from ${KALI_BASE}/"
ok "Current image: $ARCHIVE"

echo ""
echo -e "${BOLD}Configuration Summary:${RESET}"
printf "  %-20s  %s\n" "VMID:" "$VMID"
printf "  %-20s  %s\n" "Name:" "$VMNAME"
printf "  %-20s  %s MB, %s cores\n" "Resources:" "$RAM" "$CORES"
printf "  %-20s  %s\n" "Storage:" "$STORAGE"
printf "  %-20s  %s (Internal)\n" "net0:" "$BR_INTERNAL"
printf "  %-20s  %s (DMZ)\n" "net1:" "$BR_DMZ"
printf "  %-20s  %s\n" "Image:" "$ARCHIVE"
printf "  %-20s  %s\n" "Work dir:" "$WORK_DIR"
echo ""
read -rp "  Create this VM? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || { info "Aborted."; exit 0; }

cd "$WORK_DIR"

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

echo ""
info "Downloading checksum files"
curl -fsSL -o SHA256SUMS     "${KALI_BASE}/SHA256SUMS"     || die "Failed to download SHA256SUMS"
curl -fsSL -o SHA256SUMS.gpg "${KALI_BASE}/SHA256SUMS.gpg" || die "Failed to download SHA256SUMS.gpg"
ok "Checksum files downloaded"

info "Downloading $ARCHIVE (this is several GB, resumable)"
curl -fL -C - -o "$ARCHIVE" "${KALI_BASE}/${ARCHIVE}" || die "Failed to download $ARCHIVE"
ok "Image downloaded"

# ---------------------------------------------------------------------------
# Verify the signature on the checksum file, then the checksum on the image.
# Order matters. An unsigned checksum file proves nothing.
# ---------------------------------------------------------------------------

echo ""
info "Verifying the GPG signature on SHA256SUMS"

GNUPGHOME_TMP="$(mktemp -d)"
CLEANUP_PATHS+=("$GNUPGHOME_TMP")
chmod 700 "$GNUPGHOME_TMP"
export GNUPGHOME="$GNUPGHOME_TMP"

curl -fsSL "$KALI_KEY_URL" | gpg --quiet --import 2>/dev/null \
    || die "Failed to import the Kali signing key from $KALI_KEY_URL"

GPG_STATUS="$(gpg --status-fd 1 --verify SHA256SUMS.gpg SHA256SUMS 2>/dev/null || true)"

VALIDSIG_LINE="$(echo "$GPG_STATUS" | grep '^\[GNUPG:\] VALIDSIG ' || true)"
[[ -n "$VALIDSIG_LINE" ]] || {
    echo "$GPG_STATUS" >&2
    die "SHA256SUMS carries no valid signature. Do not use this download."
}

# VALIDSIG's last field is the primary key fingerprint, which is what we pin.
# The signature itself may come from a subkey, so never compare field 3.
PRIMARY_FPR="$(echo "$VALIDSIG_LINE" | awk '{print $NF}')"
if [[ "$PRIMARY_FPR" != "$KALI_FPR" ]]; then
    die "SHA256SUMS signed by an unexpected key.
       Expected: $KALI_FPR
       Got:      $PRIMARY_FPR
       Do not use this download."
fi
ok "Good signature from the Kali Linux signing key ($KALI_FPR)"

echo ""
info "Verifying the image against the signed checksum"
grep " ${ARCHIVE}\$" SHA256SUMS > "${ARCHIVE}.sha256" \
    || die "$ARCHIVE has no entry in SHA256SUMS"
[[ -s "${ARCHIVE}.sha256" ]] || die "Empty checksum line for $ARCHIVE"
sha256sum -c "${ARCHIVE}.sha256" || die "Checksum mismatch. Delete $ARCHIVE and re-download."
ok "Image checksum verified"

# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------

echo ""
EXTRACT_DIR="${WORK_DIR}/extract-$$"
CLEANUP_PATHS+=("$EXTRACT_DIR")
mkdir -p "$EXTRACT_DIR"

info "Extracting the archive"
"$SEVENZIP" x -y -o"$EXTRACT_DIR" "$ARCHIVE" >/dev/null || die "Extraction failed"

# Glob rather than assume a filename. Kali's layout changes between releases.
QCOW=""
while IFS= read -r found; do QCOW="$found"; break; done < <(find "$EXTRACT_DIR" -name '*.qcow2' -type f 2>/dev/null)
[[ -n "$QCOW" ]] || die "No .qcow2 found in the extracted archive"
ok "Found disk image: $(basename "$QCOW")"

# ---------------------------------------------------------------------------
# Create the VM shell
#
# Two deliberate choices here, both specific to this image:
#
#   virtio0, not scsi0  - Kali's prebuilt QEMU image is built for virtio-blk.
#                         Its initramfs may not carry virtio_scsi, so attaching
#                         to scsi0 can drop you at an initramfs prompt.
#   SeaBIOS, not OVMF   - the image is MBR-partitioned. OVMF will not boot it.
# ---------------------------------------------------------------------------

echo ""
info "Creating VM $VMID"
qm create "$VMID" \
    --name "$VMNAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --cpu host \
    --ostype l26 \
    --net0 "virtio,bridge=${BR_INTERNAL}" \
    --net1 "virtio,bridge=${BR_DMZ}" \
    --agent enabled=1 \
    --onboot 0 \
    || die "qm create failed"
ok "VM shell created"

info "Importing the disk into $STORAGE (this takes a few minutes)"
# 'qm disk import' is the current form; 'qm importdisk' is the older alias.
if qm help disk import &>/dev/null; then
    qm disk import "$VMID" "$QCOW" "$STORAGE" || die "Disk import failed"
else
    qm importdisk "$VMID" "$QCOW" "$STORAGE" || die "Disk import failed"
fi

# Read the volume back from the config rather than guessing its name.
# Naming differs per storage type: vm-200-disk-0 on LVM-thin,
# 200/vm-200-disk-0.qcow2 on directory storage.
DISKREF="$(qm config "$VMID" | sed -n 's/^unused0: //p' | head -1)"
[[ -n "$DISKREF" ]] || die "Could not locate the imported disk in the VM config"
ok "Imported as $DISKREF"

info "Attaching the disk and setting boot order"
qm set "$VMID" --virtio0 "$DISKREF" >/dev/null || die "Failed to attach virtio0"
qm set "$VMID" --boot order=virtio0 >/dev/null || die "Failed to set boot order"
ok "Disk attached as virtio0"

echo ""
read -rp "  Grow the disk? Enter extra GB or press Enter to skip: " GROW_GB
if [[ -n "$GROW_GB" ]]; then
    if [[ "$GROW_GB" =~ ^[0-9]+$ ]] && [[ "$GROW_GB" -gt 0 ]]; then
        info "Growing virtio0 by ${GROW_GB}G"
        qm resize "$VMID" virtio0 "+${GROW_GB}G" || warn "Resize failed, continuing"
        ok "Disk grown. Extend the filesystem inside Kali afterwards."
    else
        warn "Not a positive integer, skipping resize"
    fi
fi

echo ""
info "Starting VM $VMID"
qm start "$VMID" || die "Failed to start VM $VMID"
ok "VM started"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
ok "Kali VM $VMID is up"
echo ""
echo -e "${BOLD}Default credentials (Kali prebuilt images):${RESET}"
echo "  Username: kali"
echo "  Password: kali"
echo ""
warn "These are public, documented defaults. Every Kali prebuilt image on the"
warn "internet ships with them. Change the password at first login."
warn "12-kali-network.sh will force this before it configures anything."
echo ""
echo -e "${BOLD}Network interfaces (unconfigured, DHCP by default):${RESET}"
printf "  %-10s %-8s %s\n" "net0" "$BR_INTERNAL" "Internal, will become 10.10.10.20/24"
printf "  %-10s %-8s %s\n" "net1" "$BR_DMZ" "DMZ, will become 10.20.20.20/24"
echo ""
echo -e "${BOLD}Next steps${RESET}"
echo "  1. Open the console:  Proxmox web UI -> VM $VMID -> Console"
echo "  2. Log in as kali/kali"
echo "  3. Copy 12-kali-network.sh into the VM and run it:"
echo "       sudo bash 12-kali-network.sh"
echo "  4. Then 13-kali-rdp.sh, then 14-kali-verify.sh"
echo ""
echo -e "${BOLD}Housekeeping${RESET}"
echo "  The verified archive is kept at ${WORK_DIR}/${ARCHIVE}"
echo "  Delete it once the VM is confirmed working:"
echo "       rm -f ${WORK_DIR}/${ARCHIVE} ${WORK_DIR}/${ARCHIVE}.sha256"
echo ""
