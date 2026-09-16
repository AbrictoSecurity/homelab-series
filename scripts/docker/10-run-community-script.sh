#!/bin/bash
# Script: 10-run-community-script.sh
# Description: Fetch a Proxmox VE Community Helper-Script to disk, show its hash and contents for review, then run it
# Blog post: https://abrictosecurity.com/homelab-series-docker-kali-dvwa/
# Usage: bash 10-run-community-script.sh ct/docker.sh [COMMIT_SHA]
# Dependencies: curl, sha256sum

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

REPO="community-scripts/ProxmoxVE"
CACHE_DIR="/opt/homelab/.community-scripts"

usage() {
    cat >&2 <<'USAGE'
Usage: bash 10-run-community-script.sh SCRIPT_PATH [COMMIT_SHA]

  SCRIPT_PATH   Path within community-scripts/ProxmoxVE, e.g. ct/docker.sh
  COMMIT_SHA    Optional. Pin to a specific commit instead of tracking main.
                Strongly recommended for anything you intend to reproduce.

Examples:
  bash 10-run-community-script.sh ct/docker.sh
  bash 10-run-community-script.sh tools/addon/portainer.sh
  bash 10-run-community-script.sh ct/docker.sh a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0
USAGE
    exit 1
}

[[ $# -ge 1 ]] || usage
SCRIPT_PATH="$1"
REF="${2:-main}"

[[ "$SCRIPT_PATH" =~ ^[A-Za-z0-9_./-]+\.sh$ ]] || die "Invalid script path: $SCRIPT_PATH"
[[ "$SCRIPT_PATH" == *".."* ]] && die "Path traversal rejected: $SCRIPT_PATH"

[[ $EUID -ne 0 ]] && die "Must be run as root on the Proxmox host. Try: sudo bash $0 $*"
command -v pveversion &>/dev/null || die "pveversion not found. Is this a Proxmox VE host?"
command -v curl &>/dev/null || die "curl not found. Install it: apt install -y curl"
command -v sha256sum &>/dev/null || die "sha256sum not found (coreutils)"

URL="https://raw.githubusercontent.com/${REPO}/${REF}/${SCRIPT_PATH}"
SAFE_NAME="${SCRIPT_PATH//\//_}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL="${CACHE_DIR}/${REF}_${SAFE_NAME}"

mkdir -p "$CACHE_DIR"

echo ""
echo -e "${BOLD}Abricto HomeLab - Community Helper-Script Review Wrapper${RESET}"
echo ""

# Timestamped backup of any previous copy, so you can diff across runs.
if [[ -f "$LOCAL" ]]; then
    cp -a "$LOCAL" "${LOCAL}.bak.${STAMP}"
    info "Previous copy backed up to ${LOCAL}.bak.${STAMP}"
fi

info "Fetching ${SCRIPT_PATH} at ref ${REF}"
curl -fsSL "$URL" -o "$LOCAL" || die "Download failed: $URL"
[[ -s "$LOCAL" ]] || die "Downloaded file is empty: $LOCAL"

HASH="$(sha256sum "$LOCAL" | awk '{print $1}')"
LINES="$(wc -l < "$LOCAL")"

echo ""
echo -e "${BOLD}Fetched script${RESET}"
printf "  %-14s %s\n" "Source:" "$URL"
printf "  %-14s %s\n" "Saved to:" "$LOCAL"
printf "  %-14s %s\n" "Lines:" "$LINES"
printf "  %-14s %s\n" "SHA256:" "$HASH"
echo ""

# Surface the real supply chain. The visible script is rarely the whole story:
# these helper scripts source further code from a second repository at runtime.
if grep -qE 'curl -fsSL|wget -qO-|source <\(' "$LOCAL"; then
    warn "This script fetches additional code at runtime from:"
    grep -oE 'https://raw\.githubusercontent\.com/[A-Za-z0-9_./-]+' "$LOCAL" \
        | sort -u | sed 's/^/           /'
    grep -oE '\$\{COMMUNITY_SCRIPTS_[A-Z_]+:-[^}]+\}' "$LOCAL" \
        | sort -u | sed 's/^/           /' || true
    echo ""
    warn "Reviewing this file alone does not cover what actually runs."
    echo ""
fi

if [[ "$REF" == "main" ]]; then
    warn "Tracking 'main'. The code you review now is not guaranteed to be the"
    warn "code you get next time. Pass a commit SHA as the second argument to pin."
    echo ""
fi

echo -e "${BOLD}Review the script before running it:${RESET}"
echo "  less $LOCAL"
echo ""

read -rp "  Open it in less now? [Y/n]: " VIEW
VIEW="${VIEW,,}"
if [[ "$VIEW" != "n" && "$VIEW" != "no" ]]; then
    if command -v less &>/dev/null; then
        less "$LOCAL"
    else
        cat "$LOCAL"
    fi
fi

echo ""
echo -e "${BOLD}About to execute:${RESET} bash $LOCAL"
echo -e "  ${BOLD}SHA256:${RESET} $HASH"
echo ""
warn "This runs third-party code as root on your hypervisor."
echo ""
read -rp "  Type RUN to execute, anything else to abort: " CONFIRM
if [[ "$CONFIRM" != "RUN" ]]; then
    info "Aborted. The script is still on disk at $LOCAL for offline review."
    exit 0
fi

# Record what was run and with which hash. If the container misbehaves later,
# this is the audit trail that says exactly which revision produced it.
LOG="${CACHE_DIR}/run-log.tsv"
printf '%s\t%s\t%s\t%s\n' "$STAMP" "$SCRIPT_PATH" "$REF" "$HASH" >> "$LOG"

echo ""
info "Executing ${SCRIPT_PATH}"
echo ""
# set -e would abort here before RC could be read, so capture it explicitly.
RC=0
bash "$LOCAL" || RC=$?

echo ""
if [[ $RC -eq 0 ]]; then
    ok "${SCRIPT_PATH} completed"
else
    warn "${SCRIPT_PATH} exited with status $RC"
fi

echo ""
echo -e "${BOLD}Audit trail${RESET}"
printf "  %-14s %s\n" "Run log:" "$LOG"
printf "  %-14s %s\n" "Script copy:" "$LOCAL"
echo ""
echo -e "${BOLD}Next steps${RESET}"
echo "  1. Note the CTID the helper script assigned"
echo "  2. Verify the container: pct status CTID"
echo "  3. Enter the container:  pct exec CTID -- bash"
echo ""

exit "$RC"
