#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests: certificate handling, www auto-detection, DNS preflight and the
# smart-fallback behaviour.

test_ssl_determine_names() {
    export TEST_DNS_A='203.0.113.10'
    fresh_root
    assert_eq 'example.com www.example.com' "$(ssl_determine_names 'example.com' auto)" 'auto adds www when it resolves'

    export TEST_NO_DNS=1
    fresh_root
    assert_eq 'example.com' "$(ssl_determine_names 'example.com' auto)" 'auto skips www when it does not resolve'
    assert_eq 'example.com www.example.com' "$(ssl_determine_names 'example.com' yes)" 'yes forces www'
    assert_eq 'example.com' "$(ssl_determine_names 'example.com' no)" 'no keeps the apex only'
}

test_ssl_certificate_detection() {
    if ssl_cert_exists 'example.com'; then fail 'no certificate should exist initially'; else pass 'no certificate initially'; fi
    assert_eq '' "$(ssl_cert_days_left 'example.com')" 'no days left without a certificate'
    assert_eq 'example.com' "$(ssl_cert_names 'example.com')" 'falls back to the domain without a certificate'

    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com -d www.example.com'
    if ssl_cert_exists 'example.com'; then pass 'certificate detected after issuance'; else fail 'certificate detected after issuance'; fi
    assert_eq 'example.com www.example.com' "$(ssl_cert_names 'example.com')" 'reads the SANs with the apex first'

    local days
    days="$(ssl_cert_days_left 'example.com')"
    if [ -n "$days" ] && [ "$days" -ge 80 ] && [ "$days" -le 92 ]; then
        pass "reports a plausible validity window (${days} days)"
    else
        fail "reports a plausible validity window (got '$days')"
    fi
}

test_ssl_attempt_success_enables_https() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    if ssl_attempt 'example.com' 'example.com www.example.com' 'admin@example.com' '0'; then
        pass 'ssl_attempt succeeds'
    else
        fail 'ssl_attempt succeeds'
    fi
    local conf
    conf="$(workspace_conf 'example.com')"
    assert_file_contains "$conf" 'listen 443 ssl' 'switches the site to HTTPS'
    assert_symlink_to "$(workspace_le 'example.com')" "$BAMBOO_LETSENCRYPT_LIVE/example.com" 'links letsencrypt into the workspace'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'certbot certonly' 'runs certbot'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" '--webroot' 'uses the webroot plugin'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" '-d www.example.com' 'passes every requested name'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" '-m admin@example.com' 'passes the contact email'
}

test_ssl_attempt_failure_falls_back_to_http() {
    export TEST_CERTBOT_RESULT=1
    export TEST_CERTBOT_OUTPUT='DNS problem: NXDOMAIN looking up A for example.com'
    fresh_root
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http

    if ssl_attempt 'example.com' 'example.com' '' '0'; then
        fail 'ssl_attempt must fail when certbot fails'
    else
        pass 'ssl_attempt reports the failure'
    fi
    assert_contains "$BAMBOO_LAST_OUTPUT" 'NXDOMAIN' 'keeps the certbot output for diagnostics'
    assert_file_not_contains "$(workspace_conf 'example.com')" 'listen 443' 'leaves the site on HTTP only'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'systemctl reload nginx' 'nginx ends up reloaded and consistent'
}

test_ssl_attempt_failure_rolls_https_back() {
    workspace_create 'example.com'
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com'
    nginx_apply_site 'example.com' https
    assert_file_contains "$(workspace_conf 'example.com')" 'listen 443 ssl' 'starts from an HTTPS config'

    export BAMBOO_TEST_CERTBOT_RESULT=1
    if ssl_attempt 'example.com' 'example.com' '' '1'; then
        fail 'ssl_attempt must fail when certbot fails'
    else
        pass 'ssl_attempt reports the failure'
    fi
    assert_file_not_contains "$(workspace_conf 'example.com')" 'listen 443' 'rolls an existing HTTPS config back to HTTP'
}

test_ssl_failure_help_explains_causes() {
    ssl_print_failure_help 'example.com' 'Some challenges have failed. DNS problem: NXDOMAIN looking up A for example.com' 2>"$TEST_ROOT/help.txt"
    local help
    help="$(cat "$TEST_ROOT/help.txt")"
    assert_contains "$help" 'dig +short A example.com' 'suggests the DNS check'
    assert_contains "$help" 'sudo bamboo-site ssl example.com' 'prints the retry command'
    assert_contains "$help" 'stays online over HTTP' 'reassures that the site is still up'

    ssl_print_failure_help 'example.com' 'Error: too many certificates already issued' 2>"$TEST_ROOT/help2.txt"
    help="$(cat "$TEST_ROOT/help2.txt")"
    assert_contains "$help" 'rate limit' 'detects rate limits'

    ssl_print_failure_help 'example.com' 'Timeout during connect (likely firewall problem)' 2>"$TEST_ROOT/help3.txt"
    help="$(cat "$TEST_ROOT/help3.txt")"
    assert_contains "$help" 'Port 80 is not reachable' 'detects firewall problems'
}

test_ssl_preflight() {
    export TEST_DNS_A='203.0.113.10'
    fresh_root
    capture ssl_preflight 'example.com' 0
    assert_rc 0 "$RC" 'passes when DNS matches the server IP'
    assert_contains "$OUT" 'resolves to 203.0.113.10' 'confirms the DNS mapping'

    export TEST_NO_DNS=1
    fresh_root
    capture ssl_preflight 'example.com' 0
    assert_rc 1 "$RC" 'fails when no A record exists'
    assert_contains "$OUT" 'No A record found for example.com' 'explains the missing record'

    capture ssl_preflight 'example.com' 1
    assert_rc 0 "$RC" 'force skips the preflight'

    export TEST_DNS_A='198.51.100.7'
    fresh_root
    capture ssl_preflight 'example.com' 0
    assert_rc 0 "$RC" 'continues after a mismatch when auto-confirmed'
    assert_contains "$OUT" 'resolves to 198.51.100.7' 'warns about the mismatch'
}

test_ssl_revoke_without_certificate_is_safe() {
    capture ssl_revoke 'example.com'
    assert_rc 0 "$RC" 'revoking a missing certificate is not fatal'
    assert_contains "$OUT" 'Certificate files removed' 'certbot delete still runs'
}

test_ssl_renew_and_upgrade() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com'
    export BAMBOO_TEST_CERTBOT_RESULT=0

    capture ssl_renew 'example.com' '0'
    assert_rc 0 "$RC" 'renew runs'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'certbot renew --deploy-hook' 'asks certbot to renew with a reload hook'

    ssl_upgrade_pending_domains 'example.com'
    assert_file_contains "$(workspace_conf 'example.com')" 'listen 443 ssl' 'upgrades a pending domain to HTTPS'
}
