#!/usr/bin/env bash
# shellcheck shell=bash
#
# End-to-end tests: the real bin/bamboo-site binary, driven through a fake root.

test_cli_version() {
    capture "$BAMBOO_TEST_BIN" version
    assert_rc 0 "$RC" 'version exits 0'
    local expected
    expected="$(tr -d '[:space:]' <"$BAMBOO_ROOT/VERSION")"
    assert_contains "$OUT" "$expected" 'prints the version from the VERSION file'
    capture "$BAMBOO_TEST_BIN" --version
    assert_rc 0 "$RC" '--version exits 0'
}

test_cli_help() {
    capture "$BAMBOO_TEST_BIN" help
    assert_rc 0 "$RC" 'help exits 0'
    assert_contains "$OUT" 'add <domain>' 'lists add'
    assert_contains "$OUT" 'ssl <domain>' 'lists ssl'
    assert_contains "$OUT" 'renew [domain]' 'lists renew'
    assert_contains "$OUT" 'install' 'lists install'

    capture "$BAMBOO_TEST_BIN" help ssl
    assert_rc 0 "$RC" 'per-command help exits 0'
    assert_contains "$OUT" 'bamboo-site ssl <domain>' 'shows the ssl usage'

    capture "$BAMBOO_TEST_BIN" --help
    assert_rc 0 "$RC" '--help exits 0'

    capture "$BAMBOO_TEST_BIN" add --help
    assert_rc 0 "$RC" 'add --help exits 0'
    assert_contains "$OUT" 'bamboo-site add <domain>' 'shows the add usage'
}

test_cli_no_arguments_shows_usage() {
    capture "$BAMBOO_TEST_BIN"
    assert_rc 1 "$RC" 'no arguments exits non-zero'
    assert_contains "$OUT" 'Usage:' 'prints the usage'
}

test_cli_unknown_command() {
    capture "$BAMBOO_TEST_BIN" frobnicate
    assert_rc 1 "$RC" 'unknown command exits non-zero'
    assert_contains "$OUT" 'Unknown command: frobnicate' 'names the unknown command'
}

test_cli_unknown_global_option() {
    capture "$BAMBOO_TEST_BIN" --bogus
    assert_rc 1 "$RC" 'unknown option exits non-zero'
    assert_contains "$OUT" 'Unknown global option' 'explains the bad option'
}

test_cli_add_creates_everything() {
    capture "$BAMBOO_TEST_BIN" add example.com admin@example.com
    assert_rc 0 "$RC" 'add exits 0'

    assert_dir_exists "$BAMBOO_WWW_DIR/example.com/public_html" 'creates the workspace'
    assert_file_exists "$(workspace_conf 'example.com')" 'creates the nginx config'
    assert_symlink_to "$BAMBOO_NGINX_AVAILABLE/example.com.conf" "$(workspace_conf 'example.com')" 'links sites-available'
    assert_symlink_to "$BAMBOO_NGINX_ENABLED/example.com.conf" '../sites-available/example.com.conf' 'links sites-enabled'
    assert_file_exists "$BAMBOO_NGINX_LIMITS_FILE" 'installs the rate-limit zones'
    assert_file_exists "$BAMBOO_F2B_FILTERD/bamboo-scanner.conf" 'installs the scanner filter'
    assert_file_exists "$BAMBOO_F2B_JAILD/example.com.conf" 'creates the fail2ban jail'
    assert_file_contains_fixed "$BAMBOO_F2B_JAILD/example.com.conf" '[bamboo-example.com-scanner]' 'jail: scanner'
    assert_file_contains_fixed "$BAMBOO_F2B_JAILD/example.com.conf" '[bamboo-example.com-http-auth]' 'jail: http-auth'
    assert_file_contains_fixed "$BAMBOO_F2B_JAILD/example.com.conf" '[bamboo-example.com-limit]' 'jail: rate limit'
    assert_file_contains_fixed "$BAMBOO_F2B_JAILD/example.com.conf" '[bamboo-example.com-badbots]' 'jail: bad bots'
    assert_file_contains_fixed "$BAMBOO_F2B_JAILD/example.com.conf" "$BAMBOO_WWW_DIR/example.com/logs/access.log" 'jail watches the domain log'
    assert_file_contains "$(workspace_conf 'example.com')" 'listen 443 ssl' 'enables HTTPS automatically'
    assert_symlink_to "$(workspace_le 'example.com')" "$BAMBOO_LETSENCRYPT_LIVE/example.com" 'links letsencrypt into the workspace'
    assert_contains "$OUT" 'live at https://example.com' 'prints a success summary'
    assert_file_exists "$BAMBOO_LOG_FILE" 'writes the operations log'
}

test_cli_add_detects_www() {
    capture "$BAMBOO_TEST_BIN" add example.com
    assert_rc 0 "$RC" 'add exits 0'
    assert_file_contains "$(workspace_conf 'example.com')" 'server_name example.com www.example.com;' 'covers www when it resolves'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" '-d www.example.com' 'asks certbot for www'

    export TEST_NO_DNS=1
    fresh_root
    capture "$BAMBOO_TEST_BIN" add example.com
    assert_file_contains "$(workspace_conf 'example.com')" 'server_name example.com;' 'skips www when it does not resolve'

    export TEST_DNS_A='203.0.113.10'
    fresh_root
    capture "$BAMBOO_TEST_BIN" add example.com --no-www
    assert_file_contains "$(workspace_conf 'example.com')" 'server_name example.com;' '--no-www keeps the apex only'

    fresh_root
    capture "$BAMBOO_TEST_BIN" add example.com --www
    assert_file_contains "$(workspace_conf 'example.com')" 'server_name example.com www.example.com;' '--www forces both names'
}

test_cli_add_no_ssl() {
    capture "$BAMBOO_TEST_BIN" add example.com --no-ssl
    assert_rc 0 "$RC" 'add --no-ssl exits 0'
    assert_file_not_contains "$(workspace_conf 'example.com')" 'listen 443' 'stays on HTTP'
    assert_contains "$OUT" 'SSL skipped' 'says SSL was skipped'
    assert_contains "$OUT" 'bamboo-site ssl example.com' 'offers the retry command'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'certbot certonly' 'never calls certbot'
}

test_cli_add_ssl_failure_keeps_site_online() {
    export TEST_CERTBOT_RESULT=1
    export TEST_CERTBOT_OUTPUT='DNS problem: NXDOMAIN looking up A for example.com'
    fresh_root

    capture "$BAMBOO_TEST_BIN" add example.com
    assert_rc 0 "$RC" 'add still exits 0 when SSL fails'
    assert_file_not_contains "$(workspace_conf 'example.com')" 'listen 443' 'rolls back to HTTP only'
    assert_symlink_to "$BAMBOO_NGINX_ENABLED/example.com.conf" '../sites-available/example.com.conf' 'keeps the site enabled'
    assert_contains "$OUT" 'stays online over HTTP' 'explains the fallback'
    assert_contains "$OUT" 'dig +short A example.com' 'explains the cause'
    assert_contains "$OUT" 'sudo bamboo-site ssl example.com' 'prints the retry command'
    assert_contains "$OUT" 'live over HTTP' 'summarises the outcome'
}

test_cli_add_rejects_duplicates() {
    capture "$BAMBOO_TEST_BIN" add example.com
    capture "$BAMBOO_TEST_BIN" add example.com
    assert_rc 1 "$RC" 'a duplicate add fails'
    assert_contains "$OUT" 'already managed' 'explains the duplicate'
    assert_contains "$OUT" 'bamboo-site delete example.com' 'points at the delete command'
}

test_cli_add_rejects_invalid_domains() {
    capture "$BAMBOO_TEST_BIN" add 'bad domain'
    assert_rc 1 "$RC" 'rejects a domain with a space'
    assert_contains "$OUT" 'Invalid domain name' 'explains the invalid name'
    assert_dir_missing "$BAMBOO_WWW_DIR/bad domain" 'creates nothing for an invalid domain'

    capture "$BAMBOO_TEST_BIN" add '../../etc'
    assert_rc 1 "$RC" 'rejects path traversal'
    local count
    count="$(find "$BAMBOO_WWW_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq '0' "$count" 'creates nothing in the workspace root'

    capture "$BAMBOO_TEST_BIN" add '192.168.1.10'
    assert_rc 1 "$RC" 'rejects a bare IP address'
}

test_cli_add_requires_a_domain() {
    capture "$BAMBOO_TEST_BIN" add
    assert_rc 1 "$RC" 'add without a domain fails'
    assert_contains "$OUT" 'a domain name is required' 'explains the missing domain'
}

test_cli_list() {
    capture "$BAMBOO_TEST_BIN" list
    assert_rc 0 "$RC" 'list on an empty server exits 0'
    assert_contains "$OUT" 'No sites are managed yet' 'mentions the empty state'

    capture "$BAMBOO_TEST_BIN" add example.com
    capture "$BAMBOO_TEST_BIN" list
    assert_rc 0 "$RC" 'list exits 0'
    assert_contains "$OUT" 'example.com' 'lists the domain'
    assert_contains "$OUT" 'https' 'shows the HTTPS mode'
    assert_contains "$OUT" 'valid' 'shows the certificate validity'

    capture "$BAMBOO_TEST_BIN" list --quiet
    assert_eq 'example.com' "$OUT" 'quiet mode prints names only'

    capture "$BAMBOO_TEST_BIN" list --json
    assert_contains "$OUT" '"domain": "example.com"' 'json: domain'
    assert_contains "$OUT" '"mode": "https"' 'json: mode'
    assert_contains "$OUT" '"jail": "on"' 'json: jail'
    assert_contains "$OUT" '"ssl_days":' 'json: certificate days'

    capture "$BAMBOO_TEST_BIN" list --json
    if printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        pass 'json output parses'
    else
        # python3 is optional; fall back to a shape check.
        case "$OUT" in
            '['*']') pass 'json output has a list shape' ;;
            *) fail 'json output has a list shape' ;;
        esac
    fi
}

test_cli_ssl_retry_after_failure() {
    export TEST_CERTBOT_RESULT=1
    fresh_root
    capture "$BAMBOO_TEST_BIN" add example.com
    assert_file_not_contains "$(workspace_conf 'example.com')" 'listen 443' 'starts HTTP-only'

    export BAMBOO_TEST_CERTBOT_RESULT=0
    capture "$BAMBOO_TEST_BIN" ssl example.com
    assert_rc 0 "$RC" 'ssl retry exits 0'
    assert_file_contains "$(workspace_conf 'example.com')" 'listen 443 ssl' 'switches the site to HTTPS'
    assert_contains "$OUT" 'HTTPS enabled for example.com' 'confirms HTTPS'
}

test_cli_ssl_preflight_blocks_without_dns() {
    capture "$BAMBOO_TEST_BIN" add example.com --no-ssl
    export BAMBOO_TEST_DNS_A=''
    capture "$BAMBOO_TEST_BIN" ssl example.com
    assert_rc 1 "$RC" 'ssl fails without DNS'
    assert_contains "$OUT" 'No A record found' 'explains the DNS problem'
    assert_contains "$OUT" 'Fix DNS first, or re-run with --force' 'mentions the force override'
}

test_cli_ssl_existing_certificate() {
    capture "$BAMBOO_TEST_BIN" add example.com
    capture "$BAMBOO_TEST_BIN" ssl example.com
    assert_rc 0 "$RC" 'ssl on a certified domain exits 0'
    assert_contains "$OUT" 'already exists' 'reports the existing certificate'
    assert_contains "$OUT" '--force to re-issue' 'mentions --force'
}

test_cli_delete_removes_everything() {
    capture "$BAMBOO_TEST_BIN" add example.com
    capture "$BAMBOO_TEST_BIN" delete example.com --yes
    assert_rc 0 "$RC" 'delete exits 0'
    assert_dir_missing "$BAMBOO_WWW_DIR/example.com" 'removes the workspace'
    assert_file_missing "$BAMBOO_NGINX_ENABLED/example.com.conf" 'removes the enabled link'
    assert_file_missing "$BAMBOO_NGINX_AVAILABLE/example.com.conf" 'removes the available link'
    assert_file_missing "$BAMBOO_F2B_JAILD/example.com.conf" 'removes the fail2ban jail'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'certbot revoke' 'revokes the certificate'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'certbot delete --cert-name example.com' 'deletes the certificate files'
    capture "$BAMBOO_TEST_BIN" list --quiet
    assert_eq '' "$OUT" 'the domain is gone from the list'
}

test_cli_delete_keeps_files_on_request() {
    capture "$BAMBOO_TEST_BIN" add example.com
    printf 'keep me\n' >"$BAMBOO_WWW_DIR/example.com/public_html/keep.txt"
    capture "$BAMBOO_TEST_BIN" delete example.com --keep-files --yes
    assert_rc 0 "$RC" 'delete --keep-files exits 0'
    assert_file_exists "$BAMBOO_WWW_DIR/example.com/public_html/keep.txt" 'keeps the site content'
    assert_file_missing "$BAMBOO_NGINX_ENABLED/example.com.conf" 'still disables nginx'
    assert_file_missing "$BAMBOO_F2B_JAILD/example.com.conf" 'still removes the jail'
}

test_cli_delete_needs_confirmation_without_a_terminal() {
    capture "$BAMBOO_TEST_BIN" add example.com
    OUT="$(BAMBOO_ASSUME_YES=0 "$BAMBOO_TEST_BIN" delete example.com </dev/null 2>&1)" && RC=0 || RC=$?
    assert_rc 1 "$RC" 'delete without --yes and no terminal aborts'
    assert_contains "$OUT" 'No terminal available' 'explains why it aborted'
    assert_contains "$OUT" '--yes' 'suggests the flag'
    assert_dir_exists "$BAMBOO_WWW_DIR/example.com" 'nothing was deleted'
}

test_cli_delete_unknown_domain() {
    capture "$BAMBOO_TEST_BIN" delete nothere.example.com --yes
    assert_rc 1 "$RC" 'deleting an unmanaged domain fails'
    assert_contains "$OUT" 'is not managed' 'explains the problem'
}

test_cli_dry_run_changes_nothing() {
    capture "$BAMBOO_TEST_BIN" --dry-run add example.com
    assert_rc 0 "$RC" 'dry-run add exits 0'
    assert_dir_missing "$BAMBOO_WWW_DIR/example.com" 'creates no workspace'
    assert_file_missing "$BAMBOO_NGINX_ENABLED/example.com.conf" 'creates no symlink'
    assert_file_missing "$BAMBOO_F2B_JAILD/example.com.conf" 'creates no jail'
    assert_file_missing "$BAMBOO_NGINX_LIMITS_FILE" 'creates no zone file'
    assert_file_missing "$BAMBOO_LOG_FILE" 'writes no operations log'
    assert_contains "$OUT" '[dry-run]' 'reports what it would do'

    # The same guarantee must hold for the whole install flow.
    capture "$BAMBOO_TEST_BIN" --dry-run install
    assert_rc 0 "$RC" 'dry-run install exits 0'
    assert_file_missing "$BAMBOO_CONFIG_FILE" 'dry-run install writes no config'
    assert_file_missing "$BAMBOO_NGINX_LIMITS_FILE" 'dry-run install writes no zones'
    assert_file_missing "$BAMBOO_F2B_FILTERD/bamboo-scanner.conf" 'dry-run install writes no filter'
    assert_file_missing "$BAMBOO_F2B_JAILD/00-bamboo-defaults.conf" 'dry-run install writes no defaults'
    assert_file_missing "$BAMBOO_LETSENCRYPT_HOOKS/10-bamboo-nginx-reload.sh" 'dry-run install writes no hook'
    assert_file_missing "$BAMBOO_SWAP_FILE" 'dry-run install creates no swap file'
    assert_file_missing "$BAMBOO_FSTAB" 'dry-run install leaves fstab alone'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'fallocate' 'dry-run install allocates nothing'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'upgrade' 'dry-run install upgrades nothing'
    # (Only the harmless 'certbot --version' probe may appear.)
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'certbot certonly' 'dry-run install issues no certificate'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'certbot renew' 'dry-run install renews nothing'
}

test_cli_install() {
    capture "$BAMBOO_TEST_BIN" install --yes
    assert_rc 0 "$RC" 'install exits 0 in test mode'
    assert_file_exists "$BAMBOO_CONFIG_FILE" 'writes the config file'
    assert_file_contains "$BAMBOO_CONFIG_FILE" 'BAMBOO_SSL_WWW=auto' 'writes the defaults'
    assert_file_exists "$BAMBOO_NGINX_LIMITS_FILE" 'installs the rate-limit zones'
    assert_file_exists "$BAMBOO_LETSENCRYPT_HOOKS/10-bamboo-nginx-reload.sh" 'installs the renewal hook'
    assert_file_contains "$BAMBOO_LETSENCRYPT_HOOKS/10-bamboo-nginx-reload.sh" 'systemctl reload nginx' 'the hook reloads nginx'
    assert_file_exists "$BAMBOO_F2B_FILTERD/bamboo-scanner.conf" 'installs the fail2ban scanner filter'
    assert_file_exists "$BAMBOO_F2B_JAILD/00-bamboo-defaults.conf" 'installs the fail2ban defaults'
    assert_file_contains "$BAMBOO_F2B_JAILD/00-bamboo-defaults.conf" 'ignoreip' 'the defaults whitelist localhost'
}

test_cli_install_upgrades_the_os() {
    capture "$BAMBOO_TEST_BIN" install --yes
    assert_rc 0 "$RC" 'install exits 0'
    assert_contains "$OUT" 'Upgrading the operating system' 'runs the upgrade step'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'apt-get -y -o Dpkg::Options::=--force-confold upgrade' 'upgrades with dpkg config files preserved'
    assert_contains "$OUT" 'Operating system upgraded' 'reports the upgrade'
}

test_cli_install_no_upgrade_flag() {
    capture "$BAMBOO_TEST_BIN" install --yes --no-upgrade
    assert_rc 0 "$RC" 'install --no-upgrade exits 0'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" '--force-confold' 'does not run apt-get upgrade'
    assert_contains "$OUT" 'Skipped' 'says the upgrade was skipped'
}

test_cli_install_dist_upgrade_flag() {
    capture "$BAMBOO_TEST_BIN" install --yes --dist-upgrade
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'full-upgrade' '--dist-upgrade uses apt-get full-upgrade'
}

test_cli_install_up_to_date() {
    export TEST_UPGRADE_COUNT=0
    fresh_root
    capture "$BAMBOO_TEST_BIN" install --yes
    assert_rc 0 "$RC" 'install exits 0'
    assert_contains "$OUT" 'already up to date' 'reports that nothing needs upgrading'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" '--force-confold' 'runs no upgrade at all'
}

test_cli_install_reports_a_pending_reboot() {
    export TEST_REBOOT_REQUIRED=1
    fresh_root
    capture "$BAMBOO_TEST_BIN" install --yes
    assert_rc 0 "$RC" 'install still exits 0'
    assert_contains "$OUT" 'A reboot is required' 'warns about the pending reboot'
    assert_contains "$OUT" 'linux-image-6.8.0-test' 'names the package that wants it'
    assert_contains "$OUT" 'never reboots' 'makes clear it will not reboot'
}

test_cli_install_firewall_order() {
    capture "$BAMBOO_TEST_BIN" install --yes
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'ufw allow 22/tcp' 'opens the SSH port'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'ufw allow 80/tcp' 'opens port 80'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'ufw allow 443/tcp' 'opens port 443'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'ufw --force enable' 'enables UFW'

    local ssh_line enable_line
    ssh_line="$(grep -n 'ufw allow 22/tcp' "$BAMBOO_TEST_CMD_LOG" | head -n 1 | cut -d: -f1)"
    enable_line="$(grep -n 'ufw --force enable' "$BAMBOO_TEST_CMD_LOG" | head -n 1 | cut -d: -f1)"
    if [ -n "$ssh_line" ] && [ -n "$enable_line" ] && [ "$ssh_line" -lt "$enable_line" ]; then
        pass 'the SSH rule is added before UFW is enabled'
    else
        fail "the SSH rule must precede 'ufw enable' (ssh=$ssh_line enable=$enable_line)"
    fi
}

test_cli_install_no_ufw() {
    capture "$BAMBOO_TEST_BIN" install --yes --no-ufw
    assert_rc 0 "$RC" 'install --no-ufw exits 0'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'ufw --force enable' 'leaves the firewall alone'
}

test_cli_edit_applies_a_valid_change() {
    capture "$BAMBOO_TEST_BIN" add example.com
    local conf editor
    conf="$(workspace_conf 'example.com')"
    editor="$TEST_ROOT/editor.sh"
    cat >"$editor" <<'EOF'
#!/usr/bin/env bash
printf '\n# manual note\n' >>"$1"
EOF
    chmod +x "$editor"

    export BAMBOO_EDITOR="$editor"
    capture "$BAMBOO_TEST_BIN" edit example.com
    unset BAMBOO_EDITOR

    assert_rc 0 "$RC" 'edit exits 0 for a valid change'
    assert_file_contains "$conf" '# manual note' 'keeps the edit'
    assert_file_exists "$conf.bak" 'takes a backup before editing'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'systemctl reload nginx' 'reloads nginx'
}

test_cli_edit_rejects_a_broken_config() {
    capture "$BAMBOO_TEST_BIN" add example.com
    local conf editor
    conf="$(workspace_conf 'example.com')"
    editor="$TEST_ROOT/editor.sh"
    cat >"$editor" <<'EOF'
#!/usr/bin/env bash
printf 'this is not nginx syntax\n' >>"$1"
EOF
    chmod +x "$editor"
    : >"$BAMBOO_TEST_NGINX_TEST_FAIL_FILE"

    export BAMBOO_EDITOR="$editor"
    capture "$BAMBOO_TEST_BIN" edit example.com
    unset BAMBOO_EDITOR
    rm -f "$BAMBOO_TEST_NGINX_TEST_FAIL_FILE"

    assert_rc 1 "$RC" 'edit exits non-zero for a broken config'
    assert_contains "$OUT" 'NOT reloaded' 'says nginx was not reloaded'
    assert_contains "$OUT" "cp '$conf.bak' '$conf'" 'shows how to restore the backup'
}

test_cli_edit_reports_no_change() {
    capture "$BAMBOO_TEST_BIN" add example.com
    export BAMBOO_EDITOR=true
    capture "$BAMBOO_TEST_BIN" edit example.com
    unset BAMBOO_EDITOR
    assert_rc 0 "$RC" 'edit exits 0 when nothing changes'
    assert_contains "$OUT" 'No changes were made' 'reports the no-op'
}

test_cli_renew_upgrades_pending_domains() {
    export TEST_CERTBOT_RESULT=1
    fresh_root
    capture "$BAMBOO_TEST_BIN" add example.com
    assert_file_not_contains "$(workspace_conf 'example.com')" 'listen 443' 'starts HTTP-only'

    # The certificate appears later (issued by another process, or a retry).
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com'
    export BAMBOO_TEST_CERTBOT_RESULT=0

    capture "$BAMBOO_TEST_BIN" renew example.com
    assert_rc 0 "$RC" 'renew exits 0'
    assert_file_contains "$(workspace_conf 'example.com')" 'listen 443 ssl' 'finishes the pending HTTPS setup'
    assert_contains "$OUT" 'switching it to HTTPS' 'reports the upgrade'
}

test_cli_renew_all() {
    capture "$BAMBOO_TEST_BIN" add example.com
    capture "$BAMBOO_TEST_BIN" add second.example.com
    capture "$BAMBOO_TEST_BIN" renew
    assert_rc 0 "$RC" 'renew without a domain exits 0'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'certbot renew' 'runs certbot renew'
}

test_cli_install_repairs_existing_jails() {
    capture "$BAMBOO_TEST_BIN" add example.com --no-ssl
    # Simulate a jail left behind by an older version (references a filter that
    # no longer exists on Ubuntu 24.04).
    printf '[stale]\nfilter = nginx-badbots\n' >"$BAMBOO_F2B_JAILD/example.com.conf"

    capture "$BAMBOO_TEST_BIN" install --yes --no-ufw
    assert_rc 0 "$RC" 'install exits 0 while repairing a jail'
    assert_file_not_contains "$BAMBOO_F2B_JAILD/example.com.conf" 'nginx-badbots' 'install rewrites the stale jail'
    assert_file_contains "$BAMBOO_F2B_JAILD/example.com.conf" 'filter   = bamboo-badbots' 'the repaired jail uses bundled filters'
    assert_contains "$OUT" 'Reconciling the Fail2ban jails' 'install reports the reconciliation'
}

test_cli_edit_is_scriptable_with_bamboo_editor() {
    capture "$BAMBOO_TEST_BIN" add example.com
    local editor
    editor="$TEST_ROOT/editor.sh"
    cat >"$editor" <<'EOF'
#!/usr/bin/env bash
printf '\n# automated change\n' >>"$1"
EOF
    chmod +x "$editor"

    # No terminal here (stdin is /dev/null, stdout a pipe): BAMBOO_EDITOR is the
    # documented automation path and must work without a tty.
    export BAMBOO_EDITOR="$editor"
    capture "$BAMBOO_TEST_BIN" edit example.com
    unset BAMBOO_EDITOR

    assert_rc 0 "$RC" 'edit works without a terminal when BAMBOO_EDITOR is set'
    assert_file_contains "$(workspace_conf 'example.com')" '# automated change' 'the automated edit was applied'
}

test_cli_edit_refuses_without_terminal_or_editor() {
    capture "$BAMBOO_TEST_BIN" add example.com
    capture "$BAMBOO_TEST_BIN" edit example.com
    assert_rc 1 "$RC" 'edit refuses without a terminal and without BAMBOO_EDITOR'
    assert_contains "$OUT" 'interactive terminal' 'explains what is missing'
}

test_cli_dry_run_claims_nothing() {
    capture "$BAMBOO_TEST_BIN" --dry-run add example.com
    assert_not_contains "$OUT" 'is live at https://' 'dry-run add does not claim the site is live'
    assert_not_contains "$OUT" 'HTTPS is live' 'dry-run add does not claim HTTPS is live'
    assert_contains "$OUT" 'Dry run finished' 'dry-run add says it was a dry run'

    capture "$BAMBOO_TEST_BIN" --dry-run install
    assert_not_contains "$OUT" 'installation complete' 'dry-run install does not claim completion'

    capture "$BAMBOO_TEST_BIN" add example.com
    capture "$BAMBOO_TEST_BIN" --dry-run delete example.com
    assert_not_contains "$OUT" 'have been removed' 'dry-run delete does not claim removal'
    assert_dir_exists "$BAMBOO_WWW_DIR/example.com" 'dry-run delete really deleted nothing'

    capture "$BAMBOO_TEST_BIN" add staging.example.com --no-ssl
    capture "$BAMBOO_TEST_BIN" --dry-run ssl staging.example.com
    assert_not_contains "$OUT" 'HTTPS enabled' 'dry-run ssl does not claim HTTPS was enabled'
    assert_contains "$OUT" 'no certificate was requested' 'dry-run ssl states what it did not do'
}

test_cli_flag_order_is_flexible() {
    capture "$BAMBOO_TEST_BIN" add example.com
    # A per-command flag may appear before or after the command name.
    capture "$BAMBOO_TEST_BIN" list --quiet
    assert_eq 'example.com' "$OUT" 'flag after the command'
    capture "$BAMBOO_TEST_BIN" --quiet list
    assert_eq 'example.com' "$OUT" 'flag before the command'
    capture "$BAMBOO_TEST_BIN" --json list
    assert_contains "$OUT" '"domain": "example.com"' 'global-style json flag before the command'
}

test_cli_every_command_has_help() {
    local c
    for c in install add ssl delete edit renew list status reinstall uninstall version help; do
        capture "$BAMBOO_TEST_BIN" "$c" --help
        if [ "$RC" -eq 0 ]; then
            pass "help available for '$c'"
        else
            fail "help available for '$c' (exit $RC: $OUT)"
        fi
    done
}
