#!/usr/bin/env bash
# shellcheck shell=bash
#
# Tests for the CLI lifecycle: `reinstall` (stage, verify, swap, rollback) and
# `uninstall` (CLI only by default, --purge, --sites).
#
# These run the real install.sh against a sandboxed prefix, so they exercise the
# same code path a server would — no test double for the installer.

# stage_checkout <dir> <version> — a copy of this checkout with a stamped version.
stage_checkout() {
    local dir="$1" version="$2"
    rm -rf "$dir"
    mkdir -p "$dir"
    ( cd "$BAMBOO_ROOT" && tar --exclude='.git' --exclude='.zcode' --exclude='.github' -cf - . ) \
        | ( cd "$dir" && tar -xf - )
    printf '%s\n' "$version" >"$dir/VERSION"
    printf '%s' "$dir"
}

# Installs the CLI into the sandboxed prefix using the real bootstrap installer.
install_cli_into_sandbox() {
    BAMBOO_INSTALL_ALLOW_NONROOT=1 bash "$BAMBOO_ROOT/install.sh" --local \
        --dir "$BAMBOO_INSTALL_DIR" --bin-dir "$BAMBOO_BIN_DIR" --no-deps --yes >/dev/null 2>&1
}

current_version() { tr -d '[:space:]' <"$BAMBOO_ROOT/VERSION"; }

# --- reinstall --------------------------------------------------------------

test_reinstall_upgrades_the_cli() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    if ! install_cli_into_sandbox; then fail 'setup: install.sh --local failed'; return 0; fi
    assert_eq "$(current_version)" "$(bamboo_installed_version "$BAMBOO_INSTALL_DIR")" 'setup installed the current version'

    local staged=''
    staged="$(stage_checkout "$TEST_ROOT/staged" '9.9.9')"
    capture "$BAMBOO_TEST_BIN" reinstall --from "$staged" --yes
    assert_rc 0 "$RC" 'reinstall exits 0'
    assert_eq '9.9.9' "$(bamboo_installed_version "$BAMBOO_INSTALL_DIR")" 'the new version is installed'
    assert_eq "$(current_version)" "$(bamboo_installed_version "$BAMBOO_INSTALL_DIR.bak")" 'the previous version is kept for rollback'
    assert_symlink_to "$BAMBOO_BIN_DIR/bamboo-site" "$BAMBOO_INSTALL_DIR/bin/bamboo-site" 'the symlink points at the install dir'
    assert_contains "$OUT" 'Reinstalled: 9.9.9' 'reports the new version'
    assert_contains "$OUT" 'were not touched' 'says sites and config were untouched'
    # Run the installed binary with BAMBOO_ROOT unset: it must resolve its own
    # tree and report the version that was installed.
    local cli_out=''
    cli_out="$(env -u BAMBOO_ROOT "$BAMBOO_BIN_DIR/bamboo-site" version 2>&1)" || true
    assert_eq 'bamboo-site 9.9.9' "$cli_out" 'the installed CLI reports the new version'
}

test_reinstall_rollback_restores_the_previous_version() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    install_cli_into_sandbox
    local staged=''
    staged="$(stage_checkout "$TEST_ROOT/staged" '9.9.9')"
    capture "$BAMBOO_TEST_BIN" reinstall --from "$staged" --yes
    assert_eq '9.9.9' "$(bamboo_installed_version "$BAMBOO_INSTALL_DIR")" 'now on the new version'

    capture "$BAMBOO_TEST_BIN" reinstall --rollback --yes
    assert_rc 0 "$RC" 'rollback exits 0'
    assert_eq "$(current_version)" "$(bamboo_installed_version "$BAMBOO_INSTALL_DIR")" 'the previous version is back'
    assert_eq '9.9.9' "$(bamboo_installed_version "$BAMBOO_INSTALL_DIR.bak")" 'the newer copy is kept as the new rollback'
    assert_symlink_to "$BAMBOO_BIN_DIR/bamboo-site" "$BAMBOO_INSTALL_DIR/bin/bamboo-site" 'the symlink still points at the install dir'
}

test_reinstall_rejects_a_staging_copy_that_cannot_run() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    install_cli_into_sandbox

    local bad="$TEST_ROOT/bad"
    mkdir -p "$bad/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' >"$bad/bin/bamboo-site"
    printf '9.9.9\n' >"$bad/VERSION"

    capture "$BAMBOO_TEST_BIN" reinstall --from "$bad" --yes
    assert_rc 1 "$RC" 'a staging copy that cannot run is refused'
    assert_contains "$OUT" 'staged CLI failed to run' 'explains why'
    assert_eq "$(current_version)" "$(bamboo_installed_version "$BAMBOO_INSTALL_DIR")" 'the live copy is untouched'
    assert_file_missing "$BAMBOO_INSTALL_DIR.bak" 'no rollback copy was made'
}

test_reinstall_restores_when_the_installer_fails() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    install_cli_into_sandbox

    local staged=''
    staged="$(stage_checkout "$TEST_ROOT/staged" '9.9.9')"
    printf '#!/usr/bin/env bash\nexit 1\n' >"$staged/install.sh"

    capture "$BAMBOO_TEST_BIN" reinstall --from "$staged" --yes
    assert_rc 1 "$RC" 'a failing installer makes reinstall fail'
    assert_contains "$OUT" 'restoring the previous version' 'says it is restoring'
    assert_eq "$(current_version)" "$(bamboo_installed_version "$BAMBOO_INSTALL_DIR")" 'the previous version is still installed'
    assert_file_missing "$BAMBOO_INSTALL_DIR.bak" 'the rollback copy was consumed by the restore'
}

test_reinstall_refuses_an_unsafe_install_dir() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    OUT="$(BAMBOO_INSTALL_DIR=/opt "$BAMBOO_TEST_BIN" reinstall --from "$BAMBOO_ROOT" --yes 2>&1)" && RC=0 || RC=$?
    assert_rc 1 "$RC" 'refuses to operate on /opt'
    assert_contains "$OUT" 'Refusing to operate on the shared directory' 'explains the refusal'
}

test_reinstall_dry_run_changes_nothing() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    install_cli_into_sandbox
    local staged=''
    staged="$(stage_checkout "$TEST_ROOT/staged" '9.9.9')"

    capture "$BAMBOO_TEST_BIN" --dry-run reinstall --from "$staged" --yes
    assert_rc 0 "$RC" 'dry-run exits 0'
    assert_contains "$OUT" '[dry-run] would reinstall' 'prints the plan'
    assert_eq "$(current_version)" "$(bamboo_installed_version "$BAMBOO_INSTALL_DIR")" 'nothing was installed'
    assert_file_missing "$BAMBOO_INSTALL_DIR.bak" 'no rollback copy was created'
}

# --- uninstall --------------------------------------------------------------

test_uninstall_removes_only_the_cli() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    install_cli_into_sandbox
    config_init_defaults
    printf 'log line\n' >"$BAMBOO_LOG_FILE"
    workspace_create 'example.com'
    printf 'server {}\n' >"$(workspace_conf 'example.com')"

    capture "$BAMBOO_TEST_BIN" uninstall --yes
    assert_rc 0 "$RC" 'uninstall exits 0'
    assert_file_missing "$BAMBOO_BIN_DIR/bamboo-site" 'the symlink is removed'
    assert_contains "$OUT" 'will be removed in a moment' 'the program files are removed on a deferral'
    assert_dir_exists "$BAMBOO_ETC_DIR" 'configuration is kept without --purge'
    assert_file_exists "$BAMBOO_LOG_FILE" 'the log is kept without --purge'
    assert_dir_exists "$(workspace_dir 'example.com')" 'sites are kept without --sites'
    assert_contains "$OUT" 'apt-get remove --purge nginx' 'prints the package command instead of removing them'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'apt-get remove' 'never runs the package removal'

    sleep 2
    assert_dir_missing "$BAMBOO_INSTALL_DIR" 'the program files are gone shortly after'
}

test_uninstall_purge_removes_config_and_log() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    install_cli_into_sandbox
    config_init_defaults
    printf 'log line\n' >"$BAMBOO_LOG_FILE"
    workspace_create 'example.com'

    capture "$BAMBOO_TEST_BIN" uninstall --purge --yes
    assert_rc 0 "$RC" 'uninstall --purge exits 0'
    assert_dir_missing "$BAMBOO_ETC_DIR" 'configuration removed'
    assert_file_missing "$BAMBOO_LOG_FILE" 'log removed'
    assert_dir_exists "$(workspace_dir 'example.com')" 'sites still kept'
}

test_uninstall_sites_requires_an_explicit_yes() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    install_cli_into_sandbox
    workspace_create 'example.com'
    printf 'server {}\n' >"$(workspace_conf 'example.com')"

    OUT="$(BAMBOO_ASSUME_YES=0 "$BAMBOO_TEST_BIN" uninstall --sites </dev/null 2>&1)" && RC=0 || RC=$?
    assert_rc 1 "$RC" 'aborts without --yes and without a terminal'
    assert_contains "$OUT" 'No terminal available' 'explains why it aborted'
    assert_dir_exists "$(workspace_dir 'example.com')" 'nothing was deleted'
    assert_dir_exists "$BAMBOO_INSTALL_DIR" 'the CLI is still installed'
}

test_uninstall_sites_deletes_managed_domains() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    install_cli_into_sandbox
    mkdir -p "$BAMBOO_NGINX_CONFD"
    : >"$BAMBOO_NGINX_LIMITS_FILE"
    workspace_create 'example.com'
    ssl_test_fabricate_certificates 'certonly --cert-name example.com -d example.com'
    nginx_apply_site 'example.com' 'https'
    f2b_add_jail 'example.com'
    assert_file_exists "$(f2b_jail_path 'example.com')" 'setup: jail exists'
    assert_file_exists "$(ssl_live_dir 'example.com')/cert.pem" 'setup: certificate exists'

    capture "$BAMBOO_TEST_BIN" uninstall --sites --yes
    assert_rc 0 "$RC" 'uninstall --sites exits 0'
    assert_contains "$OUT" 'Deleting example.com' 'reports the site deletion'
    assert_dir_missing "$(workspace_dir 'example.com')" 'the workspace is deleted'
    assert_file_missing "$(f2b_jail_path 'example.com')" 'the jail is removed'
    assert_file_missing "$BAMBOO_NGINX_ENABLED/example.com.conf" 'the nginx link is removed'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'certbot revoke' 'the certificate is revoked'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'certbot delete --cert-name example.com' 'the certificate is deleted'
}

test_uninstall_refuses_a_directory_that_is_not_ours() {
    fresh_root
    mkdir -p "$BAMBOO_INSTALL_DIR/somewhere-else"
    capture "$BAMBOO_TEST_BIN" uninstall --yes
    assert_rc 1 "$RC" 'refuses to delete a directory without bin/bamboo-site'
    assert_contains "$OUT" 'does not look like a Bamboo-Site installation' 'explains the refusal'
    assert_dir_exists "$BAMBOO_INSTALL_DIR/somewhere-else" 'nothing was deleted'
}

test_uninstall_dry_run_changes_nothing() {
    export BAMBOO_INSTALL_ALLOW_NONROOT=1
    fresh_root
    install_cli_into_sandbox
    capture "$BAMBOO_TEST_BIN" --dry-run uninstall --yes
    assert_rc 0 "$RC" 'dry-run exits 0'
    assert_contains "$OUT" '[dry-run] nothing was removed' 'says nothing was removed'
    assert_dir_exists "$BAMBOO_INSTALL_DIR" 'the CLI is still installed'
    assert_symlink_to "$BAMBOO_BIN_DIR/bamboo-site" "$BAMBOO_INSTALL_DIR/bin/bamboo-site" 'the symlink is still there'
}
