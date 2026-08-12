#!/usr/bin/env bash
# HUF native Frappe Bench LXC installer for Proxmox VE.
# Inspired by Community Scripts conventions, but self-contained for local testing.
# Run on the Proxmox host as root: bash install-huf-lxc.sh
set -Eeuo pipefail

APP="HUF"
HUF_REPO="${HUF_REPO:-https://github.com/tridz-dev/huf.git}"
HUF_REF="${HUF_REF:-develop}"
DEFAULT_CORES="${HUF_CORES:-4}"
DEFAULT_MEMORY="${HUF_MEMORY:-4096}"
DEFAULT_SWAP="${HUF_SWAP:-1024}"
DEFAULT_DISK="${HUF_DISK:-30}"
DEFAULT_HOSTNAME="${HUF_HOSTNAME:-huf}"
DEFAULT_TAGS="${HUF_TAGS:-ai;automation}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
require_root() { [[ ${EUID} -eq 0 ]] || die "Run this script as root on the Proxmox host."; }
require_pve() { command -v pct >/dev/null && command -v pveam >/dev/null || die "This does not appear to be a Proxmox VE host."; }
ask() { local prompt=$1 default=$2 answer; read -r -p "$prompt [$default]: " answer; printf '%s' "${answer:-$default}"; }

cleanup() {
  [[ -n ${INSTALLER_FILE:-} ]] && rm -f "$INSTALLER_FILE"
}
trap cleanup EXIT

require_root
require_pve

cat <<'BANNER'
HUF native Frappe Bench installer

This creates one unprivileged Ubuntu LXC and installs a fresh HUF site.
It never restores the old HUF database or Docker state.

Compatibility policy, checked against the HUF upstream source on 2026-08-13:
  - Frappe 15 is the recommended stable HUF target.
  - Frappe 14 is a legacy/experimental HUF option.
  - Frappe 16 requires Python 3.14, but HUF's current LiteLLM constraint is
    incompatible with Python 3.14. It is deliberately blocked by default.
BANNER

while true; do
  read -r -p "Choose Frappe Bench major version (14, 15, 16) [15]: " FRAPPE_MAJOR
  FRAPPE_MAJOR=${FRAPPE_MAJOR:-15}
  [[ $FRAPPE_MAJOR =~ ^(14|15|16)$ ]] && break
  echo "Enter 14, 15, or 16."
done

if [[ $FRAPPE_MAJOR == 16 && ${HUF_ALLOW_UNSUPPORTED_V16:-0} != 1 ]]; then
  die "HUF on Frappe 16 is currently blocked: HUF's pinned LiteLLM range does not support Python 3.14. Use 15, or rerun only after an upstream-compatible HUF/LiteLLM release with HUF_ALLOW_UNSUPPORTED_V16=1."
fi

CTID=$(ask "Container ID" "100")
[[ $CTID =~ ^[0-9]+$ ]] || die "Container ID must be numeric."
pct status "$CTID" >/dev/null 2>&1 && die "CT $CTID already exists."
HOSTNAME=$(ask "Container hostname" "$DEFAULT_HOSTNAME")
CORES=$(ask "CPU cores" "$DEFAULT_CORES")
MEMORY=$(ask "Memory in MiB" "$DEFAULT_MEMORY")
SWAP=$(ask "Swap in MiB" "$DEFAULT_SWAP")
DISK=$(ask "Disk in GiB" "$DEFAULT_DISK")
ROOTFS_STORAGE=$(ask "Root filesystem storage" "local-lvm")
TEMPLATE_STORAGE=$(ask "Template storage" "local")
TAGS=$(ask "Proxmox tags (semicolon-separated)" "$DEFAULT_TAGS")
NETWORK=$(ask "Network bridge" "vmbr0")
IPCONF=$(ask "IPv4 configuration (dhcp or CIDR, e.g. 192.168.1.130/24)" "dhcp")
GATEWAY=""
if [[ $IPCONF != dhcp ]]; then
  GATEWAY=$(ask "IPv4 gateway" "192.168.1.1")
fi

TEMPLATE=$(pveam available --section system 2>/dev/null | awk '/ubuntu-24\.04-standard/ {print $2}' | sort -V | tail -1)
[[ -n $TEMPLATE ]] || die "Unable to find an Ubuntu 24.04 LXC template in pveam available. Run: pveam update"

log "Downloading Ubuntu template if needed"
pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" || pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"

NET0="name=eth0,bridge=$NETWORK,ip=$IPCONF"
[[ -n $GATEWAY ]] && NET0+=",gw=$GATEWAY"

log "Creating CT $CTID ($HOSTNAME)"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "$ROOTFS_STORAGE:${DISK}" \
  --net0 "$NET0" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --tags "$TAGS" \
  --onboot 1 \
  --ostype ubuntu
pct start "$CTID"

log "Waiting for network"
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1; then break; fi
  sleep 2
done
pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1 || die "CT $CTID cannot resolve github.com. Fix the LXC network/DNS, then run the installer payload manually from /root/huf-install.sh."

INSTALLER_FILE=$(mktemp /tmp/huf-install.XXXXXX.sh)
cat >"$INSTALLER_FILE" <<'INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail

FRAPPE_MAJOR="$1"
HUF_REPO="$2"
HUF_REF="$3"
SITE_NAME="huf.local"
BENCH_ROOT="/opt/frappe-bench"
CREDS_FILE="/root/huf.credentials"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
run_frappe() { sudo -H -u frappe env HOME=/home/frappe PATH="/home/frappe/.local/bin:/usr/local/bin:/usr/bin:/bin" bash -c "$1"; }

case "$FRAPPE_MAJOR" in
  14) PYTHON_VERSION=3.11; NODE_MAJOR=18 ;;
  15) PYTHON_VERSION=3.12; NODE_MAJOR=18 ;;
  16) PYTHON_VERSION=3.14; NODE_MAJOR=24 ;;
  *) die "Unsupported Frappe major: $FRAPPE_MAJOR" ;;
esac

log "Installing operating-system dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y dist-upgrade
apt-get install -y \
  acl build-essential ca-certificates cron curl fail2ban fontconfig git gnupg \
  libffi-dev libfontconfig1 libjpeg-dev libmariadb-dev libssl-dev libxrender1 \
  mariadb-client mariadb-server nginx pkg-config python3-dev python3-pip \
  redis-server sudo supervisor xvfb

log "Installing Node.js $NODE_MAJOR and Yarn 1.22.22"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y nodejs
corepack enable
corepack prepare yarn@1.22.22 --activate

log "Installing wkhtmltopdf"
# Ubuntu's package is adequate for standard Frappe print output. It avoids a distro-mismatched .deb.
apt-get install -y wkhtmltopdf

log "Configuring MariaDB for Frappe"
cat >/etc/mysql/mariadb.conf.d/99-frappe.cnf <<'EOF'
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
character-set-client-handshake = FALSE
max_allowed_packet = 256M

[mysql]
default-character-set = utf8mb4
EOF
systemctl restart mariadb

log "Enabling Redis memory-overcommit setting"
cat >/etc/sysctl.d/99-huf-redis.conf <<'EOF'
vm.overcommit_memory = 1
EOF
sysctl --system >/dev/null

log "Creating the dedicated frappe account"
id frappe >/dev/null 2>&1 || useradd --create-home --home-dir /home/frappe --shell /bin/bash frappe
install -d -o frappe -g frappe -m 0755 /opt
cat >/etc/sudoers.d/frappe <<'EOF'
frappe ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/frappe

log "Installing uv, Bench, and Python $PYTHON_VERSION"
sudo -H -u frappe env HOME=/home/frappe bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
run_frappe "uv tool install frappe-bench"
run_frappe "uv python install $PYTHON_VERSION"
PYTHON_BIN=$(run_frappe "uv python find $PYTHON_VERSION")

log "Initializing Frappe $FRAPPE_MAJOR Bench"
run_frappe "cd /opt && bench init frappe-bench --frappe-branch version-$FRAPPE_MAJOR --python '$PYTHON_BIN'"

log "Starting Bench Redis services for site creation"
sudo -H -u frappe redis-server "$BENCH_ROOT/config/redis_queue.conf" --daemonize yes
sudo -H -u frappe redis-server "$BENCH_ROOT/config/redis_cache.conf" --daemonize yes
sleep 2

log "Generating local-only credentials"
ADMIN_PASSWORD=$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 24)
DB_ROOT_PASSWORD=$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 24)
umask 077
cat >"$CREDS_FILE" <<EOF
HUF credentials, generated $(date -Is)

URL: http://$(hostname -I | awk '{print $1}')/
Username: Administrator
Administrator password: $ADMIN_PASSWORD
MariaDB root password: $DB_ROOT_PASSWORD
Site: $SITE_NAME
Bench: $BENCH_ROOT

Print these credentials again with:
  sudo cat $CREDS_FILE
EOF
chmod 600 "$CREDS_FILE"

mariadb -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL

log "Creating fresh HUF site"
run_frappe "cd '$BENCH_ROOT' && bench new-site '$SITE_NAME' --db-root-username root --db-root-password '$DB_ROOT_PASSWORD' --admin-password '$ADMIN_PASSWORD' --set-default"

log "Getting HUF source ($HUF_REF)"
run_frappe "cd '$BENCH_ROOT' && bench get-app huf '$HUF_REPO' --branch '$HUF_REF'"

log "Installing HUF and application requirements"
run_frappe "cd '$BENCH_ROOT' && bench --site '$SITE_NAME' install-app huf"
run_frappe "cd '$BENCH_ROOT' && bench setup requirements"
run_frappe "cd '$BENCH_ROOT' && bench --site '$SITE_NAME' migrate && bench build --production"

log "Configuring production services"
# bench setup production supplies supervisor and nginx definitions for this native bench.
run_frappe "uv tool install ansible"
ln -sf /home/frappe/.local/bin/ansible /usr/local/bin/ansible
ln -sf /home/frappe/.local/bin/ansible-playbook /usr/local/bin/ansible-playbook
cd "$BENCH_ROOT"
PATH="/home/frappe/.local/bin:$PATH" bench setup production frappe --yes
ln -sf "$BENCH_ROOT/config/supervisor.conf" /etc/supervisor/conf.d/frappe-bench.conf
supervisorctl reread
supervisorctl update
systemctl enable --now supervisor nginx redis-server

# This is a single-site LXC. Force the selected site for direct IP/LAN access,
# avoiding any client hosts-file entry such as "IP huf.local".
NGINX_CONF="/etc/nginx/conf.d/frappe-bench.conf"
[[ -f $NGINX_CONF ]] || die "Expected Bench Nginx config was not generated: $NGINX_CONF"
sed -i -E "s/server_name[[:space:]]+[^;]+;/server_name _;/" "$NGINX_CONF"
sed -i "s/proxy_set_header X-Frappe-Site-Name \$host;/proxy_set_header X-Frappe-Site-Name $SITE_NAME;/" "$NGINX_CONF"
nginx -t
systemctl reload nginx

log "Verifying HUF"
sleep 5
curl -fsS -o /dev/null -H "Host: $(hostname -I | awk '{print $1}')" http://127.0.0.1/ || die "Nginx/Frappe HTTP health check failed. Inspect: supervisorctl status; journalctl -u nginx -n 100"
run_frappe "cd '$BENCH_ROOT' && bench --site '$SITE_NAME' list-apps" | grep -qx huf || die "HUF is missing from the installed app list."

cat <<EOF

HUF installation completed successfully.

Open: http://$(hostname -I | awk '{print $1}')/
Credentials are intentionally not echoed by the installer.
To print the generated Administrator and MariaDB credentials locally, run:
  sudo cat $CREDS_FILE

Operational checks:
  sudo supervisorctl status
  sudo -u frappe bash -lc 'cd $BENCH_ROOT && bench --site $SITE_NAME doctor'
EOF

unset ADMIN_PASSWORD DB_ROOT_PASSWORD
INSTALLER
chmod 700 "$INSTALLER_FILE"
pct push "$CTID" "$INSTALLER_FILE" /root/huf-install.sh --perms 0700

log "Installing HUF inside CT $CTID"
pct exec "$CTID" -- /root/huf-install.sh "$FRAPPE_MAJOR" "$HUF_REPO" "$HUF_REF"

log "Completed"
printf '\nProxmox CT %s is ready.\n' "$CTID"
printf 'The installer generated credentials locally inside the LXC and does not echo them into the host install log.\n'
printf 'To print them on demand, run on the Proxmox host:\n  pct exec %s -- cat /root/huf.credentials\n' "$CTID"
