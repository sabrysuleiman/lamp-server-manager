#!/usr/bin/env bash
#
# server-manager.sh
# ------------------------------------------------------------
# LAMP (Apache2 / MySQL-MariaDB / PHP) server management toolkit
# for Ubuntu.
#
# Tools included:
#   1) Create Apache VirtualHost (+ optional Let's Encrypt SSL)
#   2) Deploy new WordPress site (extract zip, create DB, wp-config, vhost)
#   3) List VirtualHosts
#   4) Delete VirtualHost (+ optional DB / files)
#   5) Create MySQL database + user
#   6) Backup a site (files + DB)
#   7) Restore a site from backup
#   8) Switch PHP version for a vhost
#   9) Restart / status of Apache, MySQL, PHP-FPM
#  10) Tail Apache/PHP error logs
#
# Usage:
#   sudo bash server-manager.sh
#
# Tested target: Ubuntu 22.04 / 24.04 with apache2, mysql-server
# or mariadb-server, php + libapache2-mod-php (or php-fpm).
# ------------------------------------------------------------

set -uo pipefail

# ------------------------- Config ----------------------------
WWW_ROOT="/var/www"
WP_ROOT="/var/www/wp"
VHOST_AVAILABLE="/etc/apache2/sites-available"
VHOST_ENABLED="/etc/apache2/sites-enabled"
BACKUP_DIR="/var/backups/server-manager"
LOG_FILE="/var/log/server-manager.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ------------------------- Helpers -----------------------------
log()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE" 2>/dev/null; }
info()  { echo -e "${CYAN}[INFO]${NC} $*"; log "INFO: $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; log "OK: $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; log "WARN: $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; log "ERROR: $*"; }

pause() { read -rp "Press Enter to continue..." _; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use: sudo bash server-manager.sh)"
        exit 1
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

random_string() {
    local length="${1:-20}"
    tr -dc 'A-Za-z0-9_@#%' </dev/urandom | head -c "$length"
}

validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

ensure_dirs() {
    mkdir -p "$WP_ROOT" "$BACKUP_DIR"
    touch "$LOG_FILE"
}

detect_php_versions() {
    ls /etc/php/ 2>/dev/null | sort -V
}

detect_mysql_cmd() {
    if command_exists mariadb; then echo "mariadb"
    elif command_exists mysql; then echo "mysql"
    else echo ""
    fi
}

restart_apache() {
    if systemctl restart apache2; then
        ok "Apache restarted"
    else
        err "Failed to restart Apache"
        return 1
    fi
}

restart_php_fpm() {
    local restarted=0
    for s in $(systemctl list-unit-files --type=service 2>/dev/null | grep -o 'php[0-9.]*-fpm.service' | sort -u); do
        if systemctl is-active --quiet "$s" || systemctl is-enabled --quiet "$s"; then
            if systemctl restart "$s" 2>/dev/null; then
                ok "Restarted $s"
                restarted=1
            fi
        fi
    done
    if [[ $restarted -eq 0 ]]; then
        for s in $(systemctl list-units --type=service --all 2>/dev/null | grep -o 'php[0-9.]*-fpm.service' | sort -u); do
            if systemctl restart "$s" 2>/dev/null; then
                ok "Restarted $s"
                restarted=1
            fi
        done
    fi
}

restart_servers() {
    info "Restarting servers..."
    restart_apache
    restart_php_fpm
}
add_hosts_entry() {
    local domain="$1"
    local alias="${2:-}"
    local ip="127.0.0.1"

    [[ -z "$domain" ]] && return 0

    if grep -qE "(^|[[:space:]])${domain}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
        info "Domain '${domain}' already exists in /etc/hosts."
        return 0
    fi

    local entry="${ip}	${domain}"
    if [[ -n "$alias" ]]; then
        if ! grep -qE "(^|[[:space:]])${alias}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
            entry="${entry}	${alias}"
        fi
    fi

    echo -e "${entry}" >> /etc/hosts
    ok "Added to /etc/hosts: ${entry}"
}

remove_hosts_entry() {
    local domain="$1"
    [[ -z "$domain" || "$domain" == "localhost" ]] && return 0

    if grep -qE "(^|[[:space:]])${domain}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
        sed -i "/[[:space:]]${domain}\([[:space:]]\|$\)/d" /etc/hosts
        ok "Removed '${domain}' from /etc/hosts"
    fi
}


# =====================================================================
# TOOL 1: Create VirtualHost
# =====================================================================
create_vhost() {
    echo -e "\n${CYAN}=== Create Apache VirtualHost ===${NC}"

    read -rp "Domain (e.g. example.com): " DOMAIN
    if ! validate_domain "$DOMAIN"; then
        err "Invalid domain name."
        return 1
    fi

    read -rp "Document root [${WWW_ROOT}/${DOMAIN}]: " DOCROOT
    DOCROOT="${DOCROOT:-$WWW_ROOT/$DOMAIN}"

    local php_versions
    php_versions=$(detect_php_versions)
    if [[ -n "$php_versions" ]]; then
        echo "Installed PHP versions: $php_versions"
    fi
    read -rp "PHP version to use (e.g. 8.3, blank = default handler): " PHPVER

    read -rp "Enable www -> non-www redirect / alias? (y/N): " ALIAS_WWW
    read -rp "Issue free Let's Encrypt SSL now via certbot? (y/N): " WANT_SSL

    if [[ ! -d "$DOCROOT" ]]; then
        mkdir -p "$DOCROOT"
        cat > "$DOCROOT/index.html" <<EOF
<h1>${DOMAIN} is working</h1>
EOF
        chown -R www-data:www-data "$DOCROOT"
        chmod -R 755 "$DOCROOT"
        info "Created document root at $DOCROOT"
    else
        warn "Document root already exists, leaving contents untouched."
    fi

    local server_alias=""
    [[ "$ALIAS_WWW" =~ ^[Yy]$ ]] && server_alias="ServerAlias www.${DOMAIN}"

    local php_handler=""
    if [[ -n "$PHPVER" ]]; then
        php_handler="    <FilesMatch \.php\$>
        SetHandler \"proxy:unix:/run/php/php${PHPVER}-fpm.sock|fcgi://localhost\"
    </FilesMatch>"
    fi

    local conf_file="$VHOST_AVAILABLE/${DOMAIN}.conf"
    cat > "$conf_file" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ${server_alias}
    DocumentRoot ${DOCROOT}

${php_handler}

    <Directory ${DOCROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF

    a2ensite "${DOMAIN}.conf" >/dev/null 2>&1
    [[ -n "$PHPVER" ]] && a2enmod proxy_fcgi setenvif >/dev/null 2>&1

    if apache2ctl configtest >/dev/null 2>&1; then
        if [[ -n "$PHPVER" ]]; then
            systemctl restart "php${PHPVER}-fpm" 2>/dev/null || systemctl start "php${PHPVER}-fpm" 2>/dev/null
        fi
        restart_servers
        ok "VirtualHost created and enabled: $conf_file"
    else
        err "Apache config test failed. Check with: apache2ctl configtest"
        return 1
    fi

    if [[ "$WANT_SSL" =~ ^[Yy]$ ]]; then
        if command_exists certbot; then
            certbot --apache -d "$DOMAIN" $( [[ -n "$server_alias" ]] && echo "-d www.${DOMAIN}" )
            restart_servers
        else
            warn "certbot not installed. Install with: apt install certbot python3-certbot-apache"
        fi
    fi

    read -rp "Add entry to /etc/hosts (127.0.0.1 ${DOMAIN})? (y/N): " ADD_HOSTS
    if [[ "$ADD_HOSTS" =~ ^[Yy]$ ]]; then
        local host_alias=""
        [[ "$ALIAS_WWW" =~ ^[Yy]$ ]] && host_alias="www.${DOMAIN}"
        add_hosts_entry "$DOMAIN" "$host_alias"
    fi

    ok "Done. Site should be reachable at http://${DOMAIN}."
}

# =====================================================================
# TOOL 2: New WordPress site
# =====================================================================
new_wordpress() {
    echo -e "\n${CYAN}=== Deploy New WordPress Site ===${NC}"

    local mysql_cmd
    mysql_cmd=$(detect_mysql_cmd)
    if [[ -z "$mysql_cmd" ]]; then
        err "Neither 'mysql' nor 'mariadb' client found. Install mysql-server or mariadb-server first."
        return 1
    fi

    read -rp "Site name (folder name under ${WP_ROOT}, e.g. myclient): " SITE_NAME
    SITE_NAME=$(echo "$SITE_NAME" | tr -cd 'a-zA-Z0-9_-')
    if [[ -z "$SITE_NAME" ]]; then
        err "Invalid site name."
        return 1
    fi

    local target_dir="${WP_ROOT}/${SITE_NAME}"
    if [[ -d "$target_dir" ]]; then
        err "Directory already exists: $target_dir"
        return 1
    fi

    read -rp "Domain for this WordPress site (e.g. site.com): " DOMAIN
    if ! validate_domain "$DOMAIN"; then
        err "Invalid domain name."
        return 1
    fi

    read -rp "Path to wp.zip (WordPress core zip file): " WP_ZIP
    if [[ ! -f "$WP_ZIP" ]]; then
        err "File not found: $WP_ZIP"
        return 1
    fi

    if ! command_exists unzip; then
        info "Installing unzip..."
        apt-get install -y unzip >/dev/null 2>&1
    fi

    mkdir -p "$target_dir"
    info "Extracting $WP_ZIP into $target_dir ..."
    unzip -q "$WP_ZIP" -d "/tmp/wp_extract_${SITE_NAME}"

    # wp.zip from wordpress.org unpacks into a "wordpress/" subfolder — flatten it.
    if [[ -d "/tmp/wp_extract_${SITE_NAME}/wordpress" ]]; then
        mv "/tmp/wp_extract_${SITE_NAME}/wordpress/"* "$target_dir"/
    else
        mv "/tmp/wp_extract_${SITE_NAME}/"* "$target_dir"/
    fi
    rm -rf "/tmp/wp_extract_${SITE_NAME}"

    if [[ ! -f "$target_dir/wp-config-sample.php" ]]; then
        err "wp-config-sample.php not found after extraction. Is $WP_ZIP a valid WordPress core zip?"
        return 1
    fi
    ok "WordPress core extracted to $target_dir"

    # --- Database ---
    local DB_NAME="wp_${SITE_NAME}"
    local DB_USER="wp_${SITE_NAME}"
    local DB_PASS
    DB_PASS=$(random_string 20)
    DB_NAME=$(echo "$DB_NAME" | tr -cd 'a-zA-Z0-9_' | cut -c1-32)
    DB_USER=$(echo "$DB_USER" | tr -cd 'a-zA-Z0-9_' | cut -c1-32)

    info "Creating MySQL database and user..."
    $mysql_cmd -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

    if [[ $? -ne 0 ]]; then
        err "Database creation failed. Run 'sudo mysql' manually and check root auth (socket vs password)."
        return 1
    fi
    ok "Database '${DB_NAME}' and user '${DB_USER}' created."

    # --- wp-config.php ---
    info "Generating wp-config.php ..."
    cp "$target_dir/wp-config-sample.php" "$target_dir/wp-config.php"

    sed -i "s/database_name_here/${DB_NAME}/" "$target_dir/wp-config.php"
    sed -i "s/username_here/${DB_USER}/" "$target_dir/wp-config.php"
    sed -i "s/password_here/${DB_PASS}/" "$target_dir/wp-config.php"

    # Fetch fresh secret keys/salts; fall back to local random values if offline.
    local salts
    salts=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null)
    if [[ -n "$salts" ]]; then
        # Replace the default AUTH_KEY..NONCE_SALT block with fetched salts.
        php_block_start="/**#@+"
        awk -v salts="$salts" '
            BEGIN{skip=0}
            /put your unique phrase here/ {next}
            /#@\+/ {skip++; if(skip==1){print salts; next} else {skip=0; next}}
            skip==1 {next}
            {print}
        ' "$target_dir/wp-config.php" > "$target_dir/wp-config.tmp" && mv "$target_dir/wp-config.tmp" "$target_dir/wp-config.php"
        ok "Fetched unique secret keys/salts from wordpress.org."
    else
        warn "Could not reach wordpress.org for salts; leaving placeholder keys. Generate later at https://api.wordpress.org/secret-key/1.1/salt/"
    fi

    chown -R www-data:www-data "$target_dir"
    find "$target_dir" -type d -exec chmod 755 {} \;
    find "$target_dir" -type f -exec chmod 644 {} \;
    ok "Permissions set for www-data."

    # --- VirtualHost for this WP site ---
    info "Creating VirtualHost for ${DOMAIN} -> ${target_dir} ..."
    local conf_file="$VHOST_AVAILABLE/${DOMAIN}.conf"
    cat > "$conf_file" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${target_dir}

    <Directory ${target_dir}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF
    a2ensite "${DOMAIN}.conf" >/dev/null 2>&1
    a2enmod rewrite >/dev/null 2>&1

    if apache2ctl configtest >/dev/null 2>&1; then
        restart_servers
        ok "VirtualHost enabled: $conf_file"
    else
        err "Apache config test failed for ${DOMAIN}.conf — check manually."
        return 1
    fi

    read -rp "Add entry to /etc/hosts (127.0.0.1 ${DOMAIN})? (y/N): " ADD_HOSTS
    if [[ "$ADD_HOSTS" =~ ^[Yy]$ ]]; then
        add_hosts_entry "$DOMAIN" "www.${DOMAIN}"
    fi

    echo -e "\n${GREEN}=== WordPress site deployed ===${NC}"
    echo "Domain:      http://${DOMAIN}"
    echo "Path:        ${target_dir}"
    echo "DB Name:     ${DB_NAME}"
    echo "DB User:     ${DB_USER}"
    echo "DB Password: ${DB_PASS}"
    echo "-> Point DNS for ${DOMAIN} at this server, then visit it to finish the WordPress install wizard."
    echo "-> Credentials also saved to: ${BACKUP_DIR}/${SITE_NAME}-credentials.txt"
    mkdir -p "$BACKUP_DIR"
    cat > "${BACKUP_DIR}/${SITE_NAME}-credentials.txt" <<EOF
Site: ${DOMAIN}
Path: ${target_dir}
DB Name: ${DB_NAME}
DB User: ${DB_USER}
DB Password: ${DB_PASS}
Created: $(date)
EOF
    chmod 600 "${BACKUP_DIR}/${SITE_NAME}-credentials.txt"
}

# =====================================================================
# TOOL 3: List VirtualHosts
# =====================================================================
list_vhosts() {
    echo -e "\n${CYAN}=== Enabled VirtualHosts ===${NC}"
    if [[ -d "$VHOST_ENABLED" ]]; then
        for f in "$VHOST_ENABLED"/*.conf; do
            [[ -e "$f" ]] || continue
            local name docroot
            name=$(basename "$f" .conf)
            docroot=$(grep -m1 -i 'DocumentRoot' "$f" | awk '{print $2}')
            printf "  %-30s -> %s\n" "$name" "${docroot:-?}"
        done
    fi
}

# =====================================================================
# TOOL 4: Delete VirtualHost
# =====================================================================
delete_vhost() {
    echo -e "\n${CYAN}=== Delete VirtualHost ===${NC}"
    list_vhosts
    read -rp "Domain to delete (must match .conf filename without extension): " DOMAIN
    local conf_file="$VHOST_AVAILABLE/${DOMAIN}.conf"
    if [[ ! -f "$conf_file" ]]; then
        err "No such vhost: $conf_file"
        return 1
    fi
    read -rp "Also delete document root & MySQL DB/user if named wp_${DOMAIN}? (y/N): " PURGE

    a2dissite "${DOMAIN}.conf" >/dev/null 2>&1
    rm -f "$conf_file"
    restart_servers
    ok "VirtualHost removed: $DOMAIN"

    read -rp "Also remove domain from /etc/hosts? (y/N): " REMOVE_HOSTS
    if [[ "$REMOVE_HOSTS" =~ ^[Yy]$ ]]; then
        remove_hosts_entry "$DOMAIN"
        remove_hosts_entry "www.${DOMAIN}"
    fi

    if [[ "$PURGE" =~ ^[Yy]$ ]]; then
        local docroot
        docroot=$(grep -m1 -i 'DocumentRoot' "$conf_file" 2>/dev/null | awk '{print $2}')
        read -rp "Confirm delete files at [${docroot:-unknown}]? (y/N): " CONFIRM_FILES
        if [[ "$CONFIRM_FILES" =~ ^[Yy]$ && -n "$docroot" ]]; then
            rm -rf "$docroot"
            ok "Removed files at $docroot"
        fi
        local mysql_cmd; mysql_cmd=$(detect_mysql_cmd)
        read -rp "MySQL DB name to drop (blank = skip): " DBNAME
        if [[ -n "$DBNAME" && -n "$mysql_cmd" ]]; then
            $mysql_cmd -u root -e "DROP DATABASE IF EXISTS \`${DBNAME}\`; DROP USER IF EXISTS '${DBNAME}'@'localhost';"
            ok "Dropped database/user: $DBNAME"
        fi
    fi
}

# =====================================================================
# TOOL 5: Create MySQL database + user (standalone)
# =====================================================================
create_mysql_db() {
    echo -e "\n${CYAN}=== Create MySQL Database + User ===${NC}"
    local mysql_cmd; mysql_cmd=$(detect_mysql_cmd)
    if [[ -z "$mysql_cmd" ]]; then
        err "No mysql/mariadb client found."
        return 1
    fi
    read -rp "Database name: " DBNAME
    read -rp "DB username: " DBUSER
    read -rp "DB password (blank = auto-generate): " DBPASS
    [[ -z "$DBPASS" ]] && DBPASS=$(random_string 20)

    $mysql_cmd -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DBNAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';
GRANT ALL PRIVILEGES ON \`${DBNAME}\`.* TO '${DBUSER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    ok "Database '${DBNAME}' and user '${DBUSER}' ready."
    echo "Password: ${DBPASS}"
}

# =====================================================================
# TOOL 6: Backup a site (files + DB)
# =====================================================================
backup_site() {
    echo -e "\n${CYAN}=== Backup Site ===${NC}"
    read -rp "Path to site files: " SITEPATH
    if [[ ! -d "$SITEPATH" ]]; then
        err "Path not found: $SITEPATH"
        return 1
    fi
    read -rp "MySQL DB name to include (blank = files only): " DBNAME

    mkdir -p "$BACKUP_DIR"
    local ts stamp_name
    ts=$(date +%Y%m%d-%H%M%S)
    stamp_name="$(basename "$SITEPATH")-${ts}"

    tar -czf "${BACKUP_DIR}/${stamp_name}-files.tar.gz" -C "$(dirname "$SITEPATH")" "$(basename "$SITEPATH")"
    ok "Files backed up: ${BACKUP_DIR}/${stamp_name}-files.tar.gz"

    if [[ -n "$DBNAME" ]] && command_exists mysqldump; then
        mysqldump -u root "$DBNAME" | gzip > "${BACKUP_DIR}/${stamp_name}-db.sql.gz"
        ok "Database backed up: ${BACKUP_DIR}/${stamp_name}-db.sql.gz"
    fi
}

# =====================================================================
# TOOL 7: Restore a site from backup
# =====================================================================
restore_site() {
    echo -e "\n${CYAN}=== Restore Site ===${NC}"
    ls -1 "$BACKUP_DIR" 2>/dev/null | grep -E 'files.tar.gz$'
    read -rp "Backup files archive path: " ARCHIVE
    read -rp "Restore destination directory: " DEST
    if [[ ! -f "$ARCHIVE" ]]; then
        err "Archive not found."
        return 1
    fi
    mkdir -p "$DEST"
    tar -xzf "$ARCHIVE" -C "$DEST" --strip-components=1
    chown -R www-data:www-data "$DEST"
    ok "Files restored to $DEST"

    read -rp "Also restore a DB dump (.sql.gz path, blank = skip): " DUMP
    if [[ -n "$DUMP" && -f "$DUMP" ]]; then
        read -rp "Target DB name (must already exist): " DBNAME
        gunzip -c "$DUMP" | mysql -u root "$DBNAME"
        ok "Database restored into $DBNAME"
    fi
}

# =====================================================================
# TOOL 8: Switch PHP version for a vhost
# =====================================================================
switch_php_version() {
    echo -e "\n${CYAN}=== Switch PHP Version ===${NC}"
    echo "Installed versions: $(detect_php_versions | tr '\n' ' ')"
    read -rp "Domain (vhost .conf name): " DOMAIN
    read -rp "New PHP version (e.g. 8.3): " PHPVER
    local conf_file="$VHOST_AVAILABLE/${DOMAIN}.conf"
    if [[ ! -f "$conf_file" ]]; then
        err "vhost not found: $conf_file"
        return 1
    fi
    if ! [[ -S "/run/php/php${PHPVER}-fpm.sock" ]]; then
        warn "Socket /run/php/php${PHPVER}-fpm.sock not found — ensure php${PHPVER}-fpm is installed and running."
    fi

    # Remove existing FilesMatch php handler block, then insert new one.
    python3 - "$conf_file" "$PHPVER" <<'PYEOF'
import re, sys
path, ver = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = re.sub(r'\s*<FilesMatch \\\.php\$>.*?</FilesMatch>', '', content, flags=re.S)
block = f'\n    <FilesMatch \\.php$>\n        SetHandler "proxy:unix:/run/php/php{ver}-fpm.sock|fcgi://localhost"\n    </FilesMatch>\n'
content = content.replace('</VirtualHost>', block + '</VirtualHost>')
with open(path, 'w') as f:
    f.write(content)
PYEOF

    a2enmod proxy_fcgi setenvif >/dev/null 2>&1
    if apache2ctl configtest >/dev/null 2>&1; then
        if [[ -n "$PHPVER" ]]; then
            systemctl restart "php${PHPVER}-fpm" 2>/dev/null || systemctl start "php${PHPVER}-fpm" 2>/dev/null
        fi
        restart_servers
        ok "Switched $DOMAIN to PHP $PHPVER"
    else
        err "Config test failed after edit — check $conf_file manually."
    fi
}

# =====================================================================
# TOOL 9: Restart / status services
# =====================================================================
services_menu() {
    echo -e "\n${CYAN}=== Services ===${NC}"
    echo "1) Restart Apache"
    echo "2) Restart MySQL/MariaDB"
    echo "3) Restart all PHP-FPM pools"
    echo "4) Restart all web servers (Apache + PHP-FPM)"
    echo "5) Show status of apache2, mysql, php-fpm"
    read -rp "Choose: " SVC
    case "$SVC" in
        1) restart_apache ;;
        2) systemctl restart mysql 2>/dev/null || systemctl restart mariadb && ok "MySQL/MariaDB restarted" ;;
        3) restart_php_fpm ;;
        4) restart_servers ;;
        5) systemctl status apache2 --no-pager -l | head -5
           systemctl status mysql --no-pager -l 2>/dev/null | head -5 || systemctl status mariadb --no-pager -l | head -5
           systemctl list-units --type=service | grep php ;;
        *) warn "Invalid choice" ;;
    esac
}

# =====================================================================
# TOOL 10: Tail logs
# =====================================================================
view_logs() {
    echo -e "\n${CYAN}=== Logs ===${NC}"
    echo "1) Apache error log (global)"
    echo "2) Apache access log (global)"
    echo "3) Specific site's error log"
    read -rp "Choose: " LG
    case "$LG" in
        1) tail -n 100 -f /var/log/apache2/error.log ;;
        2) tail -n 100 -f /var/log/apache2/access.log ;;
        3) read -rp "Domain: " DOMAIN
           tail -n 100 -f "/var/log/apache2/${DOMAIN}_error.log" ;;
        *) warn "Invalid choice" ;;
    esac
}

# ------------------------- Main Menu -----------------------------
main_menu() {
    while true; do
        echo -e "\n${CYAN}==================================================${NC}"
        echo -e "${CYAN}      LAMP Server Manager — Ubuntu (Apache/MySQL/PHP)${NC}"
        echo -e "${CYAN}==================================================${NC}"
        echo " 1) Create VirtualHost"
        echo " 2) Deploy new WordPress site"
        echo " 3) List VirtualHosts"
        echo " 4) Delete VirtualHost"
        echo " 5) Create MySQL database + user"
        echo " 6) Backup a site (files + DB)"
        echo " 7) Restore a site from backup"
        echo " 8) Switch PHP version for a vhost"
        echo " 9) Services: restart / status"
        echo "10) View logs"
        echo " 0) Exit"
        read -rp "Choose an option: " CHOICE
        case "$CHOICE" in
            1) create_vhost ;;
            2) new_wordpress ;;
            3) list_vhosts ;;
            4) delete_vhost ;;
            5) create_mysql_db ;;
            6) backup_site ;;
            7) restore_site ;;
            8) switch_php_version ;;
            9) services_menu ;;
            10) view_logs ;;
            0) echo "Bye."; exit 0 ;;
            *) warn "Invalid option." ;;
        esac
        pause
    done
}

# ------------------------- Entry point -----------------------------
check_root
ensure_dirs
main_menu