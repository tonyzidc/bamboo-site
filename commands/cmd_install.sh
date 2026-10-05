#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site install`

cmd_install_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME install [options]

Installs and configures everything the server needs: Nginx, Certbot, Fail2ban,
UFW, the shared rate-limit zones, the certificate-renewal hook and the default
config file. Safe to re-run.

Options:
  --email <address>  Store a default Let's Encrypt contact email.
  --no-ufw           Install packages but leave the firewall untouched.
  -h, --help         Show this help.

Global options:
  --dry-run          Show what would change, touch nothing.
  --force            Continue on an unsupported OS or Ubuntu release.
  -y, --yes          Never prompt (also enables UFW without asking).

Examples:
  sudo $BAMBOO_PROG_NAME install
  sudo $BAMBOO_PROG_NAME install --email admin@example.com --yes
EOF
}

cmd_install() {
    local skip_ufw=0 email=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --email)
                [ $# -ge 2 ] || die 'install: --email requires a value.'
                email="$2"
                shift
                ;;
            --no-ufw) skip_ufw=1 ;;
            -h|--help) cmd_install_usage; return 0 ;;
            *) die "install: unknown option '$1'. See '$BAMBOO_PROG_NAME help install'." ;;
        esac
        shift
    done

    require_root
    bamboo_oplog 'install: started'

    os_install_core "$BAMBOO_FORCE" "$skip_ufw"

    # Re-running the installer also repairs the jails of sites that already
    # exist (missing, outdated, or rejected earlier).
    f2b_reconcile_all

    if [ -n "$email" ]; then
        config_set BAMBOO_DEFAULT_EMAIL "$email"
        log_ok "Default Let's Encrypt email stored: $email"
    fi

    log_step 'Installed components'
    bamboo_print_versions
    printf '\n' >&2
    if bamboo_is_dry_run; then
        log_info 'Dry run finished — nothing was installed or changed.'
        return 0
    fi
    log_ok 'Core installation complete.'
    log_hint "Next: sudo $BAMBOO_PROG_NAME add example.com you@example.com"
    printf '  Documentation: %s\n' "$BAMBOO_REPO_URL" >&2
    bamboo_oplog 'install: finished'
    return 0
}
