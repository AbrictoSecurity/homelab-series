#!/bin/bash
# Script:      03-opnsense-configure.sh
# Description: Configures OPNsense post-install via the REST API.
#              Enables and names the DMZ (OPT1) interface, then creates
#              three baseline firewall rules:
#                Allow Internal (LAN) → WAN
#                Block  Internal (LAN) → DMZ
#                Block  DMZ → Internal (LAN)
# Blog post:   https://abrictosecurity.com/homelab-series-network-architecture
# Usage:       bash 03-opnsense-configure.sh <api_key> <api_secret>
# Run from:    Any host on the Internal network (10.10.10.0/24) that can
#              reach the OPNsense LAN interface at 10.10.10.1
# Dependencies: curl
#
# SECURITY NOTE: API credentials are passed as command-line arguments.
# On a shared system, arguments are visible in process listings (ps aux).
# On a single-user homelab host this is acceptable. Avoid recording this
# command in a shared shell history file. Run:
#   unset HISTFILE && bash 03-opnsense-configure.sh <key> <secret>
# to prevent the credentials from being written to ~/.bash_history.

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

# ─── Dependency check ─────────────────────────────────────────────────────────
command -v curl &>/dev/null || die "curl not found. Install with: apt install curl -y"

# ─── Credential arguments ─────────────────────────────────────────────────────
# Generate in OPNsense: System → Access → Users → admin → API Keys → +
API_KEY="${1:?Usage: bash $0 <api_key> <api_secret>}"
API_SECRET="${2:?Usage: bash $0 <api_key> <api_secret>}"
AUTH="${API_KEY}:${API_SECRET}"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     Abricto HomeLab — 03-opnsense-configure.sh          ║${RESET}"
echo -e "${BOLD}║  Configures DMZ interface and baseline firewall rules   ║${RESET}"
echo -e "${BOLD}║  via the OPNsense REST API                              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
warn "SSL certificate verification is skipped (-k) because OPNsense"
warn "uses a self-signed certificate until Let's Encrypt is configured."
warn "This is addressed in Post 3 of the HomeLab Series."
echo ""

# ─── Interactive configuration ────────────────────────────────────────────────
echo -e "${BOLD}Configuration${RESET}"
echo ""

read -r -p "  OPNsense LAN IP [10.10.10.1]: " OPNSENSE_IP
OPNSENSE_IP="${OPNSENSE_IP:-10.10.10.1}"

read -r -p "  Internal subnet [10.10.10.0/24]: " LAN_SUBNET
LAN_SUBNET="${LAN_SUBNET:-10.10.10.0/24}"

read -r -p "  DMZ subnet [10.20.20.0/24]: " DMZ_SUBNET
DMZ_SUBNET="${DMZ_SUBNET:-10.20.20.0/24}"

echo ""

BASE_URL="https://${OPNSENSE_IP}/api"

# ─── Helper: API call with response check ─────────────────────────────────────
# Usage: api_call <METHOD> <endpoint> [json_body]
# Returns the response body; exits on HTTP error or empty response.
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

    [[ -z "$response" ]] && die "Empty response from ${endpoint} — check OPNsense is reachable and API is enabled."
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
    die "Unexpected response from API. Is OPNsense running and reachable at ${OPNSENSE_IP}?\n       Response: ${response}"
fi
echo ""

# ─── Step 2: Enable and name the DMZ interface (OPT1 / vtnet2) ───────────────
echo -e "${BOLD}Step 1 of 3 — Configure DMZ interface${RESET}"
echo ""
info "Enabling OPT1 interface and setting description to 'DMZ' ..."

response=$(api_call POST "/interfaces/overview/setInterfaceIdentifier" \
    '{"identifier": "opt1", "description": "DMZ"}')

if echo "$response" | grep -qi '"result"\s*:\s*"saved"\|"status"\s*:\s*"ok"'; then
    ok "DMZ interface configured."
else
    warn "Unexpected response — verify OPT1 in OPNsense UI (Interfaces → Assignments)."
    warn "Response: ${response}"
fi

info "Applying interface changes ..."
api_call POST "/interfaces/overview/reconfigure" > /dev/null
ok "Interface changes applied."
echo ""

# ─── Step 3: Firewall rules ───────────────────────────────────────────────────
echo -e "${BOLD}Step 2 of 3 — Baseline firewall rules${RESET}"
echo ""
echo "  Rules to be created:"
echo ""
printf "  ${GREEN}%-8s${RESET}  %-10s  %-22s  %-22s  %s\n" \
    "ACTION" "INTERFACE" "SOURCE" "DESTINATION" "DESCRIPTION"
printf "  %-8s  %-10s  %-22s  %-22s  %s\n" \
    "────────" "──────────" "──────────────────────" "──────────────────────" "────────────────────────"
printf "  ${GREEN}%-8s${RESET}  %-10s  %-22s  %-22s  %s\n" \
    "PASS" "LAN in" "$LAN_SUBNET" "any" "Allow Internal to WAN"
printf "  ${RED}%-8s${RESET}  %-10s  %-22s  %-22s  %s\n" \
    "BLOCK" "LAN in" "$LAN_SUBNET" "$DMZ_SUBNET" "Block Internal to DMZ"
printf "  ${RED}%-8s${RESET}  %-10s  %-22s  %-22s  %s\n" \
    "BLOCK" "OPT1 in" "$DMZ_SUBNET" "$LAN_SUBNET" "Block DMZ to Internal"
echo ""

read -r -p "Create these rules? [y/N]: " CONFIRM
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
echo -e "${BOLD}Step 3 of 3 — Apply changes${RESET}"
echo ""
info "Applying firewall rules ..."

api_call POST "/firewall/filter/apply" > /dev/null
ok "Firewall rules applied."
echo ""

# ─── Verify ───────────────────────────────────────────────────────────────────
info "Fetching applied rule count to confirm ..."
response=$(api_call GET "/firewall/filter/searchRule")
rule_count=$(echo "$response" | grep -o '"total":[0-9]*' | grep -o '[0-9]*' || echo "unknown")
ok "OPNsense reports ${rule_count} total firewall rule(s) active."
echo ""

# ─── Result ───────────────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   OPNsense baseline configuration complete.             ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Verify in the OPNsense web UI:${RESET}"
echo ""
echo "  Interfaces  → https://${OPNSENSE_IP} → Interfaces → Assignments"
echo "    OPT1 should appear as 'DMZ' and show as enabled"
echo ""
echo "  Firewall    → https://${OPNSENSE_IP} → Firewall → Rules → LAN"
echo "    Allow Internal to WAN   (pass)"
echo "    Block Internal to DMZ   (block)"
echo ""
echo "               https://${OPNSENSE_IP} → Firewall → Rules → DMZ"
echo "    Block DMZ to Internal   (block)"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo ""
echo "  Post 2 verification — create a test LXC on vmbr2 and confirm:"
echo "    ping 10.10.10.1   (OPNsense LAN — should succeed)"
echo "    ping 1.1.1.1      (internet — should succeed)"
echo "    ping 10.20.20.1   (DMZ gateway — should fail)"
echo ""
echo "  When verification passes, Post 2 is complete."
echo "  Post 3 begins with: domain purchase → Cloudflare DNS → SSL certs"
echo "  Repository: https://github.com/Cab00se-AS/homelab-series"
echo ""
