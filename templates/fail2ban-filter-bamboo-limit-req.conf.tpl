[Definition]
# Managed by Bamboo-Site — requests rejected by the Nginx rate limiter.
#
# Matches the messages nginx writes (to error.log) when limit_req or limit_conn
# rejects a client, i.e. an actual request flood / DDoS attempt. Bundled with the
# tool so the jail never depends on a distribution-provided filter.

failregex = ^.*\[error\] \d+#\d+: \*\d+ limiting requests, excess: [\d.]+ by zone "[^"]+", client: <HOST>,
            ^.*\[error\] \d+#\d+: \*\d+ limiting connections by zone "[^"]+", client: <HOST>,

ignoreregex =

# nginx error.log: 2026/10/05 04:41:00 [error] 1234#1234: *567 limiting requests, excess: 20.5 by zone "bamboo_req", client: ...
datepattern = %%Y/%%m/%%d %%H:%%M:%%S
