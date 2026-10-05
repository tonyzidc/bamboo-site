#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests: domain validation, templating, atomic writes, config file,
# prompts, dry-run behaviour.

test_domain_validation_accepts_valid_names() {
    local d
    for d in example.com sub.example.co.uk a-b.example.io xn--80ak6aa92e.com a1.b2.example.museum; do
        if is_valid_domain "$d"; then
            pass "accepts '$d'"
        else
            fail "should accept '$d'"
        fi
    done
}

test_domain_validation_rejects_invalid_names() {
    local d
    for d in 'example' 'exa mple.com' '-bad.com' 'bad-.com' 'bad..com' 'example.com/' \
        '../etc/passwd' '192.168.1.1' 'example.com;id' 'foo.*.com' 'UPPER.com' '' 'a.b' \
        'example.com:8080' '.example.com' 'a..b.com'; do
        if is_valid_domain "$d"; then
            fail "should reject '$d'"
        else
            pass "rejects '$d'"
        fi
    done
}

test_domain_normalization() {
    assert_eq 'example.com' "$(bamboo_normalize_domain 'Example.COM.')" 'lowercases and strips the trailing dot'
    assert_eq 'example.com' "$(bamboo_normalize_domain '  example.com  ')" 'trims surrounding whitespace'
}

test_require_domain_guards() {
    assert_eq 'example.com' "$(bamboo_require_domain 'Example.COM')" 'normalizes before validating'
    capture bamboo_require_domain 'not a domain'
    assert_rc 1 "$RC" 'rejects invalid input'
    assert_contains "$OUT" 'Invalid domain name' 'explains the rejection'
}

test_render_template_substitutes_tokens() {
    local tpl="$TEST_ROOT/tpl" out="$TEST_ROOT/out"
    printf 'domain=@DOMAIN@ root=@ROOT@ unused=@NOPE@\n' >"$tpl"
    render_template "$tpl" "$out" 'DOMAIN=example.com' 'ROOT=/var/www/example.com'
    assert_file_contains "$out" 'domain=example.com' 'renders @DOMAIN@'
    assert_file_contains "$out" 'root=/var/www/example.com' 'renders @ROOT@'
}

test_render_template_escapes_sed_metacharacters() {
    local tpl="$TEST_ROOT/tpl" out="$TEST_ROOT/out"
    printf 'v=@V@\n' >"$tpl"
    render_template "$tpl" "$out" 'V=A&B|C'
    assert_file_contains_fixed "$out" 'v=A&B|C' 'keeps & and | literal'
    render_template "$tpl" "$out" 'V=back\slash'
    assert_file_contains_fixed "$out" 'v=back\slash' 'keeps backslashes literal'
}

test_render_template_reports_missing_template() {
    capture render_template "$TEST_ROOT/missing.tpl" "$TEST_ROOT/out"
    assert_rc 1 "$RC" 'dies when the template is missing'
    assert_contains "$OUT" 'Template not found' 'explains the missing template'
}

test_atomic_write_behaviour() {
    printf 'hello\n' | atomic_write "$TEST_ROOT/f"
    assert_file_exists "$TEST_ROOT/f" 'creates the file'
    assert_file_contains "$TEST_ROOT/f" 'hello' 'writes the content'
    printf 'world\n' | atomic_write "$TEST_ROOT/f"
    assert_file_contains "$TEST_ROOT/f" 'world' 'replaces the content'
    assert_file_not_contains "$TEST_ROOT/f" 'hello' 'old content is gone'
    local leftovers
    leftovers="$(find "$TEST_ROOT" -name '.*.tmp.*' | wc -l | tr -d ' ')"
    assert_eq '0' "$leftovers" 'leaves no temporary files behind'
}

test_dry_run_writes_nothing() {
    export BAMBOO_DRY_RUN=1
    printf 'x\n' | atomic_write "$TEST_ROOT/nope"
    assert_file_missing "$TEST_ROOT/nope" 'atomic_write writes nothing in dry-run'
    mkdir -p "$TEST_ROOT/tpl.d"
    printf 'a=@A@\n' >"$TEST_ROOT/tpl.d/t"
    render_template "$TEST_ROOT/tpl.d/t" "$TEST_ROOT/rendered" 'A=1'
    assert_file_missing "$TEST_ROOT/rendered" 'render_template writes nothing in dry-run'
    export BAMBOO_DRY_RUN=0
}

test_workspace_path_guard() {
    capture assert_workspace_path "$BAMBOO_WWW_DIR" 'example.com'
    assert_rc 1 "$RC" 'rejects the shared www directory'
    capture assert_workspace_path "$BAMBOO_WWW_DIR/example.com/.." 'example.com'
    assert_rc 1 "$RC" 'rejects traversal'
    capture assert_workspace_path "$BAMBOO_WWW_DIR/other.com" 'example.com'
    assert_rc 1 "$RC" 'rejects a mismatched path'
    capture assert_workspace_path "$BAMBOO_WWW_DIR/example.com" 'bad domain'
    assert_rc 1 "$RC" 'rejects an invalid domain'
    capture assert_workspace_path "$BAMBOO_WWW_DIR/example.com" 'example.com'
    assert_rc 0 "$RC" 'accepts the exact workspace path'
}

test_config_roundtrip() {
    config_init_defaults
    assert_file_exists "$BAMBOO_CONFIG_FILE" 'config_init_defaults creates the file'
    assert_eq 'auto' "$(config_get BAMBOO_SSL_WWW)" 'reads a default'

    config_set BAMBOO_DEFAULT_EMAIL 'admin@example.com'
    assert_eq 'admin@example.com' "$(config_get BAMBOO_DEFAULT_EMAIL)" 'config_set/get round-trip'
    config_set BAMBOO_DEFAULT_EMAIL 'other@example.com'
    assert_eq 'other@example.com' "$(config_get BAMBOO_DEFAULT_EMAIL)" 'config_set replaces a value'
    assert_file_contains "$BAMBOO_CONFIG_FILE" 'BAMBOO_SSL_WWW=auto' 'unrelated keys survive an update'

    config_init_defaults
    assert_eq 'other@example.com' "$(config_get BAMBOO_DEFAULT_EMAIL)" 're-initialising keeps user values'

    config_set BAMBOO_CERTBOT_EXTRA_ARGS '--key-type rsa'
    assert_eq '--key-type rsa' "$(config_get BAMBOO_CERTBOT_EXTRA_ARGS)" 'stores values containing spaces'
}

test_config_apply_precedence() {
    config_init_defaults || true
    config_set BAMBOO_DEFAULT_EMAIL 'from-config@example.com'
    BAMBOO_DEFAULT_EMAIL=''
    config_apply
    assert_eq 'from-config@example.com' "$BAMBOO_DEFAULT_EMAIL" 'config file fills an unset value'
    BAMBOO_DEFAULT_EMAIL='from-env@example.com'
    config_apply
    assert_eq 'from-env@example.com' "$BAMBOO_DEFAULT_EMAIL" 'the environment wins over the config file'
}

test_confirm_behaviour() {
    export BAMBOO_ASSUME_YES=1
    if bamboo_confirm 'proceed?' </dev/null; then
        pass 'auto-confirms when --yes is set'
    else
        fail 'auto-confirms when --yes is set'
    fi

    export BAMBOO_ASSUME_YES=0
    if bamboo_confirm 'proceed?' </dev/null; then
        fail 'refuses without a terminal'
    else
        pass 'refuses without a terminal'
    fi
    export BAMBOO_ASSUME_YES=1
}

test_bamboo_try_captures_result() {
    bamboo_try false
    assert_eq '1' "$BAMBOO_LAST_STATUS" 'records a failing status'
    bamboo_try printf 'hi\n'
    assert_eq '0' "$BAMBOO_LAST_STATUS" 'records a successful status'
    assert_contains "$BAMBOO_LAST_OUTPUT" 'hi' 'captures stdout'
    bamboo_try bash -c 'echo oops >&2; exit 3'
    assert_eq '3' "$BAMBOO_LAST_STATUS" 'records the exact exit code'
    assert_contains "$BAMBOO_LAST_OUTPUT" 'oops' 'captures stderr'
}

test_version_comparison() {
    if bamboo_version_ge '1.25.1' '1.25.0'; then pass '1.25.1 >= 1.25.0'; else fail '1.25.1 >= 1.25.0'; fi
    if bamboo_version_ge '1.18.0' '1.25.1'; then fail '1.18.0 must not be >= 1.25.1'; else pass '1.18.0 < 1.25.1'; fi
    if bamboo_version_ge '22.04' '22.04'; then pass 'equal versions compare true'; else fail 'equal versions compare true'; fi
    if bamboo_version_ge '24.04.1' '22.04'; then pass '24.04.1 >= 22.04'; else fail '24.04.1 >= 22.04'; fi
}

test_email_resolution_precedence() {
    BAMBOO_DEFAULT_EMAIL=''
    config_init_defaults
    assert_eq 'given@example.com' "$(bamboo_resolve_email 'given@example.com')" 'explicit email wins'
    BAMBOO_DEFAULT_EMAIL='default@example.com'
    assert_eq 'default@example.com' "$(bamboo_resolve_email '')" 'falls back to the default'
    BAMBOO_DEFAULT_EMAIL=''
    assert_eq '' "$(bamboo_resolve_email '')" 'empty when nothing is configured and stdin is not a tty'
}

test_helper_utilities() {
    assert_eq '-' "$(bamboo_dir_size "$TEST_ROOT/does-not-exist")" 'dir size falls back to a dash'
    assert_eq '?' "$(bamboo_path_mtime "$TEST_ROOT/does-not-exist")" 'mtime falls back to a question mark'
    assert_eq "$(date '+%Y-%m-%d')" "$(bamboo_path_mtime "$TEST_ROOT")" 'mtime returns an ISO date'
}
