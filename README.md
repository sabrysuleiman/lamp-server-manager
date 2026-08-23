# ⚡ LAMP Server Manager (`server-manager.sh`)

[![Bash](https://img.shields.io/badge/Language-Bash%205.0+-4EAA25?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%2022.04%20%7C%2024.04%20LTS-E95420?style=flat&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Web Server](https://img.shields.io/badge/Server-Apache%202.4-D22128?style=flat&logo=apache&logoColor=white)](https://httpd.apache.org/)
[![Database](https://img.shields.io/badge/Database-MySQL%20%7C%20MariaDB-4479A1?style=flat&logo=mysql&logoColor=white)](https://www.mysql.com/)
[![PHP](https://img.shields.io/badge/PHP-Multi--Version%20(PHP--FPM)-777BB4?style=flat&logo=php&logoColor=white)](https://www.php.net/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> **An interactive, all-in-one CLI toolkit for managing Apache VirtualHosts, multi-version PHP-FPM, automated WordPress deployments, MySQL databases, backups, and local `/etc/hosts` mapping on Ubuntu LAMP stacks.**

---

## 🚀 Key Features

- **🌐 VirtualHost Automation**:
  - Create Apache 2.4 VirtualHosts with custom document roots and directory permissions.
  - Optional `www` to non-`www` aliases.
  - Instant Free SSL generation via **Certbot** (Let's Encrypt).
  - **Local DNS Integration**: Automatically syncs domains into `/etc/hosts` (`127.0.0.1`) for local testing.
- **🚀 One-Click WordPress Deployment**:
  - Extracts WordPress core archive (`wp.zip`).
  - Auto-provisions isolated MySQL database and user with secure random passwords.
  - Automatically fetches cryptographically unique salts from `api.wordpress.org`.
  - Configures `wp-config.php`, sets `www-data` ownership, and generates the Apache VirtualHost.
  - Saves site deployment credentials into `/var/backups/server-manager/<site>-credentials.txt`.
- **🔄 Multi-PHP Version Switcher**:
  - Switch PHP-FPM handler versions on any VirtualHost on-the-fly (e.g. PHP 7.4, 8.1, 8.2, 8.3).
  - Socket validation and automatic Apache / PHP-FPM service reloads.
- **🗄️ Database Management**:
  - Standalone MySQL/MariaDB database and user creator with `utf8mb4_unicode_ci` collation.
- **📦 Backup & Disaster Recovery**:
  - Automated timestamped file archive (`.tar.gz`) and database dump (`mysqldump | gzip`).
  - One-click restore tool to unpack backups and re-import database schemas.
- **🛠️ Service & Log Utilities**:
  - Centralized restart/status for Apache2, MySQL/MariaDB, and all PHP-FPM pools.
  - Real-time `tail -f` log viewer for global Apache error/access logs and per-vhost error logs.

---

## 📋 Prerequisites

Designed and tested for **Ubuntu 22.04 LTS** and **Ubuntu 24.04 LTS** with root/sudo privileges:

```bash
sudo apt update
sudo apt install -y apache2 mysql-server python3 curl unzip tar gzip
# Optional (for SSL & Multi-PHP):
sudo apt install -y certbot python3-certbot-apache
```

---

## 📥 Installation & Setup

1. **Download / Copy the script**:
   ```bash
   sudo cp /var/www/server-manager.sh /usr/local/bin/server-manager
   sudo chmod +x /usr/local/bin/server-manager
   ```

2. **Run the manager**:
   ```bash
   sudo server-manager
   ```

---

## 🖥️ Interactive Menu Overview

```text
==================================================
      LAMP Server Manager — Ubuntu (Apache/MySQL/PHP)
==================================================
 1) Create VirtualHost
 2) Deploy new WordPress site
 3) List VirtualHosts
 4) Delete VirtualHost
 5) Create MySQL database + user
 6) Backup a site (files + DB)
 7) Restore a site from backup
 8) Switch PHP version for a vhost
 9) Services: restart / status
10) View logs
 0) Exit
```
