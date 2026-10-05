#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — the isolated workspace at /var/www/<domain>.
#
#   /var/www/<domain>/
#    |-- public_html/   document root, owned by the web user
#    |-- logs/          per-domain access.log and error.log (watched by Fail2ban)
#    |-- nginx/         the real server block, root-owned
#    `-- letsencrypt/   symlink to /etc/letsencrypt/live/<domain> (once issued)

workspace_dir()    { printf '%s/%s' "$BAMBOO_WWW_DIR" "$1"; }
workspace_public() { printf '%s/public_html' "$(workspace_dir "$1")"; }
workspace_logs()   { printf '%s/logs' "$(workspace_dir "$1")"; }
workspace_nginx()  { printf '%s/nginx' "$(workspace_dir "$1")"; }
workspace_conf()   { printf '%s/%s.conf' "$(workspace_nginx "$1")" "$1"; }
workspace_le()     { printf '%s/letsencrypt' "$(workspace_dir "$1")"; }

workspace_exists() { [ -d "$(workspace_dir "$1")" ]; }

assert_workspace_path() {
    # Guards every recursive delete: the path must be exactly
    # <BAMBOO_WWW_DIR>/<valid-domain> — nothing shorter, nothing elsewhere.
    local path="$1" domain="$2" expected
    [ -n "$path" ] || die 'Internal error: refusing to operate on an empty path.'
    [ -n "$domain" ] || die 'Internal error: refusing to operate without a domain name.'
    if ! is_valid_domain "$domain"; then
        die "Internal error: refusing to operate on the invalid domain '$domain'."
    fi
    expected="$BAMBOO_WWW_DIR/$domain"
    if [ "$path" != "$expected" ]; then
        die "Refusing to operate on the unexpected path '$path' (expected '$expected')."
    fi
    case "$path" in
        /|/var|/var/www|"$BAMBOO_WWW_DIR") die "Refusing to operate on the shared directory '$path'." ;;
    esac
    return 0
}

workspace_create() {
    local domain="$1" dir log
    dir="$(workspace_dir "$domain")"
    assert_workspace_path "$dir" "$domain"

    if bamboo_is_dry_run; then
        log_info "[dry-run] would create the workspace $dir (public_html, logs, nginx)"
        return 0
    fi

    mkdir -p "$dir/public_html" "$dir/logs" "$dir/nginx" \
        || die "Unable to create the workspace at $dir"

    # Content and logs belong to the web user; the Nginx config stays root-only.
    bamboo_own "$BAMBOO_WEB_USER:$BAMBOO_WEB_GROUP" "$dir" "$dir/public_html" 2>/dev/null \
        || log_warn "Could not set ownership to $BAMBOO_WEB_USER:$BAMBOO_WEB_GROUP on $dir/public_html"
    bamboo_own "$BAMBOO_WEB_USER:$BAMBOO_LOG_GROUP" "$dir/logs" 2>/dev/null \
        || log_warn "Could not set ownership on $dir/logs"
    bamboo_chmod 0755 "$dir" "$dir/public_html" "$dir/nginx" 2>/dev/null || true
    bamboo_chmod 0750 "$dir/logs" 2>/dev/null || true

    if [ ! -f "$dir/public_html/index.html" ]; then
        render_template "$BAMBOO_ROOT/templates/index.html.tpl" "$dir/public_html/index.html" \
            "DOMAIN=$domain"
        bamboo_chmod 0644 "$dir/public_html/index.html" 2>/dev/null || true
        bamboo_own "$BAMBOO_WEB_USER:$BAMBOO_WEB_GROUP" "$dir/public_html/index.html" 2>/dev/null || true
    fi

    # Nginx writes here and Fail2ban reads here, so the files must exist with
    # the right ownership before the first request arrives.
    for log in access.log error.log; do
        if [ ! -f "$dir/logs/$log" ]; then
            : >"$dir/logs/$log" || die "Unable to create $dir/logs/$log"
            bamboo_own "$BAMBOO_WEB_USER:$BAMBOO_LOG_GROUP" "$dir/logs/$log" 2>/dev/null || true
            bamboo_chmod 0640 "$dir/logs/$log" 2>/dev/null || true
        fi
    done
    return 0
}

workspace_remove() {
    # workspace_remove <domain> [keep_files]
    local domain="$1" keep="${2:-0}" dir
    dir="$(workspace_dir "$domain")"
    assert_workspace_path "$dir" "$domain"
    [ -d "$dir" ] || return 0

    if [ "$keep" = "1" ]; then
        log_info "Keeping site content in $dir (--keep-files)."
        bamboo_run rm -f "$(workspace_le "$domain")" 2>/dev/null || true
        bamboo_run rm -f "$(workspace_conf "$domain")" 2>/dev/null || true
        bamboo_run rm -f "$dir/nginx/$domain.conf".bak* 2>/dev/null || true
        return 0
    fi

    bamboo_run rm -rf "$dir"
    return 0
}

workspace_print_tree() {
    local domain="$1" ssl_note
    if ssl_cert_exists "$domain"; then
        ssl_note="live certificate -> $BAMBOO_LETSENCRYPT_LIVE/$domain"
    else
        ssl_note="not issued yet (run: sudo $BAMBOO_PROG_NAME ssl $domain)"
    fi
    printf '\n  %s%s/%s/%s\n' "$C_BOLD" "$BAMBOO_WWW_DIR" "$domain" "$C_RESET" >&2
    printf '   |-- public_html/    document root (put your site here)\n' >&2
    printf '   |-- logs/           access.log + error.log (watched by Fail2ban)\n' >&2
    printf '   |-- nginx/          %s.conf (the server block)\n' "$domain" >&2
    printf '   `-- letsencrypt/    %s\n\n' "$ssl_note" >&2
    return 0
}

workspace_list_domains() {
    # Prints every managed domain, sorted. A domain counts as managed when its
    # workspace holds nginx/<domain>.conf.
    local entry domain
    [ -d "$BAMBOO_WWW_DIR" ] || return 0
    for entry in "$BAMBOO_WWW_DIR"/*; do
        [ -d "$entry" ] || continue
        domain="${entry##*/}"
        is_valid_domain "$domain" || continue
        [ -f "$entry/nginx/$domain.conf" ] || continue
        printf '%s\n' "$domain"
    done | sort
    return 0
}
