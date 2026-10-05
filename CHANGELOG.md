# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-10-05

### Added

- **`install` upgrades the operating system.** `apt-get upgrade` runs before the
  server packages are installed, with `--force-confold` (your config files are
  kept) and `NEEDRESTART_MODE=l` (no service is restarted behind your back). The
  tool never reboots: it reports a pending reboot and names the packages waiting
  for it. `--no-upgrade` skips it, `--dist-upgrade` uses `full-upgrade`, and
  `BAMBOO_OS_UPGRADE` sets the default.
- **`install` creates a swap file when the machine has none.** Sized from RAM
  (rounded to 64 MB, capped at 8 GB), or an explicit `BAMBOO_SWAP=512M`/`1G`.
  Existing swap of any kind is left alone, free disk space is checked first, and
  `/etc/fstab` is backed up before the entry is added and validated afterwards.
  `--no-swap` skips the step.
- **`bamboo-site status`** — a read-only health report covering the OS, resources,
  services (running *and* enabled at boot), `nginx -t`, the listening web ports,
  UFW rules for the SSH port and 80/443, Fail2ban jails per domain, certificate
  expiry and the state of every managed site. Exits `1` when a problem is found
  (warnings only with `--strict`), and supports `--json` and `--quiet` for
  monitoring.
- **`bamboo-site reinstall`** — reinstalls the CLI from GitHub (or `--from` a
  local checkout), keeping the previous copy at `<install-dir>.bak` for
  `reinstall --rollback`. The staged copy is verified before it replaces the live
  one, and a failure restores the previous version automatically.
- **`bamboo-site uninstall`** — removes the CLI. `--purge` also removes the
  configuration and log, `--sites` also deletes every managed site (after listing
  them and requiring `--yes`). Packages are never removed; the exact apt command
  is printed instead. The program files are removed by a short-lived detached
  script, because a running CLI cannot reliably delete the tree it is reading.
- Configuration keys `BAMBOO_OS_UPGRADE`, `BAMBOO_SWAP` and `BAMBOO_SWAP_FILE`.

### Changed

- The bootstrap installer forwards `--no-upgrade`, `--dist-upgrade`, `--upgrade`
  and `--no-swap` to `bamboo-site install`.
- `install.sh`'s final smoke test pins `BAMBOO_ROOT` to the directory it just
  installed, so it verifies the new copy even when invoked from a context that
  exports `BAMBOO_ROOT` (for example `bamboo-site reinstall`).

### Fixed

- A rejected Fail2ban jail is quarantined to `<domain>.conf.rejected` so the
  daemon always keeps a loadable configuration.
- `status` no longer aborts silently when no `bamboo-*` jails exist yet (an
  unguarded `grep` failed the pipeline under `set -o pipefail`).
- `uninstall --purge` no longer recreates the log file it just deleted.

### Tests

- 585 assertions (up from 357): swap sizing, creation, persistence and guards,
  the install-time OS upgrade and its flags, every `status` check with its
  exit-code contract, the reinstall/rollback path (driving the real
  `install.sh --local` against a sandboxed prefix) and uninstall at all three
  levels.

## [0.1.0] — 2026-10-05

### Added

- Isolated workspace per domain (`/var/www/<domain>` with `public_html`, `logs`,
  `nginx` and a `letsencrypt` symlink), with `/etc/nginx` holding only symlinks
  into it.
- `install`, `add`, `ssl`, `delete`, `edit`, `renew` and `list` commands.
- Automatic Let's Encrypt provisioning through Certbot's webroot plugin, with
  automatic `www` detection and a smart fallback that rolls the site back to a
  working HTTP-only configuration when issuance fails.
- Per-domain Fail2ban jails (scanner, HTTP auth, rate-limit and bad-bot) with all
  filters bundled in the tool.
- UFW integration that opens the detected SSH port before enabling the firewall.
- Nginx rate/connection limits, security headers, hidden-file denial and
  six-month immutable caching for static assets.
- Dependency-free test suite that runs on macOS (bash 3.2) and Ubuntu (bash 5),
  shellcheck-clean, with a GitHub Actions workflow.
