#!/usr/bin/env bash
#
# Bamboo-Site installer.
#
#   curl -sSL https://raw.githubusercontent.com/tonyzidc/bamboo-site/main/install.sh | sudo bash
#
# Installs the CLI into /opt/bamboo-site, links /usr/local/bin/bamboo-site, then
# offers to install the server dependencies (Nginx, Certbot, Fail2ban, UFW).
#
# Self-contained on purpose: it must run before anything is installed.

set -Eeuo pipefail

REPO='tonyzidc/bamboo-site'
BRANCH='main'
INSTALL_DIR='/opt/bamboo-site'
BIN_DIR='/usr/local/bin'
LOCAL=0
RUN_DEPS='prompt'
ASSUME_YES=0
UNINSTALL=0
EMAIL=''
UPGRADE_FLAG=''
SWAP_FLAG=''

log()  { printf '  %s\n' "$*" >&2; }
step() { printf '\n==> %s\n' "$*" >&2; }
ok()   { printf '  [ ok ] %s\n' "$*" >&2; }
warn() { printf '  [warn] %s\n' "$*" >&2; }
die()  { printf '  [error] %s\n' "$*" >&2; exit 1; }

confirm() {
    local prompt="$1" reply=''
    if [ "$ASSUME_YES" = '1' ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        return 1
    fi
    printf '%s [y/N] ' "$prompt" >&2
    read -r reply || return 1
    case "$reply" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<'EOF'
Bamboo-Site installer

Usage:
  install.sh [options]

Options:
  --repo <owner/name>   Source repository      (default: tonyzidc/bamboo-site)
  --branch <name>       Branch to install      (default: main)
  --dir <path>          Install directory      (default: /opt/bamboo-site)
  --bin-dir <path>      Symlink location       (default: /usr/local/bin)
  --local               Install from this checkout instead of downloading
  --email <address>     Default Let's Encrypt email for 'bamboo-site install'
  --no-deps             Do not offer to install server packages
  --no-upgrade          (forwarded) skip the automatic OS upgrade
  --dist-upgrade        (forwarded) use apt-get full-upgrade
  --no-swap             (forwarded) do not create a swap file
  --uninstall           Remove the CLI (sites, certificates and config are kept)
  -y, --yes             Never prompt
  -h, --help            Show this help

Examples:
  curl -sSL https://raw.githubusercontent.com/tonyzidc/bamboo-site/main/install.sh | sudo bash
  sudo ./install.sh --local
  sudo ./install.sh --branch dev --yes
EOF
}

# --- locate ourselves (works when piped or executed from a file) -------------

SELF="${BASH_SOURCE[0]:-}"
SELF_DIR=''
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
    SELF_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
fi

# --- parse arguments --------------------------------------------------------

# --help must work without root, so answer it before anything else.
for _arg in "$@"; do
    case "$_arg" in
        -h|--help)
            usage
            exit 0
            ;;
    esac
done
unset _arg

# Everything below installs files, so it normally runs as root. Installing into a
# user-writable prefix (for example ~/.local/opt/bamboo-site --bin-dir ~/.local/bin)
# is allowed when BAMBOO_INSTALL_ALLOW_NONROOT=1.
if [ "$(id -u)" -ne 0 ]; then
    if [ "${BAMBOO_INSTALL_ALLOW_NONROOT:-0}" = '1' ]; then
        warn 'Installing as a non-root user (BAMBOO_INSTALL_ALLOW_NONROOT=1).'
    elif [ -n "$SELF_DIR" ]; then
        step 'Root privileges are required — re-running with sudo'
        exec sudo -E bash "$SELF" "$@"
    else
        die 'Root privileges are required. Re-run with: curl -sSL <install-url> | sudo bash'
    fi
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            [ $# -ge 2 ] || die '--repo requires a value.'
            REPO="$2"
            shift
            ;;
        --branch)
            [ $# -ge 2 ] || die '--branch requires a value.'
            BRANCH="$2"
            shift
            ;;
        --dir)
            [ $# -ge 2 ] || die '--dir requires a value.'
            INSTALL_DIR="$2"
            shift
            ;;
        --bin-dir)
            [ $# -ge 2 ] || die '--bin-dir requires a value.'
            BIN_DIR="$2"
            shift
            ;;
        --email)
            [ $# -ge 2 ] || die '--email requires a value.'
            EMAIL="$2"
            shift
            ;;
        --local) LOCAL=1 ;;
        --upgrade) UPGRADE_FLAG='--upgrade' ;;
        --no-upgrade) UPGRADE_FLAG='--no-upgrade' ;;
        --dist-upgrade) UPGRADE_FLAG='--dist-upgrade' ;;
        --no-swap) SWAP_FLAG='--no-swap' ;;
        --no-deps) RUN_DEPS='no' ;;
        --uninstall) UNINSTALL=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

case "$INSTALL_DIR" in
    /|/usr|/usr/local|/opt|/etc|/var|/root|/home) die "Refusing to use '$INSTALL_DIR' as the install directory." ;;
esac
case "$INSTALL_DIR" in
    */*/*) ;;
    *) die "The install directory must have at least two path components: '$INSTALL_DIR'" ;;
esac

# --- uninstall -------------------------------------------------------------

if [ "$UNINSTALL" = '1' ]; then
    step "Removing the Bamboo-Site CLI (install dir: $INSTALL_DIR)"
    link="$BIN_DIR/bamboo-site"
    if [ -L "$link" ]; then
        target="$(readlink "$link")"
        case "$target" in
            "$INSTALL_DIR"/*)
                rm -f "$link"
                ok "Removed $link"
                ;;
            *)
                warn "Not removing $link: it points at $target"
                ;;
        esac
    fi
    if [ -d "$INSTALL_DIR" ]; then
        if [ ! -e "$INSTALL_DIR/bin/bamboo-site" ]; then
            warn "$INSTALL_DIR does not look like a Bamboo-Site installation — leaving it alone."
        elif confirm "Delete $INSTALL_DIR?"; then
            rm -rf "$INSTALL_DIR"
            ok "Removed $INSTALL_DIR"
        else
            warn "Kept $INSTALL_DIR"
        fi
    fi
    printf '\n' >&2
    ok 'CLI removal complete.'
    log 'Sites in /var/www, certificates and /etc/bamboo-site were left untouched.'
    log 'To remove the server config too: sudo rm -rf /etc/bamboo-site'
    exit 0
fi

# --- fetch -----------------------------------------------------------------

fetch() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest" || die "Download failed: $url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url" || die "Download failed: $url"
    else
        die 'curl or wget is required to download Bamboo-Site.'
    fi
}

SRC_DIR=''
WORK_DIR=''

cleanup_work() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup_work EXIT

if [ "$LOCAL" = '1' ]; then
    [ -n "$SELF_DIR" ] || die '--local requires running install.sh from a checkout (not through a pipe).'
    SRC_DIR="$SELF_DIR"
    [ -f "$SRC_DIR/bin/bamboo-site" ] || die "--local: $SRC_DIR is not a Bamboo-Site checkout."
    step "Installing from the local checkout: $SRC_DIR"
else
    step "Downloading $REPO (branch: $BRANCH)"
    WORK_DIR="$(mktemp -d)" || die 'Unable to create a temporary directory.'
    fetch "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" "$WORK_DIR/src.tar.gz"
    mkdir -p "$WORK_DIR/unpacked"
    tar -xzf "$WORK_DIR/src.tar.gz" -C "$WORK_DIR/unpacked" || die 'Unable to extract the downloaded archive.'
    SRC_DIR="$(find "$WORK_DIR/unpacked" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [ -n "$SRC_DIR" ] || die 'The downloaded archive was empty.'
    [ -f "$SRC_DIR/bin/bamboo-site" ] || die "The archive for $REPO@$BRANCH does not contain bin/bamboo-site — check the repository and branch."
    ok "Downloaded and verified: $REPO@$BRANCH"
fi

# --- install --------------------------------------------------------------

step "Installing the CLI to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
( cd "$SRC_DIR" && tar --exclude='.git' --exclude='.github' -cf - . ) \
    | ( cd "$INSTALL_DIR" && tar -xf - ) \
    || die "Unable to copy the files into $INSTALL_DIR"

# Normalise ownership and permissions. The source archive can carry the
# ownership of whoever created it (installing from a macOS checkout with
# --local would otherwise leave the tree owned by a non-existent uid), so the
# installed copy is always root-owned and world-readable, with only the entry
# points and helper scripts executable.
if [ "$(id -u)" -eq 0 ]; then
    chown -R root:root "$INSTALL_DIR" 2>/dev/null || true
fi
find "$INSTALL_DIR" -type d -exec chmod 0755 {} + 2>/dev/null || true
find "$INSTALL_DIR" -type f -exec chmod 0644 {} + 2>/dev/null || true
chmod 0755 "$INSTALL_DIR/bin/bamboo-site" "$INSTALL_DIR/install.sh" 2>/dev/null || true
for sub in lib commands tests; do
    if [ -d "$INSTALL_DIR/$sub" ]; then
        find "$INSTALL_DIR/$sub" -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true
    fi
done

mkdir -p "$BIN_DIR"
ln -sfn "$INSTALL_DIR/bin/bamboo-site" "$BIN_DIR/bamboo-site" || die "Unable to create $BIN_DIR/bamboo-site"
ok "Linked $BIN_DIR/bamboo-site"

# BAMBOO_ROOT is pinned so the smoke test reads the copy just installed, even
# when this script was called from a context that already exports BAMBOO_ROOT
# (for example `bamboo-site reinstall`).
version="$(BAMBOO_ROOT="$INSTALL_DIR" "$BIN_DIR/bamboo-site" version 2>/dev/null)" \
    || die 'The installed CLI failed to run.'
ok "Installed: $version"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not in your PATH — add it or call the CLI by full path." ;;
esac

# --- server dependencies ---------------------------------------------------

if [ "$RUN_DEPS" != 'no' ]; then
    printf '\n' >&2
    if [ "$RUN_DEPS" = 'yes' ] || confirm 'Install the server dependencies now (Nginx, Certbot, Fail2ban, UFW)?'; then
        deps_args=(install)
        if [ "$ASSUME_YES" = '1' ]; then
            deps_args+=(--yes)
        fi
        if [ -n "$EMAIL" ]; then
            deps_args+=(--email "$EMAIL")
        fi
        if [ -n "$UPGRADE_FLAG" ]; then
            deps_args+=("$UPGRADE_FLAG")
        fi
        if [ -n "$SWAP_FLAG" ]; then
            deps_args+=("$SWAP_FLAG")
        fi
        "$BIN_DIR/bamboo-site" "${deps_args[@]}"
    else
        log "Skipped. Install them later with: sudo bamboo-site install"
    fi
fi

step 'Done'
log "Create your first site:  sudo bamboo-site add example.com you@example.com"
log "See everything at once:  sudo bamboo-site list"
log "Documentation:           https://github.com/tonyzidc/bamboo-site"
