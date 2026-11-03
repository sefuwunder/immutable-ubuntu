#!/bin/bash
# preflight.sh — checks for transition.sh. Sourced as a library; also
# runnable standalone for a dry assessment:  sudo ./preflight.sh
set -euo pipefail

# Results exported for transition.sh
PREFLIGHT_ESP=""
PREFLIGHT_RELEASE=""
PREFLIGHT_TRANSFER_EXT=".transfer"
PREFLIGHT_VERSION_OK=0
PREFLIGHT_SYSUPDATE=""

fail() { echo "preflight: ERROR: $*" >&2; exit 1; }
warn() { echo "preflight: WARNING: $*" >&2; }
info() { echo "preflight: $*"; }

# Resolve a directory to a normalized absolute path: no trailing slash, no
# . or .. components, symlinks resolved. transition.sh needs this for
# --artifacts: sysupdate rejects a Source path that is not normalized
# absolute ("Source path is not a normalized, absolute path"), and the
# temp transfer defs carry --artifacts verbatim. Exits nonzero (empty
# output) when the directory cannot be entered. Runs in a subshell, so the
# caller's working directory is unchanged.
canonicalize_dir() {
    (cd "$1" && pwd -P)
}

# Extension this sysupdate loads for transfer definitions, with the dot:
# .conf before systemd 257, .transfer from 257 on (the rename). --help text
# does not reliably name the suffix (255's --help mentions neither, so the
# old --help probe picked .transfer on 255 and the defs were silently
# ignored), so probe the version, not the help text. Requires
# PREFLIGHT_SYSUPDATE to be resolved first.
sysupdate_def_ext() {
    local _ver
    _ver="$("$PREFLIGHT_SYSUPDATE" --version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)"
    if [ -n "$_ver" ] && [ "$_ver" -ge 257 ] 2>/dev/null; then
        echo ".transfer"
    else
        echo ".conf"
    fi
}

require_root() {
    [ "$(id -u)" = "0" ] || fail "must run as root (sudo)"
}

check_ubuntu() {
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || fail "not an Ubuntu system (ID=${ID:-unknown})"
    PREFLIGHT_RELEASE="${VERSION_CODENAME:-}"
    [ -n "$PREFLIGHT_RELEASE" ] || fail "could not determine Ubuntu release codename"
    info "Ubuntu ${VERSION_ID:-?} (${PREFLIGHT_RELEASE})"
}

# systemd-sysupdate is not in PATH on Ubuntu: it ships inside the systemd
# package at /usr/lib/systemd/systemd-sysupdate. There is no separate
# systemd-sysupdate package, so `command -v systemd-sysupdate` fails on
# every Ubuntu host even when the binary is installed. Resolve it once;
# every caller uses PREFLIGHT_SYSUPDATE, never the bare name.
resolve_sysupdate() {
    local cand
    for cand in "$(command -v systemd-sysupdate 2>/dev/null || true)" \
                /usr/lib/systemd/systemd-sysupdate \
                /lib/systemd/systemd-sysupdate; do
        if [ -n "$cand" ] && [ -x "$cand" ]; then
            PREFLIGHT_SYSUPDATE="$cand"
            return 0
        fi
    done
    return 1
}

check_systemd_sysupdate() {
    if ! resolve_sysupdate; then
        local sysv
        sysv="$(systemctl --version 2>/dev/null | head -1)"
        [ -n "$sysv" ] || sysv="unknown"
        fail "systemd-sysupdate not found. It ships inside the systemd package at /usr/lib/systemd/systemd-sysupdate (no separate package exists, and it is not in PATH). It needs systemd >= 251, i.e. Ubuntu 24.04 or newer; this system reports: ${sysv}"
    fi
    local v
    v="$("$PREFLIGHT_SYSUPDATE" --version | head -1 | grep -oE '[0-9]+' | head -1)"
    info "systemd-sysupdate v${v:-?} (${PREFLIGHT_SYSUPDATE})"
    [ "${v:-0}" -ge 254 ] || warn "systemd < 254: PathRelativeTo=esp unsupported; 20-uki.transfer needs it"
    # Which transfer-file extension this sysupdate reads: version-probed
    # (see sysupdate_def_ext); the old --help probe was wrong on 255.
    PREFLIGHT_TRANSFER_EXT="$(sysupdate_def_ext)"
    info "transfer file extension: ${PREFLIGHT_TRANSFER_EXT}"
}

check_esp() {
    local cand
    for cand in /efi /boot/efi /boot; do
        if mountpoint -q "$cand" 2>/dev/null && [ -d "$cand/EFI" ]; then
            PREFLIGHT_ESP="$cand"
            break
        fi
    done
    [ -n "$PREFLIGHT_ESP" ] || fail "no mounted ESP found (checked /efi, /boot/efi, /boot)"
    info "ESP at ${PREFLIGHT_ESP}"
    command -v bootctl >/dev/null 2>&1 || fail "bootctl not found"
    command -v efibootmgr >/dev/null 2>&1 || fail "efibootmgr not found (needed for boot-order backup)"
}

check_secure_boot() {
    # Optional arg overrides the SecureBoot variable path (tests); default
    # is the real EFI variable. v1 UKIs are unsigned and systemd-boot is
    # not Microsoft-signed, so SB-on must fail loudly here — firmware
    # refuses to start them, often silently, falling through to the next
    # entry (which looks like "Linux Boot Manager just doesn't boot").
    local sb_file="${1:-/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c}"
    local sb="unknown"
    if [ -e "$sb_file" ]; then
        # EFI variable files carry 4 attribute bytes before the data byte;
        # the old code gave up as "unknown" here when mokutil was missing,
        # so SB-on slipped through preflight entirely on mokutil-less hosts.
        local sb_byte
        sb_byte="$(od -An -tu1 -j4 -N1 "$sb_file" 2>/dev/null | tr -d ' ')"
        case "$sb_byte" in
            1) sb="SecureBoot enabled (efivars)" ;;
            0) sb="SecureBoot disabled (efivars)" ;;
            *) sb="unknown (efivars unreadable)" ;;
        esac
    elif command -v mokutil >/dev/null 2>&1; then
        sb="$(mokutil --sb-state 2>/dev/null || echo unknown)"
    fi
    info "Secure Boot state: $sb"
    case "$sb" in
        *enabled*|*Enabled*)
            fail "Secure Boot is enabled but v1 UKIs are unsigned and will not boot. Disable Secure Boot in firmware first (signed UKIs are a documented follow-up)."
            ;;
    esac
}

check_var_on_rootfs() {
    # The versioned tree lives under /var/lib/immutable on the state root.
    # If /var is a separate mount, the initrd hook cannot see it yet at
    # local-premount time (fail-open: boots with the state's own /usr).
    if mountpoint -q /var 2>/dev/null && [ "$(findmnt -n -o SOURCE /var)" != "$(findmnt -n -o SOURCE /)" ]; then
        warn "/var is a separate filesystem; the initrd hook runs before it is mounted. Transition still works but the immutable /usr will NOT apply until /var moves onto the rootfs. See docs/DESIGN.md."
    else
        info "/var is on the root filesystem"
    fi
}

check_versions_dir_space() {
    local need_kb="${1:-0}"  # estimated bytes needed, 0 = skip
    [ "$need_kb" -gt 0 ] || return 0
    local avail_kb
    avail_kb="$(df --output=avail -k /var 2>/dev/null | tail -1 | tr -d ' ')"
    info "space available under /var: $((avail_kb / 1024)) MiB; need ~$((need_kb / 1024 / 1024)) MiB"
    [ "$avail_kb" -gt "$((need_kb / 1024))" ] \
        || fail "not enough free space under /var for the versioned tree"
}

run_preflight() {
    require_root
    check_ubuntu
    check_systemd_sysupdate
    check_esp
    check_secure_boot
    check_var_on_rootfs
    info "preflight OK"
}

# Standalone mode: sudo ./preflight.sh
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_preflight
fi
