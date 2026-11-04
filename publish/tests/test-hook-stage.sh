#!/bin/bash
# test-hook-stage.sh — static guards for the immutable-usr hook's stage.
# Regression test for the 20261103.3 boot failure: the hook lived in
# scripts/local-premount/, but per the initramfs-tools man page
# local-premount runs after the root device is verified and BEFORE the
# root fs is mounted, so $rootmnt is still an empty initramfs mountpoint
# there and the hook's source path never exists — it fails open and the
# image kernel boots against the state's modules (7.0.0-42 vs 28/29,
# vfat missing, /boot/efi unmountable). local-bottom runs AFTER the
# rootfs is mounted, which is when $rootmnt is usable. This test pins
# the hook to local-bottom everywhere it is referenced.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/mkosi/mkosi.skeleton/etc/initramfs-tools/scripts/local-bottom/immutable-usr"
OLD="$ROOT/mkosi/mkosi.skeleton/etc/initramfs-tools/scripts/local-premount/immutable-usr"

fail=0
check() { # check <desc> <cmd...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
not_present() { # not_present <pattern> <file>
    ! grep -qF -- "$1" "$2"
}

check "hook exists at scripts/local-bottom/immutable-usr" test -f "$HOOK"
check "old scripts/local-premount path is gone" test ! -e "$OLD"
check "hook is executable" test -x "$HOOK"
check "hook header names local-bottom" grep -qF 'local-bottom:' "$HOOK"
check "hook body still bind-mounts via \$rootmnt paths" grep -qF 'rootmnt}/var/lib/immutable' "$HOOK"
check "build-uki.sh gate greps local-bottom/immutable-usr" grep -qF "local-bottom/immutable-usr" "$ROOT/publish/build-uki.sh"
check "build-uki.sh gate has no local-premount/immutable-usr" not_present "local-premount/immutable-usr" "$ROOT/publish/build-uki.sh"
check "DESIGN.md boot flow names local-bottom/immutable-usr" grep -qF "local-bottom/immutable-usr" "$ROOT/docs/DESIGN.md"
check "build-time hook comment names local-bottom script" grep -qF "local-bottom script" "$ROOT/mkosi/mkosi.skeleton/etc/initramfs-tools/hooks/immutable-usr"
check "preflight comment names local-bottom time" grep -qF "local-bottom time" "$ROOT/transition/preflight.sh"
no_old_refs() { # no_old_refs: true iff no old-path reference remains (self excluded)
    ! grep -rF --exclude='test-hook-stage.sh' -- 'local-premount/immutable-usr' "$ROOT" >/dev/null 2>&1
}
check "no remaining local-premount/immutable-usr path references in tree" no_old_refs

exit "$fail"
