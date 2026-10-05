#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site delete`

cmd_delete_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME delete <domain> [options]

Removes everything Bamboo-Site manages for <domain>:

  * disables and deletes the Nginx server block (with a syntax check first)
  * removes the per-domain Fail2ban jail and reloads Fail2ban
  * revokes and deletes the Let's Encrypt certificate
  * deletes the workspace /var/www/<domain>

Options:
  --keep-files       Keep public_html and logs, remove only the configuration.
  -h, --help         Show this help.

Global options: --yes (skip the confirmation), --dry-run

Examples:
  sudo $BAMBOO_PROG_NAME delete example.com
  sudo $BAMBOO_PROG_NAME delete example.com --keep-files --yes
EOF
}

cmd_delete() {
    local domain_raw='' keep_files=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --keep-files) keep_files=1 ;;
            -h|--help) cmd_delete_usage; return 0 ;;
            -*)
                die "delete: unknown option '$1'. See '$BAMBOO_PROG_NAME help delete'."
                ;;
            *)
                if [ -z "$domain_raw" ]; then
                    domain_raw="$1"
                else
                    die "delete: unexpected argument '$1'."
                fi
                ;;
        esac
        shift
    done

    if [ -z "$domain_raw" ]; then
        cmd_delete_usage >&2
        die 'delete: a domain name is required.'
    fi

    local domain
    domain="$(bamboo_require_domain "$domain_raw")"
    require_root
    require_workspace "$domain"

    log_step "About to delete $domain"
    log_info "workspace    $(workspace_dir "$domain")"
    log_info "nginx        disable + remove $(workspace_conf "$domain")"
    log_info "fail2ban     remove $(f2b_jail_path "$domain")"
    if ssl_cert_exists "$domain"; then
        log_info "certificate  revoke + delete $(ssl_live_dir "$domain")"
    else
        log_info 'certificate  none issued'
    fi
    if [ "$keep_files" = '1' ]; then
        log_info 'content      kept (--keep-files)'
    else
        log_info 'content      public_html and logs will be DELETED'
    fi

    if ! bamboo_confirm "Delete $domain permanently?"; then
        die 'Aborted — nothing was changed.'
    fi

    require_core_installed
    bamboo_oplog "delete $domain: started"

    log_step 'Disabling the Nginx configuration'
    nginx_remove_site "$domain"

    log_step 'Removing the Fail2ban jail'
    f2b_remove_jail "$domain"

    log_step 'Revoking the certificate'
    ssl_revoke "$domain"

    log_step 'Removing the workspace'
    workspace_remove "$domain" "$keep_files"

    printf '\n' >&2
    if bamboo_is_dry_run; then
        log_info "Dry run finished — $domain was not deleted."
        return 0
    fi
    if [ "$keep_files" = '1' ]; then
        log_ok "Summary: $domain is no longer served; files kept in $(workspace_dir "$domain")."
        log_hint "Re-add it later with: sudo $BAMBOO_PROG_NAME add $domain"
    else
        log_ok "Summary: $domain and everything it owned have been removed."
    fi
    bamboo_oplog "delete $domain: finished"
    return 0
}
