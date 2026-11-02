#!/usr/bin/env bash
# =============================================================================
#  server-manager.sh  v2.0.0
#  LAMP (Apache2 / MySQL-MariaDB / PHP-FPM) management toolkit for Ubuntu/Debian
#
#  Interactive:      sudo bash server-manager.sh
#  Non-interactive:  sudo bash server-manager.sh <command> [options]
#
#  Commands
#    menu                      Interactive menu (default)
#    status                    Read-only health report (changes nothing)
#    doctor                    Health report + automatic repairs
#    restart [target]          Safe restart: apache | reload | db | php | all
#    wp-version                Show the latest WordPress release (wordpress.org)
#    wp-download [locale]      Download + checksum-verify latest WordPress to cache
#    wp-update <path>          Update WordPress core of an existing site (backs up first)
#    backup <path> [dbname]    Backup site files (+ DB), then prune old backups
#    watchdog-install          Cron job: "doctor --yes --quiet --fast" every N minutes
#    watchdog-remove           Remove that cron job
#
#  Options
#    -y, --yes     Accept the default answer for every prompt (defaults for
#                  destructive actions are always "no")
#    -q, --quiet   Print only warnings/errors (for cron)
#    --fast        Skip checks that need internet access
#    --no-fix      Report only; never modify anything
#    -h, --help    -V, --version
#
#  Exit codes (status / doctor):  0 healthy   1 warnings   2 unresolved failures
#
#  Optional config: /etc/server-manager.conf  (root-owned, not group/world writable)
#  Plain shell assignments; any of these may be overridden:
#    WWW_ROOT=/var/www            WP_ROOT=/var/www/wp
#    BACKUP_DIR=/var/backups/server-manager   BACKUP_RETENTION_DAYS=14
#    WP_LOCALE=en_US              LE_EMAIL=you@example.com
#    DISK_WARN_PCT=85  DISK_CRIT_PCT=95  CERT_WARN_DAYS=14
#    ALERT_EMAIL=ops@example.com  ALERT_WEBHOOK=https://hooks.example/...
#    ALERT_COOLDOWN=3600          WATCHDOG_INTERVAL_MIN=5
# =============================================================================

set -uo pipefail

VERSION="2.0.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_NAME="${SCRIPT_PATH##*/}"

# ------------------------------- Defaults ------------------------------------
: "${WWW_ROOT:=/var/www}"
: "${WP_ROOT:=/var/www/wp}"
: "${VHOST_AVAILABLE:=/etc/apache2/sites-available}"
: "${VHOST_ENABLED:=/etc/apache2/sites-enabled}"
: "${APACHE_LOG_DIR:=/var/log/apache2}"
: "${BACKUP_DIR:=/var/backups/server-manager}"
: "${BACKUP_RETENTION_DAYS:=14}"
: "${CACHE_DIR:=/var/cache/server-manager}"
: "${STATE_DIR:=/var/lib/server-manager}"
: "${LOG_FILE:=/var/log/server-manager.log}"
: "${LOCK_FILE:=/run/lock/server-manager.lock}"
: "${HOSTS_FILE:=/etc/hosts}"
: "${WP_LOCALE:=en_US}"
: "${WP_VERSION_API:=https://api.wordpress.org/core/version-check/1.7/}"
: "${WP_SALT_API:=https://api.wordpress.org/secret-key/1.1/salt/}"
: "${LE_EMAIL:=}"
: "${DISK_WARN_PCT:=85}"
: "${DISK_CRIT_PCT:=95}"
: "${CERT_WARN_DAYS:=14}"
: "${ALERT_EMAIL:=}"
: "${ALERT_WEBHOOK:=}"
: "${ALERT_COOLDOWN:=3600}"
: "${WATCHDOG_INTERVAL_MIN:=5}"

WP_PHP_MODULES=(mysqli curl dom mbstring xml zip gd intl exif)

declare -A DIRECTIVE_MODULE=(
  [RewriteEngine]=rewrite [RewriteRule]=rewrite [RewriteCond]=rewrite [RewriteBase]=rewrite
  [Header]=headers [RequestHeader]=headers
  [ExpiresActive]=expires [ExpiresByType]=expires [ExpiresDefault]=expires
  [SSLEngine]=ssl [SSLCertificateFile]=ssl [SSLCertificateKeyFile]=ssl
  [ProxyPass]=proxy_http [ProxyPassReverse]=proxy_http [ProxyPassMatch]=proxy
  [AddOutputFilterByType]=filter [DeflateCompressionLevel]=deflate
)

# ------------------------------ Runtime state --------------------------------
ASSUME_YES=0; QUIET=0; FAST=0; AUTO_FIX=1
PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; FIX_COUNT=0
ISSUES=()
ROLLBACK=()
TMP_DIR=""
APT_UPDATED=0
APACHE_TEST_OUT=""
DB_CLIENT=""; DB_ARGS=(-u root)
WP_LATEST_VERSION=""; WP_DOWNLOAD_URL=""; WP_REQ_PHP=""; WP_REQ_MYSQL=""; WP_CORE_ARCHIVE=""
LAST_BACKUP_FILES=""; LAST_BACKUP_DB=""

# ------------------------------ Output & logging -----------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
  C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

_log()  { printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true; }
info()  { _log INFO "$*";  (( QUIET )) || printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()    { _log OK "$*";    (( QUIET )) || printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { _log WARN "$*";  printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { _log ERROR "$*"; printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { _log STEP "$*";  (( QUIET )) || printf '\n%s== %s ==%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
indent() { sed 's/^/       /'; }

# Check-result helpers (used by status/doctor)
c_ok()    { PASS_COUNT=$((PASS_COUNT + 1)); ok "$*"; }
c_warn()  { WARN_COUNT=$((WARN_COUNT + 1)); ISSUES+=("WARN: $*"); warn "$*"; }
c_fail()  { FAIL_COUNT=$((FAIL_COUNT + 1)); ISSUES+=("FAIL: $*"); err "$*"; }
c_fixed() { # kind(fail|warn) message
  FIX_COUNT=$((FIX_COUNT + 1)); ISSUES+=("FIXED: $2")
  if [[ "$1" == fail ]]; then (( FAIL_COUNT > 0 )) && FAIL_COUNT=$((FAIL_COUNT - 1))
  else (( WARN_COUNT > 0 )) && WARN_COUNT=$((WARN_COUNT - 1)); fi
  ok "FIXED: $2"
}
can_fix() { (( AUTO_FIX )) || return 1; confirm "$1" "${2:-y}"; }

# ------------------------------ Interaction ----------------------------------
# prompt "text" [default]  -> prints the answer on stdout (prompt goes to stderr)
prompt() {
  local text="$1" def="${2:-}" reply=""
  if (( ASSUME_YES )) || [[ ! -t 0 ]]; then printf '%s' "$def"; return 0; fi
  if [[ -n "$def" ]]; then printf '%s [%s]: ' "$text" "$def" >&2; else printf '%s: ' "$text" >&2; fi
  IFS= read -r reply || reply=""
  printf '%s' "${reply:-$def}"
}

# confirm "question" [y|n]  -> exit status 0 for yes. With --yes / no TTY the default is used.
confirm() {
  local q="$1" def="${2:-n}" reply hint="y/N"
  [[ "$def" == y ]] && hint="Y/n"
  if (( ASSUME_YES )) || [[ ! -t 0 ]]; then [[ "$def" == y ]]; return; fi
  printf '%s (%s): ' "$q" "$hint" >&2
  IFS= read -r reply || reply=""
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

pause() { [[ -t 0 ]] && read -rp "Press Enter to continue..." _ || true; }

# ------------------------------ Small utilities ------------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }
random_string()  { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-20}"; }

validate_domain() {
  local d="$1"
  (( ${#d} >= 1 && ${#d} <= 253 )) || return 1
  [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}
valid_docroot() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* ]]; }
valid_ident()   { [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]]; }
sql_escape()    { local s="${1//\\/\\\\}"; s="${s//\'/\\\'}"; printf '%s' "$s"; }

norm_ver() { awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 0 }' <<<"$1"; }
# version_ge A B  -> true if A >= B
version_ge() {
  local a b
  a=$(norm_ver "$1"); b=$(norm_ver "$2")
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" == "$b" ]]
}

curl_get() { curl -fsSL --connect-timeout 10 --max-time "${CURL_MAX_TIME:-120}" --retry 3 --retry-delay 2 "$@"; }

detect_web_user() {
  local u
  u=$(awk -F= '/^export APACHE_RUN_USER/ {print $2}' /etc/apache2/envvars 2>/dev/null | tr -d ' "\r')
  printf '%s' "${u:-www-data}"
}

# Never delete/chown anything outside the web roots (and never the roots themselves)
is_safe_site_path() {
  local p
  p=$(realpath -m -- "$1" 2>/dev/null) || return 1
  [[ "$p" == "$WP_ROOT" || "$p" == "$WWW_ROOT" ]] && return 1
  [[ "$p" == "$WWW_ROOT"/* || "$p" == "$WP_ROOT"/* ]]
}

# ------------------------------ Lifecycle ------------------------------------
check_root() { [[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $SCRIPT_NAME"; }

load_config() {
  local f="${SM_CONFIG:-/etc/server-manager.conf}" owner mode
  [[ -f "$f" ]] || return 0
  owner=$(stat -c '%u' "$f"); mode=$(stat -c '%a' "$f")
  if [[ "$owner" != "0" ]] || (( 8#$mode & 022 )); then
    warn "Ignoring $f: it must be owned by root and not writable by group/others"
    return 0
  fi
  # shellcheck disable=SC1090
  source "$f"
}

ensure_dirs() {
  mkdir -p "$WP_ROOT" "$BACKUP_DIR" "$CACHE_DIR" "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null
  chmod 700 "$BACKUP_DIR" "$STATE_DIR" 2>/dev/null
  touch "$LOG_FILE" 2>/dev/null && chmod 640 "$LOG_FILE" 2>/dev/null
  TMP_DIR=$(mktemp -d /tmp/server-manager.XXXXXX) || die "Cannot create a temporary directory"
}

acquire_lock() {
  command_exists flock || return 0
  exec 9>"$LOCK_FILE" || { warn "Cannot open $LOCK_FILE; continuing without a lock"; return 0; }
  if ! flock -n 9; then
    _log WARN "Another instance is running; exiting"
    err "Another server-manager instance is already running."
    exit 75
  fi
}

# Rollback stack for multi-step creations (entries: dir:/p  db:name  dbuser:name  vhost:domain)
run_rollback() {
  (( ${#ROLLBACK[@]} )) || return 0
  warn "Rolling back partial changes..."
  local i item kind arg
  for (( i = ${#ROLLBACK[@]} - 1; i >= 0; i-- )); do
    item="${ROLLBACK[$i]}"; kind="${item%%:*}"; arg="${item#*:}"
    case "$kind" in
      dir)    is_safe_site_path "$arg" && rm -rf -- "$arg" ;;
      db)     valid_ident "$arg" && db_sql "DROP DATABASE IF EXISTS \`${arg}\`;" >/dev/null 2>&1 ;;
      dbuser) valid_ident "$arg" && db_sql "DROP USER IF EXISTS '${arg}'@'localhost';" >/dev/null 2>&1 ;;
      vhost)  a2dissite "${arg}.conf" >/dev/null 2>&1; rm -f -- "$VHOST_AVAILABLE/${arg}.conf" ;;
    esac
  done
  ROLLBACK=()
  apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 >/dev/null 2>&1
  return 0
}

cleanup() {
  run_rollback
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
  return 0
}
on_interrupt() { echo; warn "Interrupted"; exit 130; }

# ------------------------------ Packages -------------------------------------
apt_install() {
  command_exists apt-get || { err "apt-get is not available on this system"; return 1; }
  if (( ! APT_UPDATED )); then
    apt-get -o DPkg::Lock::Timeout=120 update -qq >>"$LOG_FILE" 2>&1 || warn "apt-get update reported errors"
    APT_UPDATED=1
  fi
  info "Installing: $*"
  if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq "$@" >>"$LOG_FILE" 2>&1; then
    ok "Installed: $*"
  else
    err "Failed to install: $*"; tail -n 5 "$LOG_FILE" | indent; return 1
  fi
}

require_cmd() { # command package...
  local cmd="$1"; shift
  command_exists "$cmd" && return 0
  warn "'$cmd' is missing (package: $*)"
  confirm "Install $* now?" y || return 1
  apt_install "$@" && command_exists "$cmd"
}

# ------------------------------ Services -------------------------------------
svc_exists()     { systemctl cat "$1.service" >/dev/null 2>&1; }
list_fpm_units() { systemctl list-unit-files --type=service --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | sort -V; }
installed_fpm_versions() { list_fpm_units | sed -E 's/^php([0-9.]+)-fpm\.service$/\1/'; }
detect_db_service() {
  local u
  for u in mariadb mysql mysqld; do svc_exists "$u" && { printf '%s' "$u"; return 0; }; done
  return 1
}
svc_wait_active() { # unit [seconds]
  local i
  for (( i = 0; i < ${2:-10}; i++ )); do
    systemctl is-active --quiet "$1" && return 0
    sleep 1
  done
  return 1
}
svc_diagnose() { # unit
  journalctl -u "$1" -n 15 --no-pager -o cat 2>/dev/null | indent
  if [[ "$1" == mysql* || "$1" == maria* ]]; then
    local f
    for f in /var/log/mysql/error.log /var/log/mysql/mariadb.err; do
      [[ -r "$f" ]] && { echo "       --- $f"; tail -n 10 "$f" | indent; }
    done
  fi
}

ensure_service() { # start if not running, then verify
  local u="$1"
  systemctl is-active --quiet "$u" && return 0
  info "Starting $u ..."
  [[ "$u" == apache2 ]] && { apache_apply start; return; }
  systemctl reset-failed "$u" >/dev/null 2>&1
  systemctl enable "$u" >/dev/null 2>&1
  systemctl start "$u" >>"$LOG_FILE" 2>&1
  if svc_wait_active "$u" 15; then ok "$u started"; return 0; fi
  err "$u did not start:"; svc_diagnose "$u"; return 1
}

restart_service() {
  local u="$1"
  [[ "$u" == apache2 ]] && { apache_apply restart; return; }
  info "Restarting $u ..."
  systemctl reset-failed "$u" >/dev/null 2>&1
  if systemctl restart "$u" >>"$LOG_FILE" 2>&1 && svc_wait_active "$u" 15; then ok "$u restarted"; return 0; fi
  err "$u failed to restart:"; svc_diagnose "$u"; return 1
}

restart_all_fpm() {
  local u rc=0 n=0
  while read -r u; do
    [[ -n "$u" ]] || continue
    n=$((n + 1)); restart_service "${u%.service}" || rc=1
  done < <(list_fpm_units)
  (( n )) || info "No PHP-FPM services installed"
  return $rc
}

restart_target() {
  local t="${1:-all}" db rc=0
  case "$t" in
    apache) apache_apply restart || rc=1 ;;
    reload) apache_apply reload  || rc=1 ;;
    db|mysql|mariadb)
      db=$(detect_db_service) || { err "No MySQL/MariaDB service found"; return 1; }
      restart_service "$db" || rc=1 ;;
    php|fpm) restart_all_fpm || rc=1 ;;
    all) restart_target db || rc=1; restart_all_fpm || rc=1; apache_apply restart || rc=1 ;;
    *) err "Unknown target '$t' (apache | reload | db | php | all)"; return 2 ;;
  esac
  return $rc
}

# ------------------------------ Apache ---------------------------------------
apache_configtest() { APACHE_TEST_OUT=$(apache2ctl configtest 2>&1); }

# Safe, well-understood repairs. Returns 0 if it changed something.
apache_autofix() {
  local out="$APACHE_TEST_OUT" changed=1 d dir l conf=/etc/apache2/conf-available/servername.conf
  for dir in sites-enabled mods-enabled conf-enabled; do
    while IFS= read -r l; do
      [[ -n "$l" ]] || continue
      warn "Removing broken symlink: $l"; rm -f -- "$l"; changed=0
    done < <(find -L "/etc/apache2/$dir" -maxdepth 1 -type l 2>/dev/null)
  done
  d=$(sed -n "s/.*Invalid command '\([^']*\)'.*/\1/p" <<<"$out" | head -n1)
  if [[ -n "$d" && -n "${DIRECTIVE_MODULE[$d]:-}" ]]; then
    info "Enabling Apache module '${DIRECTIVE_MODULE[$d]}' (required by $d)"
    a2enmod "${DIRECTIVE_MODULE[$d]}" >>"$LOG_FILE" 2>&1 && changed=0
  fi
  if grep -q 'AH00558' <<<"$out"; then
    info "Setting a global ServerName to silence AH00558"
    if { [[ -f "$conf" ]] || printf 'ServerName localhost\n' >"$conf"; } && a2enconf servername >>"$LOG_FILE" 2>&1; then
      changed=0
    fi
  fi
  return $changed
}

# Test config (repairing known problems); never touch the running service if it's invalid.
apache_ensure_valid_config() {
  local _
  for _ in 1 2 3; do
    apache_configtest && return 0
    apache_autofix || break
  done
  err "Apache configuration is invalid. The running service was NOT touched:"
  printf '%s\n' "$APACHE_TEST_OUT" | grep -v '^$' | indent
  return 1
}

apache_port_conflict() {
  local p
  for p in 80 443; do
    ss -ltnp 2>/dev/null | awk -v p=":$p" '$4 ~ (p "$")' | grep -v apache2 | indent
  done
}

apache_apply() { # reload | restart | start
  local mode="${1:-reload}"
  apache_ensure_valid_config || return 1
  systemctl is-active --quiet apache2 || mode=start
  case "$mode" in
    reload)
      if ! systemctl reload apache2 >>"$LOG_FILE" 2>&1; then
        warn "Graceful reload failed; restarting"; systemctl restart apache2 >>"$LOG_FILE" 2>&1
      fi ;;
    *) systemctl "$mode" apache2 >>"$LOG_FILE" 2>&1 ;;
  esac
  if svc_wait_active apache2 10; then ok "Apache is running (after $mode)"; return 0; fi
  err "Apache is not running after $mode:"
  svc_diagnose apache2
  local conflicts; conflicts=$(apache_port_conflict)
  [[ -n "$conflicts" ]] && { warn "Another process is using port 80/443:"; printf '%s\n' "$conflicts"; }
  return 1
}

# ------------------------------ Apache vhost files ---------------------------
conf_directive() { # file Directive -> first value (quotes stripped)
  awk -v d="$(tr 'A-Z' 'a-z' <<<"$2")" 'tolower($1) == d { gsub(/"/, "", $2); print $2; exit }' "$1" 2>/dev/null
}
conf_php_version() {
  grep -oE 'php[0-9]+\.[0-9]+-fpm\.sock' "$1" 2>/dev/null | head -n1 | sed -E 's/^php([0-9.]+)-fpm\.sock$/\1/'
}
vhost_has_ssl() { [[ -e "$VHOST_ENABLED/${1}-le-ssl.conf" ]] || grep -qsi 'SSLCertificateFile' "$2"; }

# Prints "domain|docroot|conf" per distinct enabled site
list_sites() {
  local f name root seen=" "
  for f in "$VHOST_ENABLED"/*.conf; do
    [[ -e "$f" && "$f" != *-le-ssl.conf ]] || continue
    root=$(conf_directive "$f" DocumentRoot)
    [[ -n "$root" ]] || continue
    name=$(conf_directive "$f" ServerName)
    [[ -n "$name" ]] || name=$(basename "$f" .conf)
    [[ "$seen" == *" $name "* ]] && continue
    seen+="$name "
    printf '%s|%s|%s\n' "$name" "$root" "$f"
  done
}

write_vhost_conf() { # domain docroot phpver(or empty) www(0|1)
  local domain="$1" docroot="$2" phpver="$3" www="$4" alias_line="" handler=""
  (( www )) && alias_line="    ServerAlias www.${domain}"
  if [[ -n "$phpver" ]]; then
    handler=$(printf '    <FilesMatch "\\.php$">\n        SetHandler "proxy:unix:/run/php/php%s-fpm.sock|fcgi://localhost"\n    </FilesMatch>' "$phpver")
  fi
  cat >"$VHOST_AVAILABLE/${domain}.conf" <<EOF
<VirtualHost *:80>
    ServerName ${domain}
${alias_line}
    DocumentRoot ${docroot}
${handler}

    <Directory ${docroot}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex index.php index.html
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined
</VirtualHost>
EOF
}

# Enable a vhost; if it breaks Apache's config it is removed again so other sites stay up.
enable_vhost() { # domain phpver
  local domain="$1" phpver="${2:-}"
  a2ensite "${domain}.conf" >>"$LOG_FILE" 2>&1
  a2enmod rewrite >>"$LOG_FILE" 2>&1
  [[ -n "$phpver" ]] && a2enmod proxy_fcgi setenvif >>"$LOG_FILE" 2>&1
  if ! apache_ensure_valid_config; then
    err "The new VirtualHost breaks the Apache config - reverting so other sites stay online."
    a2dissite "${domain}.conf" >/dev/null 2>&1
    rm -f -- "$VHOST_AVAILABLE/${domain}.conf"
    return 1
  fi
  apache_apply reload
}

set_conf_php_version() { # file version|none
  local file="$1" ver="$2" tmp="$TMP_DIR/conf.$$"
  if [[ "$ver" == none ]]; then
    sed -E '/<FilesMatch "?\\.php\$"?>/,/<\/FilesMatch>/d' "$file" >"$tmp" && cat "$tmp" >"$file"
  elif grep -q 'proxy:unix:/run/php/php[0-9.]*-fpm\.sock' "$file"; then
    sed -i -E "s#/run/php/php[0-9.]+-fpm\.sock#/run/php/php${ver}-fpm.sock#g" "$file"
  else
    awk -v ver="$ver" '/<\/VirtualHost>/ { printf "    <FilesMatch \"\\.php$\">\n        SetHandler \"proxy:unix:/run/php/php%s-fpm.sock|fcgi://localhost\"\n    </FilesMatch>\n", ver } { print }' \
      "$file" >"$tmp" && cat "$tmp" >"$file"
  fi
}

# ------------------------------ HTTP / SSL helpers ---------------------------
http_status() { # host [port] [path]  -> status code (000 = no answer)
  local host="$1" port="${2:-80}" path="${3:-/}" scheme=http
  [[ "$port" == 443 ]] && scheme=https
  curl -sS -k -o /dev/null -m 15 -w '%{http_code}' --resolve "${host}:${port}:127.0.0.1" \
    "${scheme}://${host}${path}" 2>/dev/null || true
}

# Writes a throw-away PHP file, fetches it through Apache, removes it; prints the PHP version served.
php_probe() { # domain docroot
  local domain="$1" root="$2" name out
  name="sm-probe-$(random_string 12).php"
  printf '<?php echo PHP_VERSION;' >"$root/$name" || return 1
  chmod 644 "$root/$name"
  out=$(curl -sS -k -L -m 15 --resolve "${domain}:80:127.0.0.1" --resolve "${domain}:443:127.0.0.1" \
        "http://${domain}/${name}" 2>/dev/null)
  rm -f -- "$root/$name"
  [[ "$out" =~ ^[0-9]+\.[0-9]+ ]] && printf '%s' "$out"
}

cert_days_left() { # certfile
  local end
  end=$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2)
  [[ -n "$end" ]] || return 1
  echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

server_public_ip() { curl -4 -fsS -m 6 https://api.ipify.org 2>/dev/null; }
dns_ips()          { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; }

issue_ssl() { # domain www(0|1)
  local domain="$1" www="${2:-0}" ip n email names=() dargs=() eargs=()
  require_cmd certbot certbot python3-certbot-apache || return 1
  ip=$(server_public_ip)
  for n in "$domain" $( (( www )) && echo "www.$domain" ); do
    if [[ -z "$(dns_ips "$n")" ]]; then
      warn "$n has no DNS record yet - skipping it (certbot would fail)"; continue
    fi
    if [[ -n "$ip" ]] && ! dns_ips "$n" | grep -qx "$ip"; then
      warn "$n resolves to $(dns_ips "$n" | tr '\n' ' ')but this server looks like $ip (CDN/proxy, or DNS not updated?)"
      confirm "Request a certificate for $n anyway?" y || continue
    fi
    names+=("$n")
  done
  (( ${#names[@]} )) || { err "No domain is ready for a certificate. Point DNS at this server, then retry."; return 1; }
  for n in "${names[@]}"; do dargs+=(-d "$n"); done
  email=$(prompt "Email for Let's Encrypt expiry notices (blank = none)" "$LE_EMAIL")
  if [[ -n "$email" ]]; then eargs=(-m "$email"); else eargs=(--register-unsafely-without-email); fi
  info "Requesting certificate for: ${names[*]}"
  if certbot --apache --non-interactive --agree-tos --redirect "${eargs[@]}" "${dargs[@]}" >>"$LOG_FILE" 2>&1; then
    ok "SSL certificate installed for: ${names[*]}"
    apache_apply reload
  else
    err "certbot failed. Last lines of its log:"
    tail -n 12 /var/log/letsencrypt/letsencrypt.log 2>/dev/null | indent
    return 1
  fi
}

add_hosts_entry() { # domain [alias]
  local domain="$1" alias="${2:-}" entry
  grep -qE "(^|[[:space:]])${domain//./\\.}([[:space:]]|\$)" "$HOSTS_FILE" 2>/dev/null && { info "'$domain' already in $HOSTS_FILE"; return 0; }
  entry="127.0.0.1"$'\t'"${domain}"
  [[ -n "$alias" ]] && entry+=$'\t'"${alias}"
  printf '%s\n' "$entry" >>"$HOSTS_FILE" && ok "Added to $HOSTS_FILE: ${entry//$'\t'/ }"
}

remove_hosts_entry() { # removes only that hostname token; keeps other names on the line
  local d="$1"
  [[ -z "$d" || "$d" == localhost ]] && return 0
  grep -qE "(^|[[:space:]])${d//./\\.}([[:space:]]|\$)" "$HOSTS_FILE" 2>/dev/null || return 0
  cp -a "$HOSTS_FILE" "${HOSTS_FILE}.sm-bak" || return 1
  awk -v d="$d" '
    /^[[:space:]]*#/ { print; next }
    NF == 0 { print; next }
    { out = $1; n = 0
      for (i = 2; i <= NF; i++) if ($i != d) { out = out "\t" $i; n++ }
      if (n > 0 || NF == 1) print out }' "${HOSTS_FILE}.sm-bak" >"$HOSTS_FILE"
  ok "Removed '$d' from $HOSTS_FILE (backup: ${HOSTS_FILE}.sm-bak)"
}

# ------------------------------ Database -------------------------------------
db_init() {
  DB_CLIENT=""
  command_exists mariadb && DB_CLIENT=mariadb
  [[ -z "$DB_CLIENT" ]] && command_exists mysql && DB_CLIENT=mysql
  [[ -n "$DB_CLIENT" ]] || return 1
  DB_ARGS=(-u root)
  "$DB_CLIENT" "${DB_ARGS[@]}" -e 'SELECT 1' >/dev/null 2>&1 && return 0
  if [[ -r /etc/mysql/debian.cnf ]]; then
    DB_ARGS=(--defaults-file=/etc/mysql/debian.cnf)
    "$DB_CLIENT" "${DB_ARGS[@]}" -e 'SELECT 1' >/dev/null 2>&1 && return 0
  fi
  DB_ARGS=(-u root)
  return 1
}
# SQL goes through stdin so passwords never show up in the process list
db_sql() { printf '%s\n' "$1" | "$DB_CLIENT" "${DB_ARGS[@]}" -N -B; }
db_exists() { [[ -n "$(db_sql "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_escape "$1")';" 2>/dev/null)" ]]; }
db_user_exists() { [[ -n "$(db_sql "SELECT User FROM mysql.user WHERE User='$(sql_escape "$1")' AND Host='localhost';" 2>/dev/null)" ]]; }

dump_db() { # dbname outfile.sql.gz
  local tool=mysqldump
  command_exists mariadb-dump && tool=mariadb-dump
  command_exists "$tool" || { err "mysqldump is not installed"; return 1; }
  "$tool" "${DB_ARGS[@]}" --single-transaction --quick --routines --triggers --events "$1" | gzip >"$2"
}

# ------------------------------ PHP ------------------------------------------
php_module_pkg() {
  case "$1" in
    mysqli) echo mysql ;; dom|xml) echo xml ;; exif|openssl|fileinfo) echo common ;;
    *) echo "$1" ;;
  esac
}
php_missing_modules() { # version -> one missing module per line
  local ver="$1" bin mods m
  if command_exists "php-fpm${ver}"; then bin="php-fpm${ver}"
  elif command_exists "php${ver}"; then bin="php${ver}"
  else return 0; fi
  mods=$("$bin" -m 2>/dev/null | tr 'A-Z' 'a-z')
  for m in "${WP_PHP_MODULES[@]}"; do grep -qx "$m" <<<"$mods" || printf '%s\n' "$m"; done
}
ensure_php_modules() { # version
  local ver="$1" m pkg missing=() pkgs=()
  mapfile -t missing < <(php_missing_modules "$ver")
  (( ${#missing[@]} == 0 )) && return 0
  warn "PHP $ver is missing modules WordPress needs: ${missing[*]}"
  for m in "${missing[@]}"; do
    pkg="php${ver}-$(php_module_pkg "$m")"
    [[ " ${pkgs[*]} " == *" $pkg "* ]] || pkgs+=("$pkg")
  done
  confirm "Install ${pkgs[*]}?" y || return 1
  apt_install "${pkgs[@]}" || return 1
  restart_service "php${ver}-fpm" >/dev/null 2>&1
  mapfile -t missing < <(php_missing_modules "$ver")
  (( ${#missing[@]} == 0 )) && return 0
  err "Still missing after install: ${missing[*]}"; return 1
}
ensure_fpm() { # version
  local ver="$1" unit="php$1-fpm" i
  if ! svc_exists "$unit"; then
    warn "PHP-FPM $ver is not installed"
    confirm "Install php${ver}-fpm now?" y || return 1
    apt_install "php${ver}-fpm" || return 1
  fi
  ensure_service "$unit" || return 1
  for i in 1 2 3 4 5; do [[ -S "/run/php/php${ver}-fpm.sock" ]] && return 0; sleep 1; done
  err "Socket /run/php/php${ver}-fpm.sock did not appear (check /etc/php/${ver}/fpm/pool.d/www.conf)"
  return 1
}
detect_default_php() {
  local v=""
  command_exists php && v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
  if [[ -n "$v" ]] && svc_exists "php${v}-fpm"; then printf '%s' "$v"; return; fi
  installed_fpm_versions | tail -n1
}
apache_has_mod_php() { apache2ctl -M 2>/dev/null | grep -qi 'php.*_module'; }

# Prints the chosen version, or nothing for "no FPM handler" (mod_php / default)
ask_php_version() {
  local def installed
  installed=$(installed_fpm_versions | tr '\n' ' ')
  def=$(detect_default_php)
  if [[ -z "$def" ]] && ! apache_has_mod_php; then
    warn "No PHP handler found (neither PHP-FPM nor mod_php)." >&2
    if confirm "Install PHP-FPM with the modules WordPress needs?" y; then
      apt_install php-fpm php-mysql php-curl php-xml php-mbstring php-zip php-gd php-intl >&2 || return 1
      def=$(detect_default_php)
    fi
  fi
  [[ -n "$installed" ]] && echo "Installed PHP-FPM versions: $installed" >&2
  local v; v=$(prompt "PHP version (e.g. 8.3, or 'none' for mod_php/default)" "${def:-none}")
  [[ "$v" == none ]] && v=""
  [[ -z "$v" || "$v" =~ ^[0-9]+\.[0-9]+$ ]] || { err "Invalid PHP version '$v'" >&2; return 1; }
  printf '%s' "$v"
}

# ------------------------------ WordPress core -------------------------------
wp_resolve_latest() { # [locale]  -> sets WP_LATEST_VERSION, WP_DOWNLOAD_URL, WP_REQ_PHP, WP_REQ_MYSQL
  local locale="${1:-$WP_LOCALE}" json parsed
  local -a f
  command_exists python3 || { warn "python3 is required to parse the WordPress API response"; return 1; }
  json=$(curl_get "${WP_VERSION_API}?locale=${locale}") || return 1
  parsed=$(python3 -c '
import json, sys
try:
    o = json.load(sys.stdin)["offers"][0]
    for k in ("current", "download", "php_version", "mysql_version"):
        print(o.get(k) or "")
except Exception:
    sys.exit(1)
' <<<"$json") || return 1
  mapfile -t f <<<"$parsed"
  [[ "${f[0]:-}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
  [[ "${f[1]:-}" == https://* ]] || return 1
  WP_LATEST_VERSION="${f[0]}"; WP_DOWNLOAD_URL="${f[1]}"
  WP_REQ_PHP="${f[2]:-}"; WP_REQ_MYSQL="${f[3]:-}"
}

fetch_remote_hash() { # archive-url -> official checksum (sha1, else md5)
  local ext h
  for ext in sha1 md5; do
    h=$(curl_get "${1}.${ext}" 2>/dev/null | awk 'NR == 1 {print $1}')
    [[ "$h" =~ ^[0-9a-fA-F]{32,64}$ ]] && { printf '%s' "$h"; return 0; }
  done
  return 1
}
verify_hash() { # file expected
  local got
  case "${#2}" in
    32) got=$(md5sum "$1" | awk '{print $1}') ;;
    40) got=$(sha1sum "$1" | awk '{print $1}') ;;
    64) got=$(sha256sum "$1" | awk '{print $1}') ;;
    *) return 1 ;;
  esac
  [[ "${got,,}" == "${2,,}" ]]
}
wp_archive_ok()    { tar -tzf "$1" wordpress/wp-config-sample.php >/dev/null 2>&1; }
newest_cached()    { find "$CACHE_DIR" -maxdepth 1 -name "wordpress-${1}-*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR == 1 { $1 = ""; sub(/^ /, ""); print }'; }
prune_wp_cache() {
  local f
  while IFS= read -r f; do rm -f -- "$f" "$f.chk"; done < <(
    find "$CACHE_DIR" -maxdepth 1 -name "wordpress-${1}-*.tar.gz" -printf '%T@ %p\n' 2>/dev/null |
      sort -rn | awk 'NR > 2 { $1 = ""; sub(/^ /, ""); print }')
}

# Download the newest official WordPress, verified against wordpress.org's published checksum.
wp_fetch_core() { # [locale] -> sets WP_CORE_ARCHIVE
  local locale="${1:-$WP_LOCALE}" url file hash cached
  mkdir -p "$CACHE_DIR"
  if wp_resolve_latest "$locale"; then
    url="${WP_DOWNLOAD_URL%.zip}.tar.gz"
    file="$CACHE_DIR/wordpress-${locale}-${WP_LATEST_VERSION}.tar.gz"
    if [[ -f "$file" && -f "$file.chk" ]] && verify_hash "$file" "$(<"$file.chk")" && wp_archive_ok "$file"; then
      ok "Latest WordPress $WP_LATEST_VERSION ($locale) is already cached and verified"
      WP_CORE_ARCHIVE="$file"; return 0
    fi
    info "Downloading WordPress $WP_LATEST_VERSION ($locale) from wordpress.org ..."
    hash=$(fetch_remote_hash "$url") || { err "Could not fetch the official checksum for $url - refusing an unverified download"; return 1; }
    curl_get -o "$file.part" "$url" || { rm -f "$file.part"; err "Download failed: $url"; return 1; }
    if ! verify_hash "$file.part" "$hash" || ! wp_archive_ok "$file.part"; then
      rm -f "$file.part"; err "Checksum / archive verification FAILED - download discarded"; return 1
    fi
    mv -f "$file.part" "$file"; printf '%s\n' "$hash" >"$file.chk"
    ok "WordPress $WP_LATEST_VERSION downloaded and verified (official $( [[ ${#hash} -eq 40 ]] && echo SHA-1 || echo MD5 ) checksum matched)"
    prune_wp_cache "$locale"
    WP_CORE_ARCHIVE="$file"; return 0
  fi
  warn "Could not reach wordpress.org to look up the latest version"
  cached=$(newest_cached "$locale")
  if [[ -n "$cached" && -f "$cached.chk" ]] && verify_hash "$cached" "$(<"$cached.chk")"; then
    confirm "Use cached $(basename "$cached")? It may NOT be the newest release." n || return 1
    WP_CORE_ARCHIVE="$cached"; return 0
  fi
  return 1
}

wp_extract() { # archive destdir  (accepts .tar.gz/.tgz/.zip; flattens the wordpress/ folder)
  local archive="$1" dest="$2" tmp="$TMP_DIR/wpx" src
  rm -rf "$tmp"; mkdir -p "$tmp"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$tmp" || { err "Failed to extract $archive"; return 1; } ;;
    *.zip) require_cmd unzip unzip || return 1
           unzip -q "$archive" -d "$tmp" || { err "Failed to extract $archive"; return 1; } ;;
    *) err "Unsupported archive type: $archive"; return 1 ;;
  esac
  src="$tmp"; [[ -d "$tmp/wordpress" ]] && src="$tmp/wordpress"
  if [[ ! -f "$src/wp-config-sample.php" || ! -d "$src/wp-includes" ]]; then
    err "$archive is not a valid WordPress core archive"; return 1
  fi
  mkdir -p "$dest" && cp -a "$src"/. "$dest"/
}

wp_installed_version() { grep -m1 '^\$wp_version' "$1/wp-includes/version.php" 2>/dev/null | cut -d"'" -f2; }
wp_config_value() { # wp-config.php KEY
  sed -nE "s/^[[:space:]]*define\([[:space:]]*['\"]$2['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$1" 2>/dev/null | head -n1
}
wp_db_test() { # wp-config.php -> 0 ok, 1 fail, 2 not testable
  local cfg="$1" n u p h
  [[ -n "$DB_CLIENT" ]] || return 2
  n=$(wp_config_value "$cfg" DB_NAME); u=$(wp_config_value "$cfg" DB_USER)
  p=$(wp_config_value "$cfg" DB_PASSWORD); h=$(wp_config_value "$cfg" DB_HOST)
  [[ -n "$n" && -n "$u" ]] || return 2
  [[ -n "$h" ]] || h=localhost
  [[ "$h" == *:* || "$h" == */* ]] && return 2
  MYSQL_PWD="$p" "$DB_CLIENT" -h "$h" -u "$u" -e 'SELECT 1' "$n" >/dev/null 2>&1
}

gen_salt() { LC_ALL=C tr -dc 'A-Za-z0-9!@#%^*()_+=.,:;~-' </dev/urandom | head -c 64; }
local_salts() {
  local k
  for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
    printf "define( '%s', '%s' );\n" "$k" "$(gen_salt)"
  done
}
# Replace the 8 placeholder key/salt lines in wp-config.php with the lines from a file
wp_apply_salts() { # wp-config.php saltsfile
  awk -v sf="$2" '
    BEGIN { while ((getline l < sf) > 0) salts = salts l "\n"; close(sf) }
    /^define\( *.(AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT).,/ {
      if (!done) { printf "%s", salts; done = 1 }
      next
    }
    { print }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

wp_write_config() { # sitedir dbname dbuser dbpass
  local dir="$1" cfg="$1/wp-config.php" salts="$TMP_DIR/salts.txt" extra="$TMP_DIR/extra.txt"
  cp "$dir/wp-config-sample.php" "$cfg" || return 1
  sed -i -e "s/database_name_here/$2/" -e "s/username_here/$3/" -e "s/password_here/$4/" "$cfg"
  if curl_get "$WP_SALT_API" >"$salts" 2>/dev/null && [[ "$(grep -c '^define(' "$salts")" -eq 8 ]]; then
    ok "Fetched unique secret keys/salts from wordpress.org"
  else
    warn "Could not fetch salts from wordpress.org - generated random ones locally"
    local_salts >"$salts"
  fi
  wp_apply_salts "$cfg" "$salts"
  if grep -q 'put your unique phrase here' "$cfg"; then warn "Placeholder salts are still present in wp-config.php"; fi
  cat >"$extra" <<'EOF'
define( 'FS_METHOD', 'direct' );
define( 'DISALLOW_FILE_EDIT', true );
define( 'WP_MEMORY_LIMIT', '256M' );

EOF
  awk -v ef="$extra" '
    BEGIN { while ((getline l < ef) > 0) blk = blk l "\n"; close(ef) }
    /stop editing|wp-settings\.php/ && !done { printf "%s", blk; done = 1 }
    { print }' "$cfg" >"$cfg.tmp" && mv "$cfg.tmp" "$cfg"
}

fix_permissions() { # dir
  local dir="${1%/}" user
  is_safe_site_path "$dir" || { err "Refusing to change permissions outside $WWW_ROOT / $WP_ROOT: $dir"; return 1; }
  user=$(detect_web_user)
  chown -R "$user:$user" "$dir"
  find "$dir" -type d -exec chmod 755 {} +
  find "$dir" -type f -exec chmod 644 {} +
  [[ -f "$dir/wp-config.php" ]] && chmod 640 "$dir/wp-config.php"
  ok "Ownership ($user) and permissions fixed: $dir"
}

# ------------------------------ Backups --------------------------------------
prune_backups() {
  (( BACKUP_RETENTION_DAYS > 0 )) || return 0
  find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*-files.tar.gz' -o -name '*-db.sql.gz' \) \
    -mtime "+${BACKUP_RETENTION_DAYS}" -print -delete 2>/dev/null | while read -r f; do _log INFO "Pruned old backup: $f"; done
}

backup_run() { # path [dbname] [label-prefix]  -> sets LAST_BACKUP_FILES / LAST_BACKUP_DB
  local path="${1%/}" db="${2:-}" label="${3:-}" ts base need avail out
  LAST_BACKUP_FILES=""; LAST_BACKUP_DB=""
  [[ -d "$path" ]] || { err "Path not found: $path"; return 1; }
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  need=$(du -sk "$path" 2>/dev/null | awk '{print $1}'); avail=$(df -Pk "$BACKUP_DIR" | awk 'NR == 2 {print $4}')
  if (( avail < need )); then err "Not enough free space in $BACKUP_DIR (need ~$((need / 1024)) MB, have $((avail / 1024)) MB)"; return 1; fi
  ts=$(date +%Y%m%d-%H%M%S); base="${label}$(basename "$path")-${ts}"
  out="$BACKUP_DIR/${base}-files.tar.gz"
  tar -czf "$out.part" -C "$(dirname "$path")" "$(basename "$path")" 2>>"$LOG_FILE"
  if ! gzip -t "$out.part" 2>/dev/null; then rm -f "$out.part"; err "File backup failed integrity check"; return 1; fi
  mv "$out.part" "$out"; chmod 600 "$out"; LAST_BACKUP_FILES="$out"
  ok "Files backed up: $out ($(du -h "$out" | cut -f1))"
  if [[ -n "$db" ]]; then
    [[ -n "$DB_CLIENT" ]] || db_init || { err "No database access - DB not backed up"; return 1; }
    out="$BACKUP_DIR/${base}-db.sql.gz"
    if dump_db "$db" "$out.part" && gzip -t "$out.part" 2>/dev/null; then
      mv "$out.part" "$out"; chmod 600 "$out"; LAST_BACKUP_DB="$out"
      ok "Database '$db' backed up: $out ($(du -h "$out" | cut -f1))"
    else
      rm -f "$out.part"; err "Database dump of '$db' failed"; return 1
    fi
  fi
  prune_backups
}

pick_site() { # [wp] -> prints the chosen docroot
  local only="${1:-}" name root conf i=0 choice
  local -a roots=()
  while IFS='|' read -r name root conf; do
    [[ "$only" == wp && ! -f "$root/wp-includes/version.php" ]] && continue
    i=$((i + 1)); roots+=("$root")
    printf '  %2d) %-30s %s\n' "$i" "$name" "$root" >&2
  done < <(list_sites)
  choice=$(prompt "Number, or full path")
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= i )); then printf '%s' "${roots[choice - 1]}"; return 0; fi
  [[ -d "$choice" ]] && { printf '%s' "$choice"; return 0; }
  return 1
}

# =============================================================================
#  HEALTH CHECKS  (status = read-only, doctor = with automatic repairs)
# =============================================================================
chk_system() {
  step "System resources"
  local cores load1 t a pct swap seen=" " path used mnt oom
  cores=$(nproc 2>/dev/null || echo 1); load1=$(cut -d' ' -f1 /proc/loadavg)
  if awk -v l="$load1" -v c="$cores" 'BEGIN { exit !(l > c * 2) }'; then c_warn "High load average: $load1 ($cores cores)"
  else c_ok "Load average $load1 ($cores cores)"; fi

  read -r t a swap < <(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} /SwapTotal/ {s=$2} END {print t, a, s}' /proc/meminfo)
  pct=$(( a * 100 / t ))
  if (( pct < 10 )); then c_warn "Low memory: only ${pct}% available"; else c_ok "Memory: ${pct}% available"; fi
  if (( swap == 0 && t < 2097152 )); then c_warn "No swap on a small server (<2 GB RAM): MySQL/PHP may get OOM-killed"; fi

  for path in / "$WWW_ROOT" /var/lib/mysql "$BACKUP_DIR"; do
    [[ -e "$path" ]] || continue
    read -r used mnt < <(df --output=pcent,target "$path" | awk 'NR == 2 { gsub("%", "", $1); print $1, $2 }')
    [[ "$seen" == *" $mnt "* ]] && continue
    seen+="$mnt "
    if (( used >= DISK_CRIT_PCT )); then
      c_fail "Disk $mnt is ${used}% full"
      if can_fix "Free space (apt cache, journal older than 7 days, expired backups)?"; then
        apt-get clean >/dev/null 2>&1; journalctl --vacuum-time=7d >/dev/null 2>&1; prune_backups
        read -r used < <(df --output=pcent "$path" | awk 'NR == 2 { gsub("%", "", $1); print $1 }')
        (( used < DISK_CRIT_PCT )) && c_fixed fail "Disk $mnt now ${used}% full"
      fi
    elif (( used >= DISK_WARN_PCT )); then c_warn "Disk $mnt is ${used}% full"
    else c_ok "Disk $mnt ${used}% used"; fi
  done
  if (( $(df -i / | awk 'NR == 2 { gsub("%", "", $5); print $5 }') >= 90 )); then c_warn "Inode usage on / is above 90%"; fi

  oom=$(journalctl -k --since "24 hours ago" --no-pager 2>/dev/null | grep -ci 'out of memory')
  (( ${oom:-0} > 0 )) && c_warn "Kernel OOM-killer fired $oom time(s) in the last 24h"
  [[ -f /var/run/reboot-required ]] && c_warn "A reboot is required (pending kernel/library updates)"
  return 0
}

chk_one_service() {
  local u="$1"
  if systemctl is-active --quiet "$u"; then
    c_ok "$u is running"
  else
    c_fail "$u is NOT running"
    if can_fix "Try to start $u now?" && ensure_service "$u"; then c_fixed fail "$u started"; fi
  fi
  if ! systemctl is-enabled --quiet "$u" 2>/dev/null; then
    c_warn "$u is not enabled at boot"
    if can_fix "Enable $u at boot?" && systemctl enable "$u" >>"$LOG_FILE" 2>&1; then c_fixed warn "$u enabled at boot"; fi
  fi
}

chk_services() {
  step "Services"
  local u db
  if svc_exists apache2; then chk_one_service apache2; else c_fail "Apache (apache2) is not installed"; fi
  if db=$(detect_db_service); then chk_one_service "$db"; else c_fail "No MySQL/MariaDB service found"; fi
  while read -r u; do [[ -n "$u" ]] && chk_one_service "${u%.service}"; done < <(list_fpm_units)
}

chk_apache_config() {
  step "Apache configuration"
  svc_exists apache2 || return 0
  apache_configtest
  local rc=$?
  if (( rc != 0 )); then
    c_fail "Apache configuration test failed"
    printf '%s\n' "$APACHE_TEST_OUT" | grep -v '^$' | indent
    if can_fix "Attempt automatic repair (broken symlinks, missing modules)?" && apache_ensure_valid_config; then
      c_fixed fail "Apache configuration repaired"
    fi
  elif grep -q 'AH00558' <<<"$APACHE_TEST_OUT"; then
    c_warn "Apache has no global ServerName (AH00558)"
    if can_fix "Add 'ServerName localhost'?" && apache_autofix; then c_fixed warn "ServerName configured"; fi
  else
    c_ok "Syntax OK"
  fi
  if ! apache2ctl -M 2>/dev/null | grep -q rewrite_module; then
    c_warn "mod_rewrite is not enabled (WordPress permalinks need it)"
    if can_fix "Enable mod_rewrite?" && a2enmod rewrite >>"$LOG_FILE" 2>&1 && apache_apply reload; then c_fixed warn "mod_rewrite enabled"; fi
  fi
}

port_listening() { ss -ltn 2>/dev/null | awk -v p=":$1" '$4 ~ (p "$") { f = 1 } END { exit !f }'; }
chk_ports() {
  step "Listening ports"
  svc_exists apache2 || return 0
  if port_listening 80; then c_ok "Port 80 is listening"; else c_fail "Nothing is listening on port 80"; fi
  if grep -qs 'VirtualHost[^>]*:443' "$VHOST_ENABLED"/*.conf; then
    if port_listening 443; then c_ok "Port 443 is listening"; else c_fail "SSL vhosts exist but nothing listens on port 443 (is mod_ssl enabled?)"; fi
  fi
}

chk_database() {
  step "Database"
  local v conn max
  detect_db_service >/dev/null || return 0
  if ! db_init; then
    c_fail "Cannot connect to the database as root (is the service up? socket-vs-password auth?)"; return 0
  fi
  v=$(db_sql 'SELECT VERSION();')
  c_ok "Connected to $DB_CLIENT server $v"
  conn=$(db_sql "SHOW STATUS LIKE 'Threads_connected';" | awk '{print $2}')
  max=$(db_sql "SHOW VARIABLES LIKE 'max_connections';" | awk '{print $2}')
  if [[ "$conn" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] && (( conn * 100 / max >= 80 )); then
    c_warn "Database connections at $conn/$max (>=80%)"
  fi
}

chk_php() {
  step "PHP"
  local u ver highest="" m
  while read -r u; do
    [[ -n "$u" ]] || continue
    ver="${u#php}"; ver="${ver%-fpm.service}"; highest="$ver"
    if systemctl is-active --quiet "${u%.service}" && [[ ! -S "/run/php/php${ver}-fpm.sock" ]]; then
      c_fail "php${ver}-fpm is active but its socket is missing"
      if can_fix "Restart php${ver}-fpm?" && restart_service "php${ver}-fpm" && [[ -S "/run/php/php${ver}-fpm.sock" ]]; then
        c_fixed fail "php${ver}-fpm socket restored"
      fi
    else
      c_ok "PHP-FPM $ver OK"
    fi
  done < <(list_fpm_units)
  if [[ -z "$highest" ]]; then
    apache_has_mod_php && c_ok "PHP runs through mod_php" || c_warn "No PHP handler found (no PHP-FPM, no mod_php)"
    return 0
  fi
  if [[ -n "$WP_REQ_PHP" ]] && ! version_ge "$highest" "$WP_REQ_PHP"; then
    c_warn "Newest installed PHP ($highest) is below WordPress' minimum ($WP_REQ_PHP)"
  fi
  mapfile -t m < <(php_missing_modules "$highest")
  if (( ${#m[@]} )); then
    c_warn "PHP $highest lacks modules used by WordPress: ${m[*]}"
    if can_fix "Install the missing PHP modules?" n && ensure_php_modules "$highest"; then c_fixed warn "PHP modules installed"; fi
  fi
}

chk_vhost_php() { # name conf
  local name="$1" ver
  ver=$(conf_php_version "$2")
  [[ -n "$ver" ]] || return 0
  [[ -S "/run/php/php${ver}-fpm.sock" ]] && return 0
  c_fail "$name: PHP-FPM $ver socket is missing"
  if ! svc_exists "php${ver}-fpm"; then
    if can_fix "php${ver}-fpm is not installed. Install it?" n && ensure_fpm "$ver"; then c_fixed fail "$name: php${ver}-fpm installed"; fi
  elif can_fix "Start php${ver}-fpm?" && ensure_fpm "$ver"; then
    c_fixed fail "$name: php${ver}-fpm running"
  fi
}

chk_wordpress() { # name root
  local name="$1" root="$2" cfg="$2/wp-config.php" ver mode rc
  ver=$(wp_installed_version "$root")
  if [[ -n "$WP_LATEST_VERSION" && -n "$ver" ]]; then
    if version_ge "$ver" "$WP_LATEST_VERSION"; then c_ok "$name: WordPress $ver (up to date)"
    else c_warn "$name: WordPress $ver is outdated (latest: $WP_LATEST_VERSION)  ->  $SCRIPT_NAME wp-update $root"; fi
  elif [[ -n "$ver" ]]; then c_ok "$name: WordPress $ver"; fi
  wp_db_test "$cfg"; rc=$?
  case $rc in
    0) c_ok "$name: WordPress can connect to its database" ;;
    1) c_fail "$name: WordPress CANNOT connect to its database (wrong credentials, missing user or DB?)" ;;
  esac
  mode=$(stat -c '%a' "$cfg")
  if (( 8#$mode & 4 )); then
    c_warn "$name: wp-config.php is world-readable ($mode)"
    if can_fix "chmod 640 wp-config.php?" && chmod 640 "$cfg"; then c_fixed warn "$name: wp-config.php permissions tightened"; fi
  fi
}

chk_one_site() { # name root conf
  local name="$1" root="$2" conf="$3" code ssl cert days
  if [[ ! -d "$root" ]]; then c_fail "$name: DocumentRoot does not exist ($root)"; return; fi
  chk_vhost_php "$name" "$conf"
  if [[ "$name" =~ ^[A-Za-z0-9.-]+$ ]]; then
    code=$(http_status "$name" 80)
    case "$code" in
      2??|3??) c_ok "$name: HTTP $code" ;;
      000) c_fail "$name: no answer from Apache on port 80" ;;
      5??) c_fail "$name: HTTP $code (server error). Last log lines:"
           tail -n 3 "$APACHE_LOG_DIR/${name}_error.log" 2>/dev/null | indent ;;
      *)   c_warn "$name: HTTP $code" ;;
    esac
  fi
  ssl="$VHOST_ENABLED/${name}-le-ssl.conf"; [[ -e "$ssl" ]] || ssl="$conf"
  cert=$(conf_directive "$ssl" SSLCertificateFile)
  if [[ -n "$cert" && -f "$cert" ]]; then
    if days=$(cert_days_left "$cert"); then
      if (( days < 0 )); then c_fail "$name: SSL certificate EXPIRED $((-days)) day(s) ago"
      elif (( days < CERT_WARN_DAYS )); then c_warn "$name: SSL certificate expires in $days day(s)"
        if can_fix "Run 'certbot renew' now?" && command_exists certbot && certbot renew --quiet >>"$LOG_FILE" 2>&1 && apache_apply reload; then
          c_fixed warn "$name: certificates renewed"
        fi
      else c_ok "$name: SSL certificate valid for $days more day(s)"; fi
    fi
  fi
  [[ -f "$root/wp-config.php" && -f "$root/wp-includes/version.php" ]] && chk_wordpress "$name" "$root"
}

chk_sites() {
  step "Websites"
  local name root conf n=0
  while IFS='|' read -r name root conf; do
    n=$((n + 1)); chk_one_site "$name" "$root" "$conf"
  done < <(list_sites)
  (( n )) || info "No enabled virtual hosts found"
}

chk_firewall() {
  command_exists ufw || return 0
  step "Firewall"
  local s; s=$(ufw status 2>/dev/null | head -n1)
  [[ "$s" == *inactive* ]] && { info "UFW is inactive (nothing to check)"; return 0; }
  if ufw status | grep -Eiq '\b(80|443|apache|www|nginx)\b'; then c_ok "UFW allows web traffic"
  else c_warn "UFW is active but ports 80/443 do not appear to be allowed"; fi
}

chk_network() {
  step "Outbound connectivity"
  if [[ -n "$WP_LATEST_VERSION" ]]; then c_ok "wordpress.org reachable (latest WordPress: $WP_LATEST_VERSION)"
  else c_warn "Could not reach api.wordpress.org (no internet / DNS / firewall?)"; fi
}

notify() { # subject body
  local state="$STATE_DIR/last_alert" now last=0
  [[ -n "$ALERT_EMAIL$ALERT_WEBHOOK" ]] || return 0
  now=$(date +%s); [[ -f "$state" ]] && last=$(stat -c %Y "$state")
  (( now - last < ALERT_COOLDOWN )) && return 0
  : >"$state"
  if [[ -n "$ALERT_EMAIL" ]] && command_exists mail; then printf '%s\n' "$2" | mail -s "$1" "$ALERT_EMAIL"; fi
  if [[ -n "$ALERT_WEBHOOK" ]] && command_exists python3; then
    printf '%s\n%s' "$1" "$2" | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))' |
      curl -fsS -m 10 -X POST -H 'Content-Type: application/json' -d @- "$ALERT_WEBHOOK" >/dev/null 2>&1
  fi
}

run_doctor() {
  PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; FIX_COUNT=0; ISSUES=()
  WP_LATEST_VERSION=""; WP_REQ_PHP=""
  (( FAST )) || wp_resolve_latest en_US >/dev/null 2>&1
  (( AUTO_FIX )) || info "Read-only mode: nothing will be changed"
  chk_system; chk_services; chk_apache_config; chk_ports; chk_database; chk_php; chk_sites; chk_firewall
  (( FAST )) || chk_network
  step "Summary"
  printf '%s%d passed%s, %s%d warning(s)%s, %s%d failure(s)%s, %d fixed automatically\n' \
    "$C_GREEN" "$PASS_COUNT" "$C_RESET" "$C_YELLOW" "$WARN_COUNT" "$C_RESET" "$C_RED" "$FAIL_COUNT" "$C_RESET" "$FIX_COUNT"
  _log SUMMARY "pass=$PASS_COUNT warn=$WARN_COUNT fail=$FAIL_COUNT fixed=$FIX_COUNT"
  if (( FAIL_COUNT > 0 || FIX_COUNT > 0 )); then
    notify "[$(hostname)] server-manager: ${FAIL_COUNT} failure(s), ${FIX_COUNT} auto-fixed" "$(printf '%s\n' "${ISSUES[@]}")"
  fi
  (( FAIL_COUNT > 0 )) && return 2
  (( WARN_COUNT > 0 )) && return 1
  return 0
}

# =============================================================================
#  TOOLS (interactive)
# =============================================================================
list_vhosts() {
  step "Enabled VirtualHosts"
  local name root conf php ssl wpv n=0
  printf '  %-30s %-8s %-4s %-8s %s\n' DOMAIN PHP SSL WP DOCROOT
  while IFS='|' read -r name root conf; do
    php=$(conf_php_version "$conf"); php="${php:-default}"
    ssl=no; vhost_has_ssl "$name" "$conf" && ssl=yes
    wpv=$(wp_installed_version "$root"); wpv="${wpv:--}"
    printf '  %-30s %-8s %-4s %-8s %s\n' "$name" "$php" "$ssl" "$wpv" "$root"
    n=$((n + 1))
  done < <(list_sites)
  (( n )) || info "(none)"
}

create_vhost() {
  step "Create Apache VirtualHost"
  local domain docroot phpver www=0 ssl=0 pv code
  svc_exists apache2 || { err "Apache is not installed (apt install apache2)"; return 1; }
  ensure_service apache2 || return 1
  domain=$(prompt "Domain (e.g. example.com)" | tr 'A-Z' 'a-z')
  validate_domain "$domain" || { err "Invalid domain (use punycode 'xn--' for non-ASCII names)."; return 1; }
  [[ ! -e "$VHOST_AVAILABLE/${domain}.conf" ]] || { err "A VirtualHost for $domain already exists."; return 1; }
  docroot=$(prompt "Document root" "$WWW_ROOT/$domain")
  valid_docroot "$docroot" || { err "Invalid document root (absolute path; letters, digits . _ - / only)."; return 1; }
  phpver=$(ask_php_version) || return 1
  if [[ -n "$phpver" ]]; then ensure_fpm "$phpver" || return 1; fi
  confirm "Add www.$domain as an alias?" n && www=1
  confirm "Issue a free Let's Encrypt SSL certificate afterwards?" n && ssl=1

  if [[ ! -d "$docroot" ]]; then
    mkdir -p "$docroot" || return 1
    ROLLBACK+=("dir:$docroot")
    printf '<h1>%s is working</h1>\n' "$domain" >"$docroot/index.html"
    chown -R "$(detect_web_user):$(detect_web_user)" "$docroot"; chmod -R 755 "$docroot"
    info "Created document root $docroot"
  else
    warn "Document root already exists - contents left untouched."
  fi
  write_vhost_conf "$domain" "$docroot" "$phpver" "$www"
  ROLLBACK+=("vhost:$domain")
  enable_vhost "$domain" "$phpver" || { run_rollback; return 1; }
  ROLLBACK=()

  code=$(http_status "$domain" 80)
  if [[ "$code" =~ ^[23] ]]; then ok "$domain answers with HTTP $code"; else warn "$domain answered HTTP $code - check $APACHE_LOG_DIR/${domain}_error.log"; fi
  if [[ -n "$phpver" ]]; then
    pv=$(php_probe "$domain" "$docroot") && ok "PHP $pv confirmed through Apache" || warn "Could not confirm PHP execution for $domain"
  fi
  (( ssl )) && issue_ssl "$domain" "$www"
  if confirm "Add '127.0.0.1 $domain' to $HOSTS_FILE?" n; then
    add_hosts_entry "$domain" "$( (( www )) && echo "www.$domain")"
  fi
  ok "VirtualHost ready: http://${domain}"
}

new_wordpress() {
  step "Deploy new WordPress site (latest release from wordpress.org)"
  local site domain locale phpver target db_name db_pass archive ver www=0 ssl=0 dbsvc code pv cred
  svc_exists apache2 || { err "Apache is not installed (apt install apache2)"; return 1; }
  ensure_service apache2 || return 1
  dbsvc=$(detect_db_service) || { err "No MySQL/MariaDB service found (apt install mariadb-server)"; return 1; }
  ensure_service "$dbsvc" || return 1
  db_init || { err "Cannot connect to the database as root. Check root auth (try: sudo mysql)."; return 1; }
  require_cmd curl curl || return 1

  site=$(prompt "Site name (folder under ${WP_ROOT}, e.g. myclient)" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')
  [[ -n "$site" ]] || { err "Invalid site name."; return 1; }
  target="$WP_ROOT/$site"
  [[ ! -e "$target" ]] || { err "Directory already exists: $target"; return 1; }
  domain=$(prompt "Domain for this site (e.g. site.com)" | tr 'A-Z' 'a-z')
  validate_domain "$domain" || { err "Invalid domain (use punycode 'xn--' for non-ASCII names)."; return 1; }
  [[ ! -e "$VHOST_AVAILABLE/${domain}.conf" ]] || { err "A VirtualHost for $domain already exists."; return 1; }
  db_name=$(printf 'wp_%s' "$site" | tr -cd 'a-zA-Z0-9_' | cut -c1-32)
  if db_exists "$db_name" || db_user_exists "$db_name"; then
    err "Database or user '$db_name' already exists - choose another site name."; return 1
  fi
  locale=$(prompt "WordPress language/locale (e.g. en_US, ar)" "$WP_LOCALE")
  [[ "$locale" =~ ^[A-Za-z]{2,3}(_[A-Za-z]{2,3})?$ ]] || { err "Invalid locale '$locale'."; return 1; }

  # 1) Official, latest, checksum-verified WordPress
  if wp_fetch_core "$locale"; then
    archive="$WP_CORE_ARCHIVE"
  else
    archive=$(prompt "Fallback: path to a local WordPress .zip/.tar.gz (blank = cancel)")
    [[ -f "$archive" ]] || { err "Cancelled - no WordPress archive available."; return 1; }
    warn "Using a local archive - it may not be the latest WordPress."
  fi

  # 2) PHP handler and requirements
  phpver=$(ask_php_version) || return 1
  if [[ -n "$phpver" ]]; then
    ensure_fpm "$phpver" || return 1
    ensure_php_modules "$phpver" || { err "WordPress needs those PHP modules."; return 1; }
    if [[ -n "$WP_REQ_PHP" ]] && ! version_ge "$phpver" "$WP_REQ_PHP"; then
      err "WordPress $WP_LATEST_VERSION requires PHP >= $WP_REQ_PHP (selected: $phpver)."; return 1
    fi
  fi
  confirm "Add www.$domain as an alias?" n && www=1
  confirm "Issue a free Let's Encrypt SSL certificate afterwards?" n && ssl=1

  # 3) Build the site (everything is rolled back on failure)
  mkdir -p "$target" || return 1
  ROLLBACK+=("dir:$target")
  wp_extract "$archive" "$target" || { run_rollback; return 1; }
  ver=$(wp_installed_version "$target")
  ok "WordPress ${ver:-?} extracted to $target"

  db_pass=$(random_string 24)
  info "Creating database and user ..."
  db_sql "CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null || { err "Database creation failed."; run_rollback; return 1; }
  ROLLBACK+=("db:$db_name")
  db_sql "CREATE USER '${db_name}'@'localhost' IDENTIFIED BY '${db_pass}';" >/dev/null || { err "User creation failed."; run_rollback; return 1; }
  ROLLBACK+=("dbuser:$db_name")
  db_sql "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_name}'@'localhost'; FLUSH PRIVILEGES;" >/dev/null || { err "Grant failed."; run_rollback; return 1; }
  ok "Database '$db_name' and user created"

  wp_write_config "$target" "$db_name" "$db_name" "$db_pass" || { err "Could not write wp-config.php"; run_rollback; return 1; }
  fix_permissions "$target" || { run_rollback; return 1; }
  if wp_db_test "$target/wp-config.php"; then ok "wp-config.php credentials verified against the database"
  else warn "Could not verify the DB credentials from wp-config.php"; fi

  write_vhost_conf "$domain" "$target" "$phpver" "$www"
  ROLLBACK+=("vhost:$domain")
  enable_vhost "$domain" "$phpver" || { run_rollback; return 1; }
  ROLLBACK=()   # success: nothing to roll back any more

  # 4) Verify
  code=$(http_status "$domain" 80)
  if [[ "$code" =~ ^[23] ]]; then ok "Site answers with HTTP $code"; else warn "Site answered HTTP $code - check $APACHE_LOG_DIR/${domain}_error.log"; fi
  if [[ -n "$phpver" ]]; then
    pv=$(php_probe "$domain" "$target") && ok "PHP $pv confirmed through Apache" || warn "Could not confirm PHP execution"
  fi
  (( ssl )) && issue_ssl "$domain" "$www"
  if confirm "Add '127.0.0.1 $domain' to $HOSTS_FILE?" n; then add_hosts_entry "$domain" "$( (( www )) && echo "www.$domain")"; fi

  mkdir -p "$BACKUP_DIR/credentials"; chmod 700 "$BACKUP_DIR/credentials"
  cred="$BACKUP_DIR/credentials/${site}.txt"
  ( umask 077; cat >"$cred" <<EOF
Site:        ${domain}
Path:        ${target}
WordPress:   ${ver:-?}
DB name:     ${db_name}
DB user:     ${db_name}
DB password: ${db_pass}
Created:     $(date)
EOF
  )
  printf '\n%s=== WordPress %s deployed ===%s\n' "$C_GREEN" "${ver:-}" "$C_RESET"
  printf 'URL:         http://%s\nPath:        %s\nDB name/user: %s\nDB password: %s\nCredentials: %s (root-only)\n' \
    "$domain" "$target" "$db_name" "$db_pass" "$cred"
  echo "-> Point DNS for ${domain} at this server, then open the site to finish the WordPress install wizard."
}

delete_vhost() {
  step "Delete VirtualHost"
  list_vhosts
  local domain conf ssl_conf docroot dbname dbuser purge=0 backup=0
  domain=$(prompt "Domain to delete (conf filename without .conf)" | tr 'A-Z' 'a-z')
  conf="$VHOST_AVAILABLE/${domain}.conf"; ssl_conf="$VHOST_AVAILABLE/${domain}-le-ssl.conf"
  [[ -f "$conf" ]] || { err "No such vhost: $conf"; return 1; }
  docroot=$(conf_directive "$conf" DocumentRoot)
  if [[ -f "$docroot/wp-config.php" ]]; then
    dbname=$(wp_config_value "$docroot/wp-config.php" DB_NAME)
    dbuser=$(wp_config_value "$docroot/wp-config.php" DB_USER)
  fi
  confirm "Permanently remove the VirtualHost for $domain?" n || { info "Cancelled."; return 0; }
  if [[ -n "$docroot" ]] && confirm "ALSO delete the files at ${docroot}${dbname:+ and database '$dbname'}?" n; then purge=1; fi
  if (( purge )); then
    confirm "Take a final backup first (strongly recommended)?" y && backup=1
    if (( backup )); then
      db_init >/dev/null 2>&1
      backup_run "$docroot" "${dbname:-}" "final-" || { err "Backup failed - aborting deletion."; return 1; }
    fi
  fi

  a2dissite "${domain}.conf" >/dev/null 2>&1; [[ -f "$ssl_conf" ]] && a2dissite "${domain}-le-ssl.conf" >/dev/null 2>&1
  rm -f -- "$conf" "$ssl_conf"
  apache_apply reload
  ok "VirtualHost removed: $domain"
  if command_exists certbot && [[ -d "/etc/letsencrypt/live/$domain" ]] && confirm "Delete the Let's Encrypt certificate for $domain?" y; then
    certbot delete --cert-name "$domain" --non-interactive >>"$LOG_FILE" 2>&1 && ok "Certificate deleted"
  fi
  if confirm "Remove $domain from $HOSTS_FILE?" n; then remove_hosts_entry "$domain"; remove_hosts_entry "www.$domain"; fi

  if (( purge )); then
    if is_safe_site_path "$docroot"; then rm -rf -- "$docroot" && ok "Removed files at $docroot"
    else warn "Refusing to delete $docroot (outside $WWW_ROOT / $WP_ROOT) - remove it manually."; fi
    if [[ -n "$dbname" ]] && db_init && valid_ident "$dbname"; then
      db_sql "DROP DATABASE IF EXISTS \`${dbname}\`;" >/dev/null && ok "Dropped database $dbname"
      if [[ -n "$dbuser" ]] && valid_ident "$dbuser"; then
        db_sql "DROP USER IF EXISTS '${dbuser}'@'localhost';" >/dev/null && ok "Dropped DB user $dbuser"
      fi
    fi
    [[ -n "$LAST_BACKUP_FILES" ]] && info "Final backup kept at: $LAST_BACKUP_FILES ${LAST_BACKUP_DB:-}"
  fi
}

create_mysql_db() {
  step "Create MySQL database + user"
  local dbn dbu dbp
  db_init || { err "Cannot connect to the database as root."; return 1; }
  dbn=$(prompt "Database name"); dbu=$(prompt "DB username" "$dbn")
  valid_ident "$dbn" && valid_ident "$dbu" && (( ${#dbu} <= 32 )) || { err "Names: letters, digits, underscore only (user <= 32 chars)."; return 1; }
  db_exists "$dbn" && { err "Database '$dbn' already exists."; return 1; }
  dbp=$(prompt "DB password (blank = generate)")
  [[ -n "$dbp" ]] || dbp=$(random_string 24)
  db_sql "CREATE DATABASE \`${dbn}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbu}'@'localhost' IDENTIFIED BY '$(sql_escape "$dbp")';
GRANT ALL PRIVILEGES ON \`${dbn}\`.* TO '${dbu}'@'localhost'; FLUSH PRIVILEGES;" >/dev/null || { err "SQL failed."; return 1; }
  ok "Database '$dbn' and user '$dbu' ready."
  echo "Password: $dbp"
}

backup_site() {
  step "Backup site (files + DB)"
  local path db
  path=$(pick_site) || { err "No such site/path."; return 1; }
  db=""
  [[ -f "$path/wp-config.php" ]] && db=$(wp_config_value "$path/wp-config.php" DB_NAME)
  db=$(prompt "MySQL database to include (blank = files only)" "$db")
  [[ -n "$db" ]] && { db_init || { err "No database access."; return 1; }; }
  backup_run "$path" "$db"
}

restore_site() {
  step "Restore site from backup"
  local -a archives=()
  local a i dest dump db choice pre
  mapfile -t archives < <(find "$BACKUP_DIR" -maxdepth 1 -name '*-files.tar.gz' -printf '%T@ %p\n' | sort -rn | awk '{ $1 = ""; sub(/^ /, ""); print }')
  (( ${#archives[@]} )) || { err "No backups found in $BACKUP_DIR"; return 1; }
  for i in "${!archives[@]}"; do
    a="${archives[$i]}"
    printf '  %2d) %-60s %s  %s\n' "$((i + 1))" "$(basename "$a")" "$(date -r "$a" '+%F %T')" "$(du -h "$a" | cut -f1)"
  done
  choice=$(prompt "Number (or full path)")
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#archives[@]} )); then a="${archives[choice - 1]}"; else a="$choice"; fi
  [[ -f "$a" ]] || { err "Archive not found."; return 1; }
  gzip -t "$a" 2>/dev/null || { err "Archive is corrupt (gzip test failed)."; return 1; }
  dest=$(prompt "Restore destination directory")
  valid_docroot "$dest" || { err "Invalid destination."; return 1; }
  if [[ -d "$dest" && -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    warn "$dest is not empty - files from the backup will be written over it."
    confirm "Take a safety snapshot of the current contents first?" y && { backup_run "$dest" "" "pre-restore-" || return 1; }
    confirm "Continue with the restore?" n || return 0
  fi
  mkdir -p "$dest"
  tar -xzf "$a" -C "$dest" --strip-components=1 || { err "Extraction failed."; return 1; }
  is_safe_site_path "$dest" && chown -R "$(detect_web_user):$(detect_web_user)" "$dest"
  ok "Files restored to $dest"

  dump="${a%-files.tar.gz}-db.sql.gz"
  if [[ -f "$dump" ]] && confirm "Also restore the matching database dump ($(basename "$dump"))?" y; then
    db_init || { err "No database access."; return 1; }
    db=$(wp_config_value "$dest/wp-config.php" DB_NAME)
    db=$(prompt "Target database name" "$db")
    valid_ident "$db" || { err "Invalid database name."; return 1; }
    if db_exists "$db"; then
      pre="$BACKUP_DIR/pre-restore-${db}-$(date +%Y%m%d-%H%M%S)-db.sql.gz"
      confirm "Dump the current '$db' first as a safety copy?" y && dump_db "$db" "$pre" && { chmod 600 "$pre"; ok "Safety dump: $pre"; }
    else
      db_sql "CREATE DATABASE \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null || return 1
      warn "Created empty database '$db' - make sure the DB user from wp-config.php exists and has access."
    fi
    gunzip -c "$dump" | "$DB_CLIENT" "${DB_ARGS[@]}" "$db" && ok "Database restored into $db" || err "Database restore failed."
  fi
}

switch_php_version() {
  step "Switch PHP version for a vhost"
  local domain ver confs=() f docroot pv bak="$TMP_DIR/phpswitch" revert=0
  list_vhosts
  domain=$(prompt "Domain (vhost conf name)" | tr 'A-Z' 'a-z')
  [[ -f "$VHOST_AVAILABLE/${domain}.conf" ]] || { err "vhost not found: $domain"; return 1; }
  confs=("$VHOST_AVAILABLE/${domain}.conf"); [[ -f "$VHOST_AVAILABLE/${domain}-le-ssl.conf" ]] && confs+=("$VHOST_AVAILABLE/${domain}-le-ssl.conf")
  docroot=$(conf_directive "${confs[0]}" DocumentRoot)
  echo "Installed PHP-FPM versions: $(installed_fpm_versions | tr '\n' ' ')"
  ver=$(prompt "New PHP version (e.g. 8.3, or 'none')")
  [[ "$ver" == none || "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || { err "Invalid version."; return 1; }
  if [[ "$ver" != none ]]; then
    ensure_fpm "$ver" || return 1
    [[ -f "$docroot/wp-config.php" ]] && { ensure_php_modules "$ver" || return 1; }
  fi
  mkdir -p "$bak"
  for f in "${confs[@]}"; do cp -a "$f" "$bak/$(basename "$f")"; set_conf_php_version "$f" "$ver"; done
  a2enmod proxy_fcgi setenvif >>"$LOG_FILE" 2>&1
  if ! apache_ensure_valid_config; then
    err "Config test failed - restoring previous vhost files."; revert=1
  else
    apache_apply reload || revert=1
    if (( ! revert )) && [[ "$ver" != none && -d "$docroot" ]]; then
      pv=$(php_probe "$domain" "$docroot")
      if [[ "$pv" == "$ver".* ]]; then ok "Verified: $domain now runs PHP $pv"
      else
        warn "Could not confirm PHP $ver for $domain (probe returned: ${pv:-nothing})."
        confirm "Revert to the previous settings?" y && revert=1
      fi
    fi
  fi
  if (( revert )); then
    for f in "${confs[@]}"; do cp -a "$bak/$(basename "$f")" "$f"; done
    apache_apply reload; warn "Reverted to previous PHP settings."; return 1
  fi
}

update_wordpress() { # [path]
  step "Update WordPress core"
  local root="${1:-}" ver user rc name conf site_php="" n r c domain=""
  [[ -n "$root" ]] || { root=$(pick_site wp) || { err "No such site/path."; return 1; }; }
  root="${root%/}"
  [[ -f "$root/wp-includes/version.php" && -f "$root/wp-config.php" ]] || { err "Not a WordPress install: $root"; return 1; }
  is_safe_site_path "$root" || { err "Refusing: $root is outside $WWW_ROOT / $WP_ROOT"; return 1; }
  require_cmd rsync rsync || return 1
  ver=$(wp_installed_version "$root")
  wp_fetch_core en_US || { err "Could not obtain the latest WordPress."; return 1; }
  if version_ge "$ver" "$WP_LATEST_VERSION"; then ok "Already up to date (WordPress $ver)."; return 0; fi
  info "Updating WordPress $ver -> $WP_LATEST_VERSION"

  while IFS='|' read -r n r c; do
    [[ "$r" == "$root" ]] && { domain="$n"; site_php=$(conf_php_version "$c"); break; }
  done < <(list_sites)
  if [[ -n "$site_php" && -n "$WP_REQ_PHP" ]] && ! version_ge "$site_php" "$WP_REQ_PHP"; then
    err "WordPress $WP_LATEST_VERSION needs PHP >= $WP_REQ_PHP but this site uses $site_php. Switch PHP first (menu option 8)."; return 1
  fi

  db_init >/dev/null 2>&1
  confirm "Back up files + database before updating?" y && { backup_run "$root" "$(wp_config_value "$root/wp-config.php" DB_NAME)" "pre-update-" || { err "Backup failed - aborting."; return 1; }; }

  local src="$TMP_DIR/wp-update-src"; rm -rf "$src"; mkdir -p "$src"
  wp_extract "$WP_CORE_ARCHIVE" "$src" || return 1
  printf '<?php $upgrading = %s; ?>\n' "$(date +%s)" >"$root/.maintenance"
  rsync -a --delete "$src/wp-admin/" "$root/wp-admin/" &&
  rsync -a --delete "$src/wp-includes/" "$root/wp-includes/" &&
  rsync -a --exclude='/wp-content' --exclude='/wp-config.php' --exclude='/.htaccess' \
        --exclude='/wp-admin' --exclude='/wp-includes' "$src/" "$root/"
  rc=$?
  rm -f "$root/.maintenance"
  if (( rc != 0 )); then
    err "File update failed (rsync exit $rc)."
    [[ -n "$LAST_BACKUP_FILES" ]] && echo "       Restore with the backup: $LAST_BACKUP_FILES"
    return 1
  fi
  user=$(detect_web_user)
  chown -R "$user:$user" "$root/wp-admin" "$root/wp-includes"
  find "$root/wp-admin" "$root/wp-includes" -type d -exec chmod 755 {} +
  find "$root/wp-admin" "$root/wp-includes" -type f -exec chmod 644 {} +
  find "$root" -maxdepth 1 -type f ! -name 'wp-config.php' -exec chown "$user:$user" {} +

  if command_exists wp; then
    wp --allow-root --path="$root" core update-db >>"$LOG_FILE" 2>&1 && ok "Database schema updated (wp-cli)"
  elif [[ -n "$domain" ]]; then
    curl -sS -m 120 -o /dev/null --resolve "${domain}:80:127.0.0.1" "http://${domain}/wp-admin/upgrade.php?step=1" 2>/dev/null &&
      ok "Database upgrade triggered via upgrade.php"
  fi
  ok "WordPress core now at $(wp_installed_version "$root")"
  if [[ -n "$domain" ]]; then
    name=$(http_status "$domain" 80)
    [[ "$name" =~ ^[23] ]] && ok "$domain answers with HTTP $name" || warn "$domain answered HTTP $name - check the logs"
  fi
  info "Plugins/themes were not touched. Review them in wp-admin."
}

fix_permissions_menu() {
  step "Fix site ownership / permissions"
  local p; p=$(pick_site) || { err "No such site/path."; return 1; }
  confirm "Set owner to $(detect_web_user), dirs 755, files 644 on $p?" y && fix_permissions "$p"
}

services_menu() {
  step "Services"
  printf ' 1) Restart Apache (config-tested)\n 2) Reload Apache (graceful, no downtime)\n 3) Restart database\n'
  printf ' 4) Restart PHP-FPM (all versions)\n 5) Restart everything (DB -> PHP-FPM -> Apache)\n 6) Status report (read-only)\n'
  case "$(prompt "Choose")" in
    1) restart_target apache ;; 2) restart_target reload ;; 3) restart_target db ;;
    4) restart_target php ;;    5) restart_target all ;;
    6) AUTO_FIX=0 run_doctor ;;
    *) warn "Invalid choice" ;;
  esac
}

view_logs() {
  step "Logs"
  local f=""
  printf ' 1) Apache error log (global)\n 2) Apache access log (global)\n 3) A site'"'"'s error log\n 4) PHP-FPM log(s)\n 5) MySQL/MariaDB error log\n 6) server-manager log\n'
  case "$(prompt "Choose")" in
    1) f="$APACHE_LOG_DIR/error.log" ;;
    2) f="$APACHE_LOG_DIR/access.log" ;;
    3) f="$APACHE_LOG_DIR/$(prompt "Domain")_error.log" ;;
    4) f=$(ls -1 /var/log/php*-fpm.log 2>/dev/null | head -n1) ;;
    5) f=$(ls -1 /var/log/mysql/error.log /var/log/mysql/mariadb.err 2>/dev/null | head -n1) ;;
    6) f="$LOG_FILE" ;;
    *) warn "Invalid choice"; return 1 ;;
  esac
  [[ -r "$f" ]] || { err "Log not found: ${f:-none}"; return 1; }
  tail -n 60 "$f"
  if confirm "Follow live (Ctrl-C to stop)?" n; then
    trap ':' INT
    ( trap - INT; exec tail -n 0 -f "$f" )
    trap on_interrupt INT
    echo
  fi
}

install_watchdog() {
  step "Watchdog (automatic self-healing)"
  local cron=/etc/cron.d/server-manager-watchdog target=/usr/local/sbin/server-manager.sh
  if [[ -f "$cron" ]]; then
    info "A watchdog is already installed: $cron"
    confirm "Remove it?" n && remove_watchdog
    return 0
  fi
  [[ "$SCRIPT_PATH" == "$target" ]] || install -m 750 -o root -g root "$SCRIPT_PATH" "$target" || return 1
  cat >"$cron" <<EOF
# Managed by server-manager.sh - checks services/config and repairs what it safely can.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${WATCHDOG_INTERVAL_MIN} * * * * root ${target} doctor --yes --quiet --fast >/dev/null 2>&1
EOF
  chmod 644 "$cron"
  cat >/etc/logrotate.d/server-manager <<EOF
${LOG_FILE} {
    weekly
    rotate 8
    compress
    missingok
    notempty
    create 640 root root
}
EOF
  ok "Watchdog installed: runs every ${WATCHDOG_INTERVAL_MIN} min (log: $LOG_FILE). Alerts: set ALERT_EMAIL / ALERT_WEBHOOK in /etc/server-manager.conf"
}
remove_watchdog() { rm -f /etc/cron.d/server-manager-watchdog && ok "Watchdog removed"; }

show_wp_version() {
  if wp_resolve_latest "${1:-$WP_LOCALE}"; then
    echo "Latest WordPress: $WP_LATEST_VERSION  (requires PHP >= ${WP_REQ_PHP:-?}, MySQL >= ${WP_REQ_MYSQL:-?})"
    echo "Download:         ${WP_DOWNLOAD_URL%.zip}.tar.gz"
  else
    err "Could not query $WP_VERSION_API"; return 1
  fi
}

# =============================================================================
#  MAIN
# =============================================================================
usage() { sed -n '2,/^# ====/p' "$SCRIPT_PATH" | sed -e '$d' -e 's/^# \{0,1\}//'; }

main_menu() {
  local choice
  while true; do
    printf '\n%s====================================================%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   LAMP Server Manager v%s  (Apache / MySQL / PHP)%s\n' "$C_BOLD" "$VERSION" "$C_RESET"
    printf '%s====================================================%s\n' "$C_CYAN" "$C_RESET"
    cat <<'EOF'
  1) Create VirtualHost
  2) Deploy new WordPress site (latest from wordpress.org)
  3) List VirtualHosts
  4) Delete VirtualHost
  5) Create MySQL database + user
  6) Backup a site (files + DB)
  7) Restore a site from backup
  8) Switch PHP version for a vhost
  9) Services: restart / status
 10) View logs
 11) Update WordPress core (existing site)
 12) Fix site ownership / permissions
 13) Health check & auto-repair (doctor)
 14) Watchdog: install / remove automatic self-healing
  0) Exit
EOF
    choice=$(prompt "Choose an option")
    case "$choice" in
      1) create_vhost ;;      2) new_wordpress ;;     3) list_vhosts ;;
      4) delete_vhost ;;      5) create_mysql_db ;;   6) backup_site ;;
      7) restore_site ;;      8) switch_php_version ;; 9) services_menu ;;
      10) view_logs ;;        11) update_wordpress ;; 12) fix_permissions_menu ;;
      13) run_doctor ;;       14) install_watchdog ;;
      0|q|quit|exit) echo "Bye."; return 0 ;;
      *) warn "Invalid option." ;;
    esac
    ROLLBACK=()
    pause
  done
}

main() {
  local -a args=()
  while (( $# )); do
    case "$1" in
      -y|--yes)     ASSUME_YES=1 ;;
      -q|--quiet)   QUIET=1 ;;
      --fast)       FAST=1 ;;
      --no-fix)     AUTO_FIX=0 ;;
      -h|--help)    usage; exit 0 ;;
      -V|--version) echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
      --)           shift; args+=("$@"); break ;;
      -*)           die "Unknown option: $1 (see --help)" ;;
      *)            args+=("$1") ;;
    esac
    shift
  done
  local cmd="${args[0]:-menu}" rc=0

  check_root
  load_config
  ensure_dirs
  trap cleanup EXIT
  trap on_interrupt INT TERM
  acquire_lock
  _log INFO "--- $SCRIPT_NAME $VERSION started: ${cmd} (pid $$, yes=$ASSUME_YES)"

  case "$cmd" in
    menu)
      [[ -t 0 && -t 1 ]] || die "The menu needs a terminal. Use a command instead (see --help)."
      main_menu ;;
    status)  AUTO_FIX=0; run_doctor; rc=$? ;;
    doctor|heal|check) run_doctor; rc=$? ;;
    restart) restart_target "${args[1]:-all}"; rc=$? ;;
    wp-version) show_wp_version "${args[1]:-$WP_LOCALE}"; rc=$? ;;
    wp-download)
      wp_fetch_core "${args[1]:-$WP_LOCALE}" && echo "$WP_CORE_ARCHIVE"; rc=$? ;;
    wp-update)
      [[ -n "${args[1]:-}" ]] || die "Usage: $SCRIPT_NAME wp-update <site-path>"
      update_wordpress "${args[1]}"; rc=$? ;;
    backup)
      [[ -n "${args[1]:-}" ]] || die "Usage: $SCRIPT_NAME backup <site-path> [dbname]"
      db_init >/dev/null 2>&1
      backup_run "${args[1]}" "${args[2]:-}"; rc=$? ;;
    watchdog-install) install_watchdog; rc=$? ;;
    watchdog-remove)  remove_watchdog; rc=$? ;;
    help) usage ;;
    *) die "Unknown command: $cmd (see --help)" ;;
  esac
  exit "$rc"
}

# Run only when executed (not when sourced, e.g. by tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
