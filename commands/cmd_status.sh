#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site status`
#
# Read-only health report for the whole stack. Works without root but degrades:
# checks that need root (UFW rules, Fail2ban jails) are reported as unknown
# instead of failing.
#
# Exit code is part of the contract: 0 = no problems, 1 = at least one problem.
# Warnings keep the exit code at 0 unless --strict is given, which makes this
# useful in monitoring:  sudo bamboo-site status --quiet

cmd_status_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME status [options]

Read-only health report: OS, resources, services, nginx, firewall, Fail2ban
jails, certificates and the managed sites.

Exit code: 0 when no problems were found, 1 when there is at least one problem.
Warnings alone keep exit code 0 unless --strict is used.

Options:
  --json         Machine-readable output.
  --quiet        Print only warnings and problems (ideal for cron/monitoring).
  --strict       Treat warnings as problems (exit 1).
  -h, --help     Show this help.

Examples:
  sudo $BAMBOO_PROG_NAME status
  $BAMBOO_PROG_NAME status --json
  sudo $BAMBOO_PROG_NAME status --quiet || echo "attention needed"
EOF
}

STATUS_OK=0
STATUS_WARN=0
STATUS_PROBLEM=0
STATUS_ALL=''
STATUS_SITES=''
STATUS_MODE='normal'

status_check() {
    # status_check <ok|warn|problem> <id> <message>
    local level="$1" id="$2" msg="$3" line=''
    case "$level" in
        ok) STATUS_OK=$((STATUS_OK + 1)) ;;
        warn) STATUS_WARN=$((STATUS_WARN + 1)) ;;
        problem) STATUS_PROBLEM=$((STATUS_PROBLEM + 1)) ;;
    esac
    line="$(printf '%s\t%s\t%s' "$level" "$id" "$msg")"
    STATUS_ALL="$STATUS_ALL$line"$'\n'

    if [ "$STATUS_MODE" = 'quiet' ]; then
        if [ "$level" != 'ok' ]; then
            printf '%s %s: %s\n' "$level" "$id" "$msg"
        fi
        return 0
    fi
    if [ "$STATUS_MODE" = 'json' ]; then
        return 0
    fi
    case "$level" in
        ok) log_ok "$msg" ;;
        warn) log_warn "$msg" ;;
        problem) log_error "$msg" ;;
    esac
    return 0
}

# --- individual checks ------------------------------------------------------

status_check_system() {
    local os_id='' os_ver='' kernel='' up=''
    os_id="$(bamboo_os_release_field ID)"
    os_ver="$(bamboo_os_release_field VERSION_ID)"
    kernel="$(uname -r 2>/dev/null)" || kernel=''
    up="$(bamboo_uptime_human)"

    if [ -n "$os_id" ]; then
        status_check ok system.os "$os_id $os_ver (kernel $kernel${up:+, up $up})"
    else
        status_check warn system.os 'Unable to read /etc/os-release (not an Ubuntu host?)'
    fi

    if bamboo_reboot_required; then
        local pkgs=''
        pkgs="$(bamboo_reboot_required_pkgs)"
        status_check warn system.reboot "A reboot is pending${pkgs:+ (waiting on: $pkgs)}"
    else
        status_check ok system.reboot 'No reboot pending'
    fi
}

status_check_resources() {
    local ram='' swap='' free_mb='' total_mb='' used_pct=''

    swap="$(bamboo_swap_active)"
    if [ -z "$swap" ]; then
        status_check warn resource.swap 'No swap is active (bamboo-site install can create a swap file)'
    else
        status_check ok resource.swap "Swap active: $(printf '%s' "$swap" | tr '\n' ' ')"
    fi

    ram="$(bamboo_mem_total_mb)"
    if [ -n "$ram" ]; then
        status_check ok resource.ram "RAM: ${ram}MB total"
    fi

    free_mb="$(bamboo_disk_free_mb /)"
    total_mb="$(bamboo_disk_total_mb /)"
    if [ -n "$free_mb" ] && [ -n "$total_mb" ] && [ "$total_mb" -gt 0 ]; then
        used_pct=$(( (total_mb - free_mb) * 100 / total_mb ))
        if [ "$used_pct" -ge 95 ]; then
            status_check problem resource.disk "Disk almost full: ${used_pct}% used on / (${free_mb}MB free)"
        elif [ "$used_pct" -ge 85 ]; then
            status_check warn resource.disk "Disk filling up: ${used_pct}% used on / (${free_mb}MB free)"
        else
            status_check ok resource.disk "Disk: ${used_pct}% used on / (${free_mb}MB free)"
        fi
    elif [ -n "$free_mb" ]; then
        status_check ok resource.disk "Disk: ${free_mb}MB free on /"
    fi
}

status_check_services() {
    local svc
    for svc in nginx fail2ban ufw certbot.timer; do
        if bamboo_service_is_active "$svc"; then
            if bamboo_service_is_enabled "$svc"; then
                status_check ok "service.$svc" "$svc is running and enabled at boot"
            else
                status_check warn "service.$svc" "$svc is running but NOT enabled at boot"
            fi
        else
            case "$svc" in
                certbot.timer)
                    status_check warn "service.$svc" "$svc is not running (automatic renewal is paused)"
                    ;;
                *)
                    status_check problem "service.$svc" "$svc is not running"
                    ;;
            esac
        fi
    done
}

status_check_nginx() {
    local https_count=0 domain mode

    if bamboo_nginx_test; then
        status_check ok nginx.config 'nginx configuration is valid'
    else
        status_check problem nginx.config 'nginx -t failed — the running configuration may be stale'
    fi

    if [ -f "$BAMBOO_NGINX_LIMITS_FILE" ]; then
        status_check ok nginx.limits 'Rate-limit zones are installed'
    else
        status_check warn nginx.limits 'Rate-limit zones are missing (run: bamboo-site install)'
    fi

    if bamboo_port_listening 80; then
        status_check ok nginx.port80 'Port 80 is listening'
    else
        status_check problem nginx.port80 'Nothing is listening on port 80 (needed for certificate validation)'
    fi

    # shellcheck disable=SC2046
    for domain in $(workspace_list_domains); do
        mode="$(nginx_site_mode "$domain")"
        if [ "$mode" = 'https' ]; then
            https_count=$((https_count + 1))
        fi
    done

    if bamboo_port_listening 443; then
        status_check ok nginx.port443 'Port 443 is listening'
    elif [ "$https_count" -gt 0 ]; then
        status_check problem nginx.port443 "$https_count HTTPS site(s) but nothing is listening on port 443"
    else
        status_check ok nginx.port443 'Port 443 is not listening (no HTTPS sites yet)'
    fi
}

status_check_firewall() {
    local ssh_ports='' p missing=''

    if fw_is_active; then
        status_check ok firewall.active 'UFW is active'
    else
        status_check problem firewall.active 'UFW is not active (the server has no packet filter)'
        return 0
    fi

    ssh_ports="$(fw_detect_ssh_ports)"
    # shellcheck disable=SC2086
    for p in $ssh_ports 80 443; do
        if ! ufw_rule_present "$p"; then
            missing="$missing $p"
        fi
    done
    if [ -n "$missing" ]; then
        status_check problem firewall.rules "UFW is missing ALLOW rules for:$missing"
    else
        status_check ok firewall.rules "UFW allows SSH ($ssh_ports), 80 and 443"
    fi
}

status_check_fail2ban() {
    local listed='' domain jail missing_jails='' j count='' bans=0 jails=0

    bamboo_try bamboo_f2b_client -t
    if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
        status_check problem fail2ban.config 'The Fail2ban configuration is invalid (fail2ban-client -t failed)'
    else
        status_check ok fail2ban.config 'Fail2ban configuration is valid'
    fi

    bamboo_try bamboo_f2b_client status
    if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
        status_check warn fail2ban.jails 'Unable to query Fail2ban (run as root for jail and ban details)'
        return 0
    fi

    # `|| true`: a server with no bamboo jails yet makes grep find nothing, and
    # under `set -o pipefail` that would abort the whole status run.
    listed="$(printf '%s' "$BAMBOO_LAST_OUTPUT" | grep -oE 'bamboo-[a-z0-9.-]+' | sort -u || true)"
    case "$BAMBOO_LAST_OUTPUT" in
        *sshd*) status_check ok fail2ban.sshd 'The sshd jail is active' ;;
        *) status_check warn fail2ban.sshd 'The sshd jail is not active' ;;
    esac

    # shellcheck disable=SC2046
    for domain in $(workspace_list_domains); do
        missing_jails=''
        for jail in $(f2b_jail_names "$domain"); do
            case "$listed" in
                *"$jail"*) ;;
                *) missing_jails="$missing_jails ${jail##*-}" ;;
            esac
        done
        if [ -n "$missing_jails" ]; then
            status_check problem "fail2ban.$domain" "Not all jails are active for $domain: missing$missing_jails"
        else
            status_check ok "fail2ban.$domain" "All four jails are active for $domain"
        fi
    done

    if [ -n "$listed" ]; then
        for j in $listed; do
            jails=$((jails + 1))
            bamboo_try bamboo_f2b_client status "$j"
            count="$(printf '%s' "$BAMBOO_LAST_OUTPUT" | grep -oE 'Currently banned:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' || true)"
            case "$count" in
                ''|*[!0-9]*) count=0 ;;
            esac
            bans=$((bans + count))
        done
        status_check ok fail2ban.bans "$bans IP(s) currently banned across $jails jail(s)"
    fi
}

status_check_sites() {
    local domains='' domain mode days='' count=0 pending=0 line=''

    domains="$(workspace_list_domains)"
    if [ -z "$domains" ]; then
        status_check ok sites 'No sites are managed yet'
        return 0
    fi

    # shellcheck disable=SC2086
    for domain in $domains; do
        count=$((count + 1))
        mode="$(nginx_site_mode "$domain")"
        days=""
        case "$mode" in
            https) ;;
            http)
                pending=$((pending + 1))
                status_check warn "site.$domain" "$domain is served over HTTP only — retry SSL: bamboo-site ssl $domain"
                ;;
            disabled)
                status_check problem "site.$domain" "$domain is managed but disabled in nginx"
                ;;
            *)
                status_check problem "site.$domain" "$domain has no nginx configuration"
                ;;
        esac

        if ssl_cert_exists "$domain"; then
            days="$(ssl_cert_days_left "$domain")"
            case "$days" in
                ''|*[!0-9-]*)
                    status_check ok "cert.$domain" "$domain certificate present (expiry unknown)"
                    ;;
                *)
                    if [ "$days" -lt 7 ]; then
                        status_check problem "cert.$domain" "$domain certificate expires in ${days} day(s)"
                    elif [ "$days" -lt 21 ]; then
                        status_check warn "cert.$domain" "$domain certificate expires in ${days} day(s)"
                    else
                        status_check ok "cert.$domain" "$domain certificate valid for ${days} day(s)"
                    fi
                    ;;
            esac
        fi
        line="$(printf '%s\t%s\t%s' "$domain" "$mode" "${days:-}")"
        STATUS_SITES="$STATUS_SITES$line"$'\n'
    done

    status_check ok sites.summary "$count site(s) managed${pending:+, $pending awaiting SSL}"
}

status_check_install() {
    status_check ok cli.version "Bamboo-Site $BAMBOO_VERSION (running from $BAMBOO_ROOT)"
    if [ -f "$BAMBOO_CONFIG_FILE" ]; then
        status_check ok cli.config "Configuration file present: $BAMBOO_CONFIG_FILE"
    else
        status_check warn cli.config "No configuration file yet ($BAMBOO_CONFIG_FILE) — run: bamboo-site install"
    fi
}

status_render_json() {
    local line level id msg first=1 domain mode days sfirst=1
    printf '{\n'
    printf '  "host": "%s",\n' "$(bamboo_json_escape "$(hostname 2>/dev/null)")"
    printf '  "version": "%s",\n' "$(bamboo_json_escape "$BAMBOO_VERSION")"
    printf '  "checked_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "ok": %s, "warnings": %s, "problems": %s,\n' "$STATUS_OK" "$STATUS_WARN" "$STATUS_PROBLEM"

    printf '  "checks": [\n'
    printf '%s' "$STATUS_ALL" | while IFS="$(printf '\t')" read -r level id msg; do
        [ -n "$level" ] || continue
        if [ "$first" = '1' ]; then
            first=0
        else
            printf ',\n'
        fi
        printf '    {"level": "%s", "id": "%s", "message": "%s"}' \
            "$level" "$(bamboo_json_escape "$id")" "$(bamboo_json_escape "$msg")"
    done
    printf '\n  ],\n'

    printf '  "sites": [\n'
    printf '%s' "$STATUS_SITES" | while IFS="$(printf '\t')" read -r domain mode days; do
        [ -n "$domain" ] || continue
        if [ "$sfirst" = '1' ]; then
            sfirst=0
        else
            printf ',\n'
        fi
        printf '    {"domain": "%s", "mode": "%s", "ssl_days": %s}' \
            "$(bamboo_json_escape "$domain")" "$(bamboo_json_escape "$mode")" "${days:-null}"
    done
    printf '\n  ]\n}\n'
    return 0
}

cmd_status() {
    local json=0 quiet=0 strict=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=1 ;;
            --quiet|-q) quiet=1 ;;
            --strict) strict=1 ;;
            -h|--help) cmd_status_usage; return 0 ;;
            *) die "status: unknown option '$1'. See '$BAMBOO_PROG_NAME help status'." ;;
        esac
        shift
    done

    if [ "$json" = '1' ]; then
        STATUS_MODE='json'
    elif [ "$quiet" = '1' ]; then
        STATUS_MODE='quiet'
    fi

    if [ "$STATUS_MODE" = 'normal' ]; then
        log_step "Bamboo-Site status — $(hostname 2>/dev/null || printf 'server')"
    fi

    status_check_system
    status_check_resources
    status_check_services
    status_check_nginx
    status_check_firewall
    status_check_fail2ban
    status_check_sites
    status_check_install

    if [ "$json" = '1' ]; then
        status_render_json
    elif [ "$STATUS_MODE" = 'normal' ]; then
        printf '\n' >&2
        log_info "$STATUS_OK ok, $STATUS_WARN warning(s), $STATUS_PROBLEM problem(s)"
        if [ "$STATUS_PROBLEM" -gt 0 ]; then
            log_hint 'Problems found — the [error] lines above say what to fix.'
        elif [ "$STATUS_WARN" -gt 0 ]; then
            log_hint 'Only warnings; run with --strict to treat them as failures.'
        fi
    fi

    if [ "$STATUS_PROBLEM" -gt 0 ]; then
        exit 1
    fi
    if [ "$strict" = '1' ] && [ "$STATUS_WARN" -gt 0 ]; then
        exit 1
    fi
    return 0
}
