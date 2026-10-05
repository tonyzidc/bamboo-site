# Architecture

This document explains how Bamboo-Site is put together and why. It is aimed at
anyone modifying the code or debugging a server built with it.

## Design goals

1. **One domain, one directory.** Everything that belongs to a site lives under
   `/var/www/<domain>`. Migration is a `tar`, offboarding is an `rm`.
2. **Nothing is ever half-applied.** A bad configuration must never take Nginx
   down, so every change is validated first and rolled back on failure.
3. **The tool must be testable off-server.** No step may assume root or a real
   nginx/certbot binary when the test seam is active.
4. **Bans and limits are per-site.** One noisy domain must not affect another.

## Repository layout

```text
bin/bamboo-site        entry point: root discovery, flag parsing, dispatch, traps
lib/common.sh          logging, guards, prompts, validation, template rendering,
                       dry-run/test switches, and one wrapper per external binary
lib/config.sh          /etc/bamboo-site/config read/write
lib/os.sh              Ubuntu detection, apt helpers, services, renewal hook
lib/workspace.sh       /var/www/<domain> creation/removal, path guards
lib/nginx.sh           config generation, symlink wiring, nginx -t, rollback
lib/ssl.sh             certbot lifecycle, www detection, DNS preflight, fallback
lib/fail2ban.sh        per-domain jails, shared filter/defaults, reload
lib/firewall.sh        UFW rules with an SSH-lockout guard
lib/testmode.sh        test-only stubs, loaded last when BAMBOO_TEST_MODE=1
commands/cmd_*.sh      one file per command (install, add, ssl, delete, edit,
                       renew, list, help)
templates/*.tpl        static files with @TOKEN@ placeholders
tests/                 dependency-free harness + suite
```

The Nginx server blocks are generated programmatically in `lib/nginx.sh`
(heredocs) rather than from templates, because the HTTP/HTTPS variants share a
large location block that is emitted once by `nginx_emit_common_locations()`.
Templates are used for files that are mostly static: the Fail2ban filter,
defaults and per-domain jail, and the placeholder `index.html`.

## The workspace model

```text
/var/www/<domain>/
 ├── public_html/   document root
 ├── logs/          access.log + error.log (nginx writes, Fail2ban reads)
 ├── nginx/         <domain>.conf  (the server block — source of truth)
 │                  <domain>.conf.bak / .pre-https / .bak.<timestamp>
 └── letsencrypt/   symlink -> /etc/letsencrypt/live/<domain>
```

| Path | Owner | Mode | Why |
|---|---|---|---|
| `/var/www/<domain>` | `www-data:www-data` | `0755` | Site-level traversal. |
| `public_html/` | `www-data:www-data` | `0755` | The web server must read/serve it. |
| `logs/` | `www-data:adm` | `0750` | Nginx writes; `adm` can read for log tooling. |
| `logs/*.log` | `www-data:adm` | `0640` | Created up-front so the first request never fails. |
| `nginx/` | `root:root` | `0755` | Configs are privileged; the web user must not write them. |
| `nginx/<domain>.conf` | `root:root` | `0644` | Readable by Nginx, writable only by root. |
| `/etc/nginx/sites-available/<domain>.conf` | symlink | — | Points at the workspace file. |
| `/etc/nginx/sites-enabled/<domain>.conf` | symlink | — | `../sites-available/<domain>.conf`, nginx's own convention. |

Web user/group default to `www-data` and can be overridden with
`BAMBOO_WEB_USER`, `BAMBOO_WEB_GROUP` and `BAMBOO_LOG_GROUP`.

**State is derived, never stored.** There is no hidden database: `list` reads the
workspace, greps the generated config for `listen 443 ssl`, and inspects
`/etc/letsencrypt/live/<domain>`. Deleting a workspace therefore leaves nothing
behind, and a hand-copied workspace still works.

## Configuration generation flow

```text
add <domain>
  │
  ├─ workspace_create ───────────► /var/www/<domain>/{public_html,logs,nginx}
  │
  ├─ nginx_apply_site <d> http ──► nginx_ensure_limits   (conf.d/bamboo-limits.conf)
  │                                 nginx_write_site http (workspace config)
  │                                 nginx_wire_symlinks   (sites-available/enabled)
  │                                 bamboo_nginx_test     (nginx -t)
  │                                 bamboo_service_reload (systemctl reload nginx)
  │
  ├─ f2b_add_jail ───────────────► filter.d + jail.d + fail2ban-client -t + reload
  │
  └─ ssl_attempt
       ├─ ssl_issue (certbot certonly --webroot) ──► /etc/letsencrypt/live/<domain>
       ├─ ssl_link_workspace ──────────────────────► workspace letsencrypt/ symlink
       └─ nginx_set_mode https ────────────────────► render + test + reload
```

`nginx_apply_site` is the only way a config goes live and it always follows the
same sequence: back up the current file → render the new one atomically → wire
the symlinks → `nginx -t` → reload. If `nginx -t` fails, the previous file is
restored byte for byte, re-tested, and the command aborts with a clear message.
When there was no previous file, the symlinks are removed instead, so a broken
config can never be left enabled.

Every generated config references the shared rate-limit zones:

```nginx
limit_req_zone $binary_remote_addr zone=bamboo_req:10m rate=20r/s;
limit_conn_zone $binary_remote_addr zone=bamboo_conn:10m;
```

These directives are only valid in the `http` context, which is why they live in
`/etc/nginx/conf.d/bamboo-limits.conf` rather than in the per-site file. The
per-site block then applies them with `limit_req zone=bamboo_req burst=40
nodelay;` and `limit_conn bamboo_conn 32;` (answering `429`).

TLS parameters come from Certbot's own `options-ssl-nginx.conf` when it exists;
otherwise the tool emits an equivalent block. The two are mutually exclusive on
purpose — setting `ssl_protocols`/`ssl_session_cache` twice in one server block
is a hard nginx error.

## SSL lifecycle and the fallback contract

`ssl_attempt <domain> <names> <email> <force>` is the single entry point:

1. `ssl_issue` runs `certbot certonly --webroot -w <public_html>
   --cert-name <domain> --expand -d <names…> --non-interactive --agree-tos
   [--email|--register-unsafely-without-email] [--force-renewal]`. The
   result is captured (never thrown) into `BAMBOO_LAST_OUTPUT/STATUS`.
2. **On failure** → `ssl_ensure_http_fallback` guarantees the site is on a
   valid HTTP-only config (rolling back from HTTPS if necessary), and the
   caller prints the translated cause. `ssl_attempt` returns non-zero.
3. **On success** → the certificate is symlinked into the workspace and
   `nginx_set_mode https` renders the redirect + TLS blocks, tests and reloads.

`www` inclusion is decided by `ssl_determine_names`: `auto` (the default) adds
`www.<domain>` when that name has an A record, `yes`/`no` force the choice. The
generated `server_name` is then taken from the certificate's SANs, so Nginx
advertises exactly what the certificate covers.

The DNS preflight (`ssl_preflight`) distinguishes "no A record at all" (fatal —
stop before consuming rate-limit budget) from "resolves to a different IP"
(a warning, confirmed by the operator) and is skipped entirely with `--force`.

Certificates renew via `certbot.timer` plus the deploy hook installed by
`install`; `bamboo-site renew` additionally sweeps for sites still stuck in
HTTP-only mode and upgrades them.

## Fail2ban model

`install` writes the shared pieces once:

- `filter.d/bamboo-scanner.conf` — a `failregex` matching `400/403/404/444/499`
  responses in the combined access-log format, with an `ignoreregex` for
  legitimate `favicon.ico`/`robots.txt`/`sitemap.xml`/`apple-touch-icon`
  misses so ordinary visitors are not banned.
- `jail.d/00-bamboo-defaults.conf` — `[DEFAULT]`, deliberately minimal:
  `backend = auto` and `ignoreip`. Bantime/findtime/maxretry are **not** set
  there, because `[DEFAULT]` applies to every jail on the server — including the
  `sshd` jail. Making SSH bans more aggressive than the distribution default is
  a fast way to lock the operator out of their own server, so each per-domain
  jail sets its own limits (with escalating bans via `bantime.increment`,
  factor 2, capped at one week). Requires Fail2ban ≥ 0.11 (Ubuntu 22.04 ships
  0.11.2).

`add` writes `jail.d/<domain>.conf` with four jails, all reading that domain's
own log directory:

| Jail | Filter | Log | Purpose |
|---|---|---|---|
| `bamboo-<domain>-scanner` | `bamboo-scanner` | `access.log` | Vulnerability scanning / 403-404 floods. |
| `bamboo-<domain>-http-auth` | `bamboo-http-auth` | `error.log` | Repeated authentication failures. |
| `bamboo-<domain>-limit` | `bamboo-limit-req` | `error.log` | Requests rejected by the Nginx rate limiter (DDoS). |
| `bamboo-<domain>-badbots` | `bamboo-badbots` | `access.log` | Known malicious user agents. |

All four filters are **bundled with the tool** and installed as
`filter.d/bamboo-*.conf`; no jail references a filter shipped by the fail2ban
package. This matters because filter names differ across distributions (Ubuntu
24.04 dropped `nginx-badbots` entirely) and a single missing filter makes the
whole configuration unloadable — fail2ban would then refuse to start after a
reboot.

Two behaviours worth knowing when editing filter regexes:

- fail2ban strips the parsed timestamp from a line before applying
  `failregex`, so access-log patterns must not expect the literal `[...]`
  timestamp; they use a tolerant `.*` between the host and the request field.
- A jail whose filter is missing or unparsable is never left enabled: the
  configuration is tested with `fail2ban-client -t` first, and a jail that fails
  the test is moved to `<domain>.conf.rejected` so the daemon always stays
  loadable.
- Every jail pins `backend = polling` because Debian/Ubuntu ship
  `jail.d/defaults-debian.conf` with `backend = systemd` in `[DEFAULT]`. That
  file is read *after* the Bamboo-Site files, so without the per-jail pin the
  jails would scan the systemd journal and never see the domain's access/error
  log (`No file is currently monitored` in `/var/log/fail2ban.log`). Polling is
  chosen over inotify for determinism: it always works, at a negligible cost for
  a handful of per-site log files.

Verify a filter against real log lines at any time:

```bash
sudo fail2ban-regex /var/www/<domain>/logs/access.log bamboo-scanner
sudo fail2ban-regex /var/www/<domain>/logs/error.log  bamboo-limit-req
```

Changes are validated with `fail2ban-client -t` and then applied with
`systemctl reload fail2ban` (falling back to `restart`). `delete` removes the
jail file and reloads.

## Firewall

`fw_configure` detects the real SSH port(s) (`sshd -T`, then `sshd_config`),
allows them, then 80 and 443, and only then asks whether to enable UFW. This
ordering is the whole point: enabling UFW before the SSH rule exists locks the
operator out. The detected ports are printed before the confirmation prompt.

## Safety mechanisms

| Mechanism | Where | What it prevents |
|---|---|---|
| Strict domain validation | `is_valid_domain` / `bamboo_require_domain` | Path traversal, `rm -rf` on arbitrary paths, wildcard/IP confusion. |
| Path assertion before recursive delete | `assert_workspace_path` | Deleting anything that is not exactly `<WWW_DIR>/<valid-domain>`. |
| Atomic writes | `atomic_write` | Readers (Nginx) ever seeing a partial file. |
| `nginx -t` before every reload, with rollback | `nginx_apply_site`, `nginx_remove_site` | A bad config taking the server down. |
| Symlink checks before removal | `nginx_unwire_symlinks` | Deleting a config the operator created. |
| Foreign file handling | `nginx_wire_symlinks` | Silently overwriting a hand-written `/etc/nginx` file (it is moved to `.bak.<timestamp>`). |
| Locking | `bamboo_acquire_lock` | Two concurrent mutating runs (`flock`, with a `mkdir` fallback). |
| `--dry-run` | `bamboo_run`, and early returns in every mutating helper | Accidental changes during a rehearsal. |
| Non-interactive safety | `bamboo_confirm` | Hanging in a pipeline; it refuses rather than assuming "yes". |
| SSH rule before `ufw enable` | `fw_configure` | Self-inflicted lockout. |
| Certbot is the only writer under `/etc/letsencrypt` | `lib/ssl.sh` | Corrupting Certbot's own bookkeeping. |

## Path and environment overrides

Every system location is a variable with the production default, which is what
makes the suite able to run against a temporary root.

| Variable | Default | Purpose |
|---|---|---|
| `BAMBOO_ROOT` | resolved from the script location | Installation/checkout root. |
| `BAMBOO_WWW_DIR` | `/var/www` | Parent of all workspaces. |
| `BAMBOO_ETC_DIR` | `/etc/bamboo-site` | Configuration directory. |
| `BAMBOO_CONFIG_FILE` | `$BAMBOO_ETC_DIR/config` | Server-wide defaults. |
| `BAMBOO_INSTALL_DIR` | `/opt/bamboo-site` | Installed copy of the tool. |
| `BAMBOO_BIN_DIR` | `/usr/local/bin` | Where the `bamboo-site` symlink is created. |
| `BAMBOO_NGINX_AVAILABLE` / `_ENABLED` | `/etc/nginx/sites-{available,enabled}` | Symlink targets. |
| `BAMBOO_NGINX_CONFD` | `/etc/nginx/conf.d` | Shared zone file. |
| `BAMBOO_NGINX_LIMITS_FILE` | `$BAMBOO_NGINX_CONFD/bamboo-limits.conf` | Rate-limit zones. |
| `BAMBOO_LETSENCRYPT_DIR` / `_LIVE` / `_HOOKS` | `/etc/letsencrypt{,/live,/renewal-hooks/deploy}` | Certbot paths. |
| `BAMBOO_F2B_DIR` / `_JAILD` / `_FILTERD` | `/etc/fail2ban{,/jail.d,/filter.d}` | Fail2ban paths. |
| `BAMBOO_LOG_FILE` | `/var/log/bamboo-site.log` | Operations log written by every command. |
| `BAMBOO_LOCK_FILE` | `/var/lock/bamboo-site.lock` | Concurrency lock. |
| `BAMBOO_WEB_USER` / `_WEB_GROUP` / `_LOG_GROUP` | `www-data` / `www-data` / `adm` | Ownership of content and logs. |
| `BAMBOO_MAX_BODY_SIZE` | `64m` | `client_max_body_size` for new sites. |
| `BAMBOO_SSL_WWW` | `auto` | `www` inclusion default (`auto`/`yes`/`no`). |
| `BAMBOO_DEFAULT_EMAIL` | empty | Let's Encrypt contact. |
| `BAMBOO_CERTBOT_EXTRA_ARGS` | empty | Extra certbot flags. |
| `BAMBOO_F2B_IGNOREIP` | empty | Extra IPs/CIDRs Fail2ban must never ban. |
| `BAMBOO_PUBLIC_IP` | auto-detected | Override for NAT/proxy setups. |
| `BAMBOO_EDITOR` | `$EDITOR`, `$VISUAL`, nano, vim | Editor used by `edit`. |
| `BAMBOO_DRY_RUN`, `BAMBOO_ASSUME_YES`, `BAMBOO_VERBOSE`, `BAMBOO_NO_COLOR`, `BAMBOO_FORCE` | `0` | Set by the global flags. |
| `BAMBOO_TEST_MODE` | `0` | Activates the test seam (see below). |

Precedence for the values that have a config-file entry is
**environment → `/etc/bamboo-site/config` → built-in default**.

## Testing

```bash
make test        # bash tests/run.sh
bash tests/run.sh nginx   # only tests whose name matches
```

The suite needs nothing but bash and coreutils — it runs on macOS (bash 3.2) and
on Ubuntu. Two things make that possible:

1. **Thin command wrappers.** Nothing in `lib/` or `commands/` calls a system
   binary directly. Every call goes through a small function in
   `lib/common.sh` (`bamboo_systemctl`, `bamboo_nginx_bin`, `bamboo_certbot`,
   `bamboo_f2b_client`, `bamboo_ufw`, `bamboo_apt_get`, `bamboo_own`,
   `bamboo_chmod`, `bamboo_pkg_installed`, `bamboo_dns_a`, `bamboo_public_ip`,
   …). `lib/testmode.sh` is sourced last when `BAMBOO_TEST_MODE=1` and replaces
   them with stubs that log their invocations to `$BAMBOO_TEST_CMD_LOG`, so
   tests can assert *that* a reload or a certbot call happened without owning a
   server.
2. **Path indirection.** `tests/run.sh` points every `BAMBOO_*` path at a
   throwaway `mktemp -d` root before each test, so the real `/etc` and `/var/www`
   are never touched.

`BAMBOO_TEST_MODE` additionally makes the CLI's own seam (used by the
end-to-end cases that invoke `bin/bamboo-site` as a subprocess) fabricate a
self-signed certificate for the requested names instead of calling Certbot, and
honours `BAMBOO_TEST_CERTBOT_RESULT=1` to simulate a failed issuance. That is how
the smart-fallback path is tested without a network.

`--dry-run` is tested separately from test mode: `test_dry_run_writes_nothing`
asserts that no file, log entry or symlink appears at all.

The suite currently has 357 assertions covering domain validation and traversal
rejection, template rendering, config generation for both modes, symlink wiring,
rollback on a failed `nginx -t`, mode switching, certificate detection and SAN
parsing, the DNS preflight, the fallback contract, jail rendering, firewall
ordering (SSH before `enable`), and a full `add → list → ssl → delete` lifecycle
through the real binary.

## Compatibility notes

- **bash 3.2 syntax only.** Avoid associative arrays, `${var,,}`, `mapfile`,
  `local -n`, and `arr=()` followed by `arr+=()` on a *scalar* (use
  `local -a arr=()`), so the suite keeps running on macOS. Ubuntu 24.04 ships
  bash 5, which accepts all of the above, so this constraint costs nothing at
  runtime.
- **Ubuntu 22.04+.** `fail2ban`'s `bantime.increment` needs ≥ 0.11.
- **nginx 1.18–1.27.** `listen 443 ssl http2` is used below 1.25.1 and the
  `http2 on;` directive at or above it; the version is detected at render time.
- **certbot ≥ 1.21** (the `--cert-name`/`--expand` behaviour the tool relies on).
