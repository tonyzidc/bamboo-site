#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests: Nginx configuration generation and safe activation.

test_nginx_ensure_limits() {
    nginx_ensure_limits
    assert_file_exists "$BAMBOO_NGINX_LIMITS_FILE" 'writes the shared zone file'
    # shellcheck disable=SC2016  # nginx variables are literal here
    assert_file_contains_fixed "$BAMBOO_NGINX_LIMITS_FILE" 'limit_req_zone $binary_remote_addr zone=bamboo_req' 'defines the request zone'
    # shellcheck disable=SC2016
    assert_file_contains_fixed "$BAMBOO_NGINX_LIMITS_FILE" 'limit_conn_zone $binary_remote_addr zone=bamboo_conn' 'defines the connection zone'

    # Idempotent: a second call must not rewrite the file.
    local before after
    before="$(cksum <"$BAMBOO_NGINX_LIMITS_FILE")"
    nginx_ensure_limits
    after="$(cksum <"$BAMBOO_NGINX_LIMITS_FILE")"
    assert_eq "$before" "$after" 'leaves an up-to-date file untouched'
}

test_nginx_http_config_contents() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    local conf
    conf="$(workspace_conf 'example.com')"

    assert_file_exists "$conf" 'writes the server block'
    assert_file_contains "$conf" 'listen 80;' 'listens on port 80'
    assert_file_contains "$conf" 'server_name example.com;' 'sets server_name'
    assert_file_contains_fixed "$conf" "root $BAMBOO_WWW_DIR/example.com/public_html;" 'sets the document root'
    assert_file_contains_fixed "$conf" "$BAMBOO_WWW_DIR/example.com/logs/access.log" 'logs into the workspace'
    assert_file_contains_fixed "$conf" "$BAMBOO_WWW_DIR/example.com/logs/error.log" 'errors into the workspace'
    assert_file_contains "$conf" 'X-Frame-Options' 'sets X-Frame-Options'
    assert_file_contains "$conf" 'X-Content-Type-Options' 'sets X-Content-Type-Options'
    assert_file_contains "$conf" 'X-XSS-Protection' 'sets X-XSS-Protection'
    assert_file_contains "$conf" 'Referrer-Policy' 'sets Referrer-Policy'
    assert_file_contains "$conf" 'expires 6M;' 'caches static files for six months'
    assert_file_contains "$conf" 'limit_req zone=bamboo_req' 'applies the rate limit'
    assert_file_contains "$conf" 'limit_conn bamboo_conn' 'applies the connection limit'
    assert_file_contains "$conf" '\.well-known/acme-challenge' 'keeps the ACME challenge reachable'
    assert_file_contains "$conf" 'deny all;' 'denies hidden and sensitive files'
    assert_file_not_contains "$conf" 'listen 443' 'has no TLS block without a certificate'
    assert_file_not_contains "$conf" 'Strict-Transport-Security' 'has no HSTS header over HTTP'
}

test_nginx_https_requires_certificate() {
    workspace_create 'example.com'
    capture nginx_apply_site 'example.com' https
    assert_rc 1 "$RC" 'refuses HTTPS without a certificate'
    assert_contains "$OUT" 'No certificate for example.com' 'explains why HTTPS is refused'
    assert_contains "$OUT" 'bamboo-site ssl example.com' 'points at the ssl command'
    assert_file_missing "$(workspace_conf 'example.com')" 'writes no config in that case'
}

test_nginx_https_config_contents() {
    workspace_create 'example.com'
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com -d www.example.com'
    nginx_apply_site 'example.com' https
    local conf
    conf="$(workspace_conf 'example.com')"

    assert_file_contains "$conf" 'listen 443 ssl' 'listens on port 443 with TLS'
    assert_file_contains_fixed "$conf" "$BAMBOO_LETSENCRYPT_LIVE/example.com/fullchain.pem" 'references the full chain'
    assert_file_contains_fixed "$conf" "$BAMBOO_LETSENCRYPT_LIVE/example.com/privkey.pem" 'references the private key'
    assert_file_contains "$conf" 'ssl_protocols TLSv1.2 TLSv1.3;' 'restricts TLS versions'
    assert_file_contains "$conf" 'Strict-Transport-Security' 'sets HSTS'
    # shellcheck disable=SC2016  # $host/$request_uri are nginx variables
    assert_file_contains_fixed "$conf" 'return 301 https://$host$request_uri;' 'redirects port 80 to HTTPS'
    assert_file_contains "$conf" 'server_name example.com www.example.com;' 'covers every name in the certificate'
    assert_file_contains "$conf" '\.well-known/acme-challenge' 'keeps the ACME challenge reachable for renewal'
}

test_nginx_uses_certbot_tls_options_when_present() {
    workspace_create 'example.com'
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com'
    mkdir -p "$BAMBOO_LETSENCRYPT_DIR"
    printf 'ssl_protocols TLSv1.2 TLSv1.3;\n' >"$BAMBOO_LETSENCRYPT_DIR/options-ssl-nginx.conf"
    printf 'placeholder\n' >"$BAMBOO_LETSENCRYPT_DIR/ssl-dhparams.pem"
    nginx_apply_site 'example.com' https
    local conf
    conf="$(workspace_conf 'example.com')"
    assert_file_contains_fixed "$conf" "include $BAMBOO_LETSENCRYPT_DIR/options-ssl-nginx.conf;" 'includes certbot TLS options'
    assert_file_contains_fixed "$conf" "ssl_dhparam $BAMBOO_LETSENCRYPT_DIR/ssl-dhparams.pem;" 'includes the dhparams'
    assert_file_not_contains "$conf" 'ssl_session_cache' 'does not duplicate settings from the include'
}

test_nginx_wires_symlinks() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    assert_symlink_to "$BAMBOO_NGINX_AVAILABLE/example.com.conf" "$(workspace_conf 'example.com')" 'sites-available points at the workspace'
    assert_symlink_to "$BAMBOO_NGINX_ENABLED/example.com.conf" '../sites-available/example.com.conf' 'sites-enabled uses the nginx convention'
}

test_nginx_moves_foreign_config_aside() {
    workspace_create 'example.com'
    mkdir -p "$BAMBOO_NGINX_AVAILABLE"
    printf 'server { listen 80; }\n' >"$BAMBOO_NGINX_AVAILABLE/example.com.conf"
    nginx_apply_site 'example.com' http
    assert_symlink_to "$BAMBOO_NGINX_AVAILABLE/example.com.conf" "$(workspace_conf 'example.com')" 'replaces the foreign file with our symlink'
    local backups
    backups="$(find "$BAMBOO_NGINX_AVAILABLE" -name 'example.com.conf.bak.*' | wc -l | tr -d ' ')"
    assert_eq '1' "$backups" 'keeps the previous file as a backup'
}

test_nginx_apply_reloads() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'systemctl reload nginx' 'reloads nginx after applying'
}

test_nginx_apply_rolls_back_on_bad_config() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    cp "$(workspace_conf 'example.com')" "$TEST_ROOT/good.conf"
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com'

    : >"$BAMBOO_TEST_NGINX_TEST_FAIL_FILE"
    capture nginx_apply_site 'example.com' https
    assert_rc 1 "$RC" 'fails when nginx -t rejects the new config'
    assert_contains "$OUT" 'nginx -t rejected' 'says the config was rejected'
    assert_contains "$OUT" 'Restored the previous configuration' 'reports the rollback'
    if cmp -s "$TEST_ROOT/good.conf" "$(workspace_conf 'example.com')"; then
        pass 'the previous configuration is back byte for byte'
    else
        fail 'the previous configuration is back byte for byte'
    fi
    rm -f "$BAMBOO_TEST_NGINX_TEST_FAIL_FILE"
}

test_nginx_set_mode_keeps_backups() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com'
    nginx_set_mode 'example.com' https
    assert_file_exists "$(workspace_conf 'example.com').pre-https" 'keeps a pre-https copy'
    assert_file_exists "$(workspace_conf 'example.com').bak" 'keeps the previous generated version'
    assert_file_contains "$(workspace_conf 'example.com')" 'listen 443 ssl' 'switches the config to HTTPS'
}

test_nginx_site_mode_reports_state() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    assert_eq 'http' "$(nginx_site_mode 'example.com')" 'reports http'
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com'
    nginx_set_mode 'example.com' https
    assert_eq 'https' "$(nginx_site_mode 'example.com')" 'reports https'
    rm -f "$BAMBOO_NGINX_ENABLED/example.com.conf"
    assert_eq 'disabled' "$(nginx_site_mode 'example.com')" 'reports disabled'
    workspace_remove 'example.com' 1
    assert_eq 'missing' "$(nginx_site_mode 'example.com')" 'reports missing'
}

test_nginx_remove_site() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    nginx_remove_site 'example.com'
    assert_file_missing "$BAMBOO_NGINX_ENABLED/example.com.conf" 'removes the enabled link'
    assert_file_missing "$BAMBOO_NGINX_AVAILABLE/example.com.conf" 'removes the available link'
    assert_file_exists "$(workspace_conf 'example.com')" 'leaves the workspace file for the caller to delete'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'systemctl reload nginx' 'reloads nginx after removal'
}

test_nginx_remove_site_keeps_config_when_test_fails() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    : >"$BAMBOO_TEST_NGINX_TEST_FAIL_FILE"
    capture nginx_remove_site 'example.com'
    assert_rc 1 "$RC" 'aborts when nginx -t fails'
    assert_symlink_to "$BAMBOO_NGINX_ENABLED/example.com.conf" '../sites-available/example.com.conf' 're-enables the site'
    rm -f "$BAMBOO_TEST_NGINX_TEST_FAIL_FILE"
}

test_nginx_unwire_leaves_foreign_links_alone() {
    workspace_create 'example.com'
    nginx_apply_site 'example.com' http
    # Replace our symlink with one pointing somewhere else.
    rm -f "$BAMBOO_NGINX_AVAILABLE/example.com.conf"
    ln -sfn "$TEST_ROOT/elsewhere.conf" "$BAMBOO_NGINX_AVAILABLE/example.com.conf"
    nginx_unwire_symlinks 'example.com' 1
    assert_symlink_to "$BAMBOO_NGINX_AVAILABLE/example.com.conf" "$TEST_ROOT/elsewhere.conf" 'keeps a link it did not create'
}

# --- Fail2ban jail rendering (regression guard for the Ubuntu 24.04 bug) -----

test_f2b_jail_references_only_bundled_filters() {
    # The jails must never reference distribution-provided filters: Ubuntu 24.04
    # dropped nginx-badbots, and a missing filter makes the whole fail2ban
    # configuration unloadable (it would not start after a reboot).
    workspace_create 'example.com'
    f2b_add_jail 'example.com'
    local jail
    jail="$(f2b_jail_path 'example.com')"
    assert_file_exists "$jail" 'the jail file is written'

    local name
    for name in bamboo-scanner bamboo-http-auth bamboo-limit-req bamboo-badbots; do
        assert_file_contains "$jail" "filter   = $name" "jail uses the bundled $name filter"
    done
    assert_file_not_contains "$jail" 'filter   = nginx-' 'jail uses no distribution filter'
}

test_f2b_installs_every_bundled_filter() {
    workspace_create 'example.com'
    f2b_add_jail 'example.com'
    local name
    for name in bamboo-scanner bamboo-http-auth bamboo-limit-req bamboo-badbots; do
        assert_file_exists "$(f2b_filter_path "$name")" "installed filter: $name"
    done
    # Assertions must inspect the regex itself, not the explanatory comments.
    local rx
    rx="$(grep -E '^failregex' "$(f2b_filter_path 'bamboo-badbots')")"
    case "$rx" in
        *sqlmap*) pass 'the badbots regex lists known scanners' ;;
        *) fail 'the badbots regex lists known scanners' ;;
    esac
    case "$rx" in
        *Googlebot*|*bingbot*) fail 'the badbots regex must leave search engines alone' ;;
        *) pass 'the badbots regex leaves search engines alone' ;;
    esac
}

test_f2b_access_log_filters_survive_timestamp_stripping() {
    # Regression guard for a bug found on Ubuntu 24.04: fail2ban strips the
    # parsed timestamp before applying failregex, so a pattern expecting the
    # literal [...] timestamp never matches. The access-log filters must be
    # tolerant between the host and the request field.
    workspace_create 'example.com'
    f2b_add_jail 'example.com'
    local name rx
    for name in bamboo-scanner bamboo-badbots; do
        rx="$(grep -E '^failregex' "$(f2b_filter_path "$name")")"
        case "$rx" in
            *'- \S+ .*"'*) pass "$name matches after timestamp stripping" ;;
            *) fail "$name must use a tolerant (.*) pattern, got: $rx" ;;
        esac
        case "$rx" in
            *'\[[^\]]+\]'*) fail "$name must not expect the literal timestamp brackets" ;;
            *) pass "$name does not depend on the raw timestamp" ;;
        esac
    done
}

test_f2b_missing_filters_block_the_jail() {
    workspace_create 'example.com'
    mkdir -p "$BAMBOO_F2B_FILTERD"
    # No filters installed and templates unavailable: simulate by pointing the
    # filter dir at a read-only location is overkill — instead check the guard
    # that reports what is missing.
    local missing
    missing="$(f2b_missing_filters)"
    assert_contains "$missing" 'bamboo-scanner' 'reports missing filters before install'
    f2b_ensure_filters
    assert_eq '' "$(f2b_missing_filters)" 'no filters missing after ensure'
}

test_f2b_quarantines_a_rejected_jail() {
    workspace_create 'example.com'
    : >"$BAMBOO_TEST_F2B_FAIL_FILE"

    capture f2b_add_jail 'example.com'
    assert_rc 1 "$RC" 'a rejected jail is reported as a failure'
    assert_contains "$OUT" 'Disabling the rejected jail' 'explains the quarantine'
    assert_file_missing "$(f2b_jail_path 'example.com')" 'the bad jail is no longer active'
    assert_file_exists "$(f2b_jail_path 'example.com').rejected" 'the bad jail is kept for inspection'
    assert_contains "$OUT" 'Fail2ban was reloaded with the rest' 'fail2ban stays loadable'

    rm -f "$BAMBOO_TEST_F2B_FAIL_FILE"
}

test_f2b_refreshes_an_outdated_jail() {
    workspace_create 'example.com'
    mkdir -p "$BAMBOO_F2B_JAILD"
    printf '[old-jail]\nfilter = nginx-badbots\n' >"$(f2b_jail_path 'example.com')"

    f2b_add_jail 'example.com'

    assert_file_not_contains "$(f2b_jail_path 'example.com')" 'nginx-badbots' 'an outdated jail is rewritten'
    assert_file_contains "$(f2b_jail_path 'example.com')" 'filter   = bamboo-badbots' 'the refreshed jail uses bundled filters'
}

test_f2b_defaults_do_not_weaken_ssh_safety() {
    # [DEFAULT] applies to every jail on the server, including sshd. Putting
    # bantime/maxretry there would silently make SSH bans more aggressive than
    # the distribution default and risk locking the operator out.
    workspace_create 'example.com'
    f2b_add_jail 'example.com'
    local defaults
    defaults="$(f2b_defaults_path)"
    assert_file_exists "$defaults" 'the shared defaults file is written'
    assert_file_contains "$defaults" 'ignoreip' 'the defaults keep the ignore list'
    # Compare actual settings, not the explanatory comments.
    local settings
    settings="$(grep -vE '^[[:space:]]*#' "$defaults" | grep -cE '^[[:space:]]*(bantime|findtime|maxretry)')"
    assert_eq '0' "$settings" 'the shared defaults must not set bantime/findtime/maxretry'

    # ...while the per-domain jails keep their own enforcement settings.
    local jail
    jail="$(f2b_jail_path 'example.com')"
    assert_file_contains "$jail" 'maxretry' 'the jail sets maxretry itself'
    assert_file_contains "$jail" 'bantime.increment = true' 'the jail escalates repeat offenders'
}

test_f2b_jails_pin_their_log_backend() {
    # Debian/Ubuntu set 'backend = systemd' in [DEFAULT] after our file, which
    # made the jails scan the journal instead of the domain log ("No file is
    # currently monitored"). Every jail must pin the file backend itself.
    workspace_create 'example.com'
    f2b_add_jail 'example.com'
    local jail count
    jail="$(f2b_jail_path 'example.com')"
    count="$(grep -c '^backend  = polling' "$jail")"
    assert_eq '4' "$count" 'every jail pins the polling backend'
    assert_file_not_contains "$jail" 'backend  = systemd' 'no jail uses the journal backend'
}
