#!/bin/bash
# Script: 15-dvwa-lxc.sh
# Description: Create a DVWA (Damn Vulnerable Web Application) LXC in the DMZ as a practice target for the Kali VM
# Blog post: https://abrictosecurity.com/homelab-series-docker-kali-dvwa/
# Usage: sudo bash 15-dvwa-lxc.sh
# Dependencies: pct (Proxmox VE), a Debian 12 LXC template
#
# DVWA is deliberately vulnerable by design. It belongs in the DMZ, never on the
# Internal network beside the domain controller, and never on a bridge that can
# reach the management network or the internet-facing edge. This script refuses
# vmbr0 and vmbr1 for that reason and leaves the container stopped on boot.

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

DVWA_REPO="https://github.com/digininja/DVWA.git"
FORBIDDEN_BRIDGES=("vmbr0" "vmbr1")

PROVISION_SRC=""
cleanup() { [[ -n "$PROVISION_SRC" && -f "$PROVISION_SRC" ]] && rm -f "$PROVISION_SRC"; }
trap cleanup EXIT

[[ $EUID -ne 0 ]] && die "Must be run as root on the Proxmox host. Try: sudo bash $0"
command -v pct &>/dev/null || die "pct not found. Is this a Proxmox VE host?"

echo ""
echo -e "${BOLD}Abricto HomeLab - DVWA Practice Target (DMZ)${RESET}"
echo ""
warn "DVWA is intentionally vulnerable software. It exists to be exploited."
warn "Keep it in the DMZ, keep it off the internet, and power it off when idle."
echo ""

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------

read -rp "  Container ID (CTID) [104]: " CTID
CTID="${CTID:-104}"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID must be a number"
pct status "$CTID" &>/dev/null && die "CTID $CTID already exists. Choose another or destroy it first."

read -rp "  Hostname [dvwa]: " HOSTNAME
HOSTNAME="${HOSTNAME:-dvwa}"

read -rp "  Memory in MB [1024]: " MEMORY_MB
MEMORY_MB="${MEMORY_MB:-1024}"
[[ "$MEMORY_MB" =~ ^[0-9]+$ ]] || die "Memory must be a number"

read -rp "  CPU cores [2]: " CPU_CORES
CPU_CORES="${CPU_CORES:-2}"
[[ "$CPU_CORES" =~ ^[0-9]+$ ]] || die "CPU cores must be a number"

read -rp "  Disk size in GB [8]: " DISK_GB
DISK_GB="${DISK_GB:-8}"
[[ "$DISK_GB" =~ ^[0-9]+$ ]] || die "Disk size must be a number"

read -rp "  Bridge [vmbr3]: " BRIDGE
BRIDGE="${BRIDGE:-vmbr3}"
ip link show "$BRIDGE" &>/dev/null || die "Bridge $BRIDGE not found. Complete Post 2 first."

# Hard stop, not a prompt. A deliberately vulnerable host does not belong on the
# management bridge or the WAN-facing bridge under any circumstances.
for forbidden in "${FORBIDDEN_BRIDGES[@]}"; do
    if [[ "$BRIDGE" == "$forbidden" ]]; then
        die "Refusing to place DVWA on $BRIDGE.
       vmbr0 is the management network and vmbr1 is the WAN edge.
       DVWA is intentionally vulnerable and must stay in the DMZ (vmbr3)."
    fi
done

if [[ "$BRIDGE" != "vmbr3" ]]; then
    warn "$BRIDGE is not the DMZ bridge (vmbr3)."
    warn "Anything on this bridge will share a broadcast domain with DVWA."
    read -rp "  Continue anyway? [y/N]: " BR_OK
    [[ "${BR_OK,,}" == "y" ]] || die "Aborted. Re-run and choose vmbr3."
fi

read -rp "  IP address in CIDR [10.20.20.30/24]: " IP_CIDR
IP_CIDR="${IP_CIDR:-10.20.20.30/24}"
[[ "$IP_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "Expected CIDR notation, e.g. 10.20.20.30/24"
IP_ADDR="${IP_CIDR%%/*}"

read -rp "  Gateway [10.20.20.1]: " GATEWAY
GATEWAY="${GATEWAY:-10.20.20.1}"
[[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Gateway must be an IPv4 address"

echo ""
echo -e "${BOLD}DVWA security level${RESET}"
echo "  low        Classic training target. Most exercises work as documented."
echo "  medium     Partial filtering, for practising bypasses."
echo "  high       Stronger filtering, still vulnerable."
echo "  impossible Patched. Useful as a reference for secure implementations."
echo ""
read -rp "  Default security level [low]: " SEC_LEVEL
SEC_LEVEL="${SEC_LEVEL:-low}"
case "$SEC_LEVEL" in
    low|medium|high|impossible) ;;
    *) die "Invalid security level: $SEC_LEVEL" ;;
esac

read -rsp "  Container root password: " ROOT_PASS
echo ""
[[ -z "$ROOT_PASS" ]] && die "Password cannot be empty"
[[ ${#ROOT_PASS} -lt 8 ]] && die "Use at least 8 characters"
read -rsp "  Confirm password: " ROOT_PASS2
echo ""
[[ "$ROOT_PASS" == "$ROOT_PASS2" ]] || die "Passwords do not match"

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

echo ""
info "Discovering storage pools that accept container root filesystems"
STORAGE_NAMES=()
while IFS= read -r sname; do
    [[ -n "$sname" ]] && STORAGE_NAMES+=("$sname")
done < <(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')

[[ ${#STORAGE_NAMES[@]} -eq 0 ]] && die "No active storage pools with 'rootdir' content found"

echo ""
printf "  %-4s  %-20s  %-10s  %-14s\n" "NUM" "NAME" "TYPE" "AVAILABLE"
printf "  %-4s  %-20s  %-10s  %-14s\n" "---" "--------------------" "----------" "--------------"
idx=1
for storage in "${STORAGE_NAMES[@]}"; do
    stype=$(pvesm status 2>/dev/null | awk -v s="$storage" '$1==s {print $2}')
    # pvesm status columns: Name Type Status Total Used Available %
    savail=$(pvesm status 2>/dev/null | awk -v s="$storage" '$1==s {print $6}')
    printf "  %-4d  %-20s  %-10s  %-14s\n" "$idx" "$storage" "$stype" "${savail:-n/a}"
    idx=$((idx + 1))
done
echo ""

storage_choice=1
if [[ ${#STORAGE_NAMES[@]} -gt 1 ]]; then
    read -rp "  Select storage number [1]: " storage_choice
    storage_choice="${storage_choice:-1}"
fi
[[ "$storage_choice" =~ ^[0-9]+$ ]] || die "Invalid selection"
[[ "$storage_choice" -ge 1 && "$storage_choice" -le ${#STORAGE_NAMES[@]} ]] \
    || die "Invalid storage selection: choose 1 to ${#STORAGE_NAMES[@]}"
STORAGE="${STORAGE_NAMES[$((storage_choice - 1))]}"

# ---------------------------------------------------------------------------
# Template
# ---------------------------------------------------------------------------

echo ""
info "Locating a Debian 12 LXC template"
TEMPLATE_PATH="$(find /var/lib/vz/template/cache/ -maxdepth 1 -name 'debian-12-standard*.tar.*' 2>/dev/null | sort -V | tail -1)"

if [[ -z "$TEMPLATE_PATH" ]]; then
    info "Not found locally, refreshing the template list"
    pveam update >/dev/null 2>&1 || warn "pveam update reported problems"
    TEMPLATE_NAME="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/ {print $2; exit}')"
    [[ -n "$TEMPLATE_NAME" ]] || die "No debian-12-standard template available. Check: pveam available"
    info "Downloading $TEMPLATE_NAME"
    pveam download local "$TEMPLATE_NAME" >/dev/null 2>&1 || die "Template download failed"
    TEMPLATE_PATH="$(find /var/lib/vz/template/cache/ -maxdepth 1 -name 'debian-12-standard*.tar.*' 2>/dev/null | sort -V | tail -1)"
fi

[[ -f "$TEMPLATE_PATH" ]] || die "Debian 12 template not found"
TEMPLATE_REF="local:vztmpl/$(basename "$TEMPLATE_PATH")"
ok "Using $(basename "$TEMPLATE_PATH")"

# Debian 12 ships PHP 8.2, which DVWA supports cleanly. Debian 13's PHP 8.4 is
# newer than DVWA targets, so this script pins Debian 12 deliberately.

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}Configuration Summary:${RESET}"
printf "  %-20s  %s\n" "CTID:" "$CTID"
printf "  %-20s  %s\n" "Hostname:" "$HOSTNAME"
printf "  %-20s  %s MB, %s cores, %s GB\n" "Resources:" "$MEMORY_MB" "$CPU_CORES" "$DISK_GB"
printf "  %-20s  %s\n" "Storage:" "$STORAGE"
printf "  %-20s  %s\n" "Bridge:" "$BRIDGE"
printf "  %-20s  %s\n" "Address:" "$IP_CIDR"
printf "  %-20s  %s\n" "Gateway:" "$GATEWAY"
printf "  %-20s  %s\n" "Security level:" "$SEC_LEVEL"
printf "  %-20s  %s\n" "Start on boot:" "no (deliberate)"
echo ""
read -rp "  Create this container? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || { info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Create
#
# onboot 0 is deliberate. A vulnerable target should be something you start when
# you intend to use it, not something that quietly comes back after every reboot.
# ---------------------------------------------------------------------------

echo ""
info "Creating LXC $CTID ($HOSTNAME)"
pct create "$CTID" "$TEMPLATE_REF" \
    --hostname "$HOSTNAME" \
    --memory "$MEMORY_MB" \
    --cores "$CPU_CORES" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}" \
    --nameserver "$GATEWAY" \
    --password "$ROOT_PASS" \
    --unprivileged 1 \
    --onboot 0 \
    --description "DVWA practice target. Intentionally vulnerable. DMZ only." \
    || die "pct create failed"
unset ROOT_PASS ROOT_PASS2
ok "Container created"

info "Starting container"
pct start "$CTID" || die "Failed to start container $CTID"

info "Waiting for network"
NET_UP=0
for _ in {1..30}; do
    if pct exec "$CTID" -- ping -c 1 -W 1 "$GATEWAY" &>/dev/null; then NET_UP=1; break; fi
    sleep 1
done
[[ "$NET_UP" -eq 1 ]] && ok "Gateway $GATEWAY reachable" \
    || warn "Gateway $GATEWAY not reachable yet, package installs may fail"

# ---------------------------------------------------------------------------
# Provision
#
# The install runs from a script pushed into the container rather than a long
# chain of 'pct exec -- bash -c', which keeps the quoting readable and lets the
# provisioning step fail loudly on its own set -euo pipefail.
# ---------------------------------------------------------------------------

# Do not write this as 'tr -dc ... </dev/urandom | head -c 24'. head exits as
# soon as it has its bytes, tr dies on SIGPIPE with status 141, and under
# 'set -euo pipefail' that aborts the whole script with no message at all.
# Read a bounded block, filter it in full, then slice in the shell.
DB_PASS_RAW="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
DB_PASS="${DB_PASS_RAW:0:24}"
unset DB_PASS_RAW
[[ ${#DB_PASS} -eq 24 ]] || die "Failed to generate a database password"

PROVISION_SRC="$(mktemp)"
cat > "$PROVISION_SRC" <<'PROVEOF'
#!/bin/bash
set -euo pipefail

DB_PASS="$1"
SEC_LEVEL="$2"
DVWA_REPO="$3"
DVWA_DIR="/var/www/html/DVWA"

export DEBIAN_FRONTEND=noninteractive

echo "[provision] Installing packages"
apt-get update -qq
apt-get install -y -qq \
    apache2 mariadb-server git curl ca-certificates \
    php php-mysqli php-gd php-xml php-mbstring libapache2-mod-php

# MariaDB's packaged unit uses systemd sandboxing - ProtectSystem=full,
# ProtectHome=true and, critically, ProtectControlGroups=true - which all need
# mount-namespace operations that an unprivileged LXC is not permitted to make.
# Without this drop-in the service dies with:
#
#   Failed to set up mount namespacing: /run/systemd/unit-root/proc: Permission denied
#   Failed at step NAMESPACE spawning /bin/sh: Permission denied
#   status=226/NAMESPACE
#
# and every later step fails looking like a database problem. Relaxing the
# sandboxing is acceptable here specifically because this host is a deliberately
# vulnerable target; do not copy this drop-in onto a real database server.
echo "[provision] Relaxing MariaDB systemd sandboxing for unprivileged LXC"
mkdir -p /etc/systemd/system/mariadb.service.d
cat > /etc/systemd/system/mariadb.service.d/override.conf <<'DROPIN'
[Service]
ProtectSystem=false
ProtectHome=false
ProtectControlGroups=false
PrivateDevices=false
ProtectProc=default
ProcSubset=all
DROPIN
systemctl daemon-reload

echo "[provision] Starting services"
systemctl enable mariadb apache2 >/dev/null 2>&1 || true

# dpkg could not start these during install ("Could not execute systemctl" from
# deb-systemd-invoke), so start them explicitly and fail loudly if they refuse.
if ! systemctl restart mariadb; then
    echo "[provision] mariadb failed to start:" >&2
    journalctl -u mariadb --no-pager -n 20 >&2
    exit 1
fi
if ! systemctl restart apache2; then
    echo "[provision] apache2 failed to start:" >&2
    journalctl -u apache2 --no-pager -n 20 >&2
    exit 1
fi

# Wait for the socket rather than assuming it is up the instant systemd returns.
for _ in $(seq 1 30); do
    mysqladmin ping >/dev/null 2>&1 && break
    sleep 1
done
mysqladmin ping >/dev/null 2>&1 || { echo "[provision] MariaDB is not answering on its socket" >&2; exit 1; }
echo "[provision] MariaDB and Apache are up"

echo "[provision] Cloning DVWA"
rm -rf "$DVWA_DIR"
git clone --depth 1 "$DVWA_REPO" "$DVWA_DIR"

echo "[provision] Writing config.inc.php"
cd "$DVWA_DIR"
cp config/config.inc.php.dist config/config.inc.php

# Rewrite the assignment side only, so the PHP array syntax is preserved
# whatever spacing upstream is using this week.
sed -i "s|\(\$_DVWA\[ *'db_user' *\] *= *\).*|\1'dvwa';|"              config/config.inc.php
sed -i "s|\(\$_DVWA\[ *'db_password' *\] *= *\).*|\1'${DB_PASS}';|"    config/config.inc.php
sed -i "s|\(\$_DVWA\[ *'db_database' *\] *= *\).*|\1'dvwa';|"          config/config.inc.php
sed -i "s|\(\$_DVWA\[ *'db_server' *\] *= *\).*|\1'127.0.0.1';|"       config/config.inc.php
sed -i "s|\(\$_DVWA\[ *'default_security_level' *\] *= *\).*|\1'${SEC_LEVEL}';|" config/config.inc.php

grep -q "'${DB_PASS}'" config/config.inc.php || { echo "[provision] config.inc.php rewrite failed" >&2; exit 1; }

echo "[provision] Creating the database"
mysql -u root -e "CREATE DATABASE IF NOT EXISTS dvwa;"
mysql -u root -e "DROP USER IF EXISTS 'dvwa'@'127.0.0.1';"
mysql -u root -e "CREATE USER 'dvwa'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON dvwa.* TO 'dvwa'@'127.0.0.1';"
mysql -u root -e "FLUSH PRIVILEGES;"

echo "[provision] Applying DVWA's required PHP settings"
# DVWA's RFI exercises need these. They are exactly the settings you would flag
# in a real assessment, which is the point of the exercise.
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
APACHE_INI="/etc/php/${PHP_VER}/apache2/php.ini"
if [[ -f "$APACHE_INI" ]]; then
    cp -a "$APACHE_INI" "${APACHE_INI}.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i 's|^ *;* *allow_url_include *=.*|allow_url_include = On|'         "$APACHE_INI"
    sed -i 's|^ *;* *allow_url_fopen *=.*|allow_url_fopen = On|'             "$APACHE_INI"
    sed -i 's|^ *;* *display_errors *=.*|display_errors = On|'               "$APACHE_INI"
    sed -i 's|^ *;* *display_startup_errors *=.*|display_startup_errors = On|' "$APACHE_INI"
    grep -q '^allow_url_include = On' "$APACHE_INI" || echo 'allow_url_include = On' >> "$APACHE_INI"
    grep -q '^allow_url_fopen = On'   "$APACHE_INI" || echo 'allow_url_fopen = On'   >> "$APACHE_INI"
else
    echo "[provision] WARNING: $APACHE_INI not found, RFI exercises may not work" >&2
fi

echo "[provision] Setting ownership"
mkdir -p hackable/uploads
mkdir -p config
# www-data owns the tree, so Apache can write the upload and log paths DVWA
# needs without resorting to world-writable permissions.
chown -R www-data:www-data "$DVWA_DIR"
find "$DVWA_DIR" -type d -exec chmod 755 {} +
find "$DVWA_DIR" -type f -exec chmod 644 {} +
chmod 640 config/config.inc.php

# Convenience redirect so the bare IP lands on the app.
printf '%s\n' '<meta http-equiv="refresh" content="0; url=/DVWA/">' > /var/www/html/index.html
chown www-data:www-data /var/www/html/index.html

systemctl restart apache2

echo "[provision] Initialising the DVWA schema"
# setup.php is the documented way to build the schema. Drive it over loopback
# rather than making the operator click a button, but do not treat a failure
# here as fatal: the button still works.
JAR="$(mktemp)"
SETUP_URL="http://127.0.0.1/DVWA/setup.php"
TOKEN="$(curl -fsS -c "$JAR" "$SETUP_URL" 2>/dev/null \
    | grep -oE "user_token'[^>]*value='[a-f0-9]{32}'" \
    | grep -oE '[a-f0-9]{32}' | head -1 || true)"

if [[ -n "$TOKEN" ]]; then
    curl -fsS -b "$JAR" -c "$JAR" \
        --data-urlencode "create_db=Create / Reset Database" \
        --data-urlencode "user_token=${TOKEN}" \
        "$SETUP_URL" >/dev/null 2>&1 || true
else
    curl -fsS -b "$JAR" -c "$JAR" \
        --data-urlencode "create_db=Create / Reset Database" \
        "$SETUP_URL" >/dev/null 2>&1 || true
fi
rm -f "$JAR"

USER_COUNT="$(mysql -N -B -u root -e "SELECT COUNT(*) FROM dvwa.users;" 2>/dev/null || echo 0)"
if [[ "${USER_COUNT:-0}" -ge 1 ]]; then
    echo "[provision] Schema initialised, ${USER_COUNT} demo users present"
else
    echo "[provision] Schema not initialised automatically."
    echo "[provision] Browse to /DVWA/setup.php and click Create / Reset Database."
fi

# Record the generated database password for the operator, root-only.
umask 077
cat > /root/dvwa-credentials.txt <<CREDEOF
DVWA deployment details
Generated: $(date '+%Y-%m-%d %H:%M:%S')

Database
  host      127.0.0.1
  database  dvwa
  user      dvwa
  password  ${DB_PASS}

Application login (DVWA defaults, intentionally weak)
  username  admin
  password  password

Config file: ${DVWA_DIR}/config/config.inc.php
Reset schema: browse to /DVWA/setup.php and click Create / Reset Database
CREDEOF
chmod 600 /root/dvwa-credentials.txt

echo "[provision] Done"
PROVEOF

info "Pushing the provisioning script into the container"
pct push "$CTID" "$PROVISION_SRC" /root/provision-dvwa.sh --perms 700 \
    || die "Failed to push the provisioning script"

echo ""
info "Provisioning DVWA, this takes a few minutes"
echo ""
if pct exec "$CTID" -- bash /root/provision-dvwa.sh "$DB_PASS" "$SEC_LEVEL" "$DVWA_REPO"; then
    ok "DVWA provisioned"
else
    die "Provisioning failed. Inspect with: pct exec $CTID -- bash"
fi

pct exec "$CTID" -- rm -f /root/provision-dvwa.sh || true

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo ""
info "Verifying"

pct exec "$CTID" -- systemctl is-active --quiet apache2 \
    && ok "Apache running" || warn "Apache not running"
pct exec "$CTID" -- systemctl is-active --quiet mariadb \
    && ok "MariaDB running" || warn "MariaDB not running"

HTTP_CODE="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/DVWA/login.php" 2>/dev/null || echo "000")"
if [[ "$HTTP_CODE" == "200" ]]; then
    ok "DVWA login page responding (HTTP 200)"
else
    warn "DVWA login page returned HTTP $HTTP_CODE"
    warn "Investigate: pct exec $CTID -- tail -50 /var/log/apache2/error.log"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
ok "DVWA target ready at CT $CTID"
echo ""
echo -e "${BOLD}Access${RESET}"
printf "  %-20s  %s\n" "URL:" "http://${IP_ADDR}/DVWA/"
printf "  %-20s  %s\n" "Username:" "admin"
printf "  %-20s  %s\n" "Password:" "password"
printf "  %-20s  %s\n" "Security level:" "$SEC_LEVEL"
echo ""
echo -e "  DVWA's app credentials are weak by design. Leave them alone."
echo -e "  The generated database password is in the container at:"
echo -e "    /root/dvwa-credentials.txt  (mode 600)"
echo ""
echo -e "${BOLD}Reach it from Kali${RESET}"
echo "  Kali's DMZ interface (10.20.20.20) is on this bridge, so DVWA is"
echo "  reachable on-link, without traversing OPNsense:"
echo "    curl -I http://${IP_ADDR}/DVWA/login.php"
echo "    nmap -sV -p 80,3306 ${IP_ADDR}"
echo ""
echo -e "${BOLD}Keep it contained${RESET}"
echo "  Confirm these OPNsense rules before you start attacking it:"
echo "    1. Block DMZ -> Internal (protects the DC, Pi-hole, Docker LXC)"
echo "    2. Block DMZ -> Management (192.168.1.0/24)"
echo "    3. Block DMZ -> WAN once provisioning is done, so a shell on DVWA"
echo "       cannot call out. Re-enable it temporarily when you need apt."
echo "    4. Never forward a port to ${IP_ADDR} from your home router."
echo ""
echo -e "${BOLD}Lifecycle${RESET}"
echo "  Start:   pct start $CTID"
echo "  Stop:    pct stop $CTID        (do this when you are done)"
echo "  Console: pct exec $CTID -- bash"
echo "  Destroy: pct stop $CTID && pct destroy $CTID"
echo ""
echo "  This container does not start on boot, which is deliberate."
echo ""

# Restore-point guidance depends on the storage type. Thick LVM cannot snapshot,
# and printing a command that fails is worse than printing none, so check first.
STORAGE_TYPE="$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1==s {print $2}')"
case "$STORAGE_TYPE" in
    lvmthin|zfspool|dir|btrfs|cephfs|rbd)
        echo -e "${BOLD}Take a restore point before you break it${RESET}"
        echo "  Storage '$STORAGE' is type '$STORAGE_TYPE', which supports snapshots:"
        echo "    pct snapshot $CTID clean --description 'Fresh DVWA install'"
        echo "    pct rollback $CTID clean"
        ;;
    lvm)
        echo -e "${BOLD}Take a restore point before you break it${RESET}"
        warn "Storage '$STORAGE' is thick LVM, which does NOT support snapshots."
        echo "  'pct snapshot' will fail here. Use a backup instead:"
        echo "    pct stop $CTID"
        echo "    vzdump $CTID --storage local --mode stop --compress zstd"
        echo "    pct start $CTID"
        echo ""
        echo "  Restore over the wrecked container:"
        echo "    pct stop $CTID"
        echo "    pct restore $CTID /var/lib/vz/dump/vzdump-lxc-${CTID}-TIMESTAMP.tar.zst --force"
        echo "    pct start $CTID"
        echo ""
        echo "  For the faster snapshot workflow, rebuild on an lvmthin pool."
        ;;
    *)
        echo -e "${BOLD}Take a restore point before you break it${RESET}"
        echo "  Storage '$STORAGE' is type '${STORAGE_TYPE:-unknown}'."
        echo "  Try 'pct snapshot $CTID clean'. If it reports that snapshots are"
        echo "  unsupported, use 'vzdump $CTID --storage local --mode stop' instead."
        ;;
esac
echo ""
