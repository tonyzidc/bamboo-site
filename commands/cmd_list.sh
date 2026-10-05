#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site list`

cmd_list_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME list [options]

Lists every domain managed by Bamboo-Site with its mode, certificate status,
Fail2ban jail, size and creation date. Works without root; jail status is
verified live only when run as root.

Options:
  --json         Print machine-readable JSON.
  -q, --quiet    Print domain names only, one per line.
  -h, --help     Show this help.

Examples:
  $BAMBOO_PROG_NAME list
  $BAMBOO_PROG_NAME list --json | jq .
  sudo $BAMBOO_PROG_NAME list
EOF
}

# Fills the LIST_* globals for one domain (kept as globals because bash 3.2
# has no way to return several values from a function).
list_collect() {
    local domain="$1"
    LIST_MODE="$(nginx_site_mode "$domain")"
    LIST_DAYS="$(ssl_cert_days_left "$domain")"
    LIST_SSL='pending'

    if ssl_cert_exists "$domain"; then
        if [ -n "$LIST_DAYS" ]; then
            if [ "$LIST_DAYS" -lt 0 ]; then
                LIST_SSL='expired'
            elif [ "$LIST_DAYS" -le 14 ]; then
                LIST_SSL="renew soon (${LIST_DAYS}d)"
            else
                LIST_SSL="valid (${LIST_DAYS}d)"
            fi
        else
            LIST_SSL='valid'
        fi
    elif [ "$LIST_MODE" = 'https' ]; then
        LIST_SSL='missing'
    fi

    if [ "$(id -u)" -eq 0 ] || [ "$BAMBOO_TEST_MODE" = '1' ]; then
        if f2b_jail_active "bamboo-$domain-scanner"; then
            LIST_JAIL='on'
        else
            LIST_JAIL='off'
        fi
    else
        if [ -f "$(f2b_jail_path "$domain")" ]; then
            LIST_JAIL='set'
        else
            LIST_JAIL='-'
        fi
    fi

    LIST_SIZE="$(bamboo_dir_size "$(workspace_dir "$domain")")"
    LIST_CREATED="$(bamboo_path_mtime "$(workspace_dir "$domain")")"
    LIST_ENABLED='no'
    if nginx_site_enabled "$domain"; then
        LIST_ENABLED='yes'
    fi
    return 0
}

list_mode_color() {
    case "$1" in
        https) printf '%s' "$C_GREEN" ;;
        http) printf '%s' "$C_YELLOW" ;;
        *) printf '%s' "$C_DIM" ;;
    esac
}

cmd_list() {
    local json=0 quiet=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=1 ;;
            -q|--quiet) quiet=1 ;;
            -h|--help) cmd_list_usage; return 0 ;;
            -*) die "list: unknown option '$1'. See '$BAMBOO_PROG_NAME help list'." ;;
            *) die "list: unexpected argument '$1'." ;;
        esac
        shift
    done

    local domains=''
    domains="$(workspace_list_domains)"

    if [ -z "$domains" ]; then
        if [ "$quiet" = '1' ]; then
            return 0
        fi
        if [ "$json" = '1' ]; then
            printf '[]\n'
            return 0
        fi
        log_warn 'No sites are managed yet.'
        log_hint "Create one with: sudo $BAMBOO_PROG_NAME add example.com you@example.com"
        return 0
    fi

    if [ "$quiet" = '1' ]; then
        printf '%s\n' "$domains"
        return 0
    fi

    local domain first=1
    if [ "$json" = '1' ]; then
        printf '[\n'
        # shellcheck disable=SC2086
        for domain in $domains; do
            list_collect "$domain"
            [ "$first" = '1' ] || printf ',\n'
            first=0
            printf '  {"domain": "%s", "mode": "%s", "enabled": %s, "ssl": "%s", "ssl_days": %s, "jail": "%s", "size": "%s", "created": "%s", "docroot": "%s"}' \
                "$domain" \
                "$LIST_MODE" \
                "$(if [ "$LIST_ENABLED" = 'yes' ]; then printf 'true'; else printf 'false'; fi)" \
                "$LIST_SSL" \
                "${LIST_DAYS:-null}" \
                "$LIST_JAIL" \
                "$LIST_SIZE" \
                "$LIST_CREATED" \
                "$(workspace_public "$domain")"
        done
        printf '\n]\n'
        return 0
    fi

    local rule=''
    rule="$(printf '%*s' 88 '' | tr ' ' '-')"
    printf '%-34s %-9s %-20s %-6s %-7s %s\n' 'DOMAIN' 'MODE' 'SSL' 'JAIL' 'SIZE' 'CREATED'
    printf '%s\n' "$rule"
    # shellcheck disable=SC2086
    for domain in $domains; do
        list_collect "$domain"
        printf '%-34s %s%-9s%s %-20s %-6s %-7s %s\n' \
            "$domain" \
            "$(list_mode_color "$LIST_MODE")" "$LIST_MODE" "$C_RESET" \
            "$LIST_SSL" \
            "$LIST_JAIL" \
            "$LIST_SIZE" \
            "$LIST_CREATED"
    done
    printf '\n'
    printf 'MODE  https = served over TLS   http = HTTP only, SSL pending   disabled = not in sites-enabled\n'
    printf 'JAIL  on = Fail2ban jail active   set = jail file present (run as root for live status)\n'
    return 0
}
