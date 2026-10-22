#!/bin/bash
# build-uki.sh — assemble the immutable-ubuntu UKI explicitly with ukify.
#
# Why not mkosi's UKI machinery? Two version-fragile behaviors burned us:
#   1. UnifiedKernelImages defaults to 'auto', which silently skips the
#      ukify step when components are missing (exit 0, no .efi).
#   2. mkosi's default initrd is mkosi-initrd (systemd-based), which does
#      not run our initramfs-tools hook — the hook that mounts the
#      versioned /usr. (docs/DESIGN.md anticipated exactly this.)
#
# So we do it ourselves, from the tarball mkosi reliably produces:
#   1. extract the image tarball to a temp dir
#   2. chroot in and run the IMAGE's initramfs-tools (mkinitramfs), which
#      DOES run our /etc/initramfs-tools hook from the mkosi skeleton
#   3. verify the hook landed in the initrd (loud failure otherwise)
#   4. ukify build: kernel + initrd + immutable.version=<v> cmdline +
#      os-release -> <out>.efi
#
# Usage: ./build-uki.sh --version <v> --tar <tarball> --out <efi>
# Build-host needs: zstd/xz (via tar), initramfs-tools (mkinitramfs,
# lsinitramfs), ukify (systemd-ukify), EFI stub (systemd-boot-efi).
set -euo pipefail

VERSION=""; TAR=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2;;
        --tar) TAR="$2"; shift 2;;
        --out) OUT="$2"; shift 2;;
        -h|--help) sed -n '2,20p' "$0"; exit 0;;
        *) echo "build-uki: unknown argument: $1" >&2; exit 1;;
    esac
done
[ -n "$VERSION" ] && [ -n "$TAR" ] && [ -n "$OUT" ] \
    || { echo "build-uki: --version, --tar and --out are required" >&2; exit 1; }

fail() { echo "build-uki: ERROR: $*" >&2; exit 1; }
info() { echo "build-uki: $*"; }

command -v mkinitramfs >/dev/null 2>&1 || fail "mkinitramfs not found on build host (sudo apt install initramfs-tools)"
command -v lsinitramfs >/dev/null 2>&1 || fail "lsinitramfs not found on build host (sudo apt install initramfs-tools)"
command -v ukify >/dev/null 2>&1 || fail "ukify not found on build host (sudo apt install systemd-ukify)"
[ -e /usr/lib/systemd/boot/efi/linuxx64.efi.stub ] || fail "EFI stub not found on build host (sudo apt install systemd-boot-efi)"
[ -f "$TAR" ] || fail "tarball not found: $TAR"
[ "$(id -u)" = "0" ] || fail "the chroot step needs root (sudo)"

WORK="$(mktemp -d)"
R="$WORK/root"
cleanup() {
    # Detach /proc if the main flow didn't already (best effort, quiet).
    umount -l "$R/proc" 2>/dev/null || true
    # Never rm -rf a tree that is still mounted: that spams
    # "Operation not permitted" for every file under the mount.
    if grep -qs "[[:space:]]$R/proc[[:space:]]" /proc/mounts 2>/dev/null; then
        echo "build-uki: WARNING: $R/proc is still mounted; leaving $WORK for manual cleanup" >&2
        echo "build-uki:   sudo umount -l $R/proc && sudo rm -rf $WORK" >&2
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

info "extracting image tarball..."
mkdir -p "$R"
tar -a -xf "$TAR" -C "$R"

KVER="$(ls "$R/usr/lib/modules/" 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$KVER" ] || fail "no kernel modules in image"
[ -f "$R/boot/vmlinuz-$KVER" ] || fail "no /boot/vmlinuz-$KVER in image"
info "kernel: $KVER"

info "building initrd with the image's initramfs-tools (chroot; runs our hook)..."
# Only /proc is mounted: mkinitramfs assembles files and doesn't need
# /sys or /dev, and skipping those rbinds avoids unmount trouble later.
mount -t proc -o nosuid,noexec,nodev proc "$R/proc" || fail "could not mount /proc in chroot"
chroot "$R" /usr/sbin/mkinitramfs -o /tmp/immutable.cpio "$KVER" || fail "mkinitramfs failed"
cp "$R/tmp/immutable.cpio" "$WORK/immutable.cpio"
# Unmount now (not just in the EXIT trap) so a busy mount fails loudly
# here instead of spamming rm errors at exit.
if ! umount "$R/proc" 2>/dev/null; then
    umount -l "$R/proc" 2>/dev/null || true
    info "warning: $R/proc was busy; lazy-unmounted"
fi

info "verifying immutable-usr hook is in the initrd..."
lsinitramfs "$WORK/immutable.cpio" 2>/dev/null | grep -q 'local-premount/immutable-usr' \
    || fail "immutable-usr hook NOT in initrd — versioned /usr would never mount"
info "hook verified"

OSREL=""
for p in "$R/usr/lib/os-release" "$R/etc/os-release"; do
    if [ -f "$p" ]; then OSREL="$p"; break; fi
done
[ -n "$OSREL" ] || info "no os-release in image; UKI will lack os-release metadata"

info "assembling UKI with ukify..."
# shellcheck disable=SC2086
ukify build \
    --linux="$R/boot/vmlinuz-$KVER" \
    --initrd="$WORK/immutable.cpio" \
    --cmdline="immutable.version=$VERSION" \
    ${OSREL:+--os-release="$OSREL"} \
    --output="$OUT" || fail "ukify build failed"

info "UKI written: $OUT ($(du -h "$OUT" | cut -f1))"
