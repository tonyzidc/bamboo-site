#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site renew`

cmd_renew_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME renew [domain] [options]

Renews certificates. With a domain, only that certificate is renewed; without
one, certbot renews everything that is due. Ubuntu's certbot.timer already
does this automatically — this command is for forcing a run or checking state.

After a successful renewal, any site still stuck in HTTP-only mode (because
issuance failed earlier) is switched to HTTPS automatically.

Global options:
  --dry-run   Ask certbot to perform a test run (nothing is renewed), and
              change no configuration.
  -y, --yes   Never prompt.

Examples:
  sudo $BAMBOO_PROG_NAME renew
  sudo $BAMBOO_PROG_NAME renew example.com
  sudo $BAMBOO_PROG_NAME renew --dry-run
EOF
}

cmd_renew() {
    local domain_raw=''

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) cmd_renew_usage; return 0 ;;
            -*)
                die "renew: unknown option '$1'. See '$BAMBOO_PROG_NAME help renew'."
                ;;
            *)
                if [ -z "$domain_raw" ]; then
                    domain_raw="$1"
                else
                    die "renew: unexpected argument '$1'."
                fi
                ;;
        esac
        shift
    done

    require_root
    require_core_installed

    local domain=''
    if [ -n "$domain_raw" ]; then
        domain="$(bamboo_require_domain "$domain_raw")"
        require_workspace "$domain"
    fi

    log_step "Renewing ${domain:-all certificates that are due}"
    ssl_renew "$domain" "$BAMBOO_DRY_RUN"

    if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
        if [ -n "$domain" ]; then
            ssl_print_failure_help "$domain" "$BAMBOO_LAST_OUTPUT"
        else
            log_error 'certbot renew reported failures:'
            printf '%s\n' "$BAMBOO_LAST_OUTPUT" | tail -n 12 | while IFS= read -r line; do
                printf '  %s%s%s\n' "$C_DIM" "$line" "$C_RESET" >&2
            done
        fi
        exit 1
    fi
    if [ -n "$BAMBOO_LAST_OUTPUT" ]; then
        printf '%s\n' "$BAMBOO_LAST_OUTPUT" | while IFS= read -r line; do
            log_debug "$line"
        done
    fi

    if [ "$BAMBOO_DRY_RUN" != '1' ]; then
        log_step 'Checking for sites waiting on a certificate'
        ssl_upgrade_pending_domains "$domain"
    fi

    log_step 'Certificate inventory'
    bamboo_try bamboo_certbot certificates
    if [ "$BAMBOO_LAST_STATUS" -eq 0 ] && [ -n "$BAMBOO_LAST_OUTPUT" ]; then
        printf '%s\n' "$BAMBOO_LAST_OUTPUT" >&2
    else
        log_warn 'certbot certificates produced no output.'
    fi

    if [ "$BAMBOO_TEST_MODE" != '1' ] && bamboo_need_cmd systemctl; then
        log_hint "Automatic renewal status: systemctl list-timers certbot.timer"
    fi
    if bamboo_is_dry_run; then
        log_info 'Dry run finished — nothing was renewed.'
        return 0
    fi
    log_ok 'Renewal run complete.'
    bamboo_oplog "renew ${domain:-all}: finished"
    return 0
}
