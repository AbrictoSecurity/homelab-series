#!/bin/bash
# Script: 12-kali-network.sh
# Description: Configure dual-homed static addressing and source-based policy routing on the Kali VM
# Blog post: https://abrictosecurity.com/homelab-series-docker-kali-dvwa/
# Usage: sudo bash 12-kali-network.sh [INTERNAL_IF] [DMZ_IF]
# Dependencies: NetworkManager (nmcli), shipped with Kali prebuilt images

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# Series reference values. See the IP table in Post 2.
INTERNAL_ADDR="10.10.10.20/24"
INTERNAL_GW="10.10.10.1"
INTERNAL_DNS="10.10.10.2"

# The series uses yourname-lab.com as a stand-in. Override it for a real lab:
#   LAB_DOMAIN=example.com sudo bash 12-kali-network.sh
LAB_DOMAIN="${LAB_DOMAIN:-yourname-lab.com}"
INTERNAL_SEARCH="${INTERNAL_SEARCH:-corp.${LAB_DOMAIN}}"

DMZ_ADDR="10.20.20.20/24"
DMZ_GW="10.20.20.1"
DMZ_NET="10.20.20.0/24"
DMZ_TABLE="100"

CON_INTERNAL="internal"
CON_DMZ="dmz"

STAMP="$(date +%Y%m%d-%H%M%S)"

[[ $EUID -ne 0 ]] && die "Must be run as root inside the Kali VM. Try: sudo bash $0"
command -v nmcli &>/dev/null || die "nmcli not found. This script targets Kali's NetworkManager setup."
systemctl is-active --quiet NetworkManager || die "NetworkManager is not running"

echo ""
echo -e "${BOLD}Abricto HomeLab - Kali Dual-Homed Network Configuration${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Step 0: get off the default credentials before touching anything else.
# ---------------------------------------------------------------------------

TARGET_USER="${SUDO_USER:-kali}"
if id "$TARGET_USER" &>/dev/null; then
    # Kali prebuilt images ship with a documented default password for the
    # 'kali' account. There is no portable way to test a password hash from
    # a script (Debian now defaults to yescrypt, which openssl passwd cannot
    # generate, and Python dropped the crypt module in 3.13), so prompt rather
    # than guess. The account is about to get a routable address on two
    # networks, which is the wrong moment to still be on a public default.
    echo ""
    warn "Kali prebuilt images ship with the documented default password 'kali'."
    warn "This VM is about to get static addresses on the Internal and DMZ networks."
    echo ""
    read -rp "  Set a new password for '$TARGET_USER' now? [Y/n]: " DO_PASSWD
    if [[ "${DO_PASSWD,,}" != "n" && "${DO_PASSWD,,}" != "no" ]]; then
        until passwd "$TARGET_USER"; do
            warn "Password unchanged. Try again, or press Ctrl+C to abort."
        done
        ok "Password for '$TARGET_USER' updated"
    else
        warn "Skipped. Change it before this VM can reach anything: passwd $TARGET_USER"
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Step 1: identify the two Ethernet devices.
#
# Device names depend on the machine type Proxmox used, so detect rather than
# assume. Order follows the PCI enumeration, which matches net0 then net1.
# ---------------------------------------------------------------------------

if [[ $# -ge 2 ]]; then
    IF_INTERNAL="$1"
    IF_DMZ="$2"
    info "Using interfaces from arguments"
else
    mapfile -t ETH_DEVS < <(nmcli -t -f DEVICE,TYPE device status \
        | awk -F: '$2=="ethernet" {print $1}' | sort)
    if [[ ${#ETH_DEVS[@]} -lt 2 ]]; then
        echo ""
        nmcli device status
        echo ""
        die "Expected 2 ethernet devices, found ${#ETH_DEVS[@]}.
       Confirm the VM has both NICs in Proxmox (net0 on vmbr2, net1 on vmbr3),
       or pass them explicitly: sudo bash $0 INTERNAL_IF DMZ_IF"
    fi
    IF_INTERNAL="${ETH_DEVS[0]}"
    IF_DMZ="${ETH_DEVS[1]}"
fi

ip link show "$IF_INTERNAL" &>/dev/null || die "Interface $IF_INTERNAL not found"
ip link show "$IF_DMZ" &>/dev/null || die "Interface $IF_DMZ not found"

echo -e "${BOLD}Interface assignment:${RESET}"
printf "  %-12s %-10s %s\n" "$IF_INTERNAL" "Internal" "$INTERNAL_ADDR  (default route, DNS)"
printf "  %-12s %-10s %s\n" "$IF_DMZ" "DMZ" "$DMZ_ADDR  (RDP only, policy routed)"
echo ""
warn "If these are backwards, abort and re-run with the correct order:"
warn "  sudo bash $0 $IF_DMZ $IF_INTERNAL"
echo ""
read -rp "  Apply this configuration? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || { info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Step 2: back up the existing connection profiles before changing anything.
# ---------------------------------------------------------------------------

BACKUP_DIR="/root/nm-backup-${STAMP}"
mkdir -p "$BACKUP_DIR"
if compgen -G "/etc/NetworkManager/system-connections/*" > /dev/null; then
    cp -a /etc/NetworkManager/system-connections/. "$BACKUP_DIR"/
    ok "Existing NetworkManager profiles backed up to $BACKUP_DIR"
else
    info "No existing NetworkManager profiles to back up"
fi

# Remove any prior run of this script so it is idempotent.
for con in "$CON_INTERNAL" "$CON_DMZ"; do
    if nmcli -t -f NAME connection show | grep -qx "$con"; then
        info "Removing previous '$con' profile"
        nmcli connection delete "$con" >/dev/null 2>&1 || true
    fi
done

# ---------------------------------------------------------------------------
# Step 3: Internal interface. This one owns the default route and DNS.
# ---------------------------------------------------------------------------

echo ""
info "Configuring $IF_INTERNAL as Internal"
nmcli connection add \
    type ethernet \
    con-name "$CON_INTERNAL" \
    ifname "$IF_INTERNAL" \
    ipv4.method manual \
    ipv4.addresses "$INTERNAL_ADDR" \
    ipv4.gateway "$INTERNAL_GW" \
    ipv4.dns "$INTERNAL_DNS" \
    ipv4.dns-search "$INTERNAL_SEARCH" \
    ipv6.method disabled \
    connection.autoconnect yes >/dev/null \
    || die "Failed to create the Internal connection profile"
ok "Internal profile created"

# ---------------------------------------------------------------------------
# Step 4: DMZ interface.
#
# This is the part that people get wrong. A second interface with its own
# gateway gives the host two default routes. Linux picks one by metric and
# ignores the other, so replies to RDP traffic that arrived on the DMZ NIC
# leave via the Internal NIC instead. OPNsense sees a 10.20.20.20 source
# address arriving on its Internal interface, treats it as spoofed, and drops
# it. The RDP session hangs and the cause is not obvious.
#
# The fix is source-based policy routing:
#   - no ipv4.gateway on this profile, plus never-default, so it contributes
#     no default route to the main table
#   - a private table (100) holding BOTH the on-link DMZ subnet route and the
#     DMZ default route
#   - a rule saying "traffic sourced from 10.20.20.20 uses table 100"
#
# Table 100 must carry the subnet route, not just the default. Once a policy
# rule diverts a lookup to table 100, the main table is never consulted for
# that packet, so an identical on-link route sitting in main does not help.
# Omit it and traffic from 10.20.20.20 to another DMZ host is sent to the
# gateway instead of to the neighbour directly:
#
#   ip route get 10.20.20.30 from 10.20.20.20
#     -> via 10.20.20.1 dev eth1 table 100      (wrong, goes to the firewall)
#
# The firewall will not hairpin it back onto the segment it arrived from, so
# the connection simply times out while ARP still works, which makes it look
# like a host problem rather than a routing one. With the subnet route present:
#
#   ip route get 10.20.20.30 from 10.20.20.20
#     -> dev eth1 table 100                     (correct, direct on-link)
#
# Replies to inbound traffic then leave the same interface they arrived on, the
# main routing table keeps exactly one default route via the Internal gateway,
# and DMZ-local hosts stay directly reachable.
# ---------------------------------------------------------------------------

echo ""
info "Configuring $IF_DMZ as DMZ with source-based policy routing"
nmcli connection add \
    type ethernet \
    con-name "$CON_DMZ" \
    ifname "$IF_DMZ" \
    ipv4.method manual \
    ipv4.addresses "$DMZ_ADDR" \
    ipv4.never-default yes \
    ipv4.ignore-auto-dns yes \
    ipv4.routes "${DMZ_NET} 0.0.0.0 table=${DMZ_TABLE}, 0.0.0.0/0 ${DMZ_GW} table=${DMZ_TABLE}" \
    ipv4.routing-rules "priority 100 from ${DMZ_ADDR%%/*}/32 table ${DMZ_TABLE}" \
    ipv6.method disabled \
    connection.autoconnect yes >/dev/null \
    || die "Failed to create the DMZ connection profile"
ok "DMZ profile created with policy routing"

# ---------------------------------------------------------------------------
# Step 5: bring both up.
# ---------------------------------------------------------------------------

echo ""
info "Activating connections"
nmcli connection up "$CON_INTERNAL" >/dev/null || die "Failed to activate $CON_INTERNAL"
nmcli connection up "$CON_DMZ" >/dev/null || die "Failed to activate $CON_DMZ"
sleep 3
ok "Both interfaces active"

# ---------------------------------------------------------------------------
# Step 6: guest agent, so Proxmox can report the guest IPs and shut down cleanly.
# ---------------------------------------------------------------------------

echo ""
if ! dpkg-query -W -f='${Status}' qemu-guest-agent 2>/dev/null | grep -q "ok installed"; then
    info "Installing qemu-guest-agent"
    if apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq qemu-guest-agent >/dev/null 2>&1; then
        ok "qemu-guest-agent installed"
    else
        warn "Could not install qemu-guest-agent. Install it later: apt install -y qemu-guest-agent"
    fi
fi
systemctl enable --now qemu-guest-agent >/dev/null 2>&1 \
    && ok "qemu-guest-agent running" \
    || warn "qemu-guest-agent not running, non-fatal"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}Addressing${RESET}"
ip -4 -brief addr show "$IF_INTERNAL"
ip -4 -brief addr show "$IF_DMZ"

echo ""
echo -e "${BOLD}Main routing table${RESET}"
ip route show

echo ""
echo -e "${BOLD}Policy rules${RESET}"
ip rule show

echo ""
echo -e "${BOLD}DMZ routing table (${DMZ_TABLE})${RESET}"
ip route show table "$DMZ_TABLE" 2>/dev/null || warn "Table $DMZ_TABLE is empty"

echo ""
DEFAULT_COUNT=$(ip route show default | wc -l)
if [[ "$DEFAULT_COUNT" -eq 1 ]]; then
    ok "Exactly one default route in the main table, which is correct"
else
    warn "Found $DEFAULT_COUNT default routes in the main table. Expected 1."
    warn "Dual-homed routing will behave unpredictably until this is resolved."
fi

echo ""
info "Testing gateway reachability"

# Check L2 first. A firewall will commonly answer ARP while dropping ICMP on a
# DMZ interface, so a failed ping proves nothing on its own. arping asks the
# question that actually matters: is the gateway on this segment at all.
gw_reachable() {
    local ifname="$1" gw="$2"
    if command -v arping &>/dev/null && arping -c 2 -w 3 -I "$ifname" "$gw" &>/dev/null; then
        return 0
    fi
    ping -c 2 -W 2 -I "$ifname" "$gw" &>/dev/null
}

gw_reachable "$IF_INTERNAL" "$INTERNAL_GW" \
    && ok "Internal gateway $INTERNAL_GW reachable" \
    || warn "Internal gateway $INTERNAL_GW unreachable, check the OPNsense Internal interface"

if gw_reachable "$IF_DMZ" "$DMZ_GW"; then
    ok "DMZ gateway $DMZ_GW reachable"
else
    warn "DMZ gateway $DMZ_GW did not answer ARP or ICMP."
    warn "Check that the OPNsense DMZ interface is assigned and enabled."
fi

info "Testing DNS through Pi-hole"
if command -v dig &>/dev/null; then
    dig +short +timeout=3 "@${INTERNAL_DNS}" pihole."${INTERNAL_SEARCH#corp.}" >/dev/null 2>&1 \
        && ok "Pi-hole at $INTERNAL_DNS is answering" \
        || warn "Pi-hole at $INTERNAL_DNS did not answer, check Post 3"
else
    warn "dig not installed, skipping DNS test. Install: apt install -y dnsutils"
fi

echo ""
ok "Dual-homed networking configured"
echo ""
echo -e "${BOLD}Result${RESET}"
printf "  %-22s %s\n" "Internal ($IF_INTERNAL):" "${INTERNAL_ADDR}  via ${INTERNAL_GW}, default route"
printf "  %-22s %s\n" "DMZ ($IF_DMZ):" "${DMZ_ADDR}  via ${DMZ_GW}, table ${DMZ_TABLE} only"
printf "  %-22s %s\n" "DNS:" "$INTERNAL_DNS (Pi-hole)"
echo ""
echo -e "${BOLD}Rollback${RESET}"
echo "  nmcli connection delete $CON_INTERNAL $CON_DMZ"
echo "  cp -a $BACKUP_DIR/. /etc/NetworkManager/system-connections/"
echo "  systemctl restart NetworkManager"
echo ""
echo -e "${BOLD}Next step${RESET}"
echo "  sudo bash 13-kali-rdp.sh"
echo ""
