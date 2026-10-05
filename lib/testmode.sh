#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — test-mode seam.
#
# Sourced by bin/bamboo-site immediately AFTER the real libraries, and only
# when BAMBOO_TEST_MODE=1. It replaces every external-command wrapper with a
# stub, so the complete CLI can be exercised on a machine without
# nginx/certbot/fail2ban/UFW (the test suite runs on macOS).
#
# Nothing in here is reachable in production: BAMBOO_TEST_MODE is set by
# tests/run.sh and by nothing else.

bamboo_test_record() {
    [ -n "${BAMBOO_TEST_CMD_LOG:-}" ] || return 0
    printf '%s\n' "$*" >>"$BAMBOO_TEST_CMD_LOG" 2>/dev/null || true
    return 0
}

bamboo_need_cmd() { return 0; }

bamboo_service_is_active() {
    local svc="$1" s
    for s in ${BAMBOO_TEST_SERVICES_ACTIVE:-}; do
        [ "$s" = "$svc" ] && return 0
    done
    return 1
}

bamboo_service_is_enabled() {
    local svc="$1" s
    for s in ${BAMBOO_TEST_SERVICES_ENABLED:-}; do
        [ "$s" = "$svc" ] && return 0
    done
    return 1
}

bamboo_own() {
    bamboo_test_record "chown $*"
    return 0
}

bamboo_chmod() {
    bamboo_test_record "chmod $*"
    return 0
}

bamboo_systemctl() {
    bamboo_test_record "systemctl $*"
    return 0
}

bamboo_apt_get() {
    bamboo_test_record "apt-get $*"
    return 0
}

bamboo_pkg_installed() {
    # Report everything as missing so the install path runs end to end.
    return 1
}

bamboo_os_release_field() {
    case "$1" in
        ID) printf '%s' "$BAMBOO_TEST_OS_ID" ;;
        VERSION_ID) printf '%s' "$BAMBOO_TEST_OS_VERSION" ;;
        *) printf '' ;;
    esac
    return 0
}

bamboo_dns_a() {
    if [ -n "$BAMBOO_TEST_DNS_A" ]; then
        printf '%s\n' "$BAMBOO_TEST_DNS_A"
    fi
    return 0
}

bamboo_public_ip() {
    printf '%s' "$BAMBOO_TEST_PUBLIC_IP"
    return 0
}

bamboo_nginx_bin() {
    bamboo_test_record "nginx $*"
    case " $* " in
        *' -v '*) printf 'nginx version: nginx/1.18.0 (Ubuntu)\n' ;;
    esac
    return 0
}

bamboo_nginx_test() {
    bamboo_test_record 'nginx -t'
    if [ -n "${BAMBOO_TEST_NGINX_TEST_FAIL_FILE:-}" ] && [ -f "$BAMBOO_TEST_NGINX_TEST_FAIL_FILE" ]; then
        printf 'nginx: [emerg] simulated configuration error\n' >&2
        return 1
    fi
    return 0
}

bamboo_ufw() {
    bamboo_test_record "ufw $*"
    case " $* " in
        *' status '*)
            if [ "${BAMBOO_TEST_UFW_ACTIVE:-0}" = "1" ]; then
                printf 'Status: active\n'
                printf 'To                         Action      From\n'
                printf -- '--                         ------      ----\n'
                local rule
                for rule in ${BAMBOO_TEST_UFW_RULES:-22/tcp 80/tcp 443/tcp}; do
                    printf '%-27s ALLOW       Anywhere\n' "$rule"
                done
            else
                printf 'Status: inactive\n'
            fi
            ;;
    esac
    return 0
}

bamboo_f2b_client() {
    bamboo_test_record "fail2ban-client $*"
    case " $* " in
        *' -t '*)
            # Simulates a jail that fail2ban cannot parse: the test fails until
            # the offending jail has been quarantined (moved to *.rejected).
            if [ -n "${BAMBOO_TEST_F2B_FAIL_FILE:-}" ] && [ -f "$BAMBOO_TEST_F2B_FAIL_FILE" ]; then
                if ! ls "$BAMBOO_F2B_JAILD"/*.rejected >/dev/null 2>&1; then
                    printf 'ERROR   Found no accessible config files for filter.d/nonexistent-filter\n'
                    printf 'ERROR   ERROR: test configuration failed\n'
                    return 1
                fi
            fi
            return 0
            ;;
        *' --version '*) printf 'Fail2Ban v0.11.2\n' ;;
        *' status '*)
            if [ "$#" -eq 1 ]; then
                printf 'Status\n'
                printf '|- Number of jail:\t1\n'
                printf '\`- Jail list:\t%s\n' "${BAMBOO_TEST_F2B_JAILS:-sshd}"
            else
                printf 'Status for the jail: %s\n' "$2"
                printf '|- Filter\n|  |- Currently banned:\t%s\n' "${BAMBOO_TEST_F2B_BANNED:-0}"
            fi
            ;;
    esac
    return 0
}

# --- swap / system probes ---------------------------------------------------

bamboo_swapon() { bamboo_test_record "swapon $*"; return 0; }
bamboo_swapoff() { bamboo_test_record "swapoff $*"; return 0; }
bamboo_mkswap() { bamboo_test_record "mkswap $*"; return 0; }

bamboo_fallocate() {
    bamboo_test_record "fallocate $*"
    [ "${BAMBOO_TEST_FALLOCATE_FAIL:-0}" = "1" ] && return 1
    return 0
}

bamboo_dd() { bamboo_test_record "dd $*"; return 0; }

bamboo_swap_active() { printf '%s' "${BAMBOO_TEST_SWAP_ACTIVE:-}"; return 0; }
bamboo_mem_total_mb() { printf '%s' "${BAMBOO_TEST_RAM_MB:-2048}"; return 0; }
bamboo_disk_free_mb() { printf '%s' "${BAMBOO_TEST_DISK_FREE_MB:-20480}"; return 0; }
bamboo_disk_total_mb() { printf '%s' "${BAMBOO_TEST_DISK_TOTAL_MB:-40960}"; return 0; }
bamboo_uptime_human() { printf '1d 2h 3m'; return 0; }

bamboo_reboot_required() { [ "${BAMBOO_TEST_REBOOT_REQUIRED:-0}" = "1" ]; }

bamboo_reboot_required_pkgs() {
    [ "${BAMBOO_TEST_REBOOT_REQUIRED:-0}" = "1" ] && printf 'linux-image-6.8.0-test'
    return 0
}

bamboo_port_listening() {
    local port="$1" p
    for p in ${BAMBOO_TEST_OPEN_PORTS:-80 443}; do
        [ "$p" = "$port" ] && return 0
    done
    return 1
}

apt_upgrade_count() { printf '%s' "${BAMBOO_TEST_UPGRADE_COUNT:-3}"; return 0; }

ssl_test_generate_selfsigned() {
    # ssl_test_generate_selfsigned <cn> <space separated names> <directory>
    local cn="$1" names="$2" dir="$3" cfg sans='' name
    bamboo_need_cmd openssl >/dev/null 2>&1 || return 1
    for name in $names; do
        sans="$sans,DNS:$name"
    done
    sans="${sans#,}"
    bamboo_ensure_tmpdir
    cfg="$BAMBOO_TMPDIR/openssl-test.cnf"
    {
        printf '[req]\n'
        printf 'distinguished_name = dn\n'
        printf 'x509_extensions = v3\n'
        printf 'prompt = no\n'
        printf '[dn]\n'
        printf 'CN = %s\n' "$cn"
        printf '[v3]\n'
        printf 'subjectAltName = %s\n' "$sans"
        printf 'basicConstraints = CA:FALSE\n'
    } >"$cfg" || return 1
    mkdir -p "$dir" || return 1
    if openssl req -x509 -newkey rsa:2048 -nodes -days "${BAMBOO_TEST_CERT_DAYS:-90}" \
        -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" -config "$cfg" >/dev/null 2>&1; then
        cp "$dir/fullchain.pem" "$dir/cert.pem"
        cp "$dir/fullchain.pem" "$dir/chain.pem"
        return 0
    fi
    return 1
}

ssl_test_fabricate_certificates() {
    # Mirrors what certbot would leave in /etc/letsencrypt/live/<cert-name>.
    local args="$1" cert_name='' names='' prev='' arg
    # shellcheck disable=SC2086
    set -- $args
    for arg in "$@"; do
        case "$prev" in
            --cert-name) cert_name="$arg" ;;
            -d) names="$names $arg" ;;
        esac
        prev="$arg"
    done
    names="$(printf '%s' "$names" | sed -e 's/^[[:space:]]*//')"
    [ -n "$cert_name" ] || return 0
    [ -n "$names" ] || names="$cert_name"

    local dir="$BAMBOO_LETSENCRYPT_LIVE/$cert_name"
    if ssl_test_generate_selfsigned "$cert_name" "$names" "$dir"; then
        return 0
    fi
    # openssl unavailable: leave placeholder files so existence checks pass.
    mkdir -p "$dir"
    printf 'placeholder certificate\n' >"$dir/cert.pem"
    printf 'placeholder chain\n' >"$dir/chain.pem"
    printf 'placeholder chain\n' >"$dir/fullchain.pem"
    printf 'placeholder key\n' >"$dir/privkey.pem"
    return 0
}

bamboo_certbot() {
    bamboo_test_record "certbot $*"
    case " $* " in
        *' certonly '*)
            if [ "$BAMBOO_TEST_CERTBOT_RESULT" = "1" ]; then
                if [ -n "$BAMBOO_TEST_CERTBOT_OUTPUT" ]; then
                    printf '%s\n' "$BAMBOO_TEST_CERTBOT_OUTPUT"
                else
                    printf '%s\n' 'Simulated failure: DNS problem: NXDOMAIN looking up A for example.com'
                fi
                return 1
            fi
            ssl_test_fabricate_certificates "$*"
            printf 'Successfully received certificate. Certificate is saved at: %s\n' "$BAMBOO_LETSENCRYPT_LIVE"
            return 0
            ;;
        *' renew '*)
            if [ "$BAMBOO_TEST_CERTBOT_RESULT" = "1" ]; then
                printf '%s\n' "${BAMBOO_TEST_CERTBOT_OUTPUT:-Simulated renewal failure}"
                return 1
            fi
            printf 'Congratulations, all renewals succeeded.\n'
            return 0
            ;;
    esac
    return 0
}
