#!/usr/bin/env bash
# shellcheck shell=bash
#
# Tests for the swap step of `install` (lib/swap.sh) and the CLI-level
# behaviour of the new install flags.

test_swap_size_auto_follows_ram_and_caps() {
    export TEST_RAM_MB=848
    fresh_root
    assert_eq '896' "$(swap_size_mb)" 'auto rounds 848MB up to a 64MB multiple'

    export TEST_RAM_MB=1024
    fresh_root
    assert_eq '1024' "$(swap_size_mb)" 'auto matches RAM exactly when it is a multiple'

    export TEST_RAM_MB=16384
    fresh_root
    assert_eq '8192' "$(swap_size_mb)" 'auto is capped at 8GB'
}

test_swap_size_explicit_values() {
    # shellcheck disable=SC2034  # read by swap_size_mb() at call time
    BAMBOO_SWAP='512M'
    assert_eq '512' "$(swap_size_mb)" 'honours an explicit 512M'
    BAMBOO_SWAP='1G'
    assert_eq '1024' "$(swap_size_mb)" 'honours an explicit 1G'
    BAMBOO_SWAP='300'
    assert_eq '300' "$(swap_size_mb)" 'a bare number means MB'
    BAMBOO_SWAP='no'
    assert_eq '' "$(swap_size_mb)" 'no disables swap'
    BAMBOO_SWAP='nonsense'
    assert_eq '' "$(swap_size_mb)" 'garbage is treated as "do not touch"'
}

test_swap_creates_file_and_persists_it() {
    fresh_root
    capture swap_ensure
    assert_rc 0 "$RC" 'swap_ensure succeeds'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'fallocate -l 2048M' 'allocates the RAM-sized file'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" "mkswap $BAMBOO_SWAP_FILE" 'runs mkswap'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" "swapon $BAMBOO_SWAP_FILE" 'activates the swap'
    assert_file_exists "$BAMBOO_FSTAB" 'writes the fstab entry'
    assert_file_contains_fixed "$BAMBOO_FSTAB" "$BAMBOO_SWAP_FILE none swap sw 0 0" 'fstab entry is correct'
    assert_contains "$OUT" 'Swap is active' 'reports success'
}

test_swap_skips_when_swap_already_active() {
    export TEST_SWAP_ACTIVE='/swapfile 2G'
    fresh_root
    capture swap_ensure
    assert_rc 0 "$RC" 'swap_ensure succeeds'
    assert_contains "$OUT" 'already active' 'reports the existing swap'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'fallocate' 'does not create anything'
    assert_file_missing "$BAMBOO_FSTAB" 'does not touch fstab'
}

test_swap_skips_when_disabled() {
    # shellcheck disable=SC2034  # read by swap_size_mb() at call time
    BAMBOO_SWAP='no'
    fresh_root
    capture swap_ensure
    assert_rc 0 "$RC" 'swap_ensure succeeds'
    assert_contains "$OUT" 'disabled' 'explains that swap creation is disabled'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'fallocate' 'does not create anything'
}

test_swap_respects_the_disk_guard() {
    export TEST_RAM_MB=4096
    export TEST_DISK_FREE_MB=1000
    fresh_root
    capture swap_ensure
    assert_rc 0 "$RC" 'swap_ensure succeeds'
    assert_contains "$OUT" 'Not enough disk space' 'skips because the disk is too small'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'fallocate' 'creates nothing'
    assert_file_missing "$BAMBOO_FSTAB" 'leaves fstab alone'
}

test_swap_dry_run_writes_nothing() {
    export BAMBOO_DRY_RUN=1
    fresh_root
    capture swap_ensure
    assert_rc 0 "$RC" 'dry-run succeeds'
    assert_contains "$OUT" '[dry-run] would create a 2048MB swap file' 'reports the plan'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'fallocate' 'creates nothing'
    assert_file_missing "$BAMBOO_FSTAB" 'leaves fstab alone'
    export BAMBOO_DRY_RUN=0
}

test_swap_falls_back_to_dd() {
    export TEST_FALLOCATE_FAIL=1
    fresh_root
    capture swap_ensure
    assert_rc 0 "$RC" 'swap_ensure still succeeds'
    assert_contains "$OUT" 'falling back to dd' 'explains the fallback'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'dd if=/dev/zero' 'uses dd when fallocate fails'
    assert_file_exists "$BAMBOO_FSTAB" 'still persists the swap'
}

test_swap_fstab_entry_is_written_once() {
    fresh_root
    swap_add_to_fstab "$BAMBOO_SWAP_FILE"
    swap_add_to_fstab "$BAMBOO_SWAP_FILE"
    local count
    count="$(grep -cF "$BAMBOO_SWAP_FILE" "$BAMBOO_FSTAB")"
    assert_eq '1' "$count" 'the fstab entry is not duplicated'
    assert_file_contains "$BAMBOO_FSTAB" 'Added by Bamboo-Site' 'the entry is labelled'
}

test_swap_fstab_is_backed_up() {
    fresh_root
    mkdir -p "$(dirname "$BAMBOO_FSTAB")"
    printf '# existing fstab\nUUID=abc / ext4 defaults 0 1\n' >"$BAMBOO_FSTAB"
    swap_add_to_fstab "$BAMBOO_SWAP_FILE"
    local backups
    backups="$(find "$(dirname "$BAMBOO_FSTAB")" -name 'fstab.bak.*' | wc -l | tr -d ' ')"
    assert_eq '1' "$backups" 'keeps a backup of the previous fstab'
    assert_file_contains "$BAMBOO_FSTAB" 'UUID=abc' 'existing entries are preserved'
}

test_swap_fstab_is_created_when_missing() {
    fresh_root
    assert_file_missing "$BAMBOO_FSTAB" 'no fstab to begin with'
    swap_add_to_fstab "$BAMBOO_SWAP_FILE"
    assert_file_exists "$BAMBOO_FSTAB" 'creates the file'
    assert_file_contains_fixed "$BAMBOO_FSTAB" "$BAMBOO_SWAP_FILE none swap sw 0 0" 'with the swap entry'
}

# --- the install flow -------------------------------------------------------

test_cli_install_creates_swap() {
    capture "$BAMBOO_TEST_BIN" install --yes
    assert_rc 0 "$RC" 'install exits 0'
    assert_contains "$OUT" 'Checking swap' 'runs the swap step'
    assert_file_contains "$BAMBOO_TEST_CMD_LOG" 'swapon' 'activates the new swap'
    assert_file_contains_fixed "$BAMBOO_FSTAB" "$BAMBOO_SWAP_FILE none swap sw 0 0" 'makes it persistent'
}

test_cli_install_no_swap_flag() {
    capture "$BAMBOO_TEST_BIN" install --yes --no-swap
    assert_rc 0 "$RC" 'install --no-swap exits 0'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'fallocate' 'creates no swap file'
    assert_contains "$OUT" 'disabled' 'says swap creation is disabled'
}

test_cli_install_skips_swap_when_present() {
    capture "$BAMBOO_TEST_BIN" install --yes
    # A second run sees the swap it created (simulated by the knob) and leaves it.
    export TEST_SWAP_ACTIVE='/swapfile 2G'
    fresh_root
    capture "$BAMBOO_TEST_BIN" install --yes
    assert_rc 0 "$RC" 'install exits 0'
    assert_not_contains "$(cat "$BAMBOO_TEST_CMD_LOG")" 'fallocate' 'does not touch existing swap'
    assert_contains "$OUT" 'already active' 'reports the existing swap'
}
