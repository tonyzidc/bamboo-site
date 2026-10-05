[Definition]
# Managed by Bamboo-Site — detects vulnerability scanners and 403/404 floods.
#
# Matches nginx "combined" access-log lines whose status is 400/403/404/444/499.
# Legitimate browser requests for favicon/robots are ignored so normal visitors
# are never banned.
#
# Note: fail2ban strips the parsed timestamp before applying failregex, so the
# pattern is deliberately tolerant (.*) between the host and the request field
# instead of matching the [...] timestamp literally. Verified with:
#   fail2ban-regex /var/www/<domain>/logs/access.log bamboo-scanner

failregex = ^<HOST> - \S+ .*"(?:GET|POST|HEAD|PUT|DELETE|OPTIONS|PATCH|PROPFIND|TRACE) [^"]*" (?:400|403|404|444|499) \d+

ignoreregex = ^<HOST> - \S+ .*"(?:GET|HEAD) /(?:favicon\.ico|robots\.txt|apple-touch-icon[^"]*|sitemap\.xml) HTTP/[^"]*" (?:400|404)

# nginx access.log: 203.0.113.9 - - [05/Oct/2026:04:41:00 +0000] "GET /wp-login.php HTTP/1.1" 404 162 "-" "curl/8.0"
datepattern = \[%%d/%%b/%%Y:%%H:%%M:%%S %%z\]
