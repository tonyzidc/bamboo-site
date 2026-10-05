#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — `bamboo-site reinstall`
#
# Reinstalls the CLI itself: fetches the current version from GitHub (or takes a
# local checkout with --from), keeps the previous tree for --rollback, then lets
# the staged install.sh do the copy/normalise/symlink work so this command and
# the bootstrap installer can never drift apart.
#
# Sites, certificates, services and /etc/bamboo-site are never touched.

cmd_reinstall_usage() {
    cat <<EOF
Usage: $BAMBOO_PROG_NAME reinstall [options]

Replaces the installed CLI with a newer copy. The previous installation is kept
next to it (<install-dir>.bak) so 'reinstall --rollback' undoes the change.

Sites, certificates, services and the configuration in /etc/bamboo-site are not
touched — only the program files under $(printf '%s' "$BAMBOO_INSTALL_DIR").

Options:
  --from <dir>        Install from a local checkout instead of downloading.
  --repo <o/name>     Repository to download (default: $BAMBOO_REPO).
  --branch <name>     Branch to download (default: main).
  --rollback          Restore the previous installation and keep the current
                      one as the new rollback copy.
  -h, --help          Show this help.

Global options: --dry-run, --yes, --verbose, --no-color

Examples:
  sudo $BAMBOO_PROG_NAME reinstall
  sudo $BAMBOO_PROG_NAME reinstall --branch dev
  sudo $BAMBOO_PROG_NAME reinstall --from /root/bamboo-site-checkout
  sudo $BAMBOO_PROG_NAME reinstall --rollback
EOF
}

reinstall_backup_path() { printf '%s.bak' "$BAMBOO_INSTALL_DIR"; }

reinstall_repair_symlink() {
    mkdir -p "$BAMBOO_BIN_DIR" 2>/dev/null || return 1
    ln -sfn "$BAMBOO_INSTALL_DIR/bin/bamboo-site" "$BAMBOO_BIN_DIR/bamboo-site" || return 1
    return 0
}

reinstall_restore() {
    # reinstall_restore <backup-dir> — puts the backup back in place.
    local bak="$1"
    if [ ! -d "$bak" ]; then
        log_error "No rollback copy available at $bak."
        return 1
    fi
    rm -rf "$BAMBOO_INSTALL_DIR" || return 1
    mv -f "$bak" "$BAMBOO_INSTALL_DIR" || return 1
    reinstall_repair_symlink || return 1
    log_ok "Restored the previous installation ($(bamboo_installed_version "$BAMBOO_INSTALL_DIR"))."
    return 0
}

reinstall_do_rollback() {
    local bak='' current='' swap=''
    bak="$(reinstall_backup_path)"
    if [ ! -d "$bak" ]; then
        die "Nothing to roll back to: $bak does not exist."
    fi
    log_step "Rolling back to $(bamboo_installed_version "$bak")"
    if bamboo_is_dry_run; then
        log_info "[dry-run] would swap $bak back into $BAMBOO_INSTALL_DIR"
        return 0
    fi
    current="${BAMBOO_INSTALL_DIR}.current-$$"
    swap="${bak}.swap-$$"
    mv -f "$BAMBOO_INSTALL_DIR" "$current" 2>/dev/null || die "Unable to move $BAMBOO_INSTALL_DIR aside."
    if ! mv -f "$bak" "$swap" 2>/dev/null; then
        mv -f "$current" "$BAMBOO_INSTALL_DIR" 2>/dev/null || true
        die 'Unable to move the rollback copy into place; nothing was changed.'
    fi
    mv -f "$swap" "$BAMBOO_INSTALL_DIR" || die "Unable to restore $BAMBOO_INSTALL_DIR."
    mv -f "$current" "$bak" 2>/dev/null || rm -rf "$current" 2>/dev/null || true
    reinstall_repair_symlink || die "Unable to update the symlink in $BAMBOO_BIN_DIR."
    log_ok "Rolled back to $(bamboo_installed_version "$BAMBOO_INSTALL_DIR"); the newer copy is kept at $bak."
    bamboo_oplog "reinstall --rollback: $(bamboo_installed_version "$BAMBOO_INSTALL_DIR")"
    return 0
}

reinstall_stage() {
    # Prints the staging directory holding the new version.
    local from="$1" repo="$2" branch="$3" staging='' tarball=''
    if [ -n "$from" ]; then
        [ -d "$from" ] || die "--from: not a directory: $from"
        [ -f "$from/bin/bamboo-site" ] || die "--from: $from does not look like a Bamboo-Site checkout."
        printf '%s' "$from"
        return 0
    fi

    bamboo_ensure_tmpdir
    staging="$BAMBOO_TMPDIR/reinstall-src"
    tarball="$BAMBOO_TMPDIR/reinstall.tar.gz"
    rm -rf "$staging"
    mkdir -p "$staging" || die "Unable to create $staging"
    log_info "Downloading $repo@$branch ..."
    if ! bamboo_fetch_url "https://codeload.github.com/$repo/tar.gz/refs/heads/$branch" "$tarball"; then
        die "Download failed. Check the network (or use --from <checkout-dir>)."
    fi
    tar -xzf "$tarball" -C "$staging" --strip-components=1 2>/dev/null \
        || die 'Unable to extract the downloaded archive.'
    [ -f "$staging/bin/bamboo-site" ] || die "The archive for $repo@$branch does not contain bin/bamboo-site."
    printf '%s' "$staging"
    return 0
}

cmd_reinstall() {
    local from='' repo="$BAMBOO_REPO" branch="${BAMBOO_BRANCH:-main}" rollback=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --from)
                [ $# -ge 2 ] || die 'reinstall: --from requires a value.'
                from="$2"
                shift
                ;;
            --repo)
                [ $# -ge 2 ] || die 'reinstall: --repo requires a value.'
                repo="$2"
                shift
                ;;
            --branch)
                [ $# -ge 2 ] || die 'reinstall: --branch requires a value.'
                branch="$2"
                shift
                ;;
            --rollback) rollback=1 ;;
            -h|--help) cmd_reinstall_usage; return 0 ;;
            *) die "reinstall: unknown option '$1'. See '$BAMBOO_PROG_NAME help reinstall'." ;;
        esac
        shift
    done

    require_root
    bamboo_assert_safe_install_dir "$BAMBOO_INSTALL_DIR"

    if [ "$rollback" = '1' ]; then
        reinstall_do_rollback
        return $?
    fi

    local staging='' old_version='' new_version='' bak=''
    staging="$(reinstall_stage "$from" "$repo" "$branch")"
    [ -f "$staging/bin/bamboo-site" ] || die "The source at $staging does not look like a Bamboo-Site checkout."

    old_version="$(bamboo_installed_version "$BAMBOO_INSTALL_DIR")"
    new_version="$(bamboo_installed_version "$staging")"
    [ -n "$new_version" ] || die "No VERSION file in $staging — refusing to install an unversioned copy."
    [ -n "$old_version" ] || old_version='(unknown)'

    if [ "$old_version" = "$new_version" ]; then
        log_info "This server already runs $new_version; reinstalling it fresh."
    fi

    # The staged CLI must actually run before it is allowed near the live copy.
    # BAMBOO_ROOT is pinned to the staging directory so this verifies the copy
    # being installed, not the one already on the machine.
    bamboo_try env BAMBOO_ROOT="$staging" bash "$staging/bin/bamboo-site" version
    if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
        log_error 'The staged CLI failed to run:'
        printf '  %s%s%s\n' "$C_DIM" "$BAMBOO_LAST_OUTPUT" "$C_RESET" >&2
        die 'Nothing was changed.'
    fi
    case "$BAMBOO_LAST_OUTPUT" in
        *"$new_version"*) ;;
        *) die "The staged CLI reported an unexpected version: $BAMBOO_LAST_OUTPUT" ;;
    esac

    if bamboo_is_dry_run; then
        printf '\n' >&2
        log_info "[dry-run] would reinstall: $old_version -> $new_version"
        log_info "[dry-run] source:      $staging"
        log_info "[dry-run] install dir: $BAMBOO_INSTALL_DIR (previous kept as $(reinstall_backup_path))"
        log_info "[dry-run] symlink:     $BAMBOO_BIN_DIR/bamboo-site"
        log_info '[dry-run] sites, certificates, services and config would not be touched'
        return 0
    fi

    log_step "Reinstalling Bamboo-Site: $old_version -> $new_version"
    bamboo_oplog "reinstall: $old_version -> $new_version"

    bak="$(reinstall_backup_path)"
    if [ -d "$BAMBOO_INSTALL_DIR" ]; then
        rm -rf "$bak" 2>/dev/null || true
        if ! cp -a "$BAMBOO_INSTALL_DIR" "$bak" 2>/dev/null; then
            log_warn "Could not keep a rollback copy at $bak; continuing without one."
        else
            log_debug "Previous installation kept at $bak"
        fi
    fi

    if ! bash "$staging/install.sh" --local --dir "$BAMBOO_INSTALL_DIR" --bin-dir "$BAMBOO_BIN_DIR" --no-deps --yes; then
        log_error 'The installer failed; restoring the previous version.'
        reinstall_restore "$bak" || die "Restore also failed — the previous copy is at $bak."
        exit 1
    fi

    bamboo_try env BAMBOO_ROOT="$BAMBOO_INSTALL_DIR" "$BAMBOO_BIN_DIR/bamboo-site" version
    if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
        log_error 'The reinstalled CLI failed to run; restoring the previous version.'
        reinstall_restore "$bak" || die "Restore also failed — the previous copy is at $bak."
        exit 1
    fi
    case "$BAMBOO_LAST_OUTPUT" in
        *"$new_version"*)
            log_ok "Reinstalled: $new_version (previous version kept at $bak)"
            ;;
        *)
            log_warn "The reinstalled CLI reported: $BAMBOO_LAST_OUTPUT"
            ;;
    esac
    log_info 'Sites, certificates, services and /etc/bamboo-site were not touched.'
    log_hint "Undo with: sudo $BAMBOO_PROG_NAME reinstall --rollback"
    return 0
}
