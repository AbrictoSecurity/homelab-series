#!/bin/bash
# Script: 13-kali-rdp.sh
# Description: Install xrdp on the Kali VM and bind it to the DMZ interface only
# Blog post: https://abrictosecurity.com/homelab-series-docker-kali-dvwa/
# Usage: sudo bash 13-kali-rdp.sh
# Dependencies: xrdp, xorgxrdp (installed by this script)

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

DMZ_IP="10.20.20.20"
INTERNAL_IP="10.10.10.20"
RDP_PORT="3389"
XRDP_INI="/etc/xrdp/xrdp.ini"
SESMAN_INI="/etc/xrdp/sesman.ini"
STAMP="$(date +%Y%m%d-%H%M%S)"

[[ $EUID -ne 0 ]] && die "Must be run as root inside the Kali VM. Try: sudo bash $0"
command -v apt-get &>/dev/null || die "apt-get not found. This script targets Kali/Debian."

echo ""
echo -e "${BOLD}Abricto HomeLab - Kali RDP Access (DMZ interface only)${RESET}"
echo ""

# The whole point of the dual-homed design is that remote access and testing
# traffic use different interfaces. If the DMZ address is not up, binding xrdp
# to it will fail at service start, so check first.
if ! ip -4 addr show | grep -q "inet ${DMZ_IP}/"; then
    echo ""
    ip -4 -brief addr show
    echo ""
    die "DMZ address $DMZ_IP is not configured on this host.
       Run 12-kali-network.sh first."
fi
ok "DMZ address $DMZ_IP is present"

RDP_USER="${SUDO_USER:-kali}"
id "$RDP_USER" &>/dev/null || die "User '$RDP_USER' does not exist"
info "RDP session user: $RDP_USER"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

echo ""
info "Installing xrdp and xorgxrdp"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || warn "apt update reported problems, continuing"
apt-get install -y -qq xrdp xorgxrdp >/dev/null 2>&1 \
    || die "Failed to install xrdp. Check networking and apt sources."
ok "xrdp installed"

# ---------------------------------------------------------------------------
# Bind to the DMZ address only.
#
# xrdp listens on 0.0.0.0 out of the box, which would expose RDP on the
# Internal interface too, right next to the machines this VM is meant to test.
# Pinning the address keeps the attack surface on the interface that is
# actually intended for remote access.
# ---------------------------------------------------------------------------

echo ""
[[ -f "$XRDP_INI" ]] || die "$XRDP_INI not found after install"
cp -a "$XRDP_INI" "${XRDP_INI}.bak.${STAMP}"
info "Backed up $XRDP_INI to ${XRDP_INI}.bak.${STAMP}"

# xrdp 0.10 removed the old 'address=' key. Binding to a single interface is
# now expressed as a URI in 'port=' — see the examples in the stock xrdp.ini:
#
#   port=3389                      listens on EVERY interface
#   port=tcp://:3389               also every interface
#   port=tcp://10.20.20.20:3389    this address only
#
# An 'address=' line on 0.10 is silently ignored, so a script that writes one
# and then confirms it was written will report success while RDP is in fact
# exposed on every interface. Strip any such line before setting the real key.
sed -i '/^[[:space:]]*address[[:space:]]*=/d' "$XRDP_INI"

BIND_URI="tcp://${DMZ_IP}:${RDP_PORT}"

# Target the port= inside [Globals] specifically. Later sections carry their own
# port= keys (port=-1, port=ask3389) that must not be touched.
GLOBALS_PORT_LINE="$(awk '/^\[Globals\]/{g=1; next} /^\[/{g=0} g && /^[[:space:]]*port[[:space:]]*=/{print NR; exit}' "$XRDP_INI")"
if [[ -n "$GLOBALS_PORT_LINE" ]]; then
    sed -i "${GLOBALS_PORT_LINE}s#.*#port=${BIND_URI}#" "$XRDP_INI"
else
    sed -i "/^\[Globals\]/a port=${BIND_URI}" "$XRDP_INI"
fi

grep -q "^port=${BIND_URI}$" "$XRDP_INI" \
    || die "Failed to set the listen address in $XRDP_INI. Restore: ${XRDP_INI}.bak.${STAMP}"
ok "xrdp bind set to ${BIND_URI}"

# The stock file warns that every interface named in port= must be UP when xrdp
# starts, or the service fails to start. 12-kali-network.sh runs first for
# exactly this reason.

# Match sesman's listen address to loopback. It only ever talks to xrdp on the
# same host, so there is no reason for it to be reachable over the network.
if [[ -f "$SESMAN_INI" ]]; then
    cp -a "$SESMAN_INI" "${SESMAN_INI}.bak.${STAMP}"
    if grep -qE '^\s*ListenAddress=' "$SESMAN_INI"; then
        sed -i "0,/^\s*ListenAddress=.*/s//ListenAddress=127.0.0.1/" "$SESMAN_INI"
        ok "sesman bound to 127.0.0.1"
    fi
fi

# ---------------------------------------------------------------------------
# TLS key permissions.
#
# xrdp runs as the 'xrdp' user and reads /etc/ssl/private/ssl-cert-snakeoil.key,
# which is mode 640 root:ssl-cert. Without this group membership the service
# starts but every connection drops at the TLS handshake.
# ---------------------------------------------------------------------------

echo ""
if getent group ssl-cert >/dev/null; then
    if id -nG xrdp 2>/dev/null | tr ' ' '\n' | grep -qx ssl-cert; then
        ok "xrdp already in the ssl-cert group"
    else
        adduser xrdp ssl-cert >/dev/null 2>&1 \
            && ok "Added xrdp to the ssl-cert group" \
            || warn "Could not add xrdp to ssl-cert, TLS may fail"
    fi
fi

# ---------------------------------------------------------------------------
# Session startup.
#
# Kali's prebuilt image runs XFCE. xrdp needs to be told what to launch for a
# new session; without an .xsession it can hand back a blank or grey screen.
# ---------------------------------------------------------------------------

echo ""
USER_HOME="$(getent passwd "$RDP_USER" | cut -d: -f6)"
[[ -d "$USER_HOME" ]] || die "Home directory for $RDP_USER not found"

XSESSION="${USER_HOME}/.xsession"
if [[ -f "$XSESSION" ]]; then
    cp -a "$XSESSION" "${XSESSION}.bak.${STAMP}"
    info "Backed up existing $XSESSION"
fi

if command -v xfce4-session &>/dev/null; then
    printf '%s\n' 'xfce4-session' > "$XSESSION"
    ok "Session set to xfce4-session"
elif command -v startxfce4 &>/dev/null; then
    printf '%s\n' 'startxfce4' > "$XSESSION"
    ok "Session set to startxfce4"
else
    warn "No XFCE session binary found. Writing xfce4-session anyway."
    warn "If the RDP screen is blank, install a desktop: apt install -y kali-desktop-xfce"
    printf '%s\n' 'xfce4-session' > "$XSESSION"
fi

chown "$RDP_USER":"$RDP_USER" "$XSESSION"
chmod 644 "$XSESSION"

# ---------------------------------------------------------------------------
# Enable
# ---------------------------------------------------------------------------

echo ""
info "Enabling and starting xrdp"
systemctl enable xrdp >/dev/null 2>&1 || warn "Could not enable xrdp at boot"
systemctl enable xrdp-sesman >/dev/null 2>&1 || true
systemctl restart xrdp || die "xrdp failed to start. Check: journalctl -u xrdp -n 50"
sleep 2

systemctl is-active --quiet xrdp \
    && ok "xrdp is running" \
    || die "xrdp is not running. Check: journalctl -u xrdp -n 50"

# ---------------------------------------------------------------------------
# Verify the binding really is interface-specific
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}Listening sockets on port ${RDP_PORT}${RESET}"
ss -tlnp 2>/dev/null | grep ":${RDP_PORT}" || warn "Nothing listening on ${RDP_PORT}"
echo ""

# ss renders a wildcard bind as '*:3389', '0.0.0.0:3389' or '[::]:3389'
# depending on address family. All three mean "every interface", so all three
# must be treated as a failure. Matching only the literal 0.0.0.0 form lets the
# '*' case through and reports a wide-open listener as a clean bind.
LISTEN_LINES="$(ss -tln 2>/dev/null | grep ":${RDP_PORT} " || true)"

if echo "$LISTEN_LINES" | grep -qE '(^|[[:space:]])(\*|0\.0\.0\.0|\[::\]):'"${RDP_PORT}"'([[:space:]]|$)'; then
    warn "xrdp is listening on ALL interfaces, not just the DMZ address."
    warn "RDP is therefore reachable on ${INTERNAL_IP} as well, which is not intended."
    warn "Confirm this line exists in the [Globals] section of ${XRDP_INI}:"
    warn "    port=${BIND_URI}"
    warn "A bare 'port=${RDP_PORT}' or an 'address=' key will not bind to one interface on xrdp 0.10+."
elif echo "$LISTEN_LINES" | grep -q "${DMZ_IP}:${RDP_PORT}"; then
    ok "xrdp is bound to ${DMZ_IP}:${RDP_PORT} only"
    if echo "$LISTEN_LINES" | grep -q "${INTERNAL_IP}:${RDP_PORT}"; then
        warn "RDP is ALSO reachable on the Internal address ${INTERNAL_IP}. Not intended."
    else
        ok "Internal address ${INTERNAL_IP} is not listening on ${RDP_PORT}, which is correct"
    fi
else
    warn "Nothing is listening on ${RDP_PORT}. Check: journalctl -u xrdp -n 50"
fi

echo ""
ok "RDP access configured"
echo ""
echo -e "${BOLD}Connect${RESET}"
printf "  %-18s %s\n" "Address:" "${DMZ_IP}:${RDP_PORT}"
printf "  %-18s %s\n" "Username:" "$RDP_USER"
printf "  %-18s %s\n" "From Windows:" "mstsc /v:${DMZ_IP}"
printf "  %-18s %s\n" "From Linux:" "xfreerdp3 /v:${DMZ_IP} /u:${RDP_USER} +clipboard"
echo ""
echo -e "${BOLD}OPNsense rule still required${RESET}"
echo "  Firewall -> Rules -> DMZ"
echo "    Action:      Pass"
echo "    Protocol:    TCP"
echo "    Source:      Management network (192.168.1.0/24)"
echo "    Destination: ${DMZ_IP}"
echo "    Dest port:   ${RDP_PORT}"
echo ""
echo -e "${BOLD}Rollback${RESET}"
echo "  cp -a ${XRDP_INI}.bak.${STAMP} ${XRDP_INI}"
echo "  systemctl restart xrdp"
echo ""
echo -e "${BOLD}Next step${RESET}"
echo "  sudo bash 14-kali-verify.sh"
echo ""
