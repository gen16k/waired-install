#!/bin/sh
# install.sh — install Waired via the system package manager.
#
# Usage:
#   curl -fsSL https://github.com/gen16k/waired/releases/latest/download/install.sh | sh
#   curl -fsSL https://github.com/gen16k/waired/releases/latest/download/install.sh | sh -s -- --dry-run
#
# This script is intentionally OS-agnostic in shape. Today only the
# Linux + apt path is wired up (Debian / Ubuntu). New operating systems
# plug in by adding three things:
#
#   1. a new branch in detect_os to set OS_FAMILY
#   2. a handler function named <kind>_<pkgmgr>_install
#   3. a new arm in the case statement at the bottom of main()
#
# Function namespaces:
#   common_*      shared helpers — log, run, sudo, etc.
#   detect_*      probe the host (kernel, distro, arch)
#   linux_apt_*   Debian / Ubuntu installer (this PR)
#   linux_dnf_*   Fedora / RHEL                  (future)
#   linux_apk_*   Alpine                          (future)
#   darwin_brew_* macOS via Homebrew              (future)
#   windows_*     handled by a separate .ps1     (future)

set -eu

# GitHub Releases asset URL (hosts install.sh itself). `latest` resolves
# to the most recent tagged release.
WAIRED_INSTALL_BASE_URL="${WAIRED_INSTALL_BASE_URL:-https://github.com/gen16k/waired/releases/latest/download}"
# Artifact Registry APT endpoint that hosts the actual .deb packages.
# Repo is publicly readable via roles/artifactregistry.reader on allUsers
# (see infra/terraform/modules/artifact-registry/main.tf).
#
# AR's APT format publishes one suite per repository, so the URL stops
# at the project level and the suite name *is* the AR repository ID.
# Components are always `main` today. End users override these three
# vars when pinning to a future `waired-dev-apt-beta` track or a
# separately-provisioned prod repo.
WAIRED_APT_BASE_URL="${WAIRED_APT_BASE_URL:-https://asia-northeast1-apt.pkg.dev/projects/dev-waired}"
WAIRED_APT_SUITE="${WAIRED_APT_SUITE:-waired-dev-apt}"
WAIRED_APT_COMPONENT="${WAIRED_APT_COMPONENT:-main}"
# Public signing key URL. AR signs every APT repo in a region with the
# same Google-managed key, exposed at this well-known path. Derived from
# WAIRED_APT_BASE_URL so the region stays consistent.
WAIRED_APT_KEY_URL="${WAIRED_APT_KEY_URL:-https://asia-northeast1-apt.pkg.dev/doc/repo-signing-key.gpg}"

DRY_RUN=0
SUDO=""
OS_KIND=""
OS_FAMILY=""
OS_NAME=""
OS_VERSION=""
OS_CODENAME=""
OS_ARCH=""

# ---------------------------------------------------------------------
# common_* helpers
# ---------------------------------------------------------------------

common_log()  { printf '\033[1;36m[waired]\033[0m %s\n' "$*"; }
common_warn() { printf '\033[1;33m[waired]\033[0m %s\n' "$*" >&2; }
common_die()  { printf '\033[1;31m[waired]\033[0m %s\n' "$*" >&2; exit 1; }

# Run a command, or print it in dry-run mode.
common_run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '\033[1;90m[dry-run]\033[0m %s\n' "$*"
        return 0
    fi
    "$@"
}

common_require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || \
            common_die "required command not found: $c"
    done
}

# Find a privilege-escalation strategy. After this, "$SUDO cmd args"
# works whether the user is already root or not.
common_elevate() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
        return
    fi
    if command -v sudo >/dev/null 2>&1; then
        SUDO=sudo
        return
    fi
    common_die "this installer needs root privileges. Install sudo, or re-run as root."
}

show_help() {
    cat <<'HELP'
install.sh — install Waired via the system package manager.

Usage:
  curl -fsSL https://github.com/gen16k/waired/releases/latest/download/install.sh | sh
  curl -fsSL https://github.com/gen16k/waired/releases/latest/download/install.sh | sh -s -- --dry-run

Options:
  --dry-run     show every privileged command without running it
  -h, --help    print this help

Environment variables:
  WAIRED_VERSION           pin to a specific package version (e.g. 1.2.3)
  WAIRED_NO_TRAY           if set, do not install waired-tray
  WAIRED_INSTALL_BASE_URL  override URL for install.sh itself
                           (default: github.com/gen16k/waired releases)
  WAIRED_APT_BASE_URL      override the apt repository base URL
                           (default: asia-northeast1-apt.pkg.dev/projects/dev-waired)
  WAIRED_APT_SUITE         override the apt suite (= AR repository id)
                           (default: waired-dev-apt)
  WAIRED_APT_COMPONENT     override the apt component (default: main)
  WAIRED_APT_KEY_URL       override the GPG signing-key URL
                           (default: asia-northeast1-apt.pkg.dev/doc/repo-signing-key.gpg)
HELP
}

# ---------------------------------------------------------------------
# detect_* — fill in OS_KIND / OS_FAMILY / OS_NAME / OS_VERSION /
#            OS_CODENAME / OS_ARCH. Everything below dispatches on
#            these.
# ---------------------------------------------------------------------

detect_os() {
    case "$(uname -s)" in
        Linux)
            OS_KIND=linux
            if [ ! -r /etc/os-release ]; then
                common_die "/etc/os-release is missing — unsupported Linux distribution."
            fi
            # shellcheck disable=SC1091
            . /etc/os-release
            OS_NAME="${ID:-unknown}"
            OS_VERSION="${VERSION_ID:-unknown}"
            OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
            case "$OS_NAME" in
                debian|ubuntu|linuxmint|pop|elementary) OS_FAMILY=debian ;;
                fedora|rhel|centos|rocky|almalinux)     OS_FAMILY=rhel ;;
                alpine)                                  OS_FAMILY=alpine ;;
                arch|manjaro|endeavouros)                OS_FAMILY=arch ;;
                *)
                    case "${ID_LIKE:-}" in
                        *debian*)        OS_FAMILY=debian ;;
                        *rhel*|*fedora*) OS_FAMILY=rhel ;;
                        *arch*)          OS_FAMILY=arch ;;
                        *)               OS_FAMILY=unknown ;;
                    esac
                    ;;
            esac
            ;;
        Darwin)
            OS_KIND=darwin
            OS_FAMILY=darwin
            OS_NAME=macos
            OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
            ;;
        *)
            common_die "unsupported OS: $(uname -s)"
            ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  OS_ARCH=amd64 ;;
        aarch64|arm64) OS_ARCH=arm64 ;;
        *) common_die "unsupported CPU architecture: $(uname -m). Waired ships amd64 and arm64 packages." ;;
    esac
}

# ---------------------------------------------------------------------
# linux_apt_* — Debian / Ubuntu handler
# ---------------------------------------------------------------------

linux_apt_install() {
    common_log "Detected $OS_NAME $OS_VERSION (${OS_CODENAME:-unknown codename}) on $OS_ARCH"

    if [ -z "$OS_CODENAME" ]; then
        common_die "could not determine the apt suite for $OS_NAME $OS_VERSION (VERSION_CODENAME missing in /etc/os-release)."
    fi

    common_log "Installing apt prerequisites (ca-certificates, curl, gnupg)..."
    common_run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    common_run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg

    keyring_dir=/etc/apt/keyrings
    keyring_file="$keyring_dir/waired-archive-keyring.gpg"
    key_url="$WAIRED_APT_KEY_URL"
    list_file=/etc/apt/sources.list.d/waired.list

    common_log "Installing Waired signing key into $keyring_file"
    common_run $SUDO install -d -m 0755 "$keyring_dir"

    if [ "$DRY_RUN" = 1 ]; then
        common_log "  (dry-run) would fetch $key_url, dearmor if needed, and install into $keyring_file"
    else
        tmp_key="$(mktemp)"
        # shellcheck disable=SC2064
        trap "rm -f '$tmp_key' '$tmp_key.gpg'" EXIT
        curl -fsSL "$key_url" -o "$tmp_key"
        if head -c 64 "$tmp_key" | grep -q -- '-----BEGIN PGP'; then
            gpg --dearmor <"$tmp_key" >"$tmp_key.gpg"
            $SUDO install -m 0644 "$tmp_key.gpg" "$keyring_file"
        else
            $SUDO install -m 0644 "$tmp_key" "$keyring_file"
        fi
    fi

    list_line="deb [signed-by=$keyring_file arch=$OS_ARCH] $WAIRED_APT_BASE_URL $WAIRED_APT_SUITE $WAIRED_APT_COMPONENT"
    common_log "Writing $list_file"
    if [ "$DRY_RUN" = 1 ]; then
        common_log "  (dry-run) would write: $list_line"
    else
        printf '%s\n' "$list_line" | $SUDO tee "$list_file" >/dev/null
        $SUDO chmod 0644 "$list_file"
    fi

    common_log "Refreshing apt indexes (only the waired repo)"
    common_run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
        -o Dir::Etc::sourcelist="$list_file" \
        -o Dir::Etc::sourceparts=- \
        -o APT::Get::List-Cleanup=0

    pkgs="waired"
    if [ -n "${WAIRED_VERSION:-}" ]; then
        pkgs="waired=${WAIRED_VERSION}"
    fi
    if [ -z "${WAIRED_NO_TRAY:-}" ]; then
        if [ -n "${WAIRED_VERSION:-}" ]; then
            pkgs="$pkgs waired-tray=${WAIRED_VERSION}"
        else
            pkgs="$pkgs waired-tray"
        fi
    else
        common_log "WAIRED_NO_TRAY set — skipping waired-tray"
    fi

    common_log "Installing packages: $pkgs"
    # shellcheck disable=SC2086
    common_run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs

    cat <<EOF

Waired installed.

Next steps:
  1. Set your Control Plane URL:
       sudo \${EDITOR:-nano} /etc/waired/agent.env       # set WAIRED_CONTROL_URL
  2. Enroll this device (or right-click the tray icon and pick "Log in..."):
       sudo waired init --control "https://your-cp.example.com"
  3. Start the daemon:
       sudo systemctl enable --now waired-agent

Diagnostics:  journalctl -u waired-agent -e
Uninstall:    sudo apt purge waired waired-tray

EOF
}

# ---------------------------------------------------------------------
# main
# ---------------------------------------------------------------------

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            -h|--help) show_help; exit 0 ;;
            *) common_die "unknown argument: $1 (try --help)" ;;
        esac
        shift
    done

    detect_os
    detect_arch
    common_elevate

    case "$OS_KIND:$OS_FAMILY" in
        linux:debian)
            linux_apt_install
            ;;
        linux:rhel)
            common_die "Fedora / RHEL support is not yet available. Follow https://github.com/gen16k/waired/issues for updates."
            ;;
        linux:alpine)
            common_die "Alpine support is not yet available."
            ;;
        linux:arch)
            common_die "Arch support is not yet available. Track it via the AUR — coming later."
            ;;
        darwin:*)
            common_die "macOS support is not yet available. Use Homebrew tap once we ship it."
            ;;
        *)
            common_die "$OS_NAME ($OS_KIND/$OS_FAMILY) is not yet supported. Please file an issue."
            ;;
    esac
}

main "$@"
