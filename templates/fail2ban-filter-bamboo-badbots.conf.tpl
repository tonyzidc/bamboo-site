[Definition]
# Managed by Bamboo-Site — detects vulnerability scanners by user agent.
#
# Matches requests whose User-Agent names a known penetration-testing or
# vulnerability-scanning tool. Deliberately conservative: only security tools
# are listed, so ordinary crawlers (Googlebot, bingbot, ...) and browsers are
# never banned.
#
# Note: fail2ban strips the parsed timestamp before applying failregex, so the
# pattern is tolerant (.*) between the host and the quoted fields. The user
# agent is anchored to the end of the combined-format line.
# Verified with: fail2ban-regex /var/www/<domain>/logs/access.log bamboo-badbots

failregex = ^<HOST> - \S+ .*"[^"]*(?:sqlmap|nikto|nmap|masscan|zgrab|zmap|wpscan|wp-scan|dirbuster|gobuster|dirb/|hydra|acunetix|nessus|openvas|nuclei|w3af|arachni|skipfish|whatweb|joomscan|droopescan|xsstrike|commix|metasploit|havij|sqlninja|fimap|grabber|vega/|xsser|jaeles|feroxbuster|ffuf)[^"]*"\s*$

ignoreregex =

# nginx access.log: 203.0.113.9 - - [05/Oct/2026:04:41:00 +0000] "GET / HTTP/1.1" 200 612 "-" "sqlmap/1.7#stable"
datepattern = \[%%d/%%b/%%Y:%%H:%%M:%%S %%z\]
