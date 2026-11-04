#!/bin/bash
# test-build-uki-flags.sh — static guards for build-uki.sh's ukify flags.
# Regression test for the 20261103.2 refusal: ukify takes --os-release as
# TEXT|@PATH, so a bare path is embedded verbatim as the .osrel text (a
# pathname, not os-release data) and systemd-boot refuses it for missing
# fields. The @ prefix is load-bearing; this test pins it.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="build-uki.sh"

fail=0
check() { # check <desc> <cmd...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
not_present() { # not_present <pattern> <file>
    ! grep -qF -- "$1" "$2"
}

check "--os-release uses @ prefix" grep -qF -- '--os-release="@' "$SCRIPT"
check "no bare --os-release path remains" not_present '--os-release="$' "$SCRIPT"
check "--cmdline stays literal text (no @)" not_present '--cmdline="@' "$SCRIPT"
check "--linux stays a plain path (no @)" not_present '--linux="@' "$SCRIPT"
check "--initrd stays a plain path (no @)" not_present '--initrd="@' "$SCRIPT"
check ".osrel build-time gate present" grep -q 'uki-osrel-check' "$SCRIPT"

exit "$fail"
