#!/bin/bash
# uki-os-release.sh — augment an os-release file so systemd-boot accepts
# it in a UKI.
#
# systemd-boot refuses a UKI whose embedded os-release lacks PRETTY_NAME,
# ID, or VERSION_ID/BUILD_ID ("Missing fields in os-release data from
# unified kernel image ..., refusing") — and then the UKI is not listed
# at all, so no default glob can ever select it. The image's os-release
# is Ubuntu's, but do not trust it: start from it when present and add
# any missing required field, plus IMAGE_ID/IMAGE_VERSION (publish.sh
# intends mkosi to write IMAGE_VERSION; build-uki.sh guarantees it).
#
# Usage: uki-os-release.sh [input-os-release] <version>
#   input defaults to /dev/null (synthesize from scratch).
#   Output goes to stdout. Existing values are preserved; only missing
#   keys are added, so no key ever appears twice.
set -euo pipefail

SRC="${1:-/dev/null}"
VERSION="${2:-}"
[ -n "$VERSION" ] || { echo "uki-os-release: version required" >&2; exit 1; }

if [ -f "$SRC" ]; then cat "$SRC"; fi
grep -q '^PRETTY_NAME=' "$SRC" 2>/dev/null || echo 'PRETTY_NAME="Immutable Ubuntu"'
grep -q '^ID=' "$SRC" 2>/dev/null || echo 'ID=immutable-ubuntu'
if ! grep -q '^VERSION_ID=' "$SRC" 2>/dev/null && ! grep -q '^BUILD_ID=' "$SRC" 2>/dev/null; then
    echo "VERSION_ID=$VERSION"
fi
grep -q '^IMAGE_ID=' "$SRC" 2>/dev/null || echo 'IMAGE_ID=immutable-ubuntu'
grep -q '^IMAGE_VERSION=' "$SRC" 2>/dev/null || echo "IMAGE_VERSION=$VERSION"
