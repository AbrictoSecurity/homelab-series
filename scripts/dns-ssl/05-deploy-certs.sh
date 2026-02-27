#!/bin/bash
# Script:      05-deploy-certs.sh
# Description: Deploys the Let's Encrypt wildcard certificate to Proxmox (local)
#              and Pi-hole (via pct push/exec). Run after 04-certbot-setup.sh
#              and 06-pihole-lxc.sh. OPNsense import is documented but manual.
# Blog post:   https://abrictosecurity.com/homelab-series-domain-ssl-pihole-samba
# Usage:       sudo bash 05-deploy-certs.sh <domain>
# Example:     sudo bash 05-deploy-certs.sh yourname-lab.com
# Dependencies: pct (Proxmox), certbot (run 04 first), Pi-hole LXC running (run 06 first)

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
[[ $EUID -ne 0 ]] && die "Must be run as root.  Try: sudo bash $0 <domain>"

# ─── Argument validation ──────────────────────────────────────────────────────
DOMAIN="${1:?Usage: $0 <domain>  Example: $0 yourname-lab.com}"

# ─── Configuration ────────────────────────────────────────────────────────────
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
PIHOLE_CTID=101   # Update if your Pi-hole LXC uses a different container ID.

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         Abricto HomeLab, 05-deploy-certs.sh             ║${RESET}"
echo -e "${BOLD}║   Deploy wildcard cert to Proxmox and Pi-hole            ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Domain:       ${BOLD}${DOMAIN}${RESET}"
info "Cert source:  ${BOLD}${CERT_DIR}${RESET}"
info "Pi-hole CTID: ${BOLD}${PIHOLE_CTID}${RESET}"
echo ""

# ─── Dependency checks ────────────────────────────────────────────────────────
command -v pct &>/dev/null    || die "pct not found. Is this a Proxmox VE host?"
[[ -d "$CERT_DIR" ]]          || die "Certificate directory not found: ${CERT_DIR}\n       Run 04-certbot-setup.sh first."
[[ -f "${CERT_DIR}/fullchain.pem" ]] || die "fullchain.pem not found in ${CERT_DIR}"
[[ -f "${CERT_DIR}/privkey.pem" ]]   || die "privkey.pem not found in ${CERT_DIR}"

# Confirm Pi-hole LXC is running
if ! pct status "${PIHOLE_CTID}" 2>/dev/null | grep -q "^status: running"; then
    die "Pi-hole LXC (CTID ${PIHOLE_CTID}) is not running.\n       Run 06-pihole-lxc.sh first, then retry."
fi

# ─── Deploy to Proxmox ────────────────────────────────────────────────────────
echo -e "${BOLD}── Proxmox ──────────────────────────────────────────────────${RESET}"
info "Backing up existing Proxmox certs..."
BACKUP_TS="$(date +%Y%m%d%H%M%S)"
cp /etc/pve/local/pve-ssl.pem "/etc/pve/local/pve-ssl.pem.bak.${BACKUP_TS}" 2>/dev/null || true
cp /etc/pve/local/pve-ssl.key "/etc/pve/local/pve-ssl.key.bak.${BACKUP_TS}" 2>/dev/null || true
ok "Backup created (suffix: .bak.${BACKUP_TS})"

info "Copying cert chain and private key to /etc/pve/local/..."
cp "${CERT_DIR}/fullchain.pem" /etc/pve/local/pve-ssl.pem
cp "${CERT_DIR}/privkey.pem"   /etc/pve/local/pve-ssl.key
chmod 640 /etc/pve/local/pve-ssl.pem
chmod 600 /etc/pve/local/pve-ssl.key
ok "Cert files in place."

info "Restarting Proxmox web proxy (pveproxy)..."
systemctl restart pveproxy
ok "pveproxy restarted."
echo ""

# ─── Deploy to Pi-hole ────────────────────────────────────────────────────────
echo -e "${BOLD}── Pi-hole (LXC ${PIHOLE_CTID}) ──────────────────────────────────${RESET}"

# lighttpd expects a single combined PEM: private key followed by the cert chain.
COMBINED_TMP="/tmp/pihole-combined-${BACKUP_TS}.pem"
info "Building combined PEM (privkey + fullchain) → ${COMBINED_TMP}"
cat "${CERT_DIR}/privkey.pem" "${CERT_DIR}/fullchain.pem" > "$COMBINED_TMP"

info "Creating cert directory inside Pi-hole LXC..."
pct exec "${PIHOLE_CTID}" -- mkdir -p /etc/lighttpd/certs

info "Pushing combined cert into Pi-hole LXC..."
pct push "${PIHOLE_CTID}" "$COMBINED_TMP" /etc/lighttpd/certs/combined.pem --perms 600
rm "$COMBINED_TMP"
ok "Combined cert pushed."

# Enable lighttpd SSL and configure the cert path.
# This creates a drop-in config rather than modifying the Pi-hole managed file.
info "Configuring lighttpd SSL in Pi-hole LXC..."
pct exec "${PIHOLE_CTID}" -- bash -c '
  SSL_CONF="/etc/lighttpd/conf-enabled/20-pihole-ssl.conf"

  # Bail if ssl.engine is already configured (re-run safety)
  if [[ -f "$SSL_CONF" ]]; then
    echo "  SSL config already present at $SSL_CONF, skipping write."
  else
    cat > "$SSL_CONF" << EOF
# Pi-hole SSL, managed by 05-deploy-certs.sh
# Enables HTTPS on port 443 using the Let'\''s Encrypt wildcard cert.
server.modules += ("mod_openssl")

\$SERVER["socket"] == ":443" {
  ssl.engine        = "enable"
  ssl.pemfile       = "/etc/lighttpd/certs/combined.pem"
  ssl.honor-cipher-order = "enable"
}
EOF
    echo "  SSL config written."
  fi
'

info "Restarting lighttpd in Pi-hole LXC..."
pct exec "${PIHOLE_CTID}" -- systemctl restart lighttpd
ok "Pi-hole lighttpd restarted."
echo ""

# ─── OPNsense, manual step ───────────────────────────────────────────────────
echo -e "${BOLD}── OPNsense ─────────────────────────────────────────────────${RESET}"
warn "OPNsense cert import requires the web UI (or OPNsense API, see blog post)."
echo "  Steps:"
echo "    1. Download cert files from the Proxmox host:"
echo "       ${CERT_DIR}/fullchain.pem"
echo "       ${CERT_DIR}/privkey.pem"
echo "    2. OPNsense → System → Trust → Certificates → Import"
echo "    3. OPNsense → System → Settings → Administration → SSL Certificate → select imported cert"
echo "    4. Save and restart the web UI."
echo ""

# ─── Verify ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}── Verification ─────────────────────────────────────────────${RESET}"
info "Checking pveproxy TLS certificate CN..."
PROXMOX_CN=$(echo | openssl s_client -connect "127.0.0.1:8006" -servername "${DOMAIN}" 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,]+' || echo "unable to verify")
echo "  Proxmox CN: ${PROXMOX_CN}"

info "Checking Pi-hole lighttpd TLS certificate CN..."
PIHOLE_CN=$(pct exec "${PIHOLE_CTID}" -- bash -c \
    "echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,]+'" \
    2>/dev/null || echo "unable to verify")
echo "  Pi-hole CN: ${PIHOLE_CN}"
echo ""

# ─── Result ───────────────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║              Certificate deployment complete.            ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Services now using Let's Encrypt wildcard cert:${RESET}"
echo "  Proxmox:  https://proxmox.${DOMAIN}:8006"
echo "  Pi-hole:  https://pihole.${DOMAIN}/admin"
echo ""
echo -e "${BOLD}Automatic renewal:${RESET}"
echo "  The deploy hook at /etc/letsencrypt/renewal-hooks/deploy/restart-services.sh"
echo "  will re-deploy and restart services on each successful renewal."
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Add local DNS A records to Pi-hole:"
echo "     pct exec ${PIHOLE_CTID} -- bash /opt/homelab/scripts/pihole/07-pihole-dns-records.sh ${DOMAIN}"
echo ""
echo "  2. Provision Samba AD DC:"
echo "     sudo bash scripts/samba/08-samba-lxc.sh"
echo ""
