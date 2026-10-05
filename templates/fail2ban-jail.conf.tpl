# Managed by Bamboo-Site — Fail2ban jails for @DOMAIN@.
# Created/written by 'bamboo-site add' (and refreshed by 'install'),
# removed by 'bamboo-site delete'.
# Every jail watches this domain's own logs, so bans are per-site.
#
# Retry limits and escalating ban times are set per jail on purpose: putting
# them in [DEFAULT] would also apply to the sshd jail and could lock the
# operator out of their own server.
#
# 'backend' is repeated in every jail for the same reason. Debian/Ubuntu ship
# /etc/fail2ban/jail.d/defaults-debian.conf, which sets 'backend = systemd' in
# [DEFAULT] and is read AFTER this file, so it would win and the jails would
# scan the systemd journal instead of the domain's log file ("No file is
# currently monitored" in the fail2ban log). A jail-level setting always takes
# precedence over [DEFAULT], whatever order the files are read in.

# Scanner / 403-404 flood from a single IP.
[bamboo-@DOMAIN@-scanner]
enabled  = true
port     = http,https
filter   = bamboo-scanner
logpath  = @LOG_DIR@/access.log
backend  = polling
maxretry = 10
findtime = 600
bantime  = 3600
# Escalate repeat offenders (1x, 2x, 4x ... capped at one week).
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

# Repeated HTTP authentication failures.
[bamboo-@DOMAIN@-http-auth]
enabled  = true
port     = http,https
filter   = bamboo-http-auth
logpath  = @LOG_DIR@/error.log
backend  = polling
maxretry = 5
findtime = 600
bantime  = 3600
# Escalate repeat offenders (1x, 2x, 4x ... capped at one week).
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

# Requests rejected by the Nginx rate limiter (DDoS / request flooding).
[bamboo-@DOMAIN@-limit]
enabled  = true
port     = http,https
filter   = bamboo-limit-req
logpath  = @LOG_DIR@/error.log
backend  = polling
maxretry = 5
findtime = 600
bantime  = 3600
# Escalate repeat offenders (1x, 2x, 4x ... capped at one week).
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

# Known malicious scanners, by user agent.
[bamboo-@DOMAIN@-badbots]
enabled  = true
port     = http,https
filter   = bamboo-badbots
logpath  = @LOG_DIR@/access.log
backend  = polling
maxretry = 2
findtime = 86400
bantime  = 86400
# Escalate repeat offenders (1x, 2x, 4x ... capped at one week).
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
