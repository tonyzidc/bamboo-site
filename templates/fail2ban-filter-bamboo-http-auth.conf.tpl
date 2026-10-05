[Definition]
# Managed by Bamboo-Site — HTTP authentication abuse.
#
# Matches the basic-auth failures nginx writes to error.log. Bundled with the
# tool so the jail never depends on a distribution-provided filter.

failregex = ^.*\[error\] \d+#\d+: \*\d+ user "[^"]*": password mismatch, client: <HOST>,
            ^.*\[error\] \d+#\d+: \*\d+ user "[^"]*" was not found.*client: <HOST>,
            ^.*\[error\] \d+#\d+: \*\d+ no user/password was provided for basic authentication.*client: <HOST>,

ignoreregex =

# nginx error.log: 2026/10/05 04:41:00 [error] 1234#1234: *567 user "admin": password mismatch, client: ...
datepattern = %%Y/%%m/%%d %%H:%%M:%%S
