# 🎋 Bamboo-Site: Automated Nginx & SSL CLI Manager

Bamboo-Site is an open-source CLI service that automates the whole Nginx
management lifecycle on Ubuntu. It deploys websites using an **isolated
workspace architecture**, provisions SSL automatically with a **smart fallback**
when issuance fails, and integrates multi-layered security (Fail2ban, UFW) out
of the box — through a handful of commands.

```bash
curl -sSL https://raw.githubusercontent.com/tonyzidc/bamboo-site/main/install.sh | sudo bash
```

The installer puts `bamboo-site` on your `PATH` (`/usr/local/bin/bamboo-site`,
backed by `/opt/bamboo-site`) and offers to install the server packages for you.

```bash
sudo bamboo-site install                              # Nginx, Certbot, Fail2ban, UFW
sudo bamboo-site add example.com you@example.com      # site + Nginx + jail + SSL
sudo bamboo-site list                                 # what is running, with SSL status
```

---

## ✨ Core features

### 1. Workspace isolation architecture

Instead of scattering configuration and source code across the server, every
domain gets one standard directory. Backups, migrations and offboarding become a
single `cp` or `rm`:

```text
/var/www/example.com/
 ├── public_html/   👉 document root for your source code (owned by www-data)
 ├── logs/          👉 dedicated access.log and error.log for this domain
 ├── nginx/         👉 the real server block, root-owned
 └── letsencrypt/   👉 symlink to the live certificate directory
```

`/etc/nginx/sites-available/example.com.conf` and
`/etc/nginx/sites-enabled/example.com.conf` are just symlinks into that
workspace, so there is exactly one copy of the configuration and no drift.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full ownership and
permission model.

### 2. Zero-downtime SSL automation & smart fallback

- **Automatic provisioning** — `add` requests a Let's Encrypt certificate via
  Certbot's webroot plugin, switches Nginx to HTTPS, sends a permanent redirect
  from port 80 and reloads the server.
- **Smart `www` handling** — the certificate covers `www.<domain>` only when
  that name actually resolves, so the classic "www has no DNS record" failure
  never happens. Force it either way with `--www` / `--no-www`.
- **Smart fallback** — if issuance fails (DNS not propagated yet, port 80
  blocked, rate limit), the tool never leaves Nginx broken: the site is rolled
  back to a working HTTP-only configuration and you are told exactly what to fix
  and how to retry with `bamboo-site ssl <domain>`.
- **Safe symlinking** — certificates are symlinked into the workspace without
  touching Certbot's own directory layout, and a deploy hook reloads Nginx after
  every successful renewal.
- **Automatic renewal** — Ubuntu's native `certbot.timer` handles renewals;
  `bamboo-site renew` forces a run and finishes any site still waiting on a
  certificate.

### 3. System-level auto-security

- **Per-domain Fail2ban jails** — `add` writes
  `/etc/fail2ban/jail.d/<domain>.conf` with four jails that watch *that domain's*
  logs: 403/404 scanning floods, HTTP auth failures, Nginx rate-limit
  rejections (DDoS flooding) and known bad bots. `delete` removes the jail and
  reloads Fail2ban.
- **UFW integration** — during `install`, the SSH port(s) actually in use are
  detected and allowed *before* the firewall is enabled, so you cannot lock
  yourself out. Ports 80 and 443 are opened for you.
- **Nginx hardening** — hidden and sensitive files (`.env`, `.git`, `.htaccess`,
  backups, `composer.lock`, …) are denied, while `/.well-known/acme-challenge/`
  stays reachable so renewals keep working. Standard security headers
  (`X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`,
  `Referrer-Policy`, `Permissions-Policy`, HSTS over TLS) are injected.
- **Request flood protection** — shared Nginx rate/connection-limit zones are
  applied to every site, and repeat offenders are banned with escalating ban
  times.

### 4. Nginx performance optimization

Generated server blocks enable long-lived caching (up to six months, marked
`immutable`) for images, CSS, JS, fonts and media, reduce disk I/O with
per-domain logs, and keep the abuse-protection rules out of the hot path.

---

## 🛠 Command reference

| Command | What it does |
|---|---|
| `bamboo-site install` | Installs Nginx, Certbot, Fail2ban, UFW and supporting packages; enables services and the renewal hook; configures the firewall. Safe to re-run. |
| `bamboo-site add <domain> [email]` | Creates the isolated workspace, generates and enables the Nginx config, creates the Fail2ban jail and issues SSL — with automatic rollback to HTTP-only if issuance fails. |
| `bamboo-site ssl <domain>` | Issues or re-issues the certificate for an existing site and switches it to HTTPS. This is the retry command after a failed `add`. |
| `bamboo-site delete <domain>` | Disables and removes the Nginx config, deletes the Fail2ban jail, revokes and deletes the certificate and removes the workspace. |
| `bamboo-site edit <domain>` | Opens the site's Nginx config in your editor and validates it with `nginx -t` before reloading. |
| `bamboo-site renew [domain]` | Renews one certificate or everything due, then finishes any site still stuck on HTTP. |
| `bamboo-site list` | Lists managed sites with mode, certificate expiry, jail state and size (`--json`, `--quiet`). |
| `bamboo-site help [command]` | Usage for the tool or a single command. |

Global options: `--dry-run`, `--yes`, `--force`, `--verbose`, `--no-color`,
`--version`, `--help`. Every command has its own `--help`.
Full details, flags and exit codes: **[docs/COMMANDS.md](docs/COMMANDS.md)**.

---

## ⚙️ System requirements

- **Operating system:** Ubuntu 22.04 LTS or newer (the tool refuses to run
  elsewhere unless you pass `--force`).
- **Privileges:** root, or a user with `sudo`.
- **Network & DNS:** ports **80** and **443** must be allowed in your VPS
  provider's firewall. Point the domain's A record at the server *before*
  running `add` — if you cannot yet, `add` still succeeds and leaves the site on
  HTTP until you retry with `ssl`.
- **Shell:** bash 3.2+ (Ubuntu ships 5.x; the test suite also runs on macOS's
  3.2).

---

## 🚀 Quick start

```bash
# 1. Install the CLI
curl -sSL https://raw.githubusercontent.com/tonyzidc/bamboo-site/main/install.sh | sudo bash

# 2. Install and configure the server stack
sudo bamboo-site install --email you@example.com

# 3. Create a site (DNS should already point at this server)
sudo bamboo-site add example.com

# 4. Upload your content
sudo -u www-data cp -r ./my-site/. /var/www/example.com/public_html/

# 5. Check everything
sudo bamboo-site list
```

Preview anything without changing the server by adding `--dry-run`:

```bash
sudo bamboo-site --dry-run add example.com
```

### Configuration

Server-wide defaults live in `/etc/bamboo-site/config` (created by `install`):

| Key | Meaning |
|---|---|
| `BAMBOO_DEFAULT_EMAIL` | Contact email registered with Let's Encrypt. |
| `BAMBOO_SSL_WWW` | Include `www.<domain>`: `auto` (default), `yes` or `no`. |
| `BAMBOO_MAX_BODY_SIZE` | Default `client_max_body_size` for new sites (default `64m`). |
| `BAMBOO_F2B_IGNOREIP` | Extra IPs/CIDRs Fail2ban must never ban (e.g. your office IP). |
| `BAMBOO_CERTBOT_EXTRA_ARGS` | Extra arguments appended to every certbot invocation. |
| `BAMBOO_PUBLIC_IP` | Override the auto-detected public IP (useful behind NAT). |

Values in the environment win over the config file. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for every supported variable.

---

## 🩺 Troubleshooting

SSL failed during `add`? Your site is online over HTTP — fix DNS or the
firewall, then run `sudo bamboo-site ssl example.com`. The tool prints the
concrete cause and the commands to verify it.

**[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** covers:

- every common certificate failure and how to verify/fix it,
- `nginx -t` failures after editing a config (and how to restore),
- checking Fail2ban jails, unbanning an IP and whitelisting your own,
- recovering from a UFW lockout,
- renewal diagnostics and where the logs are.

---

## 🧑‍💻 Development

```bash
git clone https://github.com/tonyzidc/bamboo-site.git
cd bamboo-site

make test     # 357 assertions, no dependencies, runs on macOS and Linux
make lint     # bash -n + shellcheck on every script
make check    # both

sudo ./install.sh --local    # install this checkout to /opt/bamboo-site
```

The whole test suite runs against a temporary fake root with the external
commands stubbed (`BAMBOO_TEST_MODE=1`), so you do not need nginx, certbot or
root to develop. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#testing) for how
the seam works.

Contributions are welcome: keep scripts bash 3.2-compatible, run `make check`,
and describe the change in the commit message.

---

## 📄 License

[MIT](LICENSE) © 2026 tonyzidc
