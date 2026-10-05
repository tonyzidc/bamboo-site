#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site add`

cmd_add_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME add <domain> [email] [options]

Creates the isolated workspace for <domain>, generates the Nginx server block,
adds the Fail2ban jail and issues a Let's Encrypt certificate.

If certificate issuance fails (DNS not propagated, port 80 blocked, rate
limit), the configuration is rolled back to HTTP-only, the site stays online
and you are told to retry with '$BAMBOO_PROG_NAME ssl <domain>'.

Options:
  --www              Cover www.<domain> as well (default: auto-detect).
  --no-www           Cover only <domain>.
  --no-ssl           Skip certificate issuance for now.
  --email <address>  Let's Encrypt contact email.
  -h, --help         Show this help.

Global options: --dry-run, --force, --yes, --verbose, --no-color

Examples:
  sudo $BAMBOO_PROG_NAME add example.com
  sudo $BAMBOO_PROG_NAME add example.com admin@example.com --www
  sudo $BAMBOO_PROG_NAME add staging.example.com --no-ssl
EOF
}

cmd_add() {
    local domain_raw='' email='' www_mode="$BAMBOO_SSL_WWW" do_ssl=1
    case "$www_mode" in
        auto|yes|no) ;;
        *) www_mode='auto' ;;
    esac

    while [ $# -gt 0 ]; do
        case "$1" in
            --www) www_mode='yes' ;;
            --no-www) www_mode='no' ;;
            --no-ssl) do_ssl=0 ;;
            --email)
                [ $# -ge 2 ] || die 'add: --email requires a value.'
                email="$2"
                shift
                ;;
            -h|--help) cmd_add_usage; return 0 ;;
            -*)
                die "add: unknown option '$1'. See '$BAMBOO_PROG_NAME help add'."
                ;;
            *)
                if [ -z "$domain_raw" ]; then
                    domain_raw="$1"
                elif [ -z "$email" ]; then
                    email="$1"
                else
                    die "add: unexpected argument '$1'."
                fi
                ;;
        esac
        shift
    done

    if [ -z "$domain_raw" ]; then
        cmd_add_usage >&2
        die 'add: a domain name is required.'
    fi

    local domain
    domain="$(bamboo_require_domain "$domain_raw")"
    require_root
    require_core_installed

    if workspace_exists "$domain"; then
        die "'$domain' is already managed (workspace: $(workspace_dir "$domain")). Remove it first with: sudo $BAMBOO_PROG_NAME delete $domain"
    fi
    bamboo_oplog "add $domain: started"

    log_step "Creating the isolated workspace for $domain"
    workspace_create "$domain"
    log_ok "Workspace ready: $(workspace_dir "$domain")"

    log_step 'Generating the Nginx configuration'
    nginx_apply_site "$domain" 'http'

    log_step 'Configuring Fail2ban for this domain'
    if ! f2b_add_jail "$domain"; then
        log_warn "The Fail2ban jail for $domain is not active (see above). The site itself is unaffected."
    fi

    local ssl_pending=0 names='' cert_email=''
    if [ "$do_ssl" = '1' ]; then
        log_step "Issuing the SSL certificate for $domain"
        names="$(ssl_determine_names "$domain" "$www_mode")"
        cert_email="$(bamboo_resolve_email "$email")"
        if ! ssl_preflight "$domain" "$BAMBOO_FORCE"; then
            log_warn 'Skipping certificate issuance until DNS is fixed.'
            log_hint "The site is online over HTTP. Retry later with: sudo $BAMBOO_PROG_NAME ssl $domain"
            ssl_pending=1
        elif ssl_attempt "$domain" "$names" "$cert_email" '0'; then
            if bamboo_is_dry_run; then
                log_info "[dry-run] would issue a certificate covering: $names"
            else
                log_ok "HTTPS is live. The certificate covers: $names"
            fi
        else
            ssl_print_failure_help "$domain" "$BAMBOO_LAST_OUTPUT"
            ssl_pending=1
        fi
    else
        log_warn 'SSL skipped (--no-ssl) — the site is reachable over HTTP only.'
        log_hint "Issue a certificate later with: sudo $BAMBOO_PROG_NAME ssl $domain"
        ssl_pending=1
    fi

    if bamboo_is_dry_run; then
        printf '\n' >&2
        log_info "Dry run finished — $domain was not created and no certificate was requested."
        log_hint 'Re-run without --dry-run to apply.'
        return 0
    fi

    workspace_print_tree "$domain"

    if [ "$ssl_pending" = '1' ]; then
        log_warn "Summary: $domain is live over HTTP; SSL is still pending."
        log_hint "Retry with: sudo $BAMBOO_PROG_NAME ssl $domain"
    else
        log_ok "Summary: $domain is live at https://$domain"
    fi
    log_hint "Upload your site to: $(workspace_public "$domain")"
    log_hint "Verify DNS and ports any time with: sudo $BAMBOO_PROG_NAME list"

    bamboo_oplog "add $domain: finished (ssl_pending=$ssl_pending)"
    return 0
}
