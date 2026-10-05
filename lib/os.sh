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

apt_upgrade_count() {
    # How many packages apt would upgrade right now (0 when up to date).
    local out=''
    out="$(bamboo_apt_get -s upgrade 2>/dev/null | awk '/^Inst /{ n++ } END { print n + 0 }')" || out='0'
    case "$out" in
        ''|*[!0-9]*) out='0' ;;
    esac
    printf '%s' "$out"
    return 0
}

os_upgrade() {
    # os_upgrade <auto|upgrade|full|no>
    #
    # Upgrades installed packages before anything else is installed. Deliberately
    # conservative: `apt-get upgrade` never removes packages, dpkg keeps the
    # maintainer's config files (--force-confold) and needrestart is told to only
    # list services (NEEDRESTART_MODE=l, set in the apt wrapper) so nothing is
    # restarted behind the operator's back. The tool never reboots.
    local mode="${1:-auto}" count='' kernel_before='' kernel_after='' free_mb=''

    log_step 'Upgrading the operating system'
    case "$mode" in
        no|off|none)
            log_info 'Skipped (BAMBOO_OS_UPGRADE=no or --no-upgrade).'
            return 0
            ;;
        full|dist) mode='full-upgrade' ;;
        auto|yes|on|'') mode='upgrade' ;;
        *)
            log_warn "Unrecognised upgrade mode '$mode'; using 'upgrade'."
            mode='upgrade'
            ;;
    esac

    free_mb="$(bamboo_disk_free_mb /)"
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 250 ]; then
        log_warn "Only ${free_mb}MB free on /; skipping the OS upgrade."
        log_hint 'Free some space and re-run: sudo bamboo-site install'
        return 0
    fi

    count="$(apt_upgrade_count)"
    if [ "$count" = '0' ]; then
        log_ok 'The operating system is already up to date.'
        return 0
    fi
    if bamboo_is_dry_run; then
        log_info "[dry-run] would run: apt-get -y $mode ($count package(s) upgradable)"
        return 0
    fi

    kernel_before="$(uname -r)"
    log_info "Upgrading $count package(s) with apt-get -y $mode (this can take a few minutes) ..."
    if ! bamboo_apt_get -y -o Dpkg::Options::=--force-confold "$mode"; then
        log_warn 'apt-get failed; continuing with the existing package versions.'
        log_hint 'Inspect with: sudo apt-get -f install && sudo apt-get upgrade'
        return 0
    fi
    kernel_after="$(uname -r)"
    log_ok "Operating system upgraded ($count package(s))."
    if [ "$kernel_before" != "$kernel_after" ]; then
        log_info "A newer kernel is installed; it takes effect after the next reboot (this tool never reboots)."
    fi
    return 0
}

report_reboot_status() {
    # Called at the end of install: package work may have installed a new kernel.
    if ! bamboo_reboot_required; then
        return 0
    fi
    local pkgs=''
    pkgs="$(bamboo_reboot_required_pkgs)"
    log_warn 'A reboot is required to finish applying updates.'
    if [ -n "$pkgs" ]; then
        log_info "Waiting on: $pkgs"
    fi
    log_hint 'The tool never reboots for you — schedule it yourself, e.g.: sudo reboot'
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

    swap_ensure
    os_upgrade "$BAMBOO_OS_UPGRADE"

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
