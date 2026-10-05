#!/usr/bin/env bash
# shellcheck shell=bash
#
# Tests for `bamboo-site status`: the healthy case, every problem class, the
# exit-code contract, --json and --quiet.

# Builds a completely healthy server in the sandbox and leaves the knobs set.
# Knobs a test sets beforehand win over these defaults, so a test can ask for
# "healthy except X" without rebuilding the sandbox afterwards.
status_healthy_env() {
    export TEST_SERVICES_ACTIVE="${TEST_SERVICES_ACTIVE:-nginx fail2ban ufw certbot.timer}"
    export TEST_SERVICES_ENABLED="${TEST_SERVICES_ENABLED:-nginx fail2ban ufw certbot.timer}"
    export TEST_UFW_ACTIVE="${TEST_UFW_ACTIVE:-1}"
    export TEST_UFW_RULES="${TEST_UFW_RULES:-22/tcp 80/tcp 443/tcp}"
    export TEST_SWAP_ACTIVE="${TEST_SWAP_ACTIVE:-/swapfile 2G}"
    export TEST_OPEN_PORTS="${TEST_OPEN_PORTS:-80 443}"
    export TEST_F2B_JAILS="${TEST_F2B_JAILS:-sshd bamboo-example.com-scanner bamboo-example.com-http-auth bamboo-example.com-limit bamboo-example.com-badbots}"
    fresh_root

    config_init_defaults
    mkdir -p "$BAMBOO_NGINX_CONFD"
    : >"$BAMBOO_NGINX_LIMITS_FILE"
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com'
    workspace_create 'example.com'
    nginx_apply_site 'example.com' 'https'
    f2b_ensure_filters
    mkdir -p "$BAMBOO_F2B_JAILD"
    printf '# jail\n' >"$(f2b_jail_path 'example.com')"
}

test_status_healthy_server_exits_zero() {
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 0 "$RC" 'a healthy server reports no problems'
    assert_not_contains "$OUT" '[error]' 'no problems are printed'
    assert_contains "$OUT" 'problem(s)' 'prints the summary'
    assert_contains "$OUT" 'nginx is running and enabled at boot' 'checks services'
    assert_contains "$OUT" 'UFW allows SSH' 'checks firewall rules'
    assert_contains "$OUT" 'All four jails are active for example.com' 'checks the jails'
    assert_contains "$OUT" 'example.com certificate valid' 'checks the certificate'
}

test_status_json_is_machine_readable() {
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status --json
    assert_rc 0 "$RC" 'json mode exits 0'
    assert_contains "$OUT" '"problems": 0' 'reports zero problems'
    assert_contains "$OUT" '"host":' 'includes the host'
    assert_contains "$OUT" '"checks": [' 'includes the checks array'
    assert_contains "$OUT" '"sites": [' 'includes the sites array'
    assert_contains "$OUT" '"mode": "https"' 'includes the site mode'
    if command -v python3 >/dev/null 2>&1; then
        if printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
            pass 'the json parses'
        else
            fail "the json does not parse: $(printf '%s' "$OUT" | head -3)"
        fi
    fi
}

test_status_quiet_prints_only_issues() {
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status --quiet
    assert_rc 0 "$RC" 'quiet mode exits 0 when healthy'
    assert_eq '' "$OUT" 'quiet mode prints nothing when healthy'

    export BAMBOO_TEST_SWAP_ACTIVE=''
    capture "$BAMBOO_TEST_BIN" status --quiet
    assert_rc 0 "$RC" 'a warning alone keeps exit code 0'
    assert_contains "$OUT" 'warn resource.swap' 'quiet mode prints the warning line'
    assert_not_contains "$OUT" 'ok ' 'quiet mode hides healthy checks'
}

test_status_strict_promotes_warnings() {
    # Healthy in every respect except "no swap", so the only issue is a warning.
    export TEST_SWAP_ACTIVE='none-means-empty'
    status_healthy_env
    export BAMBOO_TEST_SWAP_ACTIVE=''
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 0 "$RC" 'without --strict a warning is not a failure'
    capture "$BAMBOO_TEST_BIN" status --strict
    assert_rc 1 "$RC" '--strict turns warnings into a failure'
}

test_status_reports_broken_nginx_config() {
    status_healthy_env
    : >"$BAMBOO_TEST_NGINX_TEST_FAIL_FILE"
    capture "$BAMBOO_TEST_BIN" status
    rm -f "$BAMBOO_TEST_NGINX_TEST_FAIL_FILE"
    assert_rc 1 "$RC" 'a broken config fails the status'
    assert_contains "$OUT" 'nginx -t failed' 'explains the nginx problem'
}

test_status_reports_a_stopped_service() {
    export TEST_SERVICES_ACTIVE='fail2ban ufw certbot.timer'
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 1 "$RC" 'a stopped service fails the status'
    assert_contains "$OUT" 'nginx is not running' 'names the service'
}

test_status_reports_a_service_not_enabled_at_boot() {
    export TEST_SERVICES_ENABLED='fail2ban ufw certbot.timer'
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 0 "$RC" 'a boot-persistence gap is a warning, not a failure'
    assert_contains "$OUT" 'NOT enabled at boot' 'warns about the boot state'
}

test_status_reports_inactive_firewall() {
    export TEST_UFW_ACTIVE=0
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 1 "$RC" 'an inactive firewall fails the status'
    assert_contains "$OUT" 'UFW is not active' 'explains the firewall problem'
}

test_status_reports_missing_firewall_rule() {
    export TEST_UFW_RULES='22/tcp 80/tcp'
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 1 "$RC" 'a missing rule fails the status'
    assert_contains "$OUT" 'missing ALLOW rules for: 443' 'names the missing port'
}

test_status_reports_closed_web_port() {
    export TEST_OPEN_PORTS='443'
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 1 "$RC" 'a closed port 80 fails the status'
    assert_contains "$OUT" 'Nothing is listening on port 80' 'explains the port problem'
}

test_status_reports_inactive_jail() {
    export TEST_F2B_JAILS='sshd'
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 1 "$RC" 'a jail that is not active fails the status'
    assert_contains "$OUT" 'Not all jails are active for example.com' 'names the domain'
}

test_status_reports_expiring_certificate() {
    export TEST_CERT_DAYS=3
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 1 "$RC" 'a certificate expiring in days fails the status'
    assert_contains "$OUT" 'certificate expires in' 'warns about the expiry'
}

test_status_reports_pending_ssl() {
    status_healthy_env
    # Turn the healthy HTTPS site into one whose certificate never arrived.
    rm -rf "$BAMBOO_LETSENCRYPT_LIVE/example.com"
    nginx_apply_site 'example.com' 'http'
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 0 "$RC" 'an HTTP-only site is a warning'
    assert_contains "$OUT" 'served over HTTP only' 'warns about the pending certificate'
    capture "$BAMBOO_TEST_BIN" status --strict
    assert_rc 1 "$RC" '--strict reports it as a failure'
}

test_status_reports_pending_reboot() {
    export TEST_REBOOT_REQUIRED=1
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_rc 0 "$RC" 'a pending reboot is a warning'
    assert_contains "$OUT" 'A reboot is pending' 'mentions the reboot'
    assert_contains "$OUT" 'linux-image-6.8.0-test' 'names the waiting package'
}

test_status_works_without_managed_sites() {
    export TEST_SWAP_ACTIVE='/swapfile 2G'
    fresh_root
    capture "$BAMBOO_TEST_BIN" status
    assert_contains "$OUT" 'No sites are managed yet' 'handles an empty server'
    assert_rc 1 "$RC" 'a server with no nginx/ufw/fail2ban is reported as a problem'
}

test_status_does_not_require_root() {
    status_healthy_env
    capture "$BAMBOO_TEST_BIN" status
    assert_not_contains "$OUT" 'must be run as root' 'status never demands root'
    assert_not_contains "$OUT" 'root privileges' 'status never demands root'
}
