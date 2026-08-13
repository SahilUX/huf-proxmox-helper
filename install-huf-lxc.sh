#!/usr/bin/env bash
# Container-side installer. It is started by ct/huf.sh through Community Scripts build.func.
set -Eeuo pipefail

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

FRAPPE_MAJOR="${FRAPPE_MAJOR:-15}"
HUF_REPO="${HUF_REPO:-https://github.com/tridz-dev/huf.git}"
HUF_REF="${HUF_REF:-develop}"
SITE_NAME="huf.local"
BENCH_ROOT="/opt/frappe-bench"
CREDS_FILE="/root/huf.credentials"

run_frappe() { sudo -H -u frappe env HOME=/home/frappe PATH="/home/frappe/.local/bin:/usr/local/bin:/usr/bin:/bin" bash -c "$1"; }

if [[ $FRAPPE_MAJOR == 16 && ${HUF_ALLOW_UNSUPPORTED_V16:-0} != 1 ]]; then
  die "HUF on Frappe 16 is blocked because current HUF LiteLLM constraints conflict with Frappe 16's Python 3.14 runtime. Choose 14 or 15, or set HUF_ALLOW_UNSUPPORTED_V16=1 only after upstream compatibility is confirmed."
fi

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
motd_ssh
customize
cleanup_lxc
