[DEFAULT]
# Managed by Bamboo-Site — shared Fail2ban settings.
# Per-domain jails live in /etc/fail2ban/jail.d/<domain>.conf.
#
# Deliberately minimal: bantime/findtime/maxretry are NOT set here, because
# [DEFAULT] applies to every jail on the server — including the sshd jail.
# Making SSH bans more aggressive than the distribution default is a fast way to
# lock the operator out of their own server, so the per-domain jails set their
# own limits instead. Tighten sshd yourself if you want it stricter.

backend = auto
ignoreip = @IGNOREIP@
