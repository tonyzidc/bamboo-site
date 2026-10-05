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
sudo bamboo-site delete example.com             # one site (keeps nothing)
sudo bamboo-site delete example.com --keep-files
sudo ./install.sh --uninstall                   # the CLI only
sudo rm -rf /etc/bamboo-site                    # the server-wide config
```

`--uninstall` never touches `/var/www`, certificates or `/etc/bamboo-site`.

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
