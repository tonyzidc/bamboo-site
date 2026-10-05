#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — shared helpers.
#
# Provides logging, guards, prompts, domain validation, template rendering,
# filesystem helpers and thin wrappers around every external binary the tool
# needs. Sourced by bin/bamboo-site and by the test harness.
#
# Two environment switches matter everywhere in this file:
#
#   BAMBOO_DRY_RUN=1   print what would happen, mutate nothing.
#   BAMBOO_TEST_MODE=1 load lib/testmode.sh after this file to replace the
#                      external-command wrappers with stubs, so the full CLI
#                      can run on a machine without nginx/certbot/fail2ban.
#
# Must stay bash 3.2 compatible (macOS ships 3.2, the test suite runs there).

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'lib/common.sh is a library and must be sourced, not executed.\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Identity and root directory (resolved through symlinks)
# ---------------------------------------------------------------------------

bamboo_resolve_root() {
    local src="$1" dir
    while [ -L "$src" ]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        case "$src" in
            /*) ;;
            *) src="$dir/$src" ;;
        esac
    done
    cd -P "$(dirname "$src")" && pwd
}

if [ -z "${BAMBOO_ROOT:-}" ]; then
    _bamboo_lib_dir="$(bamboo_resolve_root "${BASH_SOURCE[0]}")"
    BAMBOO_ROOT="$(dirname "$_bamboo_lib_dir")"
    unset _bamboo_lib_dir
fi

BAMBOO_PROG_NAME="${BAMBOO_PROG_NAME:-bamboo-site}"
BAMBOO_REPO="${BAMBOO_REPO:-tonyzidc/bamboo-site}"
# Printed by the install/help commands.
# shellcheck disable=SC2034
BAMBOO_REPO_URL="https://github.com/$BAMBOO_REPO"
BAMBOO_VERSION="unknown"
if [ -r "$BAMBOO_ROOT/VERSION" ]; then
    BAMBOO_VERSION="$(tr -d '[:space:]' <"$BAMBOO_ROOT/VERSION")"
fi
[ -n "$BAMBOO_VERSION" ] || BAMBOO_VERSION="unknown"

# ---------------------------------------------------------------------------
# Paths — every system location is overridable so the CLI can run against a
# temporary root in the test suite (see docs/ARCHITECTURE.md).
# ---------------------------------------------------------------------------

BAMBOO_ETC_DIR="${BAMBOO_ETC_DIR:-/etc/bamboo-site}"
BAMBOO_CONFIG_FILE="${BAMBOO_CONFIG_FILE:-$BAMBOO_ETC_DIR/config}"
BAMBOO_WWW_DIR="${BAMBOO_WWW_DIR:-/var/www}"
BAMBOO_INSTALL_DIR="${BAMBOO_INSTALL_DIR:-/opt/bamboo-site}"
BAMBOO_BIN_DIR="${BAMBOO_BIN_DIR:-/usr/local/bin}"
BAMBOO_LOG_FILE="${BAMBOO_LOG_FILE:-/var/log/bamboo-site.log}"
BAMBOO_LOCK_FILE="${BAMBOO_LOCK_FILE:-/var/lock/bamboo-site.lock}"

BAMBOO_NGINX_AVAILABLE="${BAMBOO_NGINX_AVAILABLE:-/etc/nginx/sites-available}"
BAMBOO_NGINX_ENABLED="${BAMBOO_NGINX_ENABLED:-/etc/nginx/sites-enabled}"
BAMBOO_NGINX_CONFD="${BAMBOO_NGINX_CONFD:-/etc/nginx/conf.d}"
BAMBOO_NGINX_LIMITS_FILE="${BAMBOO_NGINX_LIMITS_FILE:-$BAMBOO_NGINX_CONFD/bamboo-limits.conf}"

BAMBOO_LETSENCRYPT_DIR="${BAMBOO_LETSENCRYPT_DIR:-/etc/letsencrypt}"
BAMBOO_LETSENCRYPT_LIVE="${BAMBOO_LETSENCRYPT_LIVE:-$BAMBOO_LETSENCRYPT_DIR/live}"
BAMBOO_LETSENCRYPT_HOOKS="${BAMBOO_LETSENCRYPT_HOOKS:-$BAMBOO_LETSENCRYPT_DIR/renewal-hooks/deploy}"

BAMBOO_F2B_DIR="${BAMBOO_F2B_DIR:-/etc/fail2ban}"
BAMBOO_F2B_JAILD="${BAMBOO_F2B_JAILD:-$BAMBOO_F2B_DIR/jail.d}"
BAMBOO_F2B_FILTERD="${BAMBOO_F2B_FILTERD:-$BAMBOO_F2B_DIR/filter.d}"

BAMBOO_WEB_USER="${BAMBOO_WEB_USER:-www-data}"
BAMBOO_WEB_GROUP="${BAMBOO_WEB_GROUP:-www-data}"
BAMBOO_LOG_GROUP="${BAMBOO_LOG_GROUP:-adm}"
BAMBOO_SSH_SERVICE="${BAMBOO_SSH_SERVICE:-ssh}"

# Runtime switches recorded before defaults are applied, so a value from the
# config file can fill in only what the environment did not already set.
# shellcheck disable=SC2034
BAMBOO_MAX_BODY_SIZE_ENV="${BAMBOO_MAX_BODY_SIZE:-}"
# shellcheck disable=SC2034
BAMBOO_CERTBOT_EXTRA_ARGS_ENV="${BAMBOO_CERTBOT_EXTRA_ARGS:-}"
# shellcheck disable=SC2034
BAMBOO_SSL_WWW_ENV="${BAMBOO_SSL_WWW:-}"
# shellcheck disable=SC2034
BAMBOO_F2B_IGNOREIP_ENV="${BAMBOO_F2B_IGNOREIP:-}"

BAMBOO_MAX_BODY_SIZE="${BAMBOO_MAX_BODY_SIZE:-64m}"
BAMBOO_CERTBOT_EXTRA_ARGS="${BAMBOO_CERTBOT_EXTRA_ARGS:-}"
BAMBOO_SSL_WWW="${BAMBOO_SSL_WWW:-auto}"
BAMBOO_F2B_IGNOREIP="${BAMBOO_F2B_IGNOREIP:-}"
BAMBOO_DEFAULT_EMAIL="${BAMBOO_DEFAULT_EMAIL:-}"
BAMBOO_PUBLIC_IP="${BAMBOO_PUBLIC_IP:-}"
BAMBOO_EDITOR="${BAMBOO_EDITOR:-}"

BAMBOO_DRY_RUN="${BAMBOO_DRY_RUN:-0}"
BAMBOO_ASSUME_YES="${BAMBOO_ASSUME_YES:-0}"
BAMBOO_VERBOSE="${BAMBOO_VERBOSE:-0}"
BAMBOO_NO_COLOR="${BAMBOO_NO_COLOR:-0}"
BAMBOO_TEST_MODE="${BAMBOO_TEST_MODE:-0}"
BAMBOO_FORCE="${BAMBOO_FORCE:-0}"

# Test-mode knobs read by lib/testmode.sh.
BAMBOO_TEST_DNS_A="${BAMBOO_TEST_DNS_A:-}"
BAMBOO_TEST_PUBLIC_IP="${BAMBOO_TEST_PUBLIC_IP:-203.0.113.10}"
BAMBOO_TEST_CERTBOT_RESULT="${BAMBOO_TEST_CERTBOT_RESULT:-0}"
BAMBOO_TEST_CERTBOT_OUTPUT="${BAMBOO_TEST_CERTBOT_OUTPUT:-}"
BAMBOO_TEST_OS_ID="${BAMBOO_TEST_OS_ID:-ubuntu}"
BAMBOO_TEST_OS_VERSION="${BAMBOO_TEST_OS_VERSION:-22.04}"

# ---------------------------------------------------------------------------
# Colours — only when stdout is a terminal, so piped/captured output is clean.
# Re-run bamboo_init_colors() after parsing flags (--no-color).
# ---------------------------------------------------------------------------

bamboo_init_colors() {
    if [ "$BAMBOO_NO_COLOR" = "1" ] || [ ! -t 1 ]; then
        C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_MAGENTA=''
    else
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'
        C_MAGENTA=$'\033[35m'
        C_CYAN=$'\033[36m'
    fi
    return 0
}

bamboo_init_colors

# ---------------------------------------------------------------------------
# Logging — everything except command data goes to stderr.
# ---------------------------------------------------------------------------

log_step()     { printf '\n%s==>%s %s%s%s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; }
log_info()     { printf '  %s%s%s\n' "$C_CYAN" "$*" "$C_RESET" >&2; }
log_ok()       { printf '  %s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
log_warn()     { printf '  %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()    { printf '  %s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_hint()     { printf '  %s->%s %s\n' "$C_MAGENTA" "$C_RESET" "$*" >&2; }
log_debug() {
    [ "$BAMBOO_VERBOSE" = "1" ] || return 0
    printf '  %s[debug] %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2
}
die() {
    log_error "$*"
    exit 1
}
bamboo_is_dry_run() { [ "$BAMBOO_DRY_RUN" = "1" ]; }

bamboo_oplog() {
    [ -n "$BAMBOO_LOG_FILE" ] || return 0
    if bamboo_is_dry_run; then
        log_debug "[dry-run] log: $*"
        return 0
    fi
    local dir
    dir="$(dirname "$BAMBOO_LOG_FILE")"
    [ -d "$dir" ] && [ -w "$dir" ] || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$BAMBOO_PROG_NAME" "$*" >>"$BAMBOO_LOG_FILE" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# Command wrappers — the single seam the test suite replaces. Every external
# binary goes through one of these; nothing else calls system tools directly.
# ---------------------------------------------------------------------------

bamboo_run() {
    if bamboo_is_dry_run; then
        log_info "[dry-run] $*"
        return 0
    fi
    log_debug "+ $*"
    "$@"
}

bamboo_try() {
    # Run a command, capturing combined output, without ever failing the
    # caller. Result lands in BAMBOO_LAST_OUTPUT / BAMBOO_LAST_STATUS.
    local saved_trap='' errexit_was_on=0
    case "$-" in
        *e*) errexit_was_on=1 ;;
    esac
    saved_trap="$(trap -p ERR 2>/dev/null || true)"
    trap - ERR
    set +e
    BAMBOO_LAST_OUTPUT="$("$@" 2>&1)"
    BAMBOO_LAST_STATUS=$?
    [ "$errexit_was_on" = "1" ] && set -e
    if [ -n "$saved_trap" ]; then
        eval "$saved_trap"
    fi
    return 0
}

bamboo_need_cmd() { command -v "$1" >/dev/null 2>&1; }

bamboo_own()          { chown "$@"; }
bamboo_chmod()        { chmod "$@"; }
bamboo_systemctl()    { systemctl "$@"; }
bamboo_nginx_bin()    { nginx "$@"; }
bamboo_certbot()      { certbot "$@"; }
bamboo_f2b_client()   { fail2ban-client "$@"; }
bamboo_ufw()          { ufw "$@"; }
bamboo_apt_get()      { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 "$@"; }
bamboo_pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
bamboo_service_is_active() { systemctl is-active --quiet "$1"; }

bamboo_os_release_field() {
    # bamboo_os_release_field <FIELD> — e.g. ID, VERSION_ID
    local field="$1"
    if [ ! -r /etc/os-release ]; then
        printf ''
        return 0
    fi
    # shellcheck disable=SC1091
    ( . /etc/os-release 2>/dev/null; eval "printf '%s' \"\${$field:-}\"" ) 2>/dev/null || printf ''
}

bamboo_service_reload() {
    local svc="$1"
    if bamboo_is_dry_run; then
        log_info "[dry-run] systemctl reload $svc"
        return 0
    fi
    log_debug "systemctl reload $svc"
    bamboo_systemctl reload "$svc"
}

bamboo_service_restart() {
    local svc="$1"
    if bamboo_is_dry_run; then
        log_info "[dry-run] systemctl restart $svc"
        return 0
    fi
    log_debug "systemctl restart $svc"
    bamboo_systemctl restart "$svc"
}

bamboo_service_enable_now() {
    local svc="$1"
    if bamboo_is_dry_run; then
        log_info "[dry-run] systemctl enable --now $svc"
        return 0
    fi
    log_debug "systemctl enable --now $svc"
    bamboo_systemctl enable --now "$svc"
}

bamboo_nginx_test() {
    # Runs `nginx -t`, printing the output on failure. Returns nginx's status.
    if bamboo_is_dry_run; then
        # nginx may not even be installed yet during a dry-run install.
        log_debug '[dry-run] nginx -t'
        return 0
    fi
    bamboo_try bamboo_nginx_bin -t
    if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
        printf '%s\n' "$BAMBOO_LAST_OUTPUT" | while IFS= read -r line; do
            printf '  %s%s%s\n' "$C_DIM" "$line" "$C_RESET" >&2
        done
        return 1
    fi
    log_debug "$BAMBOO_LAST_OUTPUT"
    return 0
}

bamboo_dns_a() {
    # Prints the A records of a name, one per line (empty when none).
    local name="$1"
    if [ -z "$name" ]; then
        return 0
    fi
    if bamboo_need_cmd dig; then
        dig +short A "$name" 2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true
    elif bamboo_need_cmd getent; then
        getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u || true
    fi
    return 0
}

bamboo_public_ip() {
    if [ -n "$BAMBOO_PUBLIC_IP" ]; then
        printf '%s' "$BAMBOO_PUBLIC_IP"
        return 0
    fi
    local ip=''
    if bamboo_need_cmd curl; then
        ip="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    fi
    if [ -z "$ip" ] && bamboo_need_cmd ip; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit }}')"
    fi
    printf '%s' "$ip"
}

bamboo_path_mtime() {
    local path="$1" out=''
    out="$(stat -c '%y' "$path" 2>/dev/null | cut -d' ' -f1)" || out=''
    if [ -z "$out" ]; then
        out="$(stat -f '%Sm' -t '%Y-%m-%d' "$path" 2>/dev/null)" || out=''
    fi
    [ -n "$out" ] || out='?'
    printf '%s' "$out"
}

bamboo_dir_size() {
    local out=''
    out="$(du -sh "$1" 2>/dev/null | cut -f1)" || out=''
    [ -n "$out" ] || out='-'
    printf '%s' "$out"
}

bamboo_version_ge() {
    # Exit 0 when dotted version $1 >= $2.
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, A, "."); m = split(b, B, ".")
        len = (n > m) ? n : m
        for (i = 1; i <= len; i++) {
            x = (i <= n) ? A[i] + 0 : 0
            y = (i <= m) ? B[i] + 0 : 0
            if (x > y) exit 0
            if (x < y) exit 1
        }
        exit 0
    }'
}

# ---------------------------------------------------------------------------
# Guard rails
# ---------------------------------------------------------------------------

require_root() {
    [ "$BAMBOO_TEST_MODE" = "1" ] && return 0
    if [ "$(id -u)" -ne 0 ]; then
        die "This command needs root privileges. Re-run it as: sudo $BAMBOO_PROG_NAME ${BAMBOO_CURRENT_COMMAND:-<command>}"
    fi
    return 0
}

require_core_installed() {
    [ "$BAMBOO_TEST_MODE" = "1" ] && return 0
    local missing='' cmd
    for cmd in nginx certbot; do
        if ! bamboo_need_cmd "$cmd"; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        die "Missing required components:$missing. Run 'sudo $BAMBOO_PROG_NAME install' first."
    fi
    return 0
}

require_workspace() {
    local domain="$1"
    if ! workspace_exists "$domain"; then
        die "'$domain' is not managed by $BAMBOO_PROG_NAME (no workspace at $(workspace_dir "$domain")). Run 'sudo $BAMBOO_PROG_NAME add $domain' first."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

bamboo_confirm() {
    # Returns 0 for yes. --yes auto-confirms; without a terminal it refuses
    # instead of hanging in a pipeline.
    local prompt="$1" reply=''
    if [ "$BAMBOO_ASSUME_YES" = '1' ]; then
        log_info "auto-confirmed (--yes): $prompt"
        return 0
    fi
    if [ ! -t 0 ]; then
        log_error "No terminal available to answer: $prompt"
        log_hint "Re-run with --yes to proceed non-interactively."
        return 1
    fi
    printf '%s%s%s [y/N] ' "$C_BOLD" "$prompt" "$C_RESET" >&2
    read -r reply || return 1
    case "$reply" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Domain handling
# ---------------------------------------------------------------------------

BAMBOO_DOMAIN_REGEX='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

bamboo_normalize_domain() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\.$//'
}

is_valid_domain() {
    local domain="$1"
    [ -n "$domain" ] || return 1
    [ "${#domain}" -le 253 ] || return 1
    case "$domain" in
        *..*|*/*|*:*|*' '*|*'*'*|*'?'*|*'['*) return 1 ;;
    esac
    printf '%s' "$domain" | grep -Eq "$BAMBOO_DOMAIN_REGEX"
}

bamboo_require_domain() {
    local raw="$1" domain
    domain="$(bamboo_normalize_domain "$raw")"
    if ! is_valid_domain "$domain"; then
        die "Invalid domain name: '$raw'. Provide a public hostname such as example.com (IP addresses, ports and wildcards are not supported)."
    fi
    printf '%s' "$domain"
}

bamboo_resolve_email() {
    # Precedence: explicit argument > BAMBOO_DEFAULT_EMAIL/config > interactive
    # prompt > empty (caller then uses certbot's no-email registration).
    local email="${1:-}" reply=''
    if [ -n "$email" ]; then
        printf '%s' "$email"
        return 0
    fi
    if [ -n "$BAMBOO_DEFAULT_EMAIL" ]; then
        printf '%s' "$BAMBOO_DEFAULT_EMAIL"
        return 0
    fi
    if [ -t 0 ] && [ "$BAMBOO_ASSUME_YES" != "1" ]; then
        printf '%s' "Email for Let's Encrypt renewal notices (blank to skip): " >&2
        read -r reply || reply=''
        case "$reply" in
            *@*.*) printf '%s' "$reply"; return 0 ;;
            '') ;;
            *) log_warn "That does not look like an email address; continuing without one." >&2 ;;
        esac
    fi
    printf ''
}

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------

bamboo_ensure_tmpdir() {
    if [ -z "${BAMBOO_TMPDIR:-}" ] || [ ! -d "${BAMBOO_TMPDIR:-}" ]; then
        BAMBOO_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/bamboo-site.XXXXXX")" || die 'Unable to create a temporary directory'
        export BAMBOO_TMPDIR
    fi
    return 0
}

bamboo_cleanup_tmpdir() {
    if [ -n "${BAMBOO_TMPDIR:-}" ] && [ -d "${BAMBOO_TMPDIR:-}" ]; then
        rm -rf "$BAMBOO_TMPDIR"
    fi
    BAMBOO_TMPDIR=''
    return 0
}

atomic_write() {
    # atomic_write <path>   (content on stdin)
    local dest="$1" dir tmp
    dir="$(dirname "$dest")"
    if bamboo_is_dry_run; then
        cat >/dev/null
        log_info "[dry-run] would write $dest"
        return 0
    fi
    mkdir -p "$dir" || die "Unable to create directory: $dir"
    tmp="$dir/.$(basename "$dest").tmp.$$"
    cat >"$tmp" || { rm -f "$tmp"; die "Unable to write $tmp"; }
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; die "Unable to write $dest"; }
    return 0
}

backup_file() {
    # Copies <path> to <path>.bak.<timestamp> and prints the backup path.
    # Prints nothing (and returns 0) when the source does not exist.
    local src="$1" dest
    [ -e "$src" ] || return 0
    dest="$src.bak.$(date '+%Y%m%d%H%M%S')"
    if bamboo_is_dry_run; then
        log_info "[dry-run] would back up $src"
        printf '%s' "$dest"
        return 0
    fi
    if cp -p "$src" "$dest" 2>/dev/null; then
        log_debug "Backup written: $dest"
        printf '%s' "$dest"
    else
        log_warn "Unable to back up $src (continuing)"
    fi
    return 0
}

render_template() {
    # render_template <template> <destination> [TOKEN=value ...]
    # Replaces @TOKEN@ placeholders. Values must be single-line.
    local tpl="$1" dest="$2"
    shift 2
    [ -f "$tpl" ] || die "Template not found: $tpl"
    if bamboo_is_dry_run; then
        log_info "[dry-run] would render $dest from $(basename "$tpl")"
        return 0
    fi
    bamboo_ensure_tmpdir
    local tmp
    tmp="$(mktemp "$BAMBOO_TMPDIR/render.XXXXXX")" || die 'Unable to create a temporary file'
    cp "$tpl" "$tmp" || die "Unable to read template: $tpl"
    local pair key value escaped
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        escaped="$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')"
        sed -i.bamboo "s|@${key}@|${escaped}|g" "$tmp" || die "Failed to render @${key}@ in $tpl"
        rm -f "$tmp.bamboo"
    done
    mkdir -p "$(dirname "$dest")" || die "Unable to create directory: $(dirname "$dest")"
    mv -f "$tmp" "$dest" || die "Unable to write $dest"
    return 0
}

bamboo_assert_dir_writable() {
    local dir="$1"
    mkdir -p "$dir" 2>/dev/null || die "Unable to create directory: $dir"
    [ -w "$dir" ] || die "Directory is not writable: $dir"
    return 0
}

# ---------------------------------------------------------------------------
# Concurrency lock — one mutating run at a time.
# ---------------------------------------------------------------------------

BAMBOO_LOCK_HELD=0

bamboo_acquire_lock() {
    if bamboo_is_dry_run || [ "$BAMBOO_TEST_MODE" = '1' ]; then
        return 0
    fi
    local dir
    dir="$(dirname "$BAMBOO_LOCK_FILE")"
    mkdir -p "$dir" 2>/dev/null || return 0

    if bamboo_need_cmd flock; then
        exec 9>"$BAMBOO_LOCK_FILE" || die "Unable to create the lock file $BAMBOO_LOCK_FILE"
        if ! flock -n 9; then
            die "Another $BAMBOO_PROG_NAME run is in progress (lock: $BAMBOO_LOCK_FILE)."
        fi
    else
        if ! mkdir "$BAMBOO_LOCK_FILE.d" 2>/dev/null; then
            die "Another $BAMBOO_PROG_NAME run is in progress (lock: $BAMBOO_LOCK_FILE.d)."
        fi
    fi
    BAMBOO_LOCK_HELD=1
    log_debug "Lock acquired: $BAMBOO_LOCK_FILE"
    return 0
}

bamboo_release_lock() {
    [ "$BAMBOO_LOCK_HELD" = '1' ] || return 0
    if [ -d "$BAMBOO_LOCK_FILE.d" ]; then
        rmdir "$BAMBOO_LOCK_FILE.d" 2>/dev/null || true
    fi
    BAMBOO_LOCK_HELD=0
    return 0
}
