# Troubleshooting

Start with `sudo bamboo-site list` — it shows the mode, certificate status and
jail state of every site, which usually identifies the problem immediately.
`/var/log/bamboo-site.log` records what every command did.

---

## SSL failed while adding a site

That is expected behaviour, not a broken site. `add` rolled the Nginx
configuration back to HTTP-only, so the site is online — just not encrypted:

```text
[warn] Let's Encrypt could not validate example.com — the site stays online over HTTP.
  -> DNS for example.com does not point here yet. Check: dig +short A example.com
  -> Retry at any time with: sudo bamboo-site ssl example.com
```

Fix the cause, then run `sudo bamboo-site ssl example.com`. There is no need to
delete and re-add the site: the retry reuses the existing workspace, jail and
logs, issues the certificate and switches the config to HTTPS.

### Cause 1 — DNS does not point at this server

```bash
dig +short A example.com          # should print this server's public IP
dig +short A www.example.com      # only needed if you want www covered
curl -s https://api.ipify.org     # this server's public IP
```

If the record is missing or stale, fix it at your DNS provider and wait for the
TTL to pass. `bamboo-site ssl` refuses to call Let's Encrypt while there is no A
record at all (that would only burn rate limit); `--force` overrides the check.

If you are behind a proxy/CDN (Cloudflare, a load balancer), the A record
intentionally points elsewhere. The preflight only warns in that case —
continue, or use `--force`.

### Cause 2 — port 80 is not reachable

Let's Encrypt validates over plain HTTP on port 80, so it must be open all the
way to Nginx:

```bash
sudo ufw status                       # is 80/tcp allowed?
sudo ss -ltnp | grep ':80'            # is nginx listening?
curl -I http://example.com            # from another machine, ideally
```

Check your VPS provider's firewall/security group too — that is the most common
place where port 80 is still closed. `sudo bamboo-site install --yes` opens
80/443 in UFW for you; it cannot change your provider's console.

### Cause 3 — rate limits

```text
Error: too many certificates already issued for "example.com"
```

Let's Encrypt limits duplicate certificates to 5 per week per exact name set,
plus 5 failed validations per hour. Check what has been issued:

- <https://crt.sh/?q=example.com>
- <https://letsencrypt.org/docs/rate-limits/>

Wait for the window to reset, then retry. While testing, you can validate the
whole path without spending real budget:

```bash
sudo certbot certonly --webroot -w /var/www/example.com/public_html \
  -d example.com --dry-run --staging
```

### Cause 4 — the ACME challenge cannot be served

```text
Invalid response from http://example.com/.well-known/acme-challenge/...
```

Verify the challenge path is reachable (the generated config always keeps it
open, even in HTTPS mode):

```bash
mkdir -p /var/www/example.com/public_html/.well-known/acme-challenge
echo ok | sudo tee /var/www/example.com/public_html/.well-known/acme-challenge/probe
curl -i http://example.com/.well-known/acme-challenge/probe
```

If that 404s, check for an upstream proxy or a hand-edited config:

```bash
sudo bamboo-site edit example.com     # look for your own location blocks
sudo nginx -T | grep -A3 acme-challenge
```

### Cause 5 — the config is not what the tool generated

If you rewrote the server block by hand, `ssl` regenerates the file from the
template when it switches to HTTPS. The previous version is preserved as
`/var/www/example.com/nginx/example.com.conf.bak` (and `.pre-https`), so nothing
is lost — re-apply your changes on top of the regenerated file and run
`sudo nginx -t && sudo systemctl reload nginx`.

### Recovering an HTTPS site that is serving the wrong certificate

```bash
sudo bamboo-site ssl example.com --force    # re-issue
sudo bamboo-site renew example.com          # renew if it is simply due
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

---

## `nginx -t` failed after `bamboo-site edit`

This is handled safely: the broken file is kept, Nginx is **not** reloaded and
therefore keeps serving the previous configuration. The command prints the test
error and these two options:

```bash
sudo bamboo-site edit example.com                                    # fix it
sudo cp /var/www/example.com/nginx/example.com.conf.bak \
        /var/www/example.com/nginx/example.com.conf                  # or restore
sudo nginx -t && sudo systemctl reload nginx
```

`add` and `ssl` never overwrite a config that fails `nginx -t`: they restore the
previous version and abort, so a site cannot be left disabled by a bad render.

---

## Checking what Nginx is actually serving

```bash
sudo nginx -t                                   # syntax + config file check
sudo nginx -T | less                            # the full, expanded runtime config
readlink -f /etc/nginx/sites-enabled/example.com.conf   # -> workspace file
sudo tail -f /var/www/example.com/logs/error.log
sudo tail -f /var/www/example.com/logs/access.log
systemctl status nginx --no-pager
```

Each site logs to its own workspace, so you never have to filter a combined log
to find one domain's errors.

---

## Fail2ban

```bash
sudo bamboo-site list                            # jail state per domain
sudo fail2ban-client status                      # all jails
sudo fail2ban-client status bamboo-example.com-scanner
sudo fail2ban-client get bamboo-example.com-scanner banip      # who is banned
sudo fail2ban-client set bamboo-example.com-scanner unbanip 203.0.113.9
```

Problems and fixes:

- **A jail is not active.** Check the configuration and the log path:
  `sudo fail2ban-client -t` then
  `sudo journalctl -u fail2ban -n 50 --no-pager`. A jail whose log file does not
  exist yet fails to start — that is why `add` creates the log files up-front.
- **You banned yourself.** Unban with the command above, then add your own IP to
  `/etc/bamboo-site/config` (`BAMBOO_F2B_IGNOREIP="203.0.113.7"`) and re-run
  `sudo bamboo-site install --yes` to regenerate the defaults file.
- **A legitimate bot is being banned.** The `bamboo-scanner` filter matches
  400/403/404 floods; raise `maxretry` in
  `/etc/fail2ban/jail.d/example.com.conf` or extend the `ignoreregex` in
  `/etc/fail2ban/filter.d/bamboo-scanner.conf`, then reload:
  `sudo systemctl reload fail2ban`.
- **Bans never escalate.** `bantime.increment` needs Fail2ban ≥ 0.11
  (`fail2ban-client --version`).

---

## UFW / firewall lockout

`bamboo-site install` deliberately allows the detected SSH port *before*
enabling UFW, and prints it in the confirmation prompt. If you still lose SSH:

1. Use your VPS provider's **web console / rescue mode** (it bypasses the
   firewall).
2. Check and repair from there:

   ```bash
   sudo ufw status verbose
   sudo ufw allow <your-ssh-port>/tcp
   sudo ufw reload
   # worst case:
   sudo ufw disable
   ```

3. Re-run `sudo bamboo-site install --yes` once SSH is reachable again; it will
   detect the right port and re-add the rules.

To check before changing anything:

```bash
sudo sshd -T | grep -i '^port'          # the port(s) sshd really listens on
sudo ufw status numbered
```

---

## Swap was not created by `install`

The swap step is intentionally cautious, and it says why in the install output:

- **Swap already exists.** A swap partition, an existing swap file or zram all
  count. Check with `swapon --show`.
- **Not enough disk space.** The tool refuses to leave less than ~512 MB free.
  Check `df -h /`, then either free space or ask for a smaller file:
  `BAMBOO_SWAP=512M` in `/etc/bamboo-site/config`, then re-run
  `sudo bamboo-site install`.
- **Disabled.** `BAMBOO_SWAP=no` or `--no-swap` turns the step off; set it back
  to `auto` to size it from RAM (capped at 8 GB).

Doing it by hand is fine too — the tool leaves existing swap alone:

```bash
sudo fallocate -l 1G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Swappiness is deliberately left at the distribution default; on a small VPS many
operators lower it with `echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf`.

---

## A reboot is required after `install`

`install` upgrades installed packages (which can install a new kernel) but it
**never reboots** — that decision stays with you:

```bash
cat /var/run/reboot-required.pkgs     # what is waiting for the reboot
uname -r                              # the kernel currently running
sudo reboot
```

Skip the upgrade next time with `sudo bamboo-site install --no-upgrade`, or set
`BAMBOO_OS_UPGRADE=no` in `/etc/bamboo-site/config`.

If a service appears to run old code after an upgrade it usually has not been
restarted since the package was updated:

```bash
sudo systemctl restart nginx fail2ban
sudo bamboo-site status               # confirms everything came back healthy
```

---

## Rolling back a `reinstall`

`reinstall` keeps the previous version beside the current one, so the change is
reversible:

```bash
sudo bamboo-site reinstall --rollback     # previous version back in place
bamboo-site version                       # confirm
```

The newer copy becomes the new rollback, so `--rollback` again moves forward. A
reinstall that fails halfway restores the previous copy automatically; the
leftover copy sits at `/opt/bamboo-site.bak` and can be deleted once you are
happy.

---

## Certificate renewal

Automatic renewal is handled by Ubuntu's `certbot.timer` plus the deploy hook
installed by `bamboo-site install` (it reloads Nginx after a successful
renewal).

```bash
systemctl list-timers certbot.timer --all
systemctl status certbot.timer --no-pager
sudo certbot renew --dry-run             # full rehearsal, changes nothing
sudo bamboo-site renew                   # force a run and fix pending sites
sudo bamboo-site renew example.com
```

`bamboo-site renew` also switches any site that is still in HTTP-only mode to
HTTPS once its certificate exists — handy if you completed a certificate out of
band.

The renewal hook lives at
`/etc/letsencrypt/renewal-hooks/deploy/10-bamboo-nginx-reload.sh`; check
`/var/log/letsencrypt/letsencrypt.log` if a renewal fails.

---

## The site shows the Bamboo-Site placeholder page

That is the seeded `public_html/index.html`. Replace it with your own content:

```bash
sudo rsync -a --delete ./my-site/ /var/www/example.com/public_html/
sudo chown -R www-data:www-data /var/www/example.com/public_html
```

---

## Permissions look wrong after manual changes

```bash
sudo chown -R www-data:www-data /var/www/example.com/public_html
sudo chown -R www-data:adm      /var/www/example.com/logs
sudo chmod 0750                 /var/www/example.com/logs
sudo chmod 0644                 /var/www/example.com/nginx/example.com.conf
```

The config in `nginx/` must stay root-owned and non-writable by `www-data`,
otherwise a compromised site could rewrite its own server block.

---

## `bamboo-site list` says a site is `disabled`

The config exists in the workspace but is not linked into
`/etc/nginx/sites-enabled`. Re-enable it by re-applying the mode:

```bash
sudo bamboo-site ssl example.com        # or
sudo systemctl reload nginx             # if only the reload was missed
ls -l /etc/nginx/sites-enabled/
```

---

## Removing everything

```bash
sudo bamboo-site delete example.com                # one site (keeps nothing)
sudo bamboo-site delete example.com --keep-files

sudo bamboo-site uninstall                         # the CLI only
sudo bamboo-site uninstall --purge                 # + /etc/bamboo-site and the log
sudo bamboo-site uninstall --purge --sites --yes   # + every managed site
```

`uninstall` never removes packages — it prints the `apt-get remove --purge …`
line for nginx, certbot, fail2ban and ufw instead, because anything else on the
server using them breaks as well. The program files are removed by a short-lived
background script a second after the command returns, so `ls /opt/bamboo-site`
shows nothing immediately afterwards. The bootstrap installer has the same
switch: `sudo ./install.sh --uninstall`.

---

## Collecting diagnostics

When asking for help, include:

```bash
bamboo-site version
sudo bamboo-site list --json
sudo nginx -t 2>&1
tail -50 /var/log/bamboo-site.log
journalctl -u fail2ban -n 30 --no-pager
```

and, for certificate problems, the last lines of certbot's own log at
`/var/log/letsencrypt/letsencrypt.log`.
