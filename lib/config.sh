#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — server-wide defaults stored in /etc/bamboo-site/config.
#
# The file is plain KEY=value shell syntax. Values in the environment always
# win over the file; the file wins over the built-in defaults in common.sh.
# `install` creates it; every command reads it.

BAMBOO_CONFIG_KEYS='BAMBOO_DEFAULT_EMAIL BAMBOO_SSL_WWW BAMBOO_MAX_BODY_SIZE BAMBOO_F2B_IGNOREIP BAMBOO_CERTBOT_EXTRA_ARGS BAMBOO_PUBLIC_IP BAMBOO_OS_UPGRADE BAMBOO_SWAP BAMBOO_SWAP_FILE'

config_get() {
    # config_get <KEY> — prints the stored value (empty when unset).
    local key="$1" line=''
    [ -f "$BAMBOO_CONFIG_FILE" ] || return 0
    line="$(grep -E "^${key}=" "$BAMBOO_CONFIG_FILE" 2>/dev/null | tail -n 1)" || line=''
    [ -n "$line" ] || return 0
    printf '%s' "${line#*=}"
}

config_set() {
    # config_set <KEY> <value> — updates in place, appending when absent.
    local key="$1" value="$2"
    if bamboo_is_dry_run; then
        log_info "[dry-run] would set $key in $BAMBOO_CONFIG_FILE"
        return 0
    fi
    bamboo_assert_dir_writable "$(dirname "$BAMBOO_CONFIG_FILE")"
    [ -f "$BAMBOO_CONFIG_FILE" ] || : >"$BAMBOO_CONFIG_FILE"
    local tmp="$BAMBOO_CONFIG_FILE.tmp.$$"
    if awk -v k="$key" -v v="$value" '
        BEGIN { done = 0 }
        index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$BAMBOO_CONFIG_FILE" >"$tmp"; then
        mv -f "$tmp" "$BAMBOO_CONFIG_FILE" || { rm -f "$tmp"; die "Unable to write $BAMBOO_CONFIG_FILE"; }
        bamboo_chmod 0644 "$BAMBOO_CONFIG_FILE" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp"
    die "Unable to update $BAMBOO_CONFIG_FILE"
}

config_init_defaults() {
    # Creates the config file with defaults; on an existing file only missing
    # keys are appended, so user edits survive re-running `install`.
    local key defaults
    defaults="$(cat <<'EOF'
BAMBOO_DEFAULT_EMAIL=
BAMBOO_SSL_WWW=auto
BAMBOO_MAX_BODY_SIZE=64m
BAMBOO_F2B_IGNOREIP=
BAMBOO_CERTBOT_EXTRA_ARGS=
BAMBOO_PUBLIC_IP=
BAMBOO_OS_UPGRADE=auto
BAMBOO_SWAP=auto
BAMBOO_SWAP_FILE=/swapfile
EOF
)"
    if [ ! -f "$BAMBOO_CONFIG_FILE" ]; then
        if bamboo_is_dry_run; then
            log_info "[dry-run] would create $BAMBOO_CONFIG_FILE"
            return 0
        fi
        bamboo_assert_dir_writable "$(dirname "$BAMBOO_CONFIG_FILE")"
        {
            printf '# Bamboo-Site configuration — managed by the tool, safe to edit.\n'
            printf '#\n'
            printf '# BAMBOO_DEFAULT_EMAIL       Contact email registered with Let'\''s Encrypt.\n'
            printf '# BAMBOO_SSL_WWW             Include www.<domain> in certificates: auto | yes | no\n'
            printf '# BAMBOO_MAX_BODY_SIZE       Default client_max_body_size for new sites.\n'
            printf '# BAMBOO_F2B_IGNOREIP        Extra IPs/CIDRs never banned, space separated.\n'
            printf '# BAMBOO_CERTBOT_EXTRA_ARGS  Extra arguments appended to every certbot run.\n'
            printf '# BAMBOO_PUBLIC_IP           Override the auto-detected public IP.\n'
            printf '# BAMBOO_OS_UPGRADE          Upgrade the OS during install: auto | full | no\n'
            printf '# BAMBOO_SWAP                Create a swap file when there is none: auto | no | 1G | 512M\n'
            printf '# BAMBOO_SWAP_FILE           Swap file path (default /swapfile).\n'
            printf '\n'
            printf '%s\n' "$defaults"
        } | atomic_write "$BAMBOO_CONFIG_FILE"
        bamboo_chmod 0644 "$BAMBOO_CONFIG_FILE" 2>/dev/null || true
        return 0
    fi
    # Append any key that is missing, preserving existing values.
    for key in $BAMBOO_CONFIG_KEYS; do
        if ! grep -Eq "^${key}=" "$BAMBOO_CONFIG_FILE" 2>/dev/null; then
            config_set "$key" ''
        fi
    done
    return 0
}

# The values assigned here are consumed by lib/nginx.sh and lib/fail2ban.sh.
# shellcheck disable=SC2034
config_apply() {
    # Fills values the environment did not provide from the config file.
    local value=''
    if [ -z "$BAMBOO_MAX_BODY_SIZE_ENV" ]; then
        value="$(config_get BAMBOO_MAX_BODY_SIZE)"
        [ -n "$value" ] && BAMBOO_MAX_BODY_SIZE="$value"
    fi
    if [ -z "$BAMBOO_CERTBOT_EXTRA_ARGS_ENV" ]; then
        value="$(config_get BAMBOO_CERTBOT_EXTRA_ARGS)"
        [ -n "$value" ] && BAMBOO_CERTBOT_EXTRA_ARGS="$value"
    fi
    if [ -z "$BAMBOO_SSL_WWW_ENV" ]; then
        value="$(config_get BAMBOO_SSL_WWW)"
        [ -n "$value" ] && BAMBOO_SSL_WWW="$value"
    fi
    if [ -z "$BAMBOO_F2B_IGNOREIP_ENV" ]; then
        value="$(config_get BAMBOO_F2B_IGNOREIP)"
        [ -n "$value" ] && BAMBOO_F2B_IGNOREIP="$value"
    fi
    if [ -z "$BAMBOO_DEFAULT_EMAIL" ]; then
        value="$(config_get BAMBOO_DEFAULT_EMAIL)"
        [ -n "$value" ] && BAMBOO_DEFAULT_EMAIL="$value"
    fi
    if [ -z "$BAMBOO_PUBLIC_IP" ]; then
        value="$(config_get BAMBOO_PUBLIC_IP)"
        [ -n "$value" ] && BAMBOO_PUBLIC_IP="$value"
    fi
    if [ -z "$BAMBOO_OS_UPGRADE_ENV" ]; then
        value="$(config_get BAMBOO_OS_UPGRADE)"
        [ -n "$value" ] && BAMBOO_OS_UPGRADE="$value"
    fi
    if [ -z "$BAMBOO_SWAP_ENV" ]; then
        value="$(config_get BAMBOO_SWAP)"
        [ -n "$value" ] && BAMBOO_SWAP="$value"
    fi
    if [ -z "$BAMBOO_SWAP_FILE_ENV" ]; then
        value="$(config_get BAMBOO_SWAP_FILE)"
        [ -n "$value" ] && BAMBOO_SWAP_FILE="$value"
    fi
    return 0
}
