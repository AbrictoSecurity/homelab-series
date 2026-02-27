#!/bin/bash
# Script:      03-opnsense-configure.sh
# Description: Two-phase script run on the Proxmox host.
#              Phase 0: Creates a Debian 12 LXC on vmbr2 (Internal) as the
#                        permanent internal admin machine for web GUI access.
#              Phase 1: Configures OPNsense post-install via the REST API:
#                        enables and names the DMZ (OPT1) interface, then
#                        creates three baseline firewall rules:
#                          Allow Internal (LAN) → WAN
#                          Block  Internal (LAN) → DMZ
#                          Block  DMZ → Internal (LAN)
# Blog post:   https://abrictosecurity.com/homelab-series-network-architecture
# Usage:       bash 03-opnsense-configure.sh <api_key> <api_secret>
# Run from:    Proxmox host (root), requires pct and curl
# Dependencies: pct (Proxmox LXC), pveam (template manager), curl
#
# SECURITY NOTE: API credentials are passed as command-line arguments.
# On a shared system, arguments are visible in process listings (ps aux).
# On a single-user homelab host this is acceptable. To prevent the
# credentials from being written to ~/.bash_history, run:
#   unset HISTFILE && bash 03-opnsense-configure.sh <key> <secret>

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
command -v curl  &>/dev/null || die "curl not found. Install with: apt install curl -y"
command -v pct   &>/dev/null || die "pct not found. Is this a Proxmox VE host?"
command -v pveam &>/dev/null || die "pveam not found. Is this a Proxmox VE host?"

# ─── Prerequisite: Internal bridge must exist ─────────────────────────────────
ip link show vmbr2 &>/dev/null \
    || die "vmbr2 not found. Run 01-create-bridges.sh first."

# ─── Credential arguments ─────────────────────────────────────────────────────
# Generate in OPNsense: System → Access → Users → admin → API Keys → +
API_KEY="${1:?Usage: bash $0 <api_key> <api_secret>}"
API_SECRET="${2:?Usage: bash $0 <api_key> <api_secret>}"
AUTH="${API_KEY}:${API_SECRET}"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║      Abricto HomeLab, 03-opnsense-configure.sh          ║${RESET}"
echo -e "${BOLD}║   Phase 0: Create internal admin LXC on vmbr2            ║${RESET}"
echo -e "${BOLD}║   Phase 1: Configure DMZ interface + firewall rules      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
warn "SSL certificate verification is skipped (-k) because OPNsense"
warn "uses a self-signed certificate until Let's Encrypt is configured."
warn "This is addressed in Post 3 of the HomeLab Series."
echo ""

# ─── Shared network configuration prompts ─────────────────────────────────────
echo -e "${BOLD}Network Configuration${RESET}"
echo ""

read -r -p "  OPNsense LAN IP [10.10.10.1]: " OPNSENSE_IP
OPNSENSE_IP="${OPNSENSE_IP:-10.10.10.1}"

read -r -p "  Internal subnet [10.10.10.0/24]: " LAN_SUBNET
LAN_SUBNET="${LAN_SUBNET:-10.10.10.0/24}"

read -r -p "  DMZ subnet [10.20.20.0/24]: " DMZ_SUBNET
DMZ_SUBNET="${DMZ_SUBNET:-10.20.20.0/24}"

# Derive subnet mask and a host-side temp IP (.254) for the Proxmox bridge
LAN_MASK=$(echo "$LAN_SUBNET" | cut -d/ -f2)
HOST_BRIDGE_IP="${OPNSENSE_IP%.*}.254"

BASE_URL="https://${OPNSENSE_IP}/api"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 0, Internal admin LXC
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║             Phase 0: Internal Admin LXC                 ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo "  A lightweight Debian 12 LXC on vmbr2 gives you a persistent machine"
echo "  on the Internal network to access the OPNsense web GUI and run"
echo "  future scripts from inside the lab."
echo ""
read -r -p "  Create internal admin LXC now? [Y/n]: " CREATE_LXC
CREATE_LXC="${CREATE_LXC:-y}"
CREATE_LXC="${CREATE_LXC,,}"

LXC_CTID=""

if [[ "$CREATE_LXC" == "y" || "$CREATE_LXC" == "yes" ]]; then

    echo ""

    # ── LXC configuration prompts ──────────────────────────────────────────────
    while true; do
        read -r -p "  Container ID [110]: " LXC_CTID
        LXC_CTID="${LXC_CTID:-110}"
        [[ "$LXC_CTID" =~ ^[0-9]+$ ]] || { warn "CT ID must be a number."; continue; }
        if pct status "$LXC_CTID" &>/dev/null; then
            warn "CT ID ${LXC_CTID} already exists. Choose a different ID."
            continue
        fi
        break
    done

    read -r -p "  Hostname [admin-internal]: " LXC_HOSTNAME
    LXC_HOSTNAME="${LXC_HOSTNAME:-admin-internal}"

    read -r -p "  Static IP for LXC [10.10.10.10]: " LXC_IP
    LXC_IP="${LXC_IP:-10.10.10.10}"

    # ── Storage pool ──────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Available storage pools:${RESET}"
    echo ""
    printf "    %-4s  %-20s  %-12s  %s\n" "NUM" "NAME" "TYPE" "AVAILABLE"
    printf "    %-4s  %-20s  %-12s  %s\n" "───" "───────────────────" "───────────" "─────────"

    mapfile -t lxc_storage_lines < <(pvesm status 2>/dev/null | awk 'NR>1 { print $1, $2, $3, $5 }')
    lxc_storage_names=()

    for line in "${lxc_storage_lines[@]}"; do
        read -r sname stype sstatus savail <<< "$line"
        stype_lower="${stype,,}"
        [[ "$stype_lower" =~ ^(dir|lvm|lvmthin|zfspool|rbd|cephfs|nfs|cifs|btrfs|glusterfs|iscsi|iscsidirect|zfs) ]] || continue
        [[ "$sstatus" == "active" ]] || continue
        lxc_storage_names+=("$sname")
        idx=${#lxc_storage_names[@]}
        printf "    ${CYAN}%-4s${RESET}  %-20s  %-12s  %s\n" \
            "$idx" "$sname" "$stype" "${savail:-n/a}"
    done
    echo ""

    if [[ ${#lxc_storage_names[@]} -eq 0 ]]; then
        die "No active storage pools found. Run 'pvesm status' to diagnose."
    fi

    if [[ ${#lxc_storage_names[@]} -eq 1 ]]; then
        LXC_STORAGE="${lxc_storage_names[0]}"
        info "Auto-selected storage: ${BOLD}${LXC_STORAGE}${RESET}"
    else
        lxc_default_storage_idx=1
        for i in "${!lxc_storage_names[@]}"; do
            [[ "${lxc_storage_names[$i]}" == "local-lvm" ]] && { lxc_default_storage_idx=$((i+1)); break; }
        done
        while true; do
            read -r -p "  Select storage number [${lxc_default_storage_idx}]: " lxc_storage_choice
            lxc_storage_choice="${lxc_storage_choice:-${lxc_default_storage_idx}}"
            if [[ "$lxc_storage_choice" =~ ^[0-9]+$ ]] \
                && (( lxc_storage_choice >= 1 && lxc_storage_choice <= ${#lxc_storage_names[@]} )); then
                LXC_STORAGE="${lxc_storage_names[$((lxc_storage_choice-1))]}"
                break
            fi
            warn "Invalid selection. Enter a number between 1 and ${#lxc_storage_names[@]}."
        done
    fi
    echo ""

    read -r -p "  Memory in GB [2]: " LXC_MEM
    LXC_MEM="${LXC_MEM:-2}"
    [[ "$LXC_MEM" =~ ^[0-9]+$ ]] || die "Memory must be a number in GB."

    read -r -p "  CPU cores [2]: " LXC_CORES
    LXC_CORES="${LXC_CORES:-2}"
    [[ "$LXC_CORES" =~ ^[0-9]+$ ]] || die "CPU cores must be a number."

    read -r -p "  Disk size in GB [8]: " LXC_DISK_GB
    LXC_DISK_GB="${LXC_DISK_GB:-8}"
    [[ "$LXC_DISK_GB" =~ ^[0-9]+$ ]] || die "Disk size must be a number in GB."
    echo ""

    read -r -s -p "  Root password for LXC: " LXC_PASS
    echo ""
    read -r -s -p "  Confirm password: " LXC_PASS2
    echo ""
    [[ "$LXC_PASS" == "$LXC_PASS2" ]] || die "Passwords do not match."
    [[ -n "$LXC_PASS" ]]              || die "Password cannot be empty."
    echo ""

    # ── Template discovery ────────────────────────────────────────────────────
    info "Searching for Debian 12 template ..."

    TEMPLATE_PATH=$(find /var/lib/vz/template/cache/ \
        -maxdepth 1 -name "debian-12-standard*.tar.*" 2>/dev/null \
        | sort -V | tail -1)

    if [[ -z "$TEMPLATE_PATH" ]]; then
        info "No Debian 12 template found locally. Fetching template list ..."
        pveam update &>/dev/null

        TEMPLATE_NAME=$(pveam available --section system 2>/dev/null \
            | awk '{print $2}' \
            | grep "^debian-12-standard" \
            | sort -V | tail -1)

        [[ -n "$TEMPLATE_NAME" ]] \
            || die "No Debian 12 template available. Check internet connectivity on the host."

        info "Downloading ${TEMPLATE_NAME} ..."
        pveam download local "$TEMPLATE_NAME"

        TEMPLATE_PATH=$(find /var/lib/vz/template/cache/ \
            -maxdepth 1 -name "debian-12-standard*.tar.*" 2>/dev/null \
            | sort -V | tail -1)
    fi

    TEMPLATE_REF="local:vztmpl/$(basename "$TEMPLATE_PATH")"
    ok "Template: $(basename "$TEMPLATE_PATH")"
    echo ""

    # ── Confirmation ──────────────────────────────────────────────────────────
    echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD}LXC Summary:${RESET}"
    echo ""
    printf "  %-18s  %s\n" "Container ID:"  "$LXC_CTID"
    printf "  %-18s  %s\n" "Hostname:"      "$LXC_HOSTNAME"
    printf "  %-18s  %s\n" "IP:"            "${LXC_IP}/${LAN_MASK}"
    printf "  %-18s  %s\n" "Gateway:"       "$OPNSENSE_IP"
    printf "  %-18s  %s\n" "Bridge:"        "vmbr2 (Internal)"
    printf "  %-18s  %s\n" "Storage:"       "${LXC_STORAGE}:${LXC_DISK_GB}G"
    printf "  %-18s  %s\n" "Memory:"        "${LXC_MEM} GB  ($((LXC_MEM * 1024)) MB)"
    printf "  %-18s  %s\n" "CPU cores:"     "$LXC_CORES"
    printf "  %-18s  %s\n" "Template:"      "$(basename "$TEMPLATE_PATH")"
    echo ""
    echo -e "${BOLD}──────────────────────────────────────────────────────────${RESET}"
    echo ""
    read -r -p "  Create this LXC? [y/N]: " CONFIRM_LXC
    CONFIRM_LXC="${CONFIRM_LXC,,}"
    [[ "$CONFIRM_LXC" == "y" || "$CONFIRM_LXC" == "yes" ]] \
        || { info "LXC creation skipped."; LXC_CTID=""; }

    if [[ -n "$LXC_CTID" ]]; then
        info "Creating LXC ${LXC_CTID} (${LXC_HOSTNAME}) ..."

        pct create "$LXC_CTID" "$TEMPLATE_REF" \
            --hostname    "$LXC_HOSTNAME" \
            --memory      "$((LXC_MEM * 1024))" \
            --cores       "$LXC_CORES" \
            --rootfs      "${LXC_STORAGE}:${LXC_DISK_GB}" \
            --net0        "name=eth0,bridge=vmbr2,ip=${LXC_IP}/${LAN_MASK},gw=${OPNSENSE_IP}" \
            --nameserver  "$OPNSENSE_IP" \
            --password    "$LXC_PASS" \
            --unprivileged 1 \
            --onboot      1
        ok "LXC created."

        info "Starting LXC ${LXC_CTID} ..."
        pct start "$LXC_CTID"

        # Wait for network to initialise inside the container
        info "Waiting for LXC network to come up ..."
        for i in {1..15}; do
            if pct exec "$LXC_CTID" -- ping -c1 -W1 "$OPNSENSE_IP" &>/dev/null; then
                ok "LXC can reach OPNsense at ${OPNSENSE_IP}."
                break
            fi
            [[ $i -eq 15 ]] \
                && warn "LXC network not confirmed after 15s, continuing anyway. Check with: pct exec ${LXC_CTID} -- ping ${OPNSENSE_IP}"
            sleep 1
        done
        echo ""
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1, OPNsense API configuration
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         Phase 1: OPNsense API Configuration             ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Temporarily add host IP to vmbr2 so the host can reach OPNsense ──────────
# The Proxmox host is the bridge (vmbr2) but has no IP on the Internal network.
# We add a temporary .254 address so curl can reach 10.10.10.1 for API calls.
# A trap removes it on exit regardless of success or failure.
BRIDGE_IP_ADDED=false

cleanup_bridge_ip() {
    if $BRIDGE_IP_ADDED; then
        ip addr del "${HOST_BRIDGE_IP}/${LAN_MASK}" dev vmbr2 2>/dev/null || true
        info "Removed temporary host IP ${HOST_BRIDGE_IP} from vmbr2."
    fi
}
trap cleanup_bridge_ip EXIT

if ! ip addr show vmbr2 | grep -q "${HOST_BRIDGE_IP}"; then
    info "Adding temporary host IP ${HOST_BRIDGE_IP}/${LAN_MASK} to vmbr2 for API access ..."
    ip addr add "${HOST_BRIDGE_IP}/${LAN_MASK}" dev vmbr2
    BRIDGE_IP_ADDED=true
    ok "Host IP added. Will be removed automatically on script exit."
else
    info "Host IP ${HOST_BRIDGE_IP} already present on vmbr2, skipping."
fi
echo ""

# ─── Helper: API call with response check ─────────────────────────────────────
api_call() {
    local method="$1"
    local endpoint="$2"
    local body="${3:-}"
    local response

    if [[ -n "$body" ]]; then
        response=$(curl -sk -u "$AUTH" -X "$method" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "${BASE_URL}${endpoint}" 2>&1) || die "curl failed on ${endpoint}"
    else
        response=$(curl -sk -u "$AUTH" -X "$method" \
            "${BASE_URL}${endpoint}" 2>&1) || die "curl failed on ${endpoint}"
    fi

    [[ -z "$response" ]] \
        && die "Empty response from ${endpoint}, is OPNsense running and the API enabled?\n       OPNsense: System → Settings → Administration → Enable API"
    echo "$response"
}

# ─── Step 1: API connectivity check ──────────────────────────────────────────
info "Testing API connectivity to ${OPNSENSE_IP} ..."

response=$(api_call GET "/core/firmware/status")

if echo "$response" | grep -q '"product_name"'; then
    version=$(echo "$response" | grep -o '"product_version":"[^"]*"' | cut -d'"' -f4)
    ok "Connected to OPNsense ${version}"
elif echo "$response" | grep -qi "unauthorized\|403\|401"; then
    die "Authentication failed. Verify the API key and secret.\n       OPNsense: System → Access → Users → admin → API Keys"
else
    die "Unexpected API response. Is OPNsense running at ${OPNSENSE_IP}?\n       Response: ${response}"
fi
echo ""

# ─── Step 2: Enable and name the DMZ interface (OPT1 / vtnet2) ───────────────
echo -e "${BOLD}Step 1 of 3, Configure DMZ interface${RESET}"
echo ""
info "Enabling OPT1 and setting description to 'DMZ' ..."

response=$(api_call POST "/interfaces/overview/setInterfaceIdentifier" \
    '{"identifier": "opt1", "description": "DMZ"}')

if echo "$response" | grep -qi '"result"\s*:\s*"saved"\|"status"\s*:\s*"ok"'; then
    ok "DMZ interface configured."
else
    warn "Unexpected response, verify OPT1 in OPNsense: Interfaces → Assignments."
    warn "Response: ${response}"
fi

info "Applying interface changes ..."
api_call POST "/interfaces/overview/reconfigure" > /dev/null
ok "Interface changes applied."
echo ""

# ─── Step 3: Firewall rules ───────────────────────────────────────────────────
echo -e "${BOLD}Step 2 of 3, Baseline firewall rules${RESET}"
echo ""
echo "  Rules to be created:"
echo ""
printf "  ${GREEN}%-8s${RESET}  %-10s  %-22s  %-22s  %s\n" \
    "ACTION" "INTERFACE" "SOURCE" "DESTINATION" "DESCRIPTION"
printf "  %-8s  %-10s  %-22s  %-22s  %s\n" \
    "────────" "──────────" "──────────────────────" "──────────────────────" "────────────────────────"
printf "  ${GREEN}%-8s${RESET}  %-10s  %-22s  %-22s  %s\n" \
    "PASS"  "LAN in"  "$LAN_SUBNET" "any"          "Allow Internal to WAN"
printf "  ${RED}%-8s${RESET}  %-10s  %-22s  %-22s  %s\n" \
    "BLOCK" "LAN in"  "$LAN_SUBNET" "$DMZ_SUBNET"  "Block Internal to DMZ"
printf "  ${RED}%-8s${RESET}  %-10s  %-22s  %-22s  %s\n" \
    "BLOCK" "OPT1 in" "$DMZ_SUBNET" "$LAN_SUBNET"  "Block DMZ to Internal"
echo ""

read -r -p "  Create these rules? [y/N]: " CONFIRM
CONFIRM="${CONFIRM,,}"
[[ "$CONFIRM" == "y" || "$CONFIRM" == "yes" ]] \
    || { info "Aborted. No rules were created."; exit 0; }
echo ""

# ── Rule 1: Allow LAN → WAN ───────────────────────────────────────────────────
info "Creating rule: Allow Internal → WAN ..."
response=$(api_call POST "/firewall/filter/addRule" \
    "{
        \"rule\": {
            \"enabled\":         \"1\",
            \"action\":          \"pass\",
            \"interface\":       \"lan\",
            \"direction\":       \"in\",
            \"ipprotocol\":      \"inet\",
            \"protocol\":        \"any\",
            \"source_net\":      \"${LAN_SUBNET}\",
            \"source_not\":      \"0\",
            \"destination_net\": \"any\",
            \"destination_not\": \"0\",
            \"log\":             \"1\",
            \"description\":     \"HomeLab: Allow Internal to WAN\"
        }
    }")
if echo "$response" | grep -q '"uuid"'; then
    rule1_uuid=$(echo "$response" | grep -o '"uuid":"[^"]*"' | cut -d'"' -f4)
    ok "Rule created (uuid: ${rule1_uuid})"
else
    warn "Unexpected response: ${response}"
fi

# ── Rule 2: Block LAN → DMZ ───────────────────────────────────────────────────
info "Creating rule: Block Internal → DMZ ..."
response=$(api_call POST "/firewall/filter/addRule" \
    "{
        \"rule\": {
            \"enabled\":         \"1\",
            \"action\":          \"block\",
            \"interface\":       \"lan\",
            \"direction\":       \"in\",
            \"ipprotocol\":      \"inet\",
            \"protocol\":        \"any\",
            \"source_net\":      \"${LAN_SUBNET}\",
            \"source_not\":      \"0\",
            \"destination_net\": \"${DMZ_SUBNET}\",
            \"destination_not\": \"0\",
            \"log\":             \"1\",
            \"description\":     \"HomeLab: Block Internal to DMZ\"
        }
    }")
if echo "$response" | grep -q '"uuid"'; then
    rule2_uuid=$(echo "$response" | grep -o '"uuid":"[^"]*"' | cut -d'"' -f4)
    ok "Rule created (uuid: ${rule2_uuid})"
else
    warn "Unexpected response: ${response}"
fi

# ── Rule 3: Block DMZ → LAN ───────────────────────────────────────────────────
info "Creating rule: Block DMZ → Internal ..."
response=$(api_call POST "/firewall/filter/addRule" \
    "{
        \"rule\": {
            \"enabled\":         \"1\",
            \"action\":          \"block\",
            \"interface\":       \"opt1\",
            \"direction\":       \"in\",
            \"ipprotocol\":      \"inet\",
            \"protocol\":        \"any\",
            \"source_net\":      \"${DMZ_SUBNET}\",
            \"source_not\":      \"0\",
            \"destination_net\": \"${LAN_SUBNET}\",
            \"destination_not\": \"0\",
            \"log\":             \"1\",
            \"description\":     \"HomeLab: Block DMZ to Internal\"
        }
    }")
if echo "$response" | grep -q '"uuid"'; then
    rule3_uuid=$(echo "$response" | grep -o '"uuid":"[^"]*"' | cut -d'"' -f4)
    ok "Rule created (uuid: ${rule3_uuid})"
else
    warn "Unexpected response: ${response}"
fi
echo ""

# ─── Step 4: Apply firewall changes ───────────────────────────────────────────
echo -e "${BOLD}Step 3 of 3, Apply changes${RESET}"
echo ""
info "Applying firewall rules ..."
api_call POST "/firewall/filter/apply" > /dev/null
ok "Firewall rules applied."
echo ""

# ─── Verify ───────────────────────────────────────────────────────────────────
info "Fetching applied rule count ..."
response=$(api_call GET "/firewall/filter/searchRule")
rule_count=$(echo "$response" | grep -o '"total":[0-9]*' | grep -o '[0-9]*' || echo "unknown")
ok "OPNsense reports ${rule_count} total firewall rule(s) active."
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Result
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║             Phase 0 + Phase 1 complete.                  ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

if [[ -n "$LXC_CTID" ]]; then
    echo -e "${BOLD}Internal admin LXC:${RESET}"
    echo "  CT ID:     ${LXC_CTID}  (${LXC_HOSTNAME})"
    echo "  IP:        ${LXC_IP}/${LAN_MASK}  on vmbr2"
    echo "  Access:    pct enter ${LXC_CTID}     (console from Proxmox host)"
    echo "             ssh root@${LXC_IP}        (SSH from Internal network)"
    echo ""
    echo -e "${BOLD}Accessing the OPNsense web GUI from your laptop:${RESET}"
    echo ""
    echo "  Option 1, SSH tunnel (recommended):"
    echo "    Run on your laptop:"
    echo "      ssh -L 8443:${OPNSENSE_IP}:443 root@<proxmox-mgmt-ip> -N"
    echo "    Then open: https://localhost:8443"
    echo ""
    echo "  Option 2, from inside the LXC:"
    echo "    pct enter ${LXC_CTID}"
    echo "    curl -sk https://${OPNSENSE_IP} | grep -i opnsense"
    echo ""
fi

echo -e "${BOLD}Verify in the OPNsense web UI (https://${OPNSENSE_IP}):${RESET}"
echo ""
echo "  Interfaces → Assignments   OPT1 shows as 'DMZ' and is enabled"
echo "  Firewall → Rules → LAN     Allow Internal to WAN  (pass)"
echo "                             Block Internal to DMZ  (block)"
echo "  Firewall → Rules → DMZ     Block DMZ to Internal  (block)"
echo ""
echo -e "${BOLD}Post 2 connectivity verification:${RESET}"
echo "  From the admin LXC (pct enter ${LXC_CTID:-<ctid>}):"
echo "    ping -c3 ${OPNSENSE_IP}   → should succeed  (OPNsense LAN)"
echo "    ping -c3 1.1.1.1          → should succeed  (internet via OPNsense)"
echo "    ping -c3 10.20.20.1       → should fail     (DMZ blocked)"
echo ""
echo -e "${BOLD}Next:${RESET}"
echo "  Post 3, Domain → Cloudflare DNS → Let's Encrypt wildcard SSL"
echo "  Repository: https://github.com/Cab00se-AS/homelab-series"
echo ""
