#!/usr/bin/env bash
# shellcheck shell=bash
#
# Bamboo-Site — swap file management.
#
# A small VPS with no swap is one apt upgrade away from an out-of-memory kill,
# so `install` creates a swap file when the machine has none at all. Anything
# already active (a partition, a file, zram) is left completely alone.
#
# Configuration (env > /etc/bamboo-site/config > default):
#   BAMBOO_SWAP            auto | no | <N> | <N>M | <N>G   (default auto = RAM, capped)
#   BAMBOO_SWAP_FILE       default /swapfile
#   BAMBOO_SWAP_MAX_MB     cap for auto sizing (default 8192)
#   BAMBOO_SWAP_MIN_FREE_MB free space to leave on the filesystem (default 512)
#   BAMBOO_FSTAB           default /etc/fstab (overridable for tests)

swap_size_mb() {
    # Prints the swap size in MB, or nothing when swap should be skipped.
    local spec="${BAMBOO_SWAP:-auto}" ram='' size='' num=''
    case "$spec" in
        no|off|none) printf ''; return 0 ;;
    esac

    case "$spec" in
        auto|yes|on|'')
            ram="$(bamboo_mem_total_mb)"
            case "$ram" in
                ''|*[!0-9]*) printf ''; return 0 ;;
            esac
            # Round up to a 64 MB multiple; tiny boxes get a tidy number.
            size=$(( (ram + 63) / 64 * 64 ))
            ;;
        *[Mm]) num="${spec%[Mm]}"; size="$num" ;;
        *[Gg]) num="${spec%[Gg]}"; size=$(( num * 1024 )) ;;
        *[0-9]) size="$spec" ;;
        *) printf ''; return 0 ;;
    esac

    case "$size" in
        ''|*[!0-9]*) printf ''; return 0 ;;
    esac
    [ "$size" -gt 0 ] || { printf ''; return 0; }
    if [ "$size" -gt "$BAMBOO_SWAP_MAX_MB" ]; then
        size="$BAMBOO_SWAP_MAX_MB"
    fi
    printf '%s' "$size"
    return 0
}

swap_add_to_fstab() {
    # Makes the swap file persistent. /etc/fstab is backed up first: a broken
    # fstab can stop a server from booting, so nothing is written blindly.
    local file="$1" fstab entry
    fstab="$(bamboo_fstab_path)"
    entry="$file none swap sw 0 0"

    if [ -r "$fstab" ] && grep -qF "$file" "$fstab" 2>/dev/null; then
        log_debug "Swap entry already present in $fstab."
        return 0
    fi
    if [ -e "$fstab" ] && [ ! -w "$fstab" ]; then
        log_warn "Cannot write $fstab; swap is active but will not survive a reboot."
        return 0
    fi

    mkdir -p "$(dirname "$fstab")" 2>/dev/null || true
    if [ -f "$fstab" ]; then
        backup_file "$fstab" >/dev/null
        if ! printf '\n# Added by Bamboo-Site: persistent swap.\n%s\n' "$entry" >>"$fstab"; then
            log_warn "Unable to append to $fstab; swap will not survive a reboot."
            return 0
        fi
    else
        if ! printf '# Added by Bamboo-Site: persistent swap.\n%s\n' "$entry" >"$fstab"; then
            log_warn "Unable to write $fstab; swap will not survive a reboot."
            return 0
        fi
    fi

    if bamboo_need_cmd findmnt; then
        bamboo_try findmnt --verify --tab-file "$fstab"
        if [ "$BAMBOO_LAST_STATUS" -ne 0 ]; then
            log_warn "findmnt --verify is unhappy with $fstab — review it before rebooting (backup kept)."
            log_debug "$BAMBOO_LAST_OUTPUT"
        fi
    fi
    log_ok "Added the swap entry to $fstab (persistent across reboots)."
    return 0
}

swap_ensure() {
    # Creates a swap file only when the machine has no swap at all.
    log_step 'Checking swap'
    local active='' size='' file='' free_mb=''

    active="$(bamboo_swap_active)"
    if [ -n "$active" ]; then
        log_ok "Swap is already active: $(printf '%s' "$active" | tr '\n' ' ')"
        return 0
    fi

    size="$(swap_size_mb)"
    if [ -z "$size" ]; then
        log_warn "No swap is active and swap creation is disabled (BAMBOO_SWAP=${BAMBOO_SWAP:-auto})."
        log_hint 'Enable it with BAMBOO_SWAP=auto in /etc/bamboo-site/config, or create swap manually.'
        return 0
    fi

    file="$BAMBOO_SWAP_FILE"
    free_mb="$(bamboo_disk_free_mb "$(dirname "$file")")"
    if [ -z "$free_mb" ]; then
        log_warn "Unable to determine the free space on $(dirname "$file"); skipping swap."
        return 0
    fi
    if [ "$free_mb" -lt $(( size + BAMBOO_SWAP_MIN_FREE_MB )) ]; then
        log_warn "Not enough disk space for a ${size}MB swap file on $(dirname "$file") (free: ${free_mb}MB)."
        log_hint "Create it manually with a smaller size, e.g. BAMBOO_SWAP=512M."
        return 0
    fi

    if bamboo_is_dry_run; then
        log_info "[dry-run] would create a ${size}MB swap file at $file and add it to $(bamboo_fstab_path)"
        return 0
    fi

    log_info "Creating a ${size}MB swap file at $file ..."
    if [ -f "$file" ]; then
        log_info "Reusing the existing file $file (it is not active)."
    else
        if bamboo_fallocate -l "${size}M" "$file" 2>/dev/null; then
            :
        else
            log_warn 'fallocate failed (unsupported filesystem?); falling back to dd, this takes longer.'
            if ! bamboo_dd if=/dev/zero of="$file" bs=1M count="$size" status=none 2>/dev/null; then
                rm -f "$file" 2>/dev/null || true
                die "Unable to create the swap file $file"
            fi
        fi
        bamboo_chmod 0600 "$file" 2>/dev/null || true
    fi

    if ! bamboo_mkswap "$file" >/dev/null 2>&1; then
        rm -f "$file" 2>/dev/null || true
        die "mkswap failed for $file; the incomplete file was removed."
    fi
    if ! bamboo_swapon "$file" 2>/dev/null; then
        log_warn "swapon failed for $file — the file is left in place but inactive."
        return 1
    fi

    swap_add_to_fstab "$file"
    log_ok "Swap is active: $(bamboo_swap_active | tr '\n' ' ')"
    log_hint 'Swappiness is left at the distribution default; tune it with: sysctl -w vm.swappiness=10'
    return 0
}
