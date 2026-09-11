#!/bin/bash
# Script:      07-pihole-dns-records.sh
# Description: Adds local DNS A records for all Abricto HomeLab services to
#              Pi-hole's custom DNS list (/etc/pihole/custom.list).
#              Idempotent, skips records that already exist.
# Blog post:   https://abrictosecurity.com/homelab-series-domain-ssl-pihole-samba
# Usage:       bash 07-pihole-dns-records.sh <domain>
# Example:     bash 07-pihole-dns-records.sh yourname-lab.com
#              Or via Proxmox host: pct exec 101 -- bash /opt/homelab/scripts/pihole/07-pihole-dns-records.sh yourname-lab.com
# Dependencies: pihole (installed by 06-pihole-lxc.sh), dig (dnsutils)

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
[[ $EUID -ne 0 ]] && die "Must be run as root."

# ─── Argument validation ──────────────────────────────────────────────────────
DOMAIN="${1:?Usage: $0 <domain>  Example: $0 yourname-lab.com}"

# ─── Dependency checks ────────────────────────────────────────────────────────
command -v pihole &>/dev/null || die "pihole CLI not found. Run 06-pihole-lxc.sh first."
command -v dig    &>/dev/null || die "dig not found. Run: apt-get install -y dnsutils"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║        Abricto HomeLab, 07-pihole-dns-records.sh        ║${RESET}"
echo -e "${BOLD}║        Add local DNS A records to Pi-hole                ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Domain: ${BOLD}${DOMAIN}${RESET}"
echo ""

# ─── DNS record definitions ───────────────────────────────────────────────────
# Format: "hostname.domain IP"
# Keep this list in sync with docs/ip-allocation.md and the reference table in CLAUDE.md.
RECORDS=(
    "proxmox.${DOMAIN}           192.168.1.100"
    "edge.${DOMAIN}              10.10.10.1"
    "admin-internal.${DOMAIN}    10.10.10.10"
    "pihole.${DOMAIN}            10.10.10.2"
    "dc01.corp.${DOMAIN}         10.10.10.3"
)

CUSTOM_LIST="/etc/pihole/custom.list"

# ─── Backup custom.list ───────────────────────────────────────────────────────
if [[ -f "$CUSTOM_LIST" ]]; then
    BACKUP="${CUSTOM_LIST}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backing up ${CUSTOM_LIST} → ${BACKUP}"
    cp "$CUSTOM_LIST" "$BACKUP"
    ok "Backup created."
else
    info "${CUSTOM_LIST} does not exist, it will be created."
    touch "$CUSTOM_LIST"
fi
echo ""

# ─── Add records (idempotent) ─────────────────────────────────────────────────
info "Adding DNS records..."
echo ""
ADDED=0
SKIPPED=0

for record in "${RECORDS[@]}"; do
    # Read whitespace-separated: IP is last field, everything before is hostname
    hostname=$(echo "$record" | awk '{print $1}')
    ip=$(echo "$record" | awk '{print $2}')

    # Skip if this exact hostname→IP mapping already exists
    if grep -qP "^${ip}\s+${hostname}$" "$CUSTOM_LIST" 2>/dev/null; then
        printf "  ${YELLOW}SKIP${RESET}  %s → %s  (already present)\n" "$hostname" "$ip"
        (( SKIPPED++ )) || true
    else
        echo "${ip} ${hostname}" >> "$CUSTOM_LIST"
        printf "  ${GREEN}ADD${RESET}   %s → %s\n" "$hostname" "$ip"
        (( ADDED++ )) || true
    fi
done

echo ""
ok "Records processed: ${ADDED} added, ${SKIPPED} skipped."
echo ""

# ─── Reload Pi-hole DNS ───────────────────────────────────────────────────────
info "Reloading Pi-hole DNS..."
pihole restartdns reload
ok "Pi-hole DNS reloaded."
echo ""

# ─── Verify resolution ────────────────────────────────────────────────────────
info "Verifying DNS resolution via 127.0.0.1..."
echo ""
ALL_OK=true

for record in "${RECORDS[@]}"; do
    hostname=$(echo "$record" | awk '{print $1}')
    expected_ip=$(echo "$record" | awk '{print $2}')
    resolved=$(dig +short "$hostname" @127.0.0.1 2>/dev/null | head -1)

    if [[ "$resolved" == "$expected_ip" ]]; then
        printf "  ${GREEN}OK${RESET}    %-40s → %s\n" "$hostname" "$resolved"
    else
        printf "  ${RED}FAIL${RESET}  %-40s → '%s' (expected %s)\n" "$hostname" "$resolved" "$expected_ip"
        ALL_OK=false
    fi
done

echo ""

# ─── Result ───────────────────────────────────────────────────────────────────
if $ALL_OK; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║              All DNS records verified.                  ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
else
    warn "One or more records did not resolve as expected."
    warn "Check /etc/pihole/custom.list and run: pihole restartdns"
fi

echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Configure OPNsense DHCP to push 10.10.10.2 as the DNS server"
echo "     for all Internal (vmbr2) clients:"
echo "     OPNsense → Services → DHCPv4 → LAN → DNS servers → 10.10.10.2"
echo ""
echo "  2. Provision the Samba AD DC:"
echo "     sudo bash scripts/samba/08-samba-lxc.sh"
echo ""
echo "  3. After Samba is up, add conditional forwarding for the AD domain:"
echo "     pct exec 101 -- bash /opt/homelab/scripts/pihole/09-pihole-conditional-forward.sh corp.${DOMAIN} 10.10.10.3"
echo ""
