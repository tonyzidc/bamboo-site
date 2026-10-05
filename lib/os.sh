#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — operating-system checks, package installation and shared
# service plumbing.

BAMBOO_PACKAGES='nginx certbot fail2ban ufw curl openssl dnsutils ca-certificates'

require_ubuntu() {
    # require_ubuntu [force] — dies unless the host is Ubuntu >= 22.04.
    local force="${1:-0}" id='' ver=''
    if [ "$BAMBOO_TEST_MODE" = "1" ]; then
        log_debug '[test] OS check skipped'
        return 0
    fi
    id="$(bamboo_os_release_field ID)"
    ver="$(bamboo_os_release_field VERSION_ID)"
    if [ -z "$id" ]; then
        die "Unable to read /etc/os-release. $BAMBOO_PROG_NAME targets Ubuntu 22.04 LTS or newer."
    fi
    if [ "$id" != "ubuntu" ]; then
        if [ "$force" = "1" ]; then
            log_warn "Unsupported OS '$id' — continuing because --force was given."
            return 0
        fi
        die "Unsupported OS: $id. $BAMBOO_PROG_NAME targets Ubuntu 22.04 LTS or newer (use --force to override)."
    fi
    if [ -n "$ver" ] && ! bamboo_version_ge "$ver" "22.04"; then
        if [ "$force" = "1" ]; then
            log_warn "Ubuntu $ver is older than 22.04 LTS — continuing because --force was given."
            return 0
        fi
        die "Ubuntu $ver is older than the supported 22.04 LTS (use --force to override)."
    fi
    log_ok "Ubuntu ${ver:-?} detected."
    return 0
}

bamboo_apt_update() {
    if bamboo_is_dry_run; then
        log_info '[dry-run] apt-get update'
        return 0
    fi
    log_info 'Running apt-get update ...'
    if ! bamboo_apt_get update >/dev/null 2>&1; then
        log_warn 'apt-get update failed; continuing with the existing package index.'
    fi
    return 0
}

bamboo_apt_install() {
    # Installs only the packages that are not present yet.
    local missing='' pkg
    for pkg in "$@"; do
        if ! bamboo_pkg_installed "$pkg"; then
            missing="$missing $pkg"
        fi
    done
    if [ -z "$missing" ]; then
        log_ok 'All required packages are already installed.'
        return 0
    fi
    if bamboo_is_dry_run; then
        log_info "[dry-run] apt-get install -y$missing"
        return 0
    fi
    log_info "Installing:$missing"
    # shellcheck disable=SC2086
    if ! bamboo_apt_get install -y $missing; then
        die "apt-get install failed for:$missing"
    fi
    return 0
}

bamboo_timer_enable() {
    local timer="$1"
    if bamboo_is_dry_run; then
        log_info "[dry-run] systemctl enable --now $timer"
        return 0
    fi
    if bamboo_systemctl enable --now "$timer" 2>/dev/null; then
        log_ok "$timer enabled (certificates renew automatically)."
    else
        log_warn "Could not enable $timer — check 'systemctl status $timer'."
    fi
    return 0
}

bamboo_install_renewal_hook() {
    # Every successful renewal reloads Nginx so the new certificate is served.
    local hook="$BAMBOO_LETSENCRYPT_HOOKS/10-bamboo-nginx-reload.sh"
    if [ -f "$hook" ] && grep -q 'Bamboo-Site' "$hook" 2>/dev/null; then
        log_debug "Renewal hook already installed: $hook"
        return 0
    fi
    if bamboo_is_dry_run; then
        log_info "[dry-run] would install the renewal hook $hook"
        return 0
    fi
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Installed by Bamboo-Site - reload nginx after a successful renewal.\n'
        printf 'set -euo pipefail\n'
        printf 'if command -v systemctl >/dev/null 2>&1; then\n'
        printf '    systemctl reload nginx 2>/dev/null || systemctl restart nginx\n'
        printf 'else\n'
        printf '    nginx -s reload\n'
        printf 'fi\n'
    } | atomic_write "$hook"
    bamboo_chmod 0755 "$hook" 2>/dev/null || true
    log_ok "Renewal hook installed: $hook"
    return 0
}

bamboo_cmd_version() {
    local label="$1"
    shift
    bamboo_try "$@"
    if [ "$BAMBOO_LAST_STATUS" -ne 0 ] || [ -z "$BAMBOO_LAST_OUTPUT" ]; then
        printf '  %-10s not detected\n' "$label:" >&2
        return 0
    fi
    printf '  %-10s %s\n' "$label:" "$(printf '%s' "$BAMBOO_LAST_OUTPUT" | head -n 1)" >&2
    return 0
}

bamboo_print_versions() {
    bamboo_cmd_version nginx bamboo_nginx_bin -v
    bamboo_cmd_version certbot bamboo_certbot --version
    bamboo_cmd_version fail2ban bamboo_f2b_client --version
    return 0
}

os_install_core() {
    # The body of `bamboo-site install`.
    local force="${1:-0}" skip_ufw="${2:-0}"

    log_step 'Checking the operating system'
    require_ubuntu "$force"

    log_step 'Installing server packages'
    bamboo_apt_update
    # shellcheck disable=SC2086
    bamboo_apt_install $BAMBOO_PACKAGES

    log_step 'Enabling services'
    bamboo_service_enable_now nginx
    bamboo_service_enable_now fail2ban
    bamboo_timer_enable certbot.timer
    bamboo_install_renewal_hook

    log_step 'Preparing Fail2ban'
    f2b_ensure_defaults
    f2b_ensure_filters
    f2b_reload || log_warn 'Fail2ban was not reloaded.'

    log_step 'Installing Nginx rate-limit zones'
    nginx_ensure_limits
    if bamboo_nginx_test; then
        bamboo_service_reload nginx
        if ! bamboo_is_dry_run; then
            log_ok 'Rate-limit zones active.'
        fi
    else
        die 'nginx -t failed after installing the rate-limit zones.'
    fi

    fw_configure "$skip_ufw"

    log_step 'Writing default configuration'
    config_init_defaults

    return 0
}
