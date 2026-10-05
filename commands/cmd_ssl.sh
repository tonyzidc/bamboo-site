#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site ssl`
#
# The recovery path for a domain whose certificate could not be issued during
# `add` (DNS not propagated, port 80 blocked, rate limits, ...). It can also be
# used to widen an existing certificate to cover www.

cmd_ssl_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME ssl <domain> [options]

Issues (or re-issues) the Let's Encrypt certificate for a domain that is
already managed, then switches its Nginx configuration to HTTPS.

Typical use: fix DNS/ports after a failed 'add', then run this to complete the
setup — no need to delete and re-add the site.

Options:
  --www              Cover www.<domain> as well (default: auto-detect).
  --no-www           Cover only <domain>.
  --email <address>  Let's Encrypt contact email.
  -h, --help         Show this help.

Global options:
  --force            Re-issue even when a valid certificate already exists
                     (also skips the DNS preflight).
  --dry-run          Show what would happen, touch nothing.

Examples:
  sudo $BAMBOO_PROG_NAME ssl example.com
  sudo $BAMBOO_PROG_NAME ssl example.com --www
  sudo $BAMBOO_PROG_NAME ssl example.com --force
EOF
}

cmd_ssl() {
    local domain_raw='' email='' www_mode="$BAMBOO_SSL_WWW"
    case "$www_mode" in
        auto|yes|no) ;;
        *) www_mode='auto' ;;
    esac

    while [ $# -gt 0 ]; do
        case "$1" in
            --www) www_mode='yes' ;;
            --no-www) www_mode='no' ;;
            --email)
                [ $# -ge 2 ] || die 'ssl: --email requires a value.'
                email="$2"
                shift
                ;;
            -h|--help) cmd_ssl_usage; return 0 ;;
            -*)
                die "ssl: unknown option '$1'. See '$BAMBOO_PROG_NAME help ssl'."
                ;;
            *)
                if [ -z "$domain_raw" ]; then
                    domain_raw="$1"
                elif [ -z "$email" ]; then
                    email="$1"
                else
                    die "ssl: unexpected argument '$1'."
                fi
                ;;
        esac
        shift
    done

    if [ -z "$domain_raw" ]; then
        cmd_ssl_usage >&2
        die 'ssl: a domain name is required.'
    fi

    local domain
    domain="$(bamboo_require_domain "$domain_raw")"
    require_root
    require_core_installed
    require_workspace "$domain"

    local names cert_email
    names="$(ssl_determine_names "$domain" "$www_mode")"

    # Reconcile the Fail2ban jail on every run: it repairs missing or outdated
    # jail files and is a no-op when the jail is already current.
    if ! f2b_add_jail "$domain"; then
        log_warn "The Fail2ban jail for $domain is not active (see above)."
    fi

    # Already certified and no --force: just make sure HTTPS is switched on.
    if ssl_cert_exists "$domain" && [ "$BAMBOO_FORCE" != '1' ]; then
        log_ok "A certificate for $domain already exists."
        if nginx_is_https "$domain"; then
            log_info 'The site is already served over HTTPS.'
        else
            log_info 'Switching the site to HTTPS.'
            nginx_set_mode "$domain" 'https'
        fi
        log_hint "Use --force to re-issue, or 'renew' to renew when due."
        return 0
    fi

    bamboo_oplog "ssl $domain: started (force=$BAMBOO_FORCE, names=$names)"

    log_step "Issuing the certificate for $domain"
    if ! ssl_preflight "$domain" "$BAMBOO_FORCE"; then
        log_hint "Fix DNS first, or re-run with --force to try anyway."
        exit 1
    fi

    cert_email="$(bamboo_resolve_email "$email")"
    if ssl_attempt "$domain" "$names" "$cert_email" "$BAMBOO_FORCE"; then
        if bamboo_is_dry_run; then
            log_info "Dry run finished — no certificate was requested for $domain."
            return 0
        fi
        log_ok "HTTPS enabled for $domain (certificate covers: $names)."
        bamboo_oplog "ssl $domain: success ($names)"
        return 0
    fi

    ssl_print_failure_help "$domain" "$BAMBOO_LAST_OUTPUT"
    bamboo_oplog "ssl $domain: failed"
    exit 1
}
