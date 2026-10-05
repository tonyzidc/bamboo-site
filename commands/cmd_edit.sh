#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site edit`

cmd_edit_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME edit <domain>

Opens the domain's Nginx server block (the file inside the workspace) in your
editor. On save the configuration is validated with 'nginx -t':

  * valid    -> Nginx reloads and the change goes live
  * invalid  -> Nginx is NOT reloaded (it keeps serving the old config), the
                error is shown and a backup is available next to the file

The editor is chosen from \$BAMBOO_EDITOR, \$EDITOR, \$VISUAL, then nano or vim.

Note: 'add' and 'ssl' regenerate this file from the template. A copy of the
previous version is always kept as <domain>.conf.bak.

Examples:
  sudo $BAMBOO_PROG_NAME edit example.com
  sudo BAMBOO_EDITOR=vim $BAMBOO_PROG_NAME edit example.com
EOF
}

edit_pick_editor() {
    local candidate
    if [ -n "$BAMBOO_EDITOR" ]; then
        printf '%s' "$BAMBOO_EDITOR"
        return 0
    fi
    for candidate in "${EDITOR:-}" "${VISUAL:-}" nano vim vi; do
        [ -n "$candidate" ] || continue
        if bamboo_need_cmd "${candidate%% *}"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf ''
    return 0
}

cmd_edit() {
    local domain_raw=''

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) cmd_edit_usage; return 0 ;;
            -*)
                die "edit: unknown option '$1'. See '$BAMBOO_PROG_NAME help edit'."
                ;;
            *)
                if [ -z "$domain_raw" ]; then
                    domain_raw="$1"
                else
                    die "edit: unexpected argument '$1'."
                fi
                ;;
        esac
        shift
    done

    if [ -z "$domain_raw" ]; then
        cmd_edit_usage >&2
        die 'edit: a domain name is required.'
    fi

    local domain conf editor before after
    domain="$(bamboo_require_domain "$domain_raw")"
    require_root
    require_workspace "$domain"
    require_core_installed

    conf="$(workspace_conf "$domain")"
    if [ ! -f "$conf" ]; then
        die "No Nginx configuration found at $conf. Re-create it with: sudo $BAMBOO_PROG_NAME ssl $domain"
    fi
    # Interactive by default; an explicitly configured BAMBOO_EDITOR makes it
    # scriptable (the result is still validated with nginx -t before any reload).
    if [ -z "$BAMBOO_EDITOR" ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
        die 'edit needs an interactive terminal, or BAMBOO_EDITOR set to an editor/script for automation.'
    fi

    editor="$(edit_pick_editor)"
    if [ -z "$editor" ]; then
        die 'No text editor found. Install nano or vim, or set the EDITOR variable.'
    fi

    if bamboo_is_dry_run; then
        log_info "[dry-run] would open $conf with '$editor' and validate it afterwards"
        return 0
    fi

    cp -p "$conf" "$conf.bak" || die "Unable to back up $conf"
    before="$(cksum <"$conf")"

    log_info "Opening $conf with '$editor' (backup: $conf.bak)"
    # The editor may legitimately contain arguments, hence the unquoted call.
    # shellcheck disable=SC2086
    if ! $editor "$conf"; then
        die "The editor exited with an error; $conf was left unchanged."
    fi

    after="$(cksum <"$conf")"
    if [ "$before" = "$after" ]; then
        log_info 'No changes were made.'
        return 0
    fi

    log_step 'Validating the edited configuration'
    if ! bamboo_nginx_test; then
        printf '\n' >&2
        log_error 'nginx -t rejected the edited configuration — Nginx was NOT reloaded.'
        log_error 'The running server is unaffected and keeps serving the previous config.'
        log_hint "Re-edit it with: sudo $BAMBOO_PROG_NAME edit $domain"
        log_hint "Or restore the backup with: sudo cp '$conf.bak' '$conf' && sudo systemctl reload nginx"
        exit 1
    fi

    bamboo_service_reload nginx
    log_ok 'Configuration applied — Nginx reloaded.'
    log_warn "Heads-up: 'add' and 'ssl' regenerate this file from the template."
    log_warn "Your hand-edits are preserved in $conf.bak and $conf.pre-https when that happens."
    bamboo_oplog "edit $domain: applied"
    return 0
}
