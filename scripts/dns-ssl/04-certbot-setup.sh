#!/bin/bash
# Script:      04-certbot-setup.sh
# Description: Installs Certbot with the Cloudflare DNS-01 plugin, requests a
#              wildcard Let's Encrypt certificate, and configures automatic renewal.
# Blog post:   https://abrictosecurity.com/homelab-series-domain-ssl-pihole-samba
# Usage:       sudo bash 04-certbot-setup.sh <domain>
# Example:     sudo bash 04-certbot-setup.sh yourname-lab.com
# Dependencies: apt (Debian/Ubuntu); certbot and python3-certbot-dns-cloudflare
#               are installed by this script.
# Security:    The Cloudflare API token is read interactively (silent prompt).
#              It is written to /root/.secrets/certbot/cloudflare.ini (chmod 600,
#              root-only) and unset from memory immediately after. Never pass
#              tokens as shell arguments, they appear in 'ps' output and history.

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

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         Abricto HomeLab, 04-certbot-setup.sh            ║${RESET}"
echo -e "${BOLD}║   Wildcard Let's Encrypt cert via Cloudflare DNS-01      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Domain:    ${BOLD}${DOMAIN}${RESET}"
info "Certs:     ${BOLD}${DOMAIN}${RESET}  and  ${BOLD}*.${DOMAIN}${RESET}"
info "Challenge: Cloudflare DNS-01 (no open ports required)"
echo ""

# ─── Dependency check ─────────────────────────────────────────────────────────
command -v apt-get &>/dev/null || die "apt-get not found. Is this a Debian/Ubuntu-based host?"

# ─── Cloudflare API token (interactive, silent) ───────────────────────────────
warn "The Cloudflare API token is read interactively and is never echoed or stored in history."
warn "Create a scoped token: Cloudflare → My Profile → API Tokens → Create Token"
warn "Required permission: Zone → DNS → Edit  (scope to ${DOMAIN} only)"
echo ""
read -r -s -p "  Cloudflare API token: " CF_TOKEN
echo ""
[[ -z "$CF_TOKEN" ]] && die "No token entered. Aborting."
echo ""

# ─── Install Certbot and Cloudflare DNS plugin ────────────────────────────────
info "Updating package lists and installing Certbot..."
apt-get update -qq
apt-get install -y certbot python3-certbot-dns-cloudflare
ok "Certbot and certbot-dns-cloudflare installed."
echo ""

# ─── Write Cloudflare credentials file (chmod 600) ───────────────────────────
CREDS_DIR="/root/.secrets/certbot"
CREDS_FILE="${CREDS_DIR}/cloudflare.ini"

info "Writing Cloudflare credentials → ${CREDS_FILE}"
mkdir -p "$CREDS_DIR"
chmod 700 "$CREDS_DIR"

cat > "$CREDS_FILE" << EOF
# Cloudflare API token, managed by 04-certbot-setup.sh
# chmod 600, root-readable only. Never commit to version control.
dns_cloudflare_api_token = ${CF_TOKEN}
EOF

chmod 600 "$CREDS_FILE"
unset CF_TOKEN
ok "Credentials file secured (chmod 600, root-only)."
echo ""

# ─── Request wildcard certificate ────────────────────────────────────────────
info "Requesting wildcard certificate for ${DOMAIN} and *.${DOMAIN}..."
info "(DNS-01 propagation can take up to 60 s, this is expected)"
echo ""

certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CREDS_FILE" \
  --dns-cloudflare-propagation-seconds 60 \
  --agree-tos \
  --non-interactive \
  --email "admin@${DOMAIN}" \
  -d "${DOMAIN}" \
  -d "*.${DOMAIN}"

echo ""
ok "Certificate issued."
echo ""

# ─── Install renewal deploy hook ──────────────────────────────────────────────
# This hook runs automatically after every successful renewal.
# It re-deploys certs to Proxmox and Pi-hole (CTID 101) so services never
# expire mid-rotation. Update PIHOLE_CTID below if you used a different ID.
HOOK_FILE="/etc/letsencrypt/renewal-hooks/deploy/restart-services.sh"
info "Installing renewal deploy hook → ${HOOK_FILE}"
mkdir -p "$(dirname "$HOOK_FILE")"

cat > "$HOOK_FILE" << HOOK
#!/bin/bash
# Renewal deploy hook, managed by 04-certbot-setup.sh (domain: ${DOMAIN})
# Runs automatically after each successful cert renewal.
# Update PIHOLE_CTID if your Pi-hole container uses a different ID.
set -euo pipefail

DOMAIN="${DOMAIN}"
PIHOLE_CTID=101
CERT_DIR="/etc/letsencrypt/live/\${DOMAIN}"

echo "[hook] Cert renewed for \${DOMAIN}, redeploying..."

# Re-deploy to Proxmox (local copy, no SSH needed)
cp "\${CERT_DIR}/fullchain.pem" /etc/pve/local/pve-ssl.pem
cp "\${CERT_DIR}/privkey.pem"   /etc/pve/local/pve-ssl.key
systemctl restart pveproxy && echo "[hook] pveproxy restarted"

# Re-deploy to Pi-hole LXC via pct (no SSH required)
cat "\${CERT_DIR}/privkey.pem" "\${CERT_DIR}/fullchain.pem" > /tmp/pihole-combined.pem
pct push "\${PIHOLE_CTID}" /tmp/pihole-combined.pem /etc/lighttpd/certs/combined.pem --perms 600
rm /tmp/pihole-combined.pem
pct exec "\${PIHOLE_CTID}" -- systemctl restart lighttpd && echo "[hook] Pi-hole lighttpd restarted"

echo "[hook] Cert redeploy complete."
HOOK

chmod +x "$HOOK_FILE"
ok "Renewal deploy hook installed."
echo ""

# ─── Dry-run renewal test ─────────────────────────────────────────────────────
info "Testing automatic renewal (dry run)..."
certbot renew --dry-run
ok "Renewal dry-run passed, automatic rotation is working."
echo ""

# ─── Result ───────────────────────────────────────────────────────────────────
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║              Certificate issued successfully.            ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Certificate files:${RESET}"
echo "  ${CERT_DIR}/fullchain.pem  , certificate chain (use this for services)"
echo "  ${CERT_DIR}/privkey.pem    , private key (root-readable only)"
echo ""
echo -e "${BOLD}Automatic renewal:${RESET}"
echo "  systemctl status certbot.timer  , confirm timer is active"
echo "  certbot renew --dry-run         , manual dry-run test"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Create the Pi-hole LXC:"
echo "     sudo bash scripts/pihole/06-pihole-lxc.sh"
echo ""
echo "  2. Deploy certs to all lab services:"
echo "     sudo bash scripts/dns-ssl/05-deploy-certs.sh ${DOMAIN}"
echo ""
