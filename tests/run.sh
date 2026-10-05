#!/usr/bin/env bash
#
# Bamboo-Site test suite.
#
# Dependency-free: bash + coreutils only, no bats, no Docker, no nginx. The
# whole CLI is exercised against a throwaway root directory with BAMBOO_TEST_MODE
# replacing the external commands (see lib/testmode.sh).
#
#   bash tests/run.sh              # everything
#   bash tests/run.sh nginx        # only files matching "nginx"

set -uo pipefail

TESTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAMBOO_ROOT="$(dirname "$TESTS_DIR")"
export BAMBOO_ROOT

FILTER="${1:-}"

if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
else
    C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW=''
fi

# ---------------------------------------------------------------------------
# Test-mode environment
# ---------------------------------------------------------------------------

export BAMBOO_TEST_MODE=1
export BAMBOO_ASSUME_YES=1
export BAMBOO_TEST_PUBLIC_IP='203.0.113.10'

# The CLI already ships its own test seam; load the same libraries in-process so
# individual functions can be tested directly.
for _lib in common config os firewall workspace nginx ssl fail2ban testmode; do
    # shellcheck source=/dev/null
    . "$BAMBOO_ROOT/lib/$_lib.sh"
done
unset _lib

# Rebuild the sandbox root. Called before every test so tests are independent.
fresh_root() {
    bamboo_cleanup_tmpdir 2>/dev/null || true
    if [ -n "${TEST_ROOT:-}" ] && [ -d "${TEST_ROOT:-}" ]; then
        rm -rf "$TEST_ROOT"
    fi
    TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bamboo-test.XXXXXX")"
    export TEST_ROOT

    export BAMBOO_WWW_DIR="$TEST_ROOT/var/www"
    export BAMBOO_ETC_DIR="$TEST_ROOT/etc/bamboo-site"
    export BAMBOO_CONFIG_FILE="$BAMBOO_ETC_DIR/config"
    export BAMBOO_NGINX_AVAILABLE="$TEST_ROOT/etc/nginx/sites-available"
    export BAMBOO_NGINX_ENABLED="$TEST_ROOT/etc/nginx/sites-enabled"
    export BAMBOO_NGINX_CONFD="$TEST_ROOT/etc/nginx/conf.d"
    export BAMBOO_NGINX_LIMITS_FILE="$BAMBOO_NGINX_CONFD/bamboo-limits.conf"
    export BAMBOO_LETSENCRYPT_DIR="$TEST_ROOT/etc/letsencrypt"
    export BAMBOO_LETSENCRYPT_LIVE="$BAMBOO_LETSENCRYPT_DIR/live"
    export BAMBOO_LETSENCRYPT_HOOKS="$BAMBOO_LETSENCRYPT_DIR/renewal-hooks/deploy"
    export BAMBOO_F2B_DIR="$TEST_ROOT/etc/fail2ban"
    export BAMBOO_F2B_JAILD="$BAMBOO_F2B_DIR/jail.d"
    export BAMBOO_F2B_FILTERD="$BAMBOO_F2B_DIR/filter.d"
    export BAMBOO_LOG_FILE="$TEST_ROOT/var/log/bamboo-site.log"
    export BAMBOO_LOCK_FILE="$TEST_ROOT/var/lock/bamboo-site.lock"
    export BAMBOO_TEST_CMD_LOG="$TEST_ROOT/cmd.log"
    export BAMBOO_TEST_NGINX_TEST_FAIL_FILE="$TEST_ROOT/nginx-test-fail"
    export BAMBOO_TEST_F2B_FAIL_FILE="$TEST_ROOT/f2b-fail"
    export BAMBOO_TMPDIR=''

    # TEST_NO_DNS=1 simulates a name with no A record; TEST_DNS_A overrides the
    # address DNS answers with. TEST_NO_DNS is consumed by this call so the next
    # sandbox starts from the normal "DNS matches" default again.
    if [ "${TEST_NO_DNS:-0}" = '1' ]; then
        export BAMBOO_TEST_DNS_A=''
        TEST_NO_DNS=0
    else
        export BAMBOO_TEST_DNS_A="${TEST_DNS_A:-203.0.113.10}"
    fi
    export BAMBOO_TEST_CERTBOT_RESULT="${TEST_CERTBOT_RESULT:-0}"
    export BAMBOO_TEST_CERTBOT_OUTPUT="${TEST_CERTBOT_OUTPUT:-}"

    mkdir -p "$BAMBOO_WWW_DIR" "$BAMBOO_ETC_DIR" "$TEST_ROOT/var/log"
    : >"$BAMBOO_TEST_CMD_LOG"
    return 0
}

# Used by the test_cli.sh cases.
# shellcheck disable=SC2034
BAMBOO_TEST_BIN="$BAMBOO_ROOT/bin/bamboo-site"

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

_TESTS_PASSED=0
_TESTS_FAILED=0
_OUT=''
_RC=0

pass() {
    _TESTS_PASSED=$((_TESTS_PASSED + 1))
    printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

fail() {
    _TESTS_FAILED=$((_TESTS_FAILED + 1))
    printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1"
}

assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 — expected '$1', got '$2'"
    fi
}

assert_rc() {
    if [ "$1" -eq "$2" ]; then
        pass "$3"
    else
        fail "$3 — expected exit $1, got $2 (output: $(_first_line "$_OUT"))"
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) pass "$3" ;;
        *) fail "$3 — output does not contain '$2' (output: $(_first_line "$1"))" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "$3 — output unexpectedly contains '$2'" ;;
        *) pass "$3" ;;
    esac
}

assert_file_exists() {
    if [ -f "$1" ]; then pass "$2"; else fail "$2 — missing file: $1"; fi
}

assert_file_missing() {
    if [ -e "$1" ]; then fail "$2 — file should not exist: $1"; else pass "$2"; fi
}

assert_dir_exists() {
    if [ -d "$1" ]; then pass "$2"; else fail "$2 — missing directory: $1"; fi
}

assert_dir_missing() {
    if [ -e "$1" ]; then fail "$2 — directory should not exist: $1"; else pass "$2"; fi
}

assert_symlink_to() {
    if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then
        pass "$3"
    else
        fail "$3 — expected symlink $1 -> $2 (found: $(_link_state "$1"))"
    fi
}

assert_file_contains() {
    if [ -f "$1" ] && grep -q -- "$2" "$1" 2>/dev/null; then
        pass "$3"
    else
        fail "$3 — $1 does not contain '$2'"
    fi
}

assert_file_contains_fixed() {
    if [ -f "$1" ] && grep -qF -- "$2" "$1" 2>/dev/null; then
        pass "$3"
    else
        fail "$3 — $1 does not contain '$2'"
    fi
}

assert_file_not_contains() {
    if [ -f "$1" ] && grep -q -- "$2" "$1" 2>/dev/null; then
        fail "$3 — $1 unexpectedly contains '$2'"
    else
        pass "$3"
    fi
}

_first_line() {
    printf '%s' "$1" | head -n 2 | tr '\n' ' '
}

_link_state() {
    if [ -L "$1" ]; then
        printf 'symlink -> %s' "$(readlink "$1")"
    elif [ -e "$1" ]; then
        printf 'regular file'
    else
        printf 'nothing'
    fi
}

# Runs a function or binary in a subshell: OUT + RC are set, the harness is
# never killed by a `die` inside the command under test.
capture() {
    OUT="$("$@" </dev/null 2>&1)" && RC=0 || RC=$?
    _OUT="$OUT"
    _RC="$RC"
    return 0
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

run_test() {
    local fn="$1"
    printf '\n%s%s%s\n' "$C_BOLD" "$fn" "$C_RESET"
    # Reset the per-test knobs before the sandbox is rebuilt.
    TEST_DNS_A=''
    TEST_NO_DNS=0
    TEST_CERTBOT_RESULT=''
    TEST_CERTBOT_OUTPUT=''
    fresh_root
    "$fn"
    return 0
}

main() {
    printf '%sBamboo-Site test suite%s\n' "$C_BOLD" "$C_RESET"
    printf 'root: %s\n' "$BAMBOO_ROOT"

    local file
    # Every file is always sourced so the function-name filter below can see all
    # test functions; the filter selects functions, not files.
    for file in "$TESTS_DIR"/test_*.sh; do
        [ -f "$file" ] || continue
        printf '\n\n%s== %s ==%s\n' "$C_YELLOW" "${file##*/}" "$C_RESET"
        # shellcheck source=/dev/null
        . "$file"
    done

    local fn
    for fn in $(declare -F | awk '{print $NF}' | grep '^test_' | sort); do
        if [ -n "$FILTER" ]; then
            case "$fn" in
                *"$FILTER"*) ;;
                *) continue ;;
            esac
        fi
        run_test "$fn"
    done

    printf '\n\n%s== Summary ==%s\n' "$C_YELLOW" "$C_RESET"
    printf '  passed: %s%d%s\n' "$C_GREEN" "$_TESTS_PASSED" "$C_RESET"
    if [ "$_TESTS_FAILED" -gt 0 ]; then
        printf '  failed: %s%d%s\n' "$C_RED" "$_TESTS_FAILED" "$C_RESET"
    else
        printf '  failed: %d\n' "$_TESTS_FAILED"
    fi

    if [ -n "${TEST_ROOT:-}" ] && [ -d "$TEST_ROOT" ]; then
        rm -rf "$TEST_ROOT"
    fi
    bamboo_cleanup_tmpdir 2>/dev/null || true

    [ "$_TESTS_FAILED" -eq 0 ]
}

main
