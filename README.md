# server-manager

**A single-file LAMP server toolkit for Ubuntu/Debian: deploy, monitor, repair and back up Apache + MySQL/MariaDB + PHP-FPM sites, with WordPress always installed from the official latest release.**

![Shell](https://img.shields.io/badge/shell-bash-4EAA25)
![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04%20%7C%2024.04-E95420)
![Version](https://img.shields.io/badge/version-2.0.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)

`server-manager.sh` replaces a pile of manual `apache2ctl`, `systemctl`, `mysql` and `certbot` steps with one interactive menu and a set of scriptable commands. It verifies the state of the server before and after every change, repairs the common problems that normally need a human, and refuses to leave the server worse than it found it.

---

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands and options](#commands-and-options)
- [Health checks and auto-repair](#health-checks-and-auto-repair)
- [WordPress deployment and updates](#wordpress-deployment-and-updates)
- [Backups and restore](#backups-and-restore)
- [Watchdog (automatic self-healing)](#watchdog-automatic-self-healing)
- [Configuration](#configuration)
- [Safety design](#safety-design)
- [File locations](#file-locations)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Development](#development)
- [Changelog](#changelog)
- [License](#license)

---

## Features

| Area | What you get |
| --- | --- |
| **WordPress** | Always downloads the newest release from wordpress.org, verifies it against the official checksum, builds `wp-config.php` with fresh salts, and creates the database, user and vhost in one run. Any locale (`en_US`, `ar`, `de_DE`, ...). |
| **Health checks** | `status` (read-only) and `doctor` (with repairs) inspect system resources, services, Apache config, ports, database, PHP-FPM, every site's HTTP response, SSL expiry, WordPress versions and the firewall. |
| **Self-healing** | Starts stopped services, enables them at boot, enables missing Apache modules, removes broken symlinks, restarts PHP-FPM with a missing socket, renews expiring certificates, and more. |
| **Safe changes** | Apache is config-tested before every reload. An invalid config never touches the running service, and a broken new vhost is removed automatically so other sites stay online. |
| **Rollback** | If a multi-step action fails halfway (for example deploying a site), files, database, user and vhost are cleaned up. |
| **Virtual hosts** | Create, list, delete, switch PHP version per site (HTTP and HTTPS configs together), optional Let's Encrypt SSL that skips names without DNS records. |
| **Backups** | Files + database, integrity-verified, with retention pruning and automatic safety snapshots before updates, restores and deletions. |
| **Automation** | Every important action is also a command, with proper exit codes, quiet mode, locking, logging and optional email/webhook alerts. A cron-based watchdog is one command away. |

## Requirements

- Ubuntu 22.04 / 24.04 (other Debian-based systems should work)
- `root` access (run with `sudo`)
- systemd
- Apache 2.4 (`apache2`)
- MySQL or MariaDB, with root access through the unix socket (the Ubuntu default), `/etc/mysql/debian.cnf`, or `~/.my.cnf`
- PHP-FPM (or `libapache2-mod-php`)
- `curl`, `tar`, `python3` (used to parse the WordPress API response), `flock` (util-linux)

Installed on demand, with a confirmation prompt: `unzip`, `rsync`, `certbot` + `python3-certbot-apache`, and the PHP-FPM packages and modules WordPress needs.

Optional: `ufw` (firewall check), `mail` (email alerts), `wp-cli` (used for the database upgrade after a core update when present).

## Installation

```bash
git clone https://github.com/YOUR-USERNAME/server-manager.git
cd server-manager
sudo bash server-manager.sh
```

To make it available system-wide:

```bash
sudo install -m 750 -o root -g root server-manager.sh /usr/local/sbin/server-manager.sh
```

> **Run it on a staging server first.** The script changes system configuration as root. Read it, try `status`, and only then use it in production.

## Quick start

```bash
sudo bash server-manager.sh status      # read-only health report, changes nothing
sudo bash server-manager.sh doctor      # health report + automatic repairs
sudo bash server-manager.sh             # interactive menu
```

Interactive menu:

```
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
```

Example `doctor` output on a server where services were down:

```
== Services ==
[ OK ] apache2 is running
[FAIL] mariadb is NOT running
[INFO] Starting mariadb ...
[ OK ] mariadb started
[ OK ] FIXED: mariadb started
[FAIL] php8.3-fpm is NOT running
[INFO] Starting php8.3-fpm ...
[ OK ] php8.3-fpm started
[ OK ] FIXED: php8.3-fpm started

== Summary ==
11 passed, 0 warning(s), 0 failure(s), 2 fixed automatically
```

## Commands and options

```
sudo bash server-manager.sh <command> [options]
```

| Command | Description |
| --- | --- |
| `menu` | Interactive menu (default; needs a terminal). |
| `status` | Read-only health report. Changes nothing. |
| `doctor` | Health report plus automatic repairs. Aliases: `heal`, `check`. |
| `restart [target]` | Safe, verified restart. Targets: `apache`, `reload` (graceful), `db`, `php`, `all` (DB, then PHP-FPM, then Apache). |
| `wp-version [locale]` | Show the latest WordPress release and its PHP/MySQL requirements. |
| `wp-download [locale]` | Download and verify the latest WordPress into the cache; prints the archive path. |
| `wp-update <path>` | Update the WordPress core of an existing site (backs up first). |
| `backup <path> [dbname]` | Back up site files and, if given, a database; then prune old backups. |
| `watchdog-install` | Install the cron-based watchdog (asks to remove it if already installed). |
| `watchdog-remove` | Remove the watchdog. |
| `help` | Show usage. |

| Option | Description |
| --- | --- |
| `-y`, `--yes` | Accept the default answer to every prompt. Defaults for destructive actions are always "no". |
| `-q`, `--quiet` | Print only warnings and errors (for cron). |
| `--fast` | Skip checks that need internet access. |
| `--no-fix` | Report only; never modify anything. |
| `-h`, `--help` / `-V`, `--version` | Usage / version. |

**Exit codes**

| Code | Meaning |
| --- | --- |
| `0` | Healthy (`status` / `doctor`), or success. |
| `1` | Warnings only (`status` / `doctor`), or a failed action. |
| `2` | Unresolved failures remain (`status` / `doctor`). |
| `75` | Another instance is already running. |
| `130` | Interrupted (Ctrl-C). |

This makes `status` usable from monitoring systems and shell scripts:

```bash
sudo bash server-manager.sh status --quiet --fast || echo "needs attention (exit $?)"
```

## Health checks and auto-repair

`status` runs every check and only reports. `doctor` runs the same checks and offers a repair for each fixable problem (with `--yes` it applies the default answer without asking).

| Check | Reports | Automatic repair |
| --- | --- | --- |
| **System** | Load vs. CPU cores, available memory, missing swap on small servers, disk usage (warn at 85%, fail at 95%), inode usage, OOM-killer events in the last 24 h, pending reboot | When a disk is critical: clean the apt cache, vacuum the journal to 7 days, prune expired backups |
| **Services** | `apache2`, MySQL/MariaDB and every `php*-fpm` unit: running and enabled at boot | Start the service (with verification and log excerpt on failure); enable at boot |
| **Apache config** | `configtest` result, missing global `ServerName`, `mod_rewrite` | Remove broken symlinks in `*-enabled`; enable the module a failing directive needs (`rewrite`, `headers`, `expires`, `ssl`, `proxy`, ...); add `ServerName localhost`; enable `mod_rewrite` |
| **Ports** | Port 80 listening; port 443 when SSL vhosts exist | Reported only; the process holding a port is shown when Apache fails to start |
| **Database** | Root connectivity, connection usage vs. `max_connections` | Reported only |
| **PHP** | FPM sockets, newest PHP vs. WordPress' minimum, missing PHP modules | Restart FPM when its socket is missing; install missing modules (default: no) |
| **Websites** | DocumentRoot exists, PHP-FPM socket for each vhost, HTTP status through Apache (2xx/3xx OK, 4xx warn, 5xx and no answer fail, with the last error-log lines), SSL certificate expiry | Start/install the PHP-FPM version a vhost needs; `certbot renew` when a certificate is close to expiry |
| **WordPress** | Installed vs. latest version, whether WordPress can connect to its own database, `wp-config.php` permissions | `chmod 640 wp-config.php` |
| **Firewall** | UFW active but ports 80/443 not allowed | Reported only |
| **Connectivity** | Outbound access to `api.wordpress.org` (skipped with `--fast`) | Reported only |

## WordPress deployment and updates

### Deploying a new site (menu option 2)

1. Preflight: Apache and the database are running, root DB access works, `curl` is present.
2. You enter a site name, domain and locale (for example `en_US` or `ar`).
3. The latest release is looked up via `api.wordpress.org`, downloaded from wordpress.org, and verified against the official `.sha1` checksum (falling back to `.md5`). A failed checksum discards the download. Verified archives are cached, so repeat deployments of the same version need no download.
4. You pick a PHP version. Missing PHP-FPM packages and WordPress modules (`mysqli`, `curl`, `dom`, `mbstring`, `xml`, `zip`, `gd`, `intl`, `exif`) are detected and offered for installation, and the version is checked against the release's minimum PHP.
5. The files are extracted, a database and user are created (`wp_<site>`, random 24-character password), and `wp-config.php` is generated with unique salts from the official API (random local salts as a fallback). It also sets `FS_METHOD`, `DISALLOW_FILE_EDIT` and `WP_MEMORY_LIMIT`.
6. Ownership is set to the Apache user (directories `755`, files `644`, `wp-config.php` `640`), the vhost is created and enabled, and Apache is reloaded.
7. The site is verified: HTTP status, plus a throw-away PHP probe file that confirms which PHP version Apache is really serving. Then optional Let's Encrypt SSL.
8. Credentials are printed once and saved to `/var/backups/server-manager/credentials/<site>.txt` (mode `600`).

If any step fails, everything created so far is rolled back.

### Updating an existing site

```bash
sudo bash server-manager.sh wp-update /var/www/wp/mysite
```

- Aborts if the site's PHP version is below the new release's minimum.
- Creates a files + database backup first (prefix `pre-update-`).
- Enables maintenance mode while files are replaced.
- Replaces `wp-admin/`, `wp-includes/` and the root core files. **`wp-content/`, `wp-config.php` and `.htaccess` are never touched.**
- Runs the database upgrade (via `wp-cli` if installed, otherwise `wp-admin/upgrade.php`), then verifies the version and HTTP response.
- Plugins and themes are not updated; do that in wp-admin.

`status`/`doctor` flag outdated installs and print the exact `wp-update` command to run.

## Backups and restore

```bash
sudo bash server-manager.sh backup /var/www/wp/mysite wp_mysite
```

- Files are archived to `<name>-<timestamp>-files.tar.gz`, databases dumped with `--single-transaction --routines --triggers --events` to `<name>-<timestamp>-db.sql.gz`. Both are integrity-checked before they are kept, and stored with mode `600` in a `700` directory.
- Free disk space is checked first.
- Backups older than `BACKUP_RETENTION_DAYS` (default 14; `0` disables) are pruned.
- Automatic safety backups are created before deleting a vhost (`final-`), updating WordPress (`pre-update-`) and restoring over existing files (`pre-restore-`).
- Restore (menu option 7) lists backups, verifies the archive, offers a safety snapshot of the current contents, restores files, and can restore the matching database dump.

Nightly backup via cron:

```cron
0 3 * * * root /usr/local/sbin/server-manager.sh backup /var/www/wp/mysite wp_mysite --quiet
```

## Watchdog (automatic self-healing)

```bash
sudo bash server-manager.sh watchdog-install
```

This installs a copy of the script to `/usr/local/sbin/server-manager.sh`, a cron job at `/etc/cron.d/server-manager-watchdog`, and a logrotate policy for the log file. The job runs every `WATCHDOG_INTERVAL_MIN` minutes (default 5):

```
doctor --yes --quiet --fast
```

With `--yes`, only repairs whose default answer is "yes" are applied: restarting stopped services, enabling them at boot, Apache config repairs, restarting a PHP-FPM pool with a missing socket, tightening `wp-config.php` permissions, renewing expiring certificates and the disk cleanup described above. Package installs default to "no" and are never done unattended.

Set `ALERT_EMAIL` and/or `ALERT_WEBHOOK` (Slack-compatible JSON `{"text": ...}`) in the config file to get notified when something fails or is auto-repaired. Alerts are throttled by `ALERT_COOLDOWN` (default one hour). A watchdog run is skipped when you have the interactive menu open; the lock prevents both from running at the same time.

## Configuration

Everything works with no configuration. To override defaults, create `/etc/server-manager.conf` as plain shell assignments. The file is **ignored unless it is owned by root and not writable by group or others**. Set `SM_CONFIG=/path/to/file` to use a different location.

```bash
# /etc/server-manager.conf
WWW_ROOT=/var/www
WP_ROOT=/var/www/wp
BACKUP_DIR=/var/backups/server-manager
BACKUP_RETENTION_DAYS=14
WP_LOCALE=en_US
LE_EMAIL=admin@example.com
DISK_WARN_PCT=85
DISK_CRIT_PCT=95
CERT_WARN_DAYS=14
ALERT_EMAIL=ops@example.com
ALERT_WEBHOOK=https://hooks.example.com/your-webhook
ALERT_COOLDOWN=3600
WATCHDOG_INTERVAL_MIN=5
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `WWW_ROOT` | `/var/www` | Default parent for document roots; also a boundary for destructive operations. |
| `WP_ROOT` | `/var/www/wp` | Where new WordPress sites are created. |
| `VHOST_AVAILABLE` / `VHOST_ENABLED` | `/etc/apache2/sites-available` / `sites-enabled` | Apache vhost directories. |
| `APACHE_LOG_DIR` | `/var/log/apache2` | Where per-site error logs are read from. |
| `BACKUP_DIR` | `/var/backups/server-manager` | Backups and saved credentials. |
| `BACKUP_RETENTION_DAYS` | `14` | Age after which backups are pruned (`0` = keep forever). |
| `CACHE_DIR` | `/var/cache/server-manager` | Verified WordPress archives (the newest two per locale are kept). |
| `STATE_DIR` | `/var/lib/server-manager` | Alert throttling state. |
| `LOG_FILE` | `/var/log/server-manager.log` | Action log. |
| `LOCK_FILE` | `/run/lock/server-manager.lock` | Prevents concurrent runs. |
| `HOSTS_FILE` | `/etc/hosts` | File edited by the optional local hosts-entry feature. |
| `WP_LOCALE` | `en_US` | Default WordPress language. |
| `WP_VERSION_API` / `WP_SALT_API` | wordpress.org endpoints | Where the release and salts are fetched from. |
| `LE_EMAIL` | *(empty)* | Default email for Let's Encrypt notices. |
| `DISK_WARN_PCT` / `DISK_CRIT_PCT` | `85` / `95` | Disk usage thresholds. |
| `CERT_WARN_DAYS` | `14` | Warn (and renew) when a certificate has fewer days left. |
| `ALERT_EMAIL` / `ALERT_WEBHOOK` | *(empty)* | Alert destinations. |
| `ALERT_COOLDOWN` | `3600` | Minimum seconds between alerts. |
| `WATCHDOG_INTERVAL_MIN` | `5` | Watchdog frequency in minutes. |

## Safety design

- **Validate before applying.** Apache's config is tested before every reload or restart; if it is invalid the running service is left alone. A new vhost that breaks the config is removed again immediately.
- **Graceful by default.** Config changes use `reload`, not `restart`, so sites stay up.
- **Verify after acting.** Services are checked to be active after every start/restart, and new sites are verified over HTTP and with a PHP probe.
- **Rollback stack.** Partial deployments are undone on failure or interruption.
- **Path guards.** Recursive `rm` and `chown` only operate on paths strictly inside `WWW_ROOT` or `WP_ROOT`, never on the roots themselves, and `..` traversal is resolved first.
- **Safe defaults.** Prompts for destructive actions default to "no"; `--yes` never overrides a "no" default.
- **Verified downloads.** WordPress archives are checked against the official checksum, and an unverifiable download is refused.
- **Secrets hygiene.** SQL (including passwords) goes through stdin, never the process list; database passwords for tests use `MYSQL_PWD`; backups and credentials files are `600` in `700` directories; the config file must be root-owned.
- **Single instance.** A lock file prevents the menu, cron jobs and CLI calls from running over each other.
- **Audit trail.** Every action is logged to `/var/log/server-manager.log`.

## File locations

| Path | Purpose |
| --- | --- |
| `/var/log/server-manager.log` | Action log (rotated weekly once the watchdog is installed). |
| `/var/backups/server-manager/` | Backups; `credentials/` holds generated DB credentials. |
| `/var/cache/server-manager/` | Cached, verified WordPress archives and their checksums. |
| `/var/lib/server-manager/` | State (alert throttling). |
| `/etc/server-manager.conf` | Optional configuration. |
| `/etc/cron.d/server-manager-watchdog` | Watchdog cron job (if installed). |
| `/usr/local/sbin/server-manager.sh` | Watchdog's copy of the script (if installed). |

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| `Cannot connect to the database as root` | Check that `sudo mysql` works. The script tries the unix socket, `/etc/mysql/debian.cnf`, then `~/.my.cnf`. |
| `Could not fetch the official checksum ... refusing an unverified download` | The server can't reach wordpress.org, or a proxy is interfering. Check DNS/firewall with `curl -I https://wordpress.org`, or use the local-archive fallback when prompted. |
| Apache fails to start | The error output includes the journal and, for port conflicts, the process using ports 80/443. Run `sudo apache2ctl configtest` for the exact config error. |
| `certbot failed` | The last lines of the Let's Encrypt log are printed. The usual causes are DNS not pointing at the server yet or rate limits. |
| Domain rejected as invalid | Only ASCII hostnames are accepted. Enter internationalised domains in punycode (`xn--...`). |
| `Another server-manager instance is already running` | Wait for the other run (menu, cron or CLI) to finish. |
| Need to know what happened | `sudo tail -n 100 /var/log/server-manager.log` |

## Limitations

- Apache only (no Nginx support) and Debian/Ubuntu package management.
- Domain names must be ASCII (use punycode for IDNs).
- `wp-update` updates WordPress core only, not plugins or themes.
- SSL is issued through `certbot --apache`; wildcard certificates (DNS challenge) are not handled.
- Designed for single servers, not clusters.

## Development

The script is a single Bash file. Its `main` function only runs when the file is executed, so you can `source` it to test individual functions.

```bash
bash -n server-manager.sh                    # syntax check
shellcheck -S warning server-manager.sh      # static analysis
```

Contributions are welcome: open an issue to discuss larger changes, keep the script `shellcheck`-clean, and make sure new actions follow the existing pattern of validating first, verifying afterwards and logging what they do.

## Changelog

### 2.0.0

- **Added:** `status` / `doctor` health checks with automatic repair; verified service restarts; graceful Apache reloads with config testing.
- **Added:** WordPress is always fetched from wordpress.org (latest release, any locale, checksum-verified, cached); core updates for existing sites; salts from the official API.
- **Added:** rollback on failed deployments; watchdog with alerts; CLI commands with exit codes, `--yes`, `--quiet`, `--fast`, `--no-fix`; config file; locking; logging with rotation; backup retention and safety snapshots.
- **Fixed:** deleting a vhost read the document root after removing the config, so file deletion never ran; the database user to drop was taken from the database name.
- **Fixed:** switching PHP version ignored the HTTPS (`-le-ssl`) vhost.
- **Fixed:** a vhost that failed the config test stayed enabled and could break Apache for every site.
- **Fixed:** an existing database was reused silently and its user's password reset.
- **Fixed:** removing a hosts entry deleted the whole line, including other names such as `localhost`.
- **Fixed:** fragile salt replacement could corrupt `wp-config.php`.

## License

Released under the [MIT License](LICENSE).
