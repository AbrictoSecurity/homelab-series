#!/bin/bash
# Script: 14-kali-verify.sh
# Description: Verify the dual-homed Kali build: addressing, policy routing, DNS, services, RDP binding
# Blog post: https://abrictosecurity.com/homelab-series-docker-kali-dvwa/
# Usage: bash 14-kali-verify.sh
# Dependencies: iproute2, iputils-ping, dnsutils, netcat-openbsd

set -uo pipefail   # deliberately not -e: every check must run, then report

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

INTERNAL_IP="10.10.10.20"
INTERNAL_GW="10.10.10.1"
DMZ_IP="10.20.20.20"
DMZ_GW="10.20.20.1"
DMZ_TABLE="100"

PIHOLE="10.10.10.2"
SAMBA_DC="10.10.10.3"
DOCKER_VM="10.10.10.4"
OPNSENSE="10.10.10.1"

# The series uses yourname-lab.com as a stand-in. Override for a real lab:
#   LAB_DOMAIN=example.com bash 14-kali-verify.sh
DOMAIN="${LAB_DOMAIN:-yourname-lab.com}"
AD_REALM="${AD_REALM:-corp.${DOMAIN}}"
RDP_PORT="3389"

PASS=0; FAIL=0; SKIP=0

pass() { echo -e "  ${GREEN}[PASS]${RESET} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1"; [[ -n "${2:-}" ]] && echo -e "         ${YELLOW}Fix:${RESET} $2"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}[SKIP]${RESET} $1"; SKIP=$((SKIP + 1)); }
section() { echo ""; echo -e "${BOLD}$1${RESET}"; }

have() { command -v "$1" &>/dev/null; }

echo ""
echo -e "${BOLD}Abricto HomeLab - Kali Build Verification${RESET}"
echo -e "Run: $(date '+%Y-%m-%d %H:%M:%S')"

# ---------------------------------------------------------------------------
section "1. Interface addressing"
# ---------------------------------------------------------------------------

if ip -4 addr show | grep -q "inet ${INTERNAL_IP}/"; then
    IF_INTERNAL=$(ip -4 -o addr show | awk -v ip="$INTERNAL_IP" '$4 ~ "^"ip"/" {print $2}' | head -1)
    pass "Internal address $INTERNAL_IP present on ${IF_INTERNAL:-unknown}"
else
    fail "Internal address $INTERNAL_IP not configured" "Run 12-kali-network.sh"
fi

if ip -4 addr show | grep -q "inet ${DMZ_IP}/"; then
    IF_DMZ=$(ip -4 -o addr show | awk -v ip="$DMZ_IP" '$4 ~ "^"ip"/" {print $2}' | head -1)
    pass "DMZ address $DMZ_IP present on ${IF_DMZ:-unknown}"
else
    fail "DMZ address $DMZ_IP not configured" "Run 12-kali-network.sh"
fi

# ---------------------------------------------------------------------------
section "2. Routing"
# ---------------------------------------------------------------------------

DEFAULT_COUNT=$(ip route show default 2>/dev/null | wc -l)
if [[ "$DEFAULT_COUNT" -eq 1 ]]; then
    pass "Exactly one default route in the main table"
elif [[ "$DEFAULT_COUNT" -eq 0 ]]; then
    fail "No default route" "Run 12-kali-network.sh"
else
    fail "$DEFAULT_COUNT default routes in the main table, expected 1" \
         "The DMZ profile needs ipv4.never-default yes"
fi

if ip route show default 2>/dev/null | grep -q "via ${INTERNAL_GW}"; then
    pass "Default route points at the Internal gateway $INTERNAL_GW"
else
    fail "Default route does not use $INTERNAL_GW" "Check the Internal profile gateway"
fi

if ip rule show 2>/dev/null | grep -q "from ${DMZ_IP}.*lookup ${DMZ_TABLE}"; then
    pass "Policy rule present: from $DMZ_IP lookup table $DMZ_TABLE"
else
    fail "No policy rule for traffic sourced from $DMZ_IP" \
         "Check ipv4.routing-rules on the dmz profile"
fi

if ip route show table "$DMZ_TABLE" 2>/dev/null | grep -q "default via ${DMZ_GW}"; then
    pass "Table $DMZ_TABLE holds a default route via $DMZ_GW"
else
    fail "Table $DMZ_TABLE has no default route via $DMZ_GW" \
         "Check ipv4.routes on the dmz profile"
fi

# Table 100 needs the on-link subnet route too, not just the default. Once the
# policy rule diverts a lookup here the main table is never consulted, so
# without it DMZ-local traffic is sent to the gateway and silently times out.
DMZ_NET="${DMZ_IP%.*}.0/24"
if ip route show table "$DMZ_TABLE" 2>/dev/null | grep -q "^${DMZ_NET} "; then
    pass "Table $DMZ_TABLE holds the on-link route for $DMZ_NET"
else
    fail "Table $DMZ_TABLE is missing the on-link route for $DMZ_NET" \
         "Add it: nmcli connection modify dmz ipv4.routes \"${DMZ_NET} 0.0.0.0 table=${DMZ_TABLE}, 0.0.0.0/0 ${DMZ_GW} table=${DMZ_TABLE}\""
fi

# Prove the policy path resolves on-link rather than via the gateway. Plain
# 'ip route get' consults the main table and looks correct either way, so the
# source address must be supplied to exercise the rule.
if have ip; then
    DMZ_PEER="${DMZ_IP%.*}.30"
    POLICY_PATH="$(ip route get "$DMZ_PEER" from "$DMZ_IP" 2>/dev/null || true)"
    if [[ -z "$POLICY_PATH" ]]; then
        skip "Could not evaluate the policy route path to $DMZ_PEER"
    elif echo "$POLICY_PATH" | grep -q "via ${DMZ_GW}"; then
        fail "DMZ-local traffic to $DMZ_PEER is routed via the gateway" \
             "Table $DMZ_TABLE is missing the on-link ${DMZ_NET} route"
    else
        pass "DMZ-local traffic to $DMZ_PEER resolves on-link, not via the gateway"
    fi
fi

# ---------------------------------------------------------------------------
section "3. Gateway reachability"
# ---------------------------------------------------------------------------

# A firewall will often answer ARP while dropping ICMP on a DMZ interface, so
# test layer 2 first and only fall back to ping. Otherwise a correctly locked
# down OPNsense DMZ interface reports as a failure.
gw_reachable() {
    local ifname="$1" gw="$2"
    if have arping && arping -c 2 -w 3 -I "$ifname" "$gw" &>/dev/null; then
        return 0
    fi
    ping -c 2 -W 2 -I "$ifname" "$gw" &>/dev/null
}

if gw_reachable "${IF_INTERNAL:-eth0}" "$INTERNAL_GW"; then
    pass "Internal gateway $INTERNAL_GW reachable"
else
    fail "Internal gateway $INTERNAL_GW unreachable" "Check the OPNsense Internal interface and vmbr2"
fi

if gw_reachable "${IF_DMZ:-eth1}" "$DMZ_GW"; then
    pass "DMZ gateway $DMZ_GW reachable (ARP or ICMP)"
else
    fail "DMZ gateway $DMZ_GW answered neither ARP nor ICMP" \
         "Check the OPNsense DMZ interface is assigned and enabled, and vmbr3"
fi

# ---------------------------------------------------------------------------
section "4. DNS"
# ---------------------------------------------------------------------------

if ! have dig; then
    skip "dig not installed (apt install -y dnsutils)"
else
    if dig +short +timeout=3 +tries=1 "@${PIHOLE}" "pihole.${DOMAIN}" 2>/dev/null | grep -qE '^[0-9]+\.'; then
        pass "Pi-hole resolves pihole.${DOMAIN}"
    else
        fail "Pi-hole did not resolve pihole.${DOMAIN}" "Check local DNS records in Pi-hole (Post 3)"
    fi

    if dig +short +timeout=3 +tries=1 "@${PIHOLE}" kali.org 2>/dev/null | grep -qE '^[0-9]+\.'; then
        pass "Pi-hole resolves external names (kali.org)"
    else
        fail "External resolution through Pi-hole failed" "Check Pi-hole upstream DNS"
    fi

    if dig +short +timeout=3 +tries=1 "@${SAMBA_DC}" SRV "_ldap._tcp.${AD_REALM}" 2>/dev/null | grep -q .; then
        pass "Samba DC answers the AD SRV lookup for ${AD_REALM}"
    else
        fail "No SRV record from the Samba DC" "Check the Samba AD DC (Post 3)"
    fi

    if grep -q "nameserver ${PIHOLE}" /etc/resolv.conf 2>/dev/null; then
        pass "System resolver points at Pi-hole ($PIHOLE)"
    else
        fail "System resolver does not use $PIHOLE" "Check ipv4.dns on the internal profile"
    fi
fi

# ---------------------------------------------------------------------------
section "5. Lab service reachability"
# ---------------------------------------------------------------------------

check_port() {
    local host="$1" port="$2" label="$3" fixhint="$4"
    if have nc; then
        if nc -z -w 3 "$host" "$port" &>/dev/null; then
            pass "$label reachable at ${host}:${port}"
        else
            fail "$label unreachable at ${host}:${port}" "$fixhint"
        fi
    else
        # Bash's /dev/tcp works even when netcat is absent.
        if timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
            pass "$label reachable at ${host}:${port}"
        else
            fail "$label unreachable at ${host}:${port}" "$fixhint"
        fi
    fi
}

check_port "$OPNSENSE"   443 "OPNsense web UI"  "Check the OPNsense Internal firewall rules"
check_port "$PIHOLE"      80 "Pi-hole admin"    "Check the Pi-hole LXC (Post 3)"
check_port "$SAMBA_DC"   389 "Samba AD LDAP"    "Check the Samba AD DC (Post 3)"
check_port "$DOCKER_VM"  22 "Docker VM SSH"    "Check VM 103 is running: qm status 103"
check_port "$DOCKER_VM" 9443 "Portainer UI"     "Check the Portainer container in VM 103"

# ---------------------------------------------------------------------------
section "6. RDP binding"
# ---------------------------------------------------------------------------

if ! have ss; then
    skip "ss not available (iproute2)"
elif ! systemctl is-active --quiet xrdp 2>/dev/null; then
    skip "xrdp is not running (run 13-kali-rdp.sh)"
else
    if ss -tln 2>/dev/null | grep -q "0\.0\.0\.0:${RDP_PORT}"; then
        fail "xrdp is listening on 0.0.0.0:${RDP_PORT}" \
             "Set address=${DMZ_IP} in /etc/xrdp/xrdp.ini, then restart xrdp"
    elif ss -tln 2>/dev/null | grep -q "${DMZ_IP}:${RDP_PORT}"; then
        pass "xrdp bound to ${DMZ_IP}:${RDP_PORT} only"
    else
        fail "xrdp is not listening on ${DMZ_IP}:${RDP_PORT}" "Check: journalctl -u xrdp -n 50"
    fi

    if ss -tln 2>/dev/null | grep -q "${INTERNAL_IP}:${RDP_PORT}"; then
        fail "RDP exposed on the Internal address ${INTERNAL_IP}" \
             "Bind xrdp to ${DMZ_IP} only"
    else
        pass "RDP not exposed on the Internal address"
    fi
fi

# ---------------------------------------------------------------------------
section "7. Guest integration"
# ---------------------------------------------------------------------------

if systemctl is-active --quiet qemu-guest-agent 2>/dev/null; then
    pass "qemu-guest-agent running, Proxmox can report guest IPs"
else
    fail "qemu-guest-agent not running" \
         "apt install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}Summary${RESET}"
echo -e "  ${GREEN}Passed:${RESET}  $PASS"
echo -e "  ${RED}Failed:${RESET}  $FAIL"
echo -e "  ${YELLOW}Skipped:${RESET} $SKIP"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All checks passed. The dual-homed Kali build is verified.${RESET}"
    echo ""
    echo -e "${BOLD}You can now${RESET}"
    echo "  - RDP in from the management network: mstsc /v:${DMZ_IP}"
    echo "  - Test the internal lab from ${INTERNAL_IP}"
    echo "  - Run containerised tooling on the Docker VM at ${DOCKER_VM}"
    echo ""
    exit 0
else
    echo -e "${RED}${BOLD}${FAIL} check(s) failed. See the Fix hints above.${RESET}"
    echo ""
    exit 1
fi
