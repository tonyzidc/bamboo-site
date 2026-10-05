# Command reference

Every command accepts the global options below and answers `--help`.

| Global option | Effect |
|---|---|
| `--dry-run` | Print what would change and touch nothing (no files, no services, no certbot). |
| `-y`, `--yes` | Never prompt. Required in scripts and non-interactive sessions. |
| `--force` | Continue on an unsupported OS/Ubuntu release; for `ssl`, re-issue even when a certificate already exists and skip the DNS preflight. |
| `-v`, `--verbose` | Show debug output (external commands, previous config versions, raw certbot output). |
| `--no-color` | Disable ANSI colours. |
| `-V`, `--version` | Print the version and exit. |
| `-h`, `--help` | Print help for the tool or for one command. |

Exit codes: `0` success, `1` error. `add` deliberately exits `0` when the site
was created but SSL could not be issued yet — check the summary line or
`bamboo-site list`.

---

## `bamboo-site install`

```text
sudo bamboo-site install [--email <address>] [--no-ufw]
```

Installs and configures the whole stack. Safe to re-run; already-installed
packages are skipped.

What it does, in order:

1. Verifies the OS is Ubuntu 22.04+ (`--force` overrides).
2. `apt-get update`, then installs only the missing packages from:
   `nginx`, `certbot`, `fail2ban`, `ufw`, `curl`, `openssl`, `dnsutils`,
   `ca-certificates`. Uses `DPkg::Lock::Timeout=600` so it waits instead of
   failing on a busy apt lock.
3. Enables and starts `nginx` and `fail2ban`, and enables `certbot.timer` so
   certificates renew automatically.
4. Installs the renewal deploy hook
   `/etc/letsencrypt/renewal-hooks/deploy/10-bamboo-nginx-reload.sh`, which
   reloads Nginx after every successful renewal.
5. Installs the shared Fail2ban filter and defaults.
6. Writes `/etc/nginx/conf.d/bamboo-limits.conf` (the rate/connection-limit
   zones every site references), tests the config and reloads Nginx.
7. Configures UFW: detects the SSH port(s) from `sshd -T`, allows them **first**,
   then 80 and 443, and only then offers to enable the firewall.
8. Writes `/etc/bamboo-site/config` with defaults (existing values are kept).

Useful flags: `--email` stores a default Let's Encrypt contact;
`--no-ufw` leaves the firewall untouched.

---

## `bamboo-site add <domain> [email]`

```text
sudo bamboo-site add <domain> [email] [--www | --no-www] [--no-ssl] [--email <address>]
```

Creates everything needed to serve a domain:

1. **Validates the domain** — public hostnames only; IP addresses, ports,
   wildcards and path characters are rejected before any file is created.
   Uppercase input and a trailing dot are normalised.
2. **Refuses duplicates** — an existing workspace must be removed with
   `delete` first.
3. **Workspace** — creates `/var/www/<domain>/{public_html,logs,nginx}`, sets
   ownership (`www-data` for content and logs, root for Nginx configs), creates
   empty `access.log`/`error.log` and seeds a placeholder `index.html` if there
   is none. Existing content is never overwritten.
4. **Nginx** — renders the server block into
   `/var/www/<domain>/nginx/<domain>.conf`, symlinks it into
   `sites-available`/`sites-enabled`, runs `nginx -t` and reloads. If the test
   fails, the previous configuration is restored automatically.
   The HTTP-only block is applied first, so the site is reachable immediately.
5. **Fail2ban** — writes `/etc/fail2ban/jail.d/<domain>.conf` with four
   per-domain jails, validates the configuration (`fail2ban-client -t`) and
   reloads the daemon.
6. **SSL** — determines whether `www.<domain>` resolves (`--www`/`--no-www`
   override), asks Certbot for a webroot certificate covering the apex (and
   `www` when applicable), then rewrites the Nginx config as HTTPS with a
   permanent port-80 redirect, retests and reloads. The certificate is
   symlinked into the workspace as `letsencrypt/`.
7. **Smart fallback on failure** — if Certbot fails, the site is left (or rolled
   back) on the working HTTP-only configuration, the output is translated into a
   concrete cause, and the summary tells you to retry with
   `sudo bamboo-site ssl <domain>`.

`--no-ssl` skips step 6 entirely for sites that are not ready for a certificate.

Exit code is `0` even when SSL is pending — the site is live, just not
encrypted yet. `bamboo-site list` shows the status.

---

## `bamboo-site ssl <domain>`

```text
sudo bamboo-site ssl <domain> [--www | --no-www] [--email <address>] [--force]
```

The recovery path for a site whose certificate is missing, plus a way to widen
an existing certificate.

1. Refuses to run for a domain that is not managed yet.
2. Preflight: if the apex has **no A record at all**, it stops before spending
   Let's Encrypt rate-limit budget and prints the DNS checks to run. If the A
   record points elsewhere, it warns and asks for confirmation. `--force`
   bypasses the preflight.
3. Ensures the Fail2ban jail still exists.
4. Requests the certificate (with `--force`, even when one already exists) and
   on success switches the site to HTTPS and reloads Nginx.
5. On failure: keeps the site on HTTP, exits `1`, and prints the cause plus the
   exact commands to verify and retry.

Running it on a site that already has a valid certificate just makes sure HTTPS
is switched on (use `--force` to actually re-issue).

---

## `bamboo-site delete <domain>`

```text
sudo bamboo-site delete <domain> [--keep-files]
```

Shows exactly what will be destroyed and asks for confirmation (use `--yes` in
scripts; without a terminal and without `--yes` it aborts rather than guessing).

Order of operations, chosen so Nginx never references a file that no longer
exists:

1. Removes the `sites-enabled` symlink, runs `nginx -t`, reloads Nginx. If the
   test fails, the link is restored and nothing else happens.
2. Removes the `sites-available` symlink and the generated workspace config.
3. Removes the Fail2ban jail and reloads the daemon.
4. Revokes and deletes the certificate (tolerating "not found" / "already
   revoked").
5. Deletes the workspace — or, with `--keep-files`, keeps `public_html/` and
   `logs/` and removes only the generated pieces.

---

## `bamboo-site edit <domain>`

```text
sudo bamboo-site edit <domain>
```

Opens `/var/www/<domain>/nginx/<domain>.conf` in `$BAMBOO_EDITOR`, `$EDITOR`,
`$VISUAL`, `nano` or `vim` (first one available). A backup is written to
`<domain>.conf.bak` before the editor starts.

On save:

- **Valid** → `nginx -t` passes, Nginx reloads, the change is live.
- **Invalid** → Nginx is *not* reloaded (it keeps serving the previous config),
  the `nginx -t` error is shown, and the restore command is printed.
- **Unchanged** → nothing happens.

Warning: `add` and `ssl` regenerate this file from the template. When that
happens the previous version is kept as `<domain>.conf.bak` (and
`<domain>.conf.pre-https` for the HTTP→HTTPS switch), but hand-edits are not
merged back. Keep structural changes in mind, or apply them after the last
`ssl` run.

Interactive by default (it needs a terminal to host the editor). Setting
`BAMBOO_EDITOR` makes it scriptable: point it at an editor or any script that
modifies the file, and the result is still validated with `nginx -t` before
anything is reloaded.

---

## `bamboo-site renew [domain]`

```text
sudo bamboo-site renew [domain] [--dry-run]
```

1. Runs `certbot renew` — for one certificate (`--cert-name <domain>`) or for
   everything that is due — with a deploy hook that reloads Nginx.
2. Any site still in HTTP-only mode whose certificate now exists is switched to
   HTTPS automatically. This is how you finish a setup that originally failed
   without re-adding the site.
3. Prints the certificate inventory (`certbot certificates`) and where to check
   the automatic renewal timer.

`--dry-run` passes `--dry-run` to certbot (a full staging rehearsal) and changes
no configuration.

Renewal normally happens on its own via `certbot.timer`; this command is for
forcing a run, recovering pending sites, or checking what is about to expire.

---

## `bamboo-site list`

```text
bamboo-site list [--json | --quiet]
```

Works without root. Lists every domain whose workspace contains a generated
Nginx config:

```text
DOMAIN                             MODE      SSL                  JAIL   SIZE    CREATED
-------------------------------------------------------------------------------------------------
example.com                        https     valid (89d)          on     4.0K    2026-10-05
staging.example.com                http      pending              on     4.0K    2026-10-05
```

- **MODE** — `https` (TLS live), `http` (HTTP only, certificate pending),
  `disabled` (config exists but is not in `sites-enabled`), `missing`.
- **SSL** — `valid (Nd)`, `renew soon (Nd)` under 15 days, `expired`, `pending`
  (no certificate yet) or `missing` (HTTPS mode without a certificate).
- **JAIL** — `on`/`off` verified live when run as root, otherwise `set` (jail
  file present) or `-`.
- **SIZE** / **CREATED** — document-root size and when the workspace was made.

`--quiet` prints domain names only (useful in scripts); `--json` prints one
object per site:

```json
[
  {"domain": "example.com", "mode": "https", "enabled": true, "ssl": "valid (89d)",
   "ssl_days": 89, "jail": "on", "size": "4.0K", "created": "2026-10-05",
   "docroot": "/var/www/example.com/public_html"}
]
```

---

## `bamboo-site help` and `version`

```text
bamboo-site help [command]
bamboo-site version
bamboo-site --version
```

`help` with no argument prints the overview; with a command name it prints that
command's usage, options and examples. `version` prints the installed version
(read from the `VERSION` file in the installation directory).
