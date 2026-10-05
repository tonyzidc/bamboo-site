#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — top-level usage and `bamboo-site help [command]`

bamboo_print_usage() {
    cat <<EOF
$BAMBOO_PROG_NAME v$BAMBOO_VERSION — automated Nginx & SSL manager for Ubuntu

Usage: $BAMBOO_PROG_NAME <command> [options]

Commands:
  install                 Install server dependencies (Nginx, Certbot, Fail2ban, UFW)
  add <domain> [email]    Create a site: workspace, Nginx, Fail2ban jail, SSL
  ssl <domain>            Issue/re-issue SSL and switch the site to HTTPS
  delete <domain>         Remove a site and everything it owns
  edit <domain>           Edit the site's Nginx config (validated on save)
  renew [domain]          Renew certificates and finish pending HTTPS setups
  list                    List managed sites and their SSL status
  status                  Health report for the whole stack (exit 1 on problems)
  reinstall               Reinstall/upgrade the CLI (with --rollback)
  uninstall               Remove the CLI (--purge, --sites)
  version                 Print the version
  help [command]          Show help for a command

Global options:
  --dry-run         Show what would change, touch nothing
  -y, --yes         Never prompt (required in scripts)
  --force           Override OS checks and re-issue certificates
  -v, --verbose     Verbose/diagnostic output
  --no-color        Disable colours
  -V, --version     Print the version
  -h, --help        Show this help

Examples:
  sudo $BAMBOO_PROG_NAME install
  sudo $BAMBOO_PROG_NAME add example.com you@example.com --www
  sudo $BAMBOO_PROG_NAME ssl example.com
  $BAMBOO_PROG_NAME list

Documentation: $BAMBOO_REPO_URL
EOF
}

cmd_help() {
    local topic="${1:-}"
    case "$topic" in
        '') bamboo_print_usage ;;
        install) cmd_install_usage ;;
        add) cmd_add_usage ;;
        ssl) cmd_ssl_usage ;;
        delete) cmd_delete_usage ;;
        edit) cmd_edit_usage ;;
        renew) cmd_renew_usage ;;
        list) cmd_list_usage ;;
        status) cmd_status_usage ;;
        reinstall) cmd_reinstall_usage ;;
        uninstall) cmd_uninstall_usage ;;
        version) printf 'Usage: %s version\n\nPrints the installed version.\n' "$BAMBOO_PROG_NAME" ;;
        help) printf 'Usage: %s help [command]\n\nShows the general help, or detailed help for one command.\n' "$BAMBOO_PROG_NAME" ;;
        *)
            log_error "No help available for '$topic'."
            bamboo_print_usage >&2
            return 1
            ;;
    esac
    return 0
}
