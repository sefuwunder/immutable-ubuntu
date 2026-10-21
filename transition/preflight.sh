#!/bin/bash
# preflight.sh — checks for transition.sh. Sourced as a library; also
# runnable standalone for a dry assessment:  sudo ./preflight.sh
set -euo pipefail

# Results exported for transition.sh
PREFLIGHT_ESP=""
PREFLIGHT_RELEASE=""
PREFLIGHT_TRANSFER_EXT=".transfer"
PREFLIGHT_VERSION_OK=0

fail() { echo "preflight: ERROR: $*" >&2; exit 1; }
warn() { echo "preflight: WARNING: $*" >&2; }
info() { echo "preflight: $*"; }

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

check_systemd_sysupdate() {
    command -v systemd-sysupdate >/dev/null 2>&1 \
        || fail "systemd-sysupdate not found (systemd too old or minimal install)"
    local v
    v="$(systemd-sysupdate --version | head -1 | grep -oE '[0-9]+' | head -1)"
    info "systemd-sysupdate v${v:-?}"
    [ "${v:-0}" -ge 254 ] || warn "systemd < 254: PathRelativeTo=esp unsupported; 20-uki.transfer needs it"
    # Probe which transfer-file extension this sysupdate reads (.transfer vs .conf).
    if systemd-sysupdate --help 2>/dev/null | grep -qF '*.conf'; then
        PREFLIGHT_TRANSFER_EXT=".conf"
    else
        PREFLIGHT_TRANSFER_EXT=".transfer"
    fi
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
    local sb="unknown"
    if command -v mokutil >/dev/null 2>&1; then
        sb="$(mokutil --sb-state 2>/dev/null || echo unknown)"
    elif [ -e /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c ]; then
        sb="unknown (efivars present, mokutil missing)"
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
