#!/bin/bash
# Script:      09-pihole-conditional-forward.sh
# Description: Configures Pi-hole to forward all DNS queries for the Samba AD
#              domain to the Samba DC via a dnsmasq drop-in configuration file.
#              All other queries continue to upstream resolvers (Cloudflare 1.1.1.1).
# Blog post:   https://abrictosecurity.com/homelab-series-domain-ssl-pihole-samba
# Usage:       bash 09-pihole-conditional-forward.sh <ad_domain> <samba_dc_ip>
# Example:     bash 09-pihole-conditional-forward.sh corp.yourname-lab.com 10.10.10.3
#              Or via Proxmox host: pct exec 101 -- bash /opt/homelab/scripts/pihole/09-pihole-conditional-forward.sh corp.yourname-lab.com 10.10.10.3
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
AD_DOMAIN="${1:?Usage: $0 <ad_domain> <samba_dc_ip>  Example: $0 corp.yourname-lab.com 10.10.10.3}"
DC_IP="${2:?Usage: $0 <ad_domain> <samba_dc_ip>}"

# ─── Dependency checks ────────────────────────────────────────────────────────
command -v pihole &>/dev/null || die "pihole CLI not found. Run 06-pihole-lxc.sh first."
command -v dig    &>/dev/null || die "dig not found. Run: apt-get install -y dnsutils"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     Abricto HomeLab, 09-pihole-conditional-forward.sh   ║${RESET}"
echo -e "${BOLD}║     Wire Pi-hole conditional forwarding → Samba DC       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "AD domain:   ${BOLD}${AD_DOMAIN}${RESET}"
info "Samba DC IP: ${BOLD}${DC_IP}${RESET}"
echo ""
info "DNS flow after this change:"
echo "  Client → Pi-hole → ${AD_DOMAIN} queries → ${DC_IP} (Samba DC)"
echo "                    → all other queries  → upstream (Cloudflare 1.1.1.1)"
echo ""

# ─── Write dnsmasq drop-in configuration ─────────────────────────────────────
DNSMASQ_CONF="/etc/dnsmasq.d/02-homelab-conditional.conf"

# Back up if already exists (supports re-running with different values)
if [[ -f "$DNSMASQ_CONF" ]]; then
    BACKUP="${DNSMASQ_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    info "Existing config found, backing up → ${BACKUP}"
    cp "$DNSMASQ_CONF" "$BACKUP"
    ok "Backup created."
    echo ""
fi

info "Writing ${DNSMASQ_CONF}..."
cat > "$DNSMASQ_CONF" << EOF
# HomeLab conditional DNS forwarding, managed by 09-pihole-conditional-forward.sh
# Forward all queries for the Samba AD domain to the Samba DC.
# This allows internal clients to resolve AD hostnames via Pi-hole without
# needing to point their DNS directly at the DC.
#
# AD domain:   ${AD_DOMAIN}
# Samba DC IP: ${DC_IP}

server=/${AD_DOMAIN}/${DC_IP}
EOF

ok "Conditional forwarding config written."
echo ""

# ─── Reload Pi-hole DNS ───────────────────────────────────────────────────────
info "Reloading Pi-hole DNS..."
pihole restartdns reload
ok "Pi-hole DNS reloaded."
echo ""

# ─── Verify resolution ────────────────────────────────────────────────────────
info "Verifying AD domain resolution via Pi-hole (127.0.0.1)..."
echo ""

# Give dnsmasq a moment to fully reload
sleep 2

DC_FQDN="dc01.${AD_DOMAIN}"
RESOLVED=$(dig +short "$DC_FQDN" @127.0.0.1 2>/dev/null | head -1)

if [[ "$RESOLVED" == "$DC_IP" ]]; then
    printf "  ${GREEN}OK${RESET}    %s → %s\n" "$DC_FQDN" "$RESOLVED"
    echo ""
    VERIFY_OK=true
else
    printf "  ${YELLOW}WARN${RESET}  %s → '%s' (expected %s)\n" "$DC_FQDN" "$RESOLVED" "$DC_IP"
    echo ""
    warn "Resolution did not return the expected IP."
    warn "Possible causes:"
    warn "  • Samba AD DC (CTID 102) is not yet running, start it first"
    warn "  • The DC's hostname is not registered in Samba DNS, check samba-tool dns query"
    warn "  • Pi-hole dnsmasq did not fully reload, try: pihole restartdns"
    echo ""
    VERIFY_OK=false
fi

# ─── Result ───────────────────────────────────────────────────────────────────
if $VERIFY_OK; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║         Conditional forwarding configured and verified.  ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
else
    echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${YELLOW}${BOLD}║   Forwarding written, verify once Samba DC is running.  ║${RESET}"
    echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
fi

echo ""
echo -e "${BOLD}Manual verification commands (run from any Internal network host):${RESET}"
echo "  # AD hostname via Pi-hole:"
echo "  dig ${DC_FQDN} @10.10.10.2"
echo ""
echo "  # AD hostname via Samba DC directly:"
echo "  dig ${DC_FQDN} @${DC_IP}"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Run the end-to-end verification checklist:"
echo "     dig proxmox.\${DOMAIN} @10.10.10.2   # internal host resolves"
echo "     dig ${DC_FQDN} @10.10.10.2            # AD host resolves via Pi-hole → Samba"
echo "     curl -sI https://proxmox.\${DOMAIN}:8006 | head -3   # no cert warnings"
echo ""
echo "  2. Post 3 is ready to publish."
echo "     Tag the release after final review:"
echo "     git tag -a v3.0-dns-ssl -m 'Domain, SSL, Pi-hole and Samba AD post'"
echo "     git push origin --tags"
echo ""
