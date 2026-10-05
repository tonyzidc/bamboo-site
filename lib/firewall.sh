#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — UFW firewall integration.
#
# The golden rule: never enable UFW before the SSH port is allowed, otherwise
# the operator is locked out of the server.

fw_detect_ssh_ports() {
    # Prints a space-separated list of SSH ports.
    if [ "$BAMBOO_TEST_MODE" = "1" ]; then
        printf '%s' "${BAMBOO_TEST_SSH_PORTS:-22}"
        return 0
    fi
    local ports=''
    if bamboo_need_cmd sshd; then
        ports="$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" { print $2 }' | sort -u | tr '\n' ' ')" || ports=''
    fi
    if [ -z "$ports" ] && [ -r /etc/ssh/sshd_config ]; then
        ports="$(awk 'tolower($1) == "port" { print $2 }' /etc/ssh/sshd_config 2>/dev/null | sort -u | tr '\n' ' ')" || ports=''
    fi
    ports="$(printf '%s' "$ports" | sed -e 's/[[:space:]]*$//')"
    [ -n "$ports" ] || ports='22'
    printf '%s' "$ports"
}

fw_is_active() {
    local out=''
    out="$(bamboo_ufw status 2>/dev/null | head -n 1)" || out=''
    # Match the exact prefix: "Status: inactive" must not look active.
    case "$out" in
        'Status: active'*) return 0 ;;
        *) return 1 ;;
    esac
}

ufw_rule_present() {
    # True when `ufw status` shows an ALLOW rule for the given TCP port.
    local port="$1" out=''
    out="$(bamboo_ufw status 2>/dev/null)" || out=''
    [ -n "$out" ] || return 1
    printf '%s\n' "$out" | grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW" && return 0
    return 1
}

fw_allow_port() {
    local port="$1" proto="${2:-tcp}"
    if bamboo_is_dry_run; then
        log_info "[dry-run] ufw allow $port/$proto"
        return 0
    fi
    if bamboo_ufw allow "$port/$proto" >/dev/null 2>&1; then
        log_ok "Firewall allows $port/$proto."
    else
        log_warn "Could not add the UFW rule for $port/$proto (is UFW installed?)."
    fi
    return 0
}

fw_configure() {
    # fw_configure [skip] — opens SSH + 80 + 443 and offers to enable UFW.
    local skip="${1:-0}" ssh_ports='' port
    log_step 'Configuring the firewall (UFW)'

    if [ "$skip" = "1" ]; then
        log_warn 'Skipped because --no-ufw was given.'
        return 0
    fi
    if ! bamboo_need_cmd ufw && [ "$BAMBOO_TEST_MODE" != "1" ]; then
        log_warn 'UFW is not installed; skipping firewall configuration.'
        return 0
    fi

    ssh_ports="$(fw_detect_ssh_ports)"
    log_info "SSH port(s) detected: $ssh_ports"
    for port in $ssh_ports; do
        # shellcheck disable=SC2086
        fw_allow_port "$port"
    done
    fw_allow_port 80
    fw_allow_port 443

    if fw_is_active; then
        log_ok 'UFW is already active; rules updated.'
        return 0
    fi

    log_warn 'UFW is inactive. Enabling it now blocks every inbound port except the rules above.'
    if ! bamboo_confirm "Enable UFW now? (SSH stays open on port(s): $ssh_ports)"; then
        log_warn "UFW left disabled. Enable it when ready with: ufw enable"
        return 0
    fi
    if bamboo_is_dry_run; then
        log_info '[dry-run] ufw --force enable'
        return 0
    fi
    if bamboo_ufw --force enable >/dev/null 2>&1; then
        log_ok 'UFW enabled with ports 80, 443 and SSH open.'
    else
        log_warn "Failed to enable UFW — inspect it with 'ufw status'."
    fi
    return 0
}
