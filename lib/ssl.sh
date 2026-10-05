#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — Let's Encrypt lifecycle.
#
# The smart-fallback contract: whichever way certbot exits, the site is left in
# a state Nginx can serve. On failure the configuration is rolled back to
# HTTP-only and the operator is told how to retry with `bamboo-site ssl <domain>`.

ssl_live_dir() { printf '%s/%s' "$BAMBOO_LETSENCRYPT_LIVE" "$1"; }

ssl_cert_exists() {
    local live
    live="$(ssl_live_dir "$1")"
    [ -f "$live/fullchain.pem" ] || return 1
    [ -f "$live/privkey.pem" ] || return 1
    return 0
}

ssl_cert_days_left() {
    # Prints whole days until expiry, or nothing when it cannot be determined.
    local domain="$1" cert end epoch='' now
    cert="$(ssl_live_dir "$domain")/cert.pem"
    if [ ! -f "$cert" ]; then
        printf ''
        return 0
    fi
    end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)" || end=''
    if [ -z "$end" ]; then
        printf ''
        return 0
    fi
    epoch="$(date -d "$end" +%s 2>/dev/null)" || epoch=''
    if [ -z "$epoch" ]; then
        # BSD/macOS date, used by the test suite.
        epoch="$(date -j -f '%b %d %T %Y %Z' "$end" +%s 2>/dev/null)" || epoch=''
    fi
    if [ -z "$epoch" ]; then
        printf ''
        return 0
    fi
    now="$(date +%s)"
    printf '%s' "$(( (epoch - now) / 86400 ))"
    return 0
}

ssl_cert_names() {
    # Prints the DNS names covered by the certificate, apex first.
    local domain="$1" cert names='' ordered='' name
    cert="$(ssl_live_dir "$domain")/cert.pem"
    if [ ! -f "$cert" ]; then
        printf '%s' "$domain"
        return 0
    fi
    names="$(openssl x509 -in "$cert" -noout -text 2>/dev/null | awk '
        /X509v3 Subject Alternative Name/ { grab = 1; next }
        grab { print; exit }
    ' | tr ',' '\n' | sed -n 's/^ *DNS:\([^ ]*\).*$/\1/p' | sort -u | tr '\n' ' ')" || names=''
    names="$(printf '%s' "$names" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -z "$names" ]; then
        names="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p')" || names=''
    fi
    if [ -z "$names" ]; then
        printf '%s' "$domain"
        return 0
    fi
    ordered="$domain"
    for name in $names; do
        [ "$name" = "$domain" ] && continue
        ordered="$ordered $name"
    done
    printf '%s' "$ordered"
    return 0
}

ssl_determine_names() {
    # ssl_determine_names <domain> <auto|yes|no>
    local domain="$1" mode="${2:-auto}" www="www.$1"
    case "$mode" in
        yes)
            printf '%s %s' "$domain" "$www"
            return 0
            ;;
        no)
            printf '%s' "$domain"
            return 0
            ;;
    esac
    if [ -n "$(bamboo_dns_a "$www")" ]; then
        printf '%s %s' "$domain" "$www"
    else
        printf '%s' "$domain"
    fi
    return 0
}

ssl_preflight() {
    # Warns about DNS problems before Let's Encrypt rate-limit budget is spent.
    # Returns non-zero when the operator should fix DNS first.
    local domain="$1" force="${2:-0}" apex_ip='' public_ip=''
    if [ "$force" = "1" ]; then
        log_debug 'DNS preflight skipped (--force).'
        return 0
    fi
    apex_ip="$(bamboo_dns_a "$domain" | head -n 1)"
    if [ -z "$apex_ip" ]; then
        log_error "No A record found for $domain."
        log_hint "Point $domain (and www.$domain if you want it covered) at this server and wait for DNS to propagate."
        log_hint "Check with: dig +short A $domain"
        return 1
    fi
    public_ip="$(bamboo_public_ip)"
    if [ -n "$public_ip" ] && [ "$apex_ip" != "$public_ip" ]; then
        log_warn "$domain resolves to $apex_ip but this server's public IP is $public_ip."
        log_warn "That is normal behind a proxy/CDN; otherwise Let's Encrypt validation will fail."
        if ! bamboo_confirm 'Continue anyway?'; then
            return 1
        fi
    else
        log_ok "$domain resolves to $apex_ip."
    fi
    return 0
}

ssl_issue() {
    # ssl_issue <domain> <names> <email> <force>
    # Never fails the caller; the result is in BAMBOO_LAST_STATUS / _OUTPUT.
    local domain="$1" names="$2" email="$3" force="${4:-0}"
    local webroot name
    local -a args=()
    webroot="$(workspace_public "$domain")"

    args=(certonly --webroot -w "$webroot" --cert-name "$domain")
    for name in $names; do
        args+=(-d "$name")
    done
    args+=(--expand --non-interactive --agree-tos --no-eff-email)
    if [ -n "$email" ]; then
        args+=(-m "$email")
    else
        args+=(--register-unsafely-without-email)
    fi
    if [ "$force" = "1" ]; then
        args+=(--force-renewal)
    fi
    if [ -n "$BAMBOO_CERTBOT_EXTRA_ARGS" ]; then
        # shellcheck disable=SC2206
        args+=($BAMBOO_CERTBOT_EXTRA_ARGS)
    fi

    bamboo_oplog "certbot certonly --cert-name $domain -d $(printf '%s' "$names" | tr ' ' ',') force=$force"
    if bamboo_is_dry_run; then
        log_info "[dry-run] would run: certbot ${args[*]}"
        BAMBOO_LAST_STATUS=0
        BAMBOO_LAST_OUTPUT='[dry-run]'
        return 0
    fi
    log_info "Requesting a certificate for: $names"
    bamboo_try bamboo_certbot "${args[@]}"
    return 0
}

ssl_link_workspace() {
    # Convenience symlink inside the workspace: letsencrypt/ -> live/<domain>.
    local domain="$1" link
    link="$(workspace_le "$domain")"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$(ssl_live_dir "$domain")" ]; then
        return 0
    fi
    if bamboo_is_dry_run; then
        log_info "[dry-run] would link $link -> $(ssl_live_dir "$domain")"
        return 0
    fi
    if ln -sfn "$(ssl_live_dir "$domain")" "$link" 2>/dev/null; then
        log_debug "Linked $link -> $(ssl_live_dir "$domain")"
    else
        log_warn "Could not create the convenience symlink $link"
    fi
    return 0
}

ssl_ensure_http_fallback() {
    # The smart fallback: whatever state the config is in, make sure Nginx is
    # serving plain HTTP so a missing certificate can never break the site.
    local domain="$1"
    if nginx_is_https "$domain"; then
        log_warn 'Rolling the Nginx configuration back to HTTP-only.'
        nginx_set_mode "$domain" http
    elif ! nginx_site_enabled "$domain"; then
        log_warn 'Re-enabling the HTTP-only configuration.'
        nginx_set_mode "$domain" http
    else
        log_debug 'HTTP-only configuration already in place.'
    fi
    return 0
}

ssl_attempt() {
    # ssl_attempt <domain> <names> <email> <force>
    # Returns 0 and switches the site to HTTPS on success; returns 1 and leaves
    # the site on HTTP when issuance fails.
    local domain="$1" names="$2" email="$3" force="${4:-0}"

    ssl_issue "$domain" "$names" "$email" "$force"
    if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
        ssl_ensure_http_fallback "$domain"
        return 1
    fi
    ssl_link_workspace "$domain"
    nginx_set_mode "$domain" https
    return 0
}

ssl_print_failure_help() {
    local domain="$1" output="$2" matched=0
    printf '\n' >&2
    log_warn "Let's Encrypt could not validate $domain — the site stays online over HTTP."
    if printf '%s' "$output" | grep -qi 'rate limit\|too many certificates\|too many failed authorizations'; then
        log_hint "A Let's Encrypt rate limit was hit. Wait for the window to reset, then retry (https://letsencrypt.org/docs/rate-limits/)."
        matched=1
    fi
    if printf '%s' "$output" | grep -qi 'nxdomain\|no valid ip\|dns problem\|could not be resolved'; then
        log_hint "DNS for $domain does not point here yet. Check: dig +short A $domain"
        matched=1
    fi
    if printf '%s' "$output" | grep -qi 'timeout during connect\|connection refused\|connection timed out\|fetching http://'; then
        log_hint 'Port 80 is not reachable from the internet. Check the VPS provider firewall and: sudo ufw status'
        matched=1
    fi
    if printf '%s' "$output" | grep -qi 'unauthorized\|invalid response\|404'; then
        log_hint "The ACME challenge could not be served. Verify with: curl -I http://$domain/.well-known/acme-challenge/probe"
        matched=1
    fi
    if [ "$matched" = "0" ]; then
        log_hint 'Review the certbot output below, fix the cause, then retry.'
    fi
    log_hint "Retry at any time with: sudo $BAMBOO_PROG_NAME ssl $domain"
    if [ -n "$output" ]; then
        printf '\n' >&2
        printf '%s\n' "$output" | tail -n 6 | while IFS= read -r line; do
            printf '  %s%s%s\n' "$C_DIM" "$line" "$C_RESET" >&2
        done
        printf '\n' >&2
    fi
    return 0
}

ssl_revoke() {
    # Best-effort revoke + delete; never fatal, since the site data is being
    # removed anyway.
    local domain="$1" live
    if bamboo_is_dry_run; then
        log_info "[dry-run] would revoke and delete the certificate for $domain"
        return 0
    fi
    live="$(ssl_live_dir "$domain")"
    if [ -f "$live/cert.pem" ]; then
        bamboo_try bamboo_certbot revoke --cert-path "$live/cert.pem" --non-interactive
        if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
            case "$BAMBOO_LAST_OUTPUT" in
                *'already been revoked'*|*'Certificate not found'*|*'No such file'*)
                    log_warn "The certificate for $domain was already revoked."
                    ;;
                *)
                    log_warn "Could not revoke the certificate for $domain (continuing)."
                    log_debug "$BAMBOO_LAST_OUTPUT"
                    ;;
            esac
        else
            log_ok "Certificate revoked for $domain."
        fi
    else
        log_debug "No certificate to revoke for $domain."
    fi

    bamboo_try bamboo_certbot delete --cert-name "$domain" --non-interactive
    if [ "$BAMBOO_LAST_STATUS" -eq 0 ]; then
        log_ok "Certificate files removed for $domain."
    else
        log_debug "certbot delete: $BAMBOO_LAST_OUTPUT"
    fi
    return 0
}

ssl_renew() {
    # ssl_renew [domain] [dry_run]
    local domain="${1:-}" dry="${2:-0}"
    local -a args=(renew --deploy-hook 'systemctl reload nginx')
    if [ -n "$domain" ]; then
        args+=(--cert-name "$domain")
    fi
    if [ "$dry" = '1' ]; then
        args+=(--dry-run)
        log_info 'Certbot dry run — no certificate will be changed.'
    fi
    bamboo_oplog "certbot renew ${domain:-all} dry=$dry"
    if bamboo_is_dry_run; then
        log_info "[dry-run] would run: certbot ${args[*]}"
        BAMBOO_LAST_STATUS=0
        BAMBOO_LAST_OUTPUT='[dry-run]'
        return 0
    fi
    bamboo_try bamboo_certbot "${args[@]}"
    return 0
}

ssl_upgrade_pending_domains() {
    # After a renewal, move any HTTP-only site whose certificate now exists to
    # HTTPS. An optional argument limits the sweep to one domain.
    local only="${1:-}" domain mode
    # shellcheck disable=SC2046
    for domain in $(workspace_list_domains); do
        if [ -n "$only" ] && [ "$domain" != "$only" ]; then
            continue
        fi
        mode="$(nginx_site_mode "$domain")"
        if [ "$mode" = "http" ] && ssl_cert_exists "$domain"; then
            log_info "Certificate available for $domain — switching it to HTTPS."
            nginx_set_mode "$domain" https
        fi
    done
    return 0
}
