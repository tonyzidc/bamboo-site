#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — per-domain Fail2ban jails.
#
# Adding a domain writes /etc/fail2ban/jail.d/<domain>.conf with four jails that
# read that domain's own logs:
#
#   bamboo-<domain>-scanner    403/404 scanning floods      (access.log)
#   bamboo-<domain>-http-auth  repeated auth failures       (error.log)
#   bamboo-<domain>-limit      nginx rate-limit rejections  (error.log)
#   bamboo-<domain>-badbots    known malicious user agents  (access.log)
#
# Every filter is bundled with the tool (templates/fail2ban-filter-*.conf.tpl)
# and installed as filter.d/bamboo-*.conf. The jails never reference filters
# shipped by the fail2ban package: Ubuntu 24.04 dropped nginx-badbots, and a
# missing filter makes the whole configuration unloadable.
#
# Deleting a domain removes its jail file and reloads Fail2ban.

# Filters shipped with the tool; the jail template may only reference these.
F2B_BUNDLED_FILTERS='bamboo-scanner bamboo-http-auth bamboo-limit-req bamboo-badbots'

f2b_jail_path()     { printf '%s/%s.conf' "$BAMBOO_F2B_JAILD" "$1"; }
f2b_filter_path()   { printf '%s/%s.conf' "$BAMBOO_F2B_FILTERD" "$1"; }
f2b_defaults_path() { printf '%s/00-bamboo-defaults.conf' "$BAMBOO_F2B_JAILD"; }

f2b_missing_filters() {
    # Prints the bundled filters that are not installed yet (empty when ready).
    local name missing=''
    for name in $F2B_BUNDLED_FILTERS; do
        if [ ! -f "$(f2b_filter_path "$name")" ]; then
            missing="$missing $name"
        fi
    done
    printf '%s' "$missing"
}

f2b_jail_names() {
    # Prints one jail name per line for the given domain.
    local domain="$1"
    printf '%s\n' \
        "bamboo-$domain-scanner" \
        "bamboo-$domain-http-auth" \
        "bamboo-$domain-limit" \
        "bamboo-$domain-badbots"
}

f2b_ignore_ip() {
    local ips="127.0.0.1/8 ::1"
    if [ -n "$BAMBOO_F2B_IGNOREIP" ]; then
        ips="$ips $BAMBOO_F2B_IGNOREIP"
    fi
    printf '%s' "$ips"
}

f2b_ensure_defaults() {
    local tpl="$BAMBOO_ROOT/templates/fail2ban-defaults.conf.tpl" dest rendered
    dest="$(f2b_defaults_path)"
    [ -f "$tpl" ] || die "Missing template: $tpl"

    if bamboo_is_dry_run; then
        log_info "[dry-run] would write the Fail2ban defaults $dest"
        return 0
    fi

    # Render first, then compare: the template contains a token, so comparing
    # against it directly would rewrite the file on every run.
    bamboo_ensure_tmpdir
    rendered="$(mktemp "$BAMBOO_TMPDIR/f2b-defaults.XXXXXX")"
    render_template "$tpl" "$rendered" "IGNOREIP=$(f2b_ignore_ip)"
    if [ -f "$dest" ] && cmp -s "$rendered" "$dest"; then
        rm -f "$rendered"
        log_debug 'Fail2ban defaults already installed.'
        return 0
    fi
    mkdir -p "$(dirname "$dest")" || die "Unable to create $(dirname "$dest")"
    if ! mv -f "$rendered" "$dest"; then
        rm -f "$rendered"
        die "Unable to write $dest"
    fi
    bamboo_chmod 0644 "$dest" 2>/dev/null || true
    log_debug "Fail2ban defaults written: $dest"
    return 0
}

f2b_ensure_filters() {
    local name tpl dest
    for name in $F2B_BUNDLED_FILTERS; do
        tpl="$BAMBOO_ROOT/templates/fail2ban-filter-$name.conf.tpl"
        dest="$(f2b_filter_path "$name")"
        [ -f "$tpl" ] || die "Missing template: $tpl"
        if [ -f "$dest" ] && cmp -s "$tpl" "$dest" 2>/dev/null; then
            log_debug "Fail2ban filter already installed: $name"
            continue
        fi
        render_template "$tpl" "$dest"
        if ! bamboo_is_dry_run; then
            log_ok "Fail2ban filter installed: $dest"
        fi
    done
    return 0
}

f2b_reload() {
    # f2b_reload [jail-file-just-written]
    #
    # Validates the configuration, then asks the daemon to re-read it. If the
    # test fails, the candidate jail file is moved aside, because a jail that
    # fail2ban cannot parse would also stop the daemon from starting after a
    # reboot. Fail2ban always ends up with a loadable configuration.
    local candidate="${1:-}"
    if bamboo_is_dry_run; then
        log_info '[dry-run] would validate and reload Fail2ban'
        return 0
    fi
    if [ "$BAMBOO_TEST_MODE" != "1" ] && ! bamboo_need_cmd fail2ban-client; then
        log_warn 'fail2ban-client not found; skipping the Fail2ban reload.'
        return 0
    fi
    bamboo_try bamboo_f2b_client -t
    if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
        log_warn 'The Fail2ban configuration test failed:'
        printf '%s\n' "$BAMBOO_LAST_OUTPUT" | while IFS= read -r line; do
            printf '  %s%s%s\n' "$C_DIM" "$line" "$C_RESET" >&2
        done
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            log_warn "Disabling the rejected jail so Fail2ban stays loadable: $candidate"
            mv -f "$candidate" "$candidate.rejected" 2>/dev/null || rm -f "$candidate"
            bamboo_try bamboo_f2b_client -t
            if [ "$BAMBOO_LAST_STATUS" -eq 0 ]; then
                log_warn "Jail rejected and disabled (kept as $candidate.rejected); Fail2ban was reloaded with the rest."
                if ! bamboo_service_reload fail2ban; then
                    log_warn 'Could not reload Fail2ban.'
                fi
                return 1
            fi
            log_error 'Fail2ban is still unhappy without that jail — there is a pre-existing configuration problem.'
        fi
        log_warn 'Fail2ban was not reloaded.'
        return 1
    fi
    if ! bamboo_service_reload fail2ban; then
        if ! bamboo_service_restart fail2ban; then
            log_warn 'Could not reload or restart Fail2ban.'
            return 1
        fi
    fi
    log_ok 'Fail2ban reloaded.'
    return 0
}

f2b_add_jail() {
    local domain="$1" tpl="$BAMBOO_ROOT/templates/fail2ban-jail.conf.tpl" dest missing='' rendered=''
    dest="$(f2b_jail_path "$domain")"
    [ -f "$tpl" ] || die "Missing template: $tpl"

    f2b_ensure_defaults
    f2b_ensure_filters

    missing="$(f2b_missing_filters)"
    if [ -n "$missing" ]; then
        log_error "Refusing to write $dest — bundled Fail2ban filter(s) missing:$missing"
        return 1
    fi

    if bamboo_is_dry_run; then
        log_info "[dry-run] would write the Fail2ban jail $dest"
        return 0
    fi

    # Render first and compare, so an existing jail is refreshed when the
    # template changed (for example after an upgrade) instead of going stale.
    bamboo_ensure_tmpdir
    rendered="$(mktemp "$BAMBOO_TMPDIR/jail.XXXXXX")"
    render_template "$tpl" "$rendered" \
        "DOMAIN=$domain" \
        "LOG_DIR=$(workspace_logs "$domain")"

    if [ -f "$dest" ] && cmp -s "$rendered" "$dest"; then
        rm -f "$rendered"
        log_debug "Fail2ban jail already up to date: $dest"
        if ! f2b_reload "$dest"; then
            log_warn 'Fail2ban was not reloaded.'
            return 1
        fi
        return 0
    fi

    mkdir -p "$(dirname "$dest")" || die "Unable to create $(dirname "$dest")"
    if ! mv -f "$rendered" "$dest"; then
        rm -f "$rendered"
        die "Unable to write $dest"
    fi
    bamboo_chmod 0644 "$dest" 2>/dev/null || true
    log_ok "Fail2ban jail written: $dest"
    if ! f2b_reload "$dest"; then
        log_warn 'Fail2ban was not reloaded.'
        return 1
    fi
    return 0
}

f2b_remove_jail() {
    local domain="$1" dest
    dest="$(f2b_jail_path "$domain")"
    if [ ! -f "$dest" ]; then
        log_debug "No Fail2ban jail to remove for $domain."
        return 0
    fi
    bamboo_run rm -f "$dest"
    if bamboo_is_dry_run; then
        return 0
    fi
    log_ok "Fail2ban jail removed: $dest"
    f2b_reload || log_warn 'Fail2ban was not reloaded.'
    return 0
}

f2b_reconcile_all() {
    # Re-applies the per-domain jails for every managed site. Used by `install`
    # so re-running the installer repairs missing or outdated jails.
    local domains='' domain
    domains="$(workspace_list_domains)"
    if [ -z "$domains" ]; then
        return 0
    fi
    log_step 'Reconciling the Fail2ban jails of managed sites'
    # shellcheck disable=SC2086
    for domain in $domains; do
        if ! f2b_add_jail "$domain"; then
            log_warn "The Fail2ban jail for $domain is not active."
        fi
    done
    return 0
}

f2b_jail_active() {
    local jail="$1"
    bamboo_try bamboo_f2b_client status "$jail"
    [ "$BAMBOO_LAST_STATUS" -eq 0 ]
}

f2b_verify_domain() {
    local domain="$1" jail
    if bamboo_is_dry_run; then
        return 0
    fi
    f2b_jail_names "$domain" | while IFS= read -r jail; do
        if f2b_jail_active "$jail"; then
            log_ok "Fail2ban jail active: $jail"
        else
            log_warn "Fail2ban jail not active yet: $jail"
        fi
    done
    return 0
}
