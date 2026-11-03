#!/bin/bash
# test-uki-os-release.sh — fixture tests for publish/uki-os-release.sh.
# The UKI is not listed by systemd-boot at all when its embedded
# os-release lacks PRETTY_NAME, ID, or VERSION_ID/BUILD_ID, so the
# augmentation must guarantee those keys (and IMAGE_ID/IMAGE_VERSION)
# while preserving every value the image already provides.
set -euo pipefail
cd "$(dirname "$0")/.."
HELPER="$PWD/uki-os-release.sh"
[ -x "$HELPER" ] || chmod +x "$HELPER"

fail=0
check() { # check <desc> <cmd...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# no key may appear twice in the output
no_dups() { # no_dups <file>
    [ -z "$(cut -d= -f1 "$1" | sort | uniq -d)" ]
}

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# 1. Ubuntu-like os-release: values preserved, IMAGE_* added, no dups.
cat > "$W/ubuntu" <<'EOF'
PRETTY_NAME="Ubuntu 26.04 LTS"
NAME="Ubuntu"
VERSION_ID="26.04"
VERSION="26.04 LTS (Resolute Raccoon)"
ID=ubuntu
ID_LIKE=debian
HOME_URL="https://ubuntu.com/"
EOF
"$HELPER" "$W/ubuntu" 20261103.2 > "$W/out1"
check "ubuntu PRETTY_NAME preserved" grep -q '^PRETTY_NAME="Ubuntu 26.04 LTS"$' "$W/out1"
check "ubuntu ID preserved" grep -q '^ID=ubuntu$' "$W/out1"
check "ubuntu VERSION_ID preserved" grep -q '^VERSION_ID="26.04"$' "$W/out1"
check "ubuntu gains IMAGE_ID" grep -q '^IMAGE_ID=immutable-ubuntu$' "$W/out1"
check "ubuntu gains IMAGE_VERSION" grep -q '^IMAGE_VERSION=20261103.2$' "$W/out1"
check "ubuntu output has no duplicate keys" no_dups "$W/out1"

# 2. Empty input: full minimal valid set synthesized.
: > "$W/empty"
"$HELPER" "$W/empty" 20261103.2 > "$W/out2"
check "empty gains PRETTY_NAME" grep -q '^PRETTY_NAME=' "$W/out2"
check "empty gains ID" grep -q '^ID=' "$W/out2"
check "empty gains VERSION_ID" grep -q '^VERSION_ID=20261103.2$' "$W/out2"
check "empty gains IMAGE_ID" grep -q '^IMAGE_ID=' "$W/out2"
check "empty gains IMAGE_VERSION" grep -q '^IMAGE_VERSION=20261103.2$' "$W/out2"
check "empty output has no duplicate keys" no_dups "$W/out2"

# 3. Missing input (/dev/null): same as empty.
"$HELPER" /dev/null 20261103.2 > "$W/out3"
check "devnull gains required triple" grep -q '^PRETTY_NAME=' "$W/out3" && grep -q '^ID=' "$W/out3" && grep -q '^VERSION_ID=' "$W/out3"
check "devnull output has no duplicate keys" no_dups "$W/out3"

# 4. BUILD_ID present, VERSION_ID absent: VERSION_ID must NOT be added
# (systemd-boot accepts VERSION_ID *or* BUILD_ID).
printf 'PRETTY_NAME="X"\nID=x\nBUILD_ID=abc123\n' > "$W/buildid"
"$HELPER" "$W/buildid" 20261103.2 > "$W/out4"
check "BUILD_ID satisfies version requirement" grep -q '^BUILD_ID=abc123$' "$W/out4"
check "no VERSION_ID added when BUILD_ID present" sh -c '! grep -q "^VERSION_ID=" "$0"' "$W/out4"
check "buildid output has no duplicate keys" no_dups "$W/out4"

# 5. IMAGE_VERSION already present: preserved, not duplicated or overridden.
printf 'PRETTY_NAME="X"\nID=x\nVERSION_ID="1"\nIMAGE_VERSION=20261101.9\n' > "$W/imgver"
"$HELPER" "$W/imgver" 20261103.2 > "$W/out5"
check "existing IMAGE_VERSION preserved" grep -q '^IMAGE_VERSION=20261101.9$' "$W/out5"
check "imgver output has no duplicate keys" no_dups "$W/out5"

# 6. Missing version argument: loud failure, no output.
check "missing version fails" sh -c '! "$0" "$1" >/dev/null 2>&1' "$HELPER" "$W/ubuntu"

exit "$fail"
