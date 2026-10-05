#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site uninstall`
#
# Removes the CLI itself. Sites, certificates and the server packages are kept
# unless you ask for them explicitly:
#
#   uninstall                 CLI only (symlink + program files)
#   uninstall --purge         also /etc/bamboo-site and the operations log
#   uninstall --sites         also every managed site (needs --yes)
#
# Packages are never removed; the exact apt command is printed instead.

cmd_uninstall_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME uninstall [options]

Removes the Bamboo-Site CLI from this server:

  * the symlink in $BAMBOO_BIN_DIR
  * the program files in $BAMBOO_INSTALL_DIR

Sites, certificates, services and /etc/bamboo-site are left untouched by
default. Nothing here is applied to packages — nginx, certbot, fail2ban and ufw
keep working; the command prints the apt line if you want them gone too.

Options:
  --purge        Also remove the configuration and the operations log.
  --sites        Also delete every managed site, including its certificate.
                 Requires --yes (or an interactive confirmation).
  -h, --help     Show this help.

Global options: --dry-run, --yes

Examples:
  sudo $BAMBOO_PROG_NAME uninstall
  sudo $BAMBOO_PROG_NAME uninstall --purge
  sudo $BAMBOO_PROG_NAME uninstall --purge --sites --yes
EOF
}

uninstall_site() {
    # Same pipeline as `delete`, without the interactive prompt.
    local domain="$1"
    nginx_remove_site "$domain" || log_warn "nginx cleanup failed for $domain."
    f2b_remove_jail "$domain" || log_warn "Fail2ban cleanup failed for $domain."
    ssl_revoke "$domain" || log_warn "Certificate cleanup failed for $domain."
    workspace_remove "$domain" 0 || log_warn "Could not remove $(workspace_dir "$domain")."
    return 0
}

cmd_uninstall() {
    local purge=0 sites=0 domains='' domain='' link='' target='' count=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --purge) purge=1 ;;
            --sites) sites=1 ;;
            -h|--help) cmd_uninstall_usage; return 0 ;;
            *) die "uninstall: unknown option '$1'. See '$BAMBOO_PROG_NAME help uninstall'." ;;
        esac
        shift
    done

    require_root
    bamboo_assert_safe_install_dir "$BAMBOO_INSTALL_DIR"

    link="$BAMBOO_BIN_DIR/bamboo-site"
    domains="$(workspace_list_domains)"
    if [ -n "$domains" ]; then
        count="$(printf '%s' "$domains" | grep -c .)"
    fi

    log_step 'About to remove the Bamboo-Site CLI'
    log_info "program files  $BAMBOO_INSTALL_DIR"
    log_info "symlink        $link"
    if [ "$purge" = '1' ]; then
        log_info "configuration  $BAMBOO_ETC_DIR and $BAMBOO_LOG_FILE will be removed"
    else
        log_info "configuration  $BAMBOO_ETC_DIR is kept (use --purge to remove it)"
    fi
    if [ "$sites" = '1' ]; then
        if [ "$count" -eq 0 ]; then
            log_info 'managed sites  none'
        else
            log_warn "managed sites  $count will be DELETED, including their certificates:"
            printf '%s\n' "$domains" | while IFS= read -r domain; do
                [ -n "$domain" ] || continue
                log_info "               - $domain"
            done
        fi
    else
        log_info "managed sites  $count kept (use --sites to delete them)"
    fi

    # Never delete something that is not ours.
    if [ -d "$BAMBOO_INSTALL_DIR" ] && [ ! -e "$BAMBOO_INSTALL_DIR/bin/bamboo-site" ]; then
        die "$BAMBOO_INSTALL_DIR does not look like a Bamboo-Site installation — refusing to delete it."
    fi

    if ! bamboo_confirm 'Remove the Bamboo-Site CLI from this server?'; then
        die 'Aborted — nothing was changed.'
    fi
    if [ "$sites" = '1' ] && [ "$count" -gt 0 ]; then
        if ! bamboo_confirm "Permanently DELETE $count managed site(s) and their certificates?"; then
            die 'Aborted — nothing was changed.'
        fi
    fi

    if bamboo_is_dry_run; then
        printf '\n' >&2
        log_info '[dry-run] nothing was removed.'
        return 0
    fi

    bamboo_oplog 'uninstall: started'

    if [ "$sites" = '1' ] && [ "$count" -gt 0 ]; then
        printf '%s\n' "$domains" | while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            log_step "Deleting $domain"
            uninstall_site "$domain"
        done
    fi

    if [ "$purge" = '1' ]; then
        log_step 'Removing the configuration'
        if [ -d "$BAMBOO_ETC_DIR" ]; then
            rm -rf "$BAMBOO_ETC_DIR" && log_ok "Removed $BAMBOO_ETC_DIR"
        fi
        if [ -f "$BAMBOO_LOG_FILE" ]; then
            rm -f "$BAMBOO_LOG_FILE" && log_ok "Removed $BAMBOO_LOG_FILE"
        fi
        # Stop writing to it: the final op-log line would recreate the file the
        # operator just asked us to delete.
        BAMBOO_LOG_FILE=''
    fi

    if [ -L "$link" ]; then
        target="$(readlink "$link")"
        case "$target" in
            "$BAMBOO_INSTALL_DIR"/*)
                rm -f "$link" && log_ok "Removed $link"
                ;;
            *)
                log_warn "Not removing $link: it points at $target."
                ;;
        esac
    fi

    log_step 'Packages were left installed'
    log_info 'This command never removes packages. If you really want them gone:'
    log_hint 'sudo apt-get remove --purge nginx certbot fail2ban ufw && sudo apt-get autoremove --purge'
    log_warn 'Removing packages affects anything else on this server that uses nginx or certbot.'

    if [ -d "$BAMBOO_INSTALL_DIR" ]; then
        if bamboo_schedule_tree_removal "$BAMBOO_INSTALL_DIR"; then
            log_ok 'The program files will be removed in a moment (deferred so this copy can finish).'
        else
            log_warn "Remove them manually with: sudo rm -rf $BAMBOO_INSTALL_DIR"
        fi
    fi

    bamboo_oplog 'uninstall: finished'
    printf '\n' >&2
    log_ok 'Uninstall complete.'
    return 0
}
