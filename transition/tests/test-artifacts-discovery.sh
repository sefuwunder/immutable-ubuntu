#!/bin/bash
# Regression test: transition.sh must fail helpfully when --artifacts holds
# no ubuntu_*.efi, and must find artifacts in a well-formed directory.
#
# The bug: the old error was just "no ubuntu_*.efi found in $ARTIFACTS",
# which hid the two common causes — --artifacts pointed at the parent of
# the release directory (publish.sh lays out <out>/<release>/, e.g.
# out/noble/), or publish.sh never ran. The new error lists the directory
# contents, states the expected layout, and suggests the subdirectory when
# it holds the files.
#
# Run from anywhere: bash transition/tests/test-artifacts-discovery.sh
# Requires root (preflight requires it) and unshare -rm for a private
# mount namespace holding a fake ESP. If unshare cannot mount, the
# end-to-end cases SKIP and only the static guards run.
# Everything runs with --dry-run: nothing on the host is modified, and the
# fake ESP lives only inside the throwaway namespace.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
failures=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Static guard: the diagnostic text must exist in transition.sh.
if grep -q "Did you mean" "$REPO_ROOT/transition/transition.sh" \
    && grep -q "publish.sh output directory for one release" "$REPO_ROOT/transition/transition.sh"; then
    echo "ok: diagnostic error text present in transition.sh"
else
    echo "FAIL: diagnostic error text missing from transition.sh"
    failures=$((failures + 1))
fi

if [ "$(id -u)" != "0" ]; then
    echo "SKIP: end-to-end cases need root (preflight requires it); re-run with sudo"
elif ! command -v unshare >/dev/null 2>&1; then
    echo "SKIP: unshare not available; end-to-end cases need a private mount namespace"
else
    # Inner script: runs inside unshare -rm with a fake ESP on /efi and
    # stub bootctl/efibootmgr (preflight only checks they exist; every
    # later use is dry-run-echoed, never executed).
    cat > "$WORK/inner.sh" <<'INNER'
set -u
REPO_ROOT="$1"; CASE="$2"; ART="$3"
ESP_DIR="$(mktemp -d)"
mkdir -p "$ESP_DIR/EFI" /efi
mount --bind "$ESP_DIR" /efi || exit 99
BIN_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' > "$BIN_DIR/bootctl"
printf '#!/bin/sh\nexit 0\n' > "$BIN_DIR/efibootmgr"
chmod +x "$BIN_DIR/bootctl" "$BIN_DIR/efibootmgr"
export PATH="$BIN_DIR:/usr/bin:/bin"
exec bash "$REPO_ROOT/transition/transition.sh" --artifacts "$ART" --from-local --yes --dry-run
INNER
    run_case() {
        # Exit 99 from inner.sh means the fake-ESP bind mount failed.
        unshare -rm bash "$WORK/inner.sh" "$REPO_ROOT" "$1" "$2" 2>&1
    }

    # Case A: empty artifacts dir -> diagnostic error, <empty> contents.
    EMPTY_DIR="$WORK/empty"; mkdir -p "$EMPTY_DIR"
    out="$(run_case empty "$EMPTY_DIR")"; rc=$?
    if [ "$rc" -eq 99 ]; then
        echo "SKIP: mount namespace unavailable in this environment (fake ESP bind failed)"
    elif echo "$out" | grep -q "no ubuntu_\*.efi found in $EMPTY_DIR (contents: <empty>)"; then
        echo "ok: empty dir reports <empty> contents"
    else
        echo "FAIL: empty-dir case did not report the diagnostic error:"
        echo "$out" | tail -5
        failures=$((failures + 1))
    fi

    # Case B: parent dir, files one level down -> hint names the subdir.
    PARENT_DIR="$WORK/parent"; mkdir -p "$PARENT_DIR/noble"
    touch "$PARENT_DIR/noble/ubuntu_20261103.1.efi"
    out="$(run_case parent "$PARENT_DIR")"; rc=$?
    if [ "$rc" -eq 99 ]; then
        echo "SKIP: mount namespace unavailable in this environment (fake ESP bind failed)"
    elif echo "$out" | grep -q "Did you mean $PARENT_DIR/noble/"; then
        echo "ok: parent dir hints at the release subdirectory"
    else
        echo "FAIL: parent-dir case did not hint at noble/:"
        echo "$out" | tail -5
        failures=$((failures + 1))
    fi

    # Case C: well-formed dir -> dry-run reaches the summary.
    GOOD_DIR="$WORK/good"; mkdir -p "$GOOD_DIR"
    touch "$GOOD_DIR/ubuntu_20261103.1.efi" "$GOOD_DIR/ubuntu_20261103.1.root.tar.zst"
    out="$(run_case good "$GOOD_DIR")"; rc=$?
    if [ "$rc" -eq 99 ]; then
        echo "SKIP: mount namespace unavailable in this environment (fake ESP bind failed)"
    elif echo "$out" | grep -q "transition: done"; then
        echo "ok: well-formed dir reaches the dry-run summary"
    else
        echo "FAIL: well-formed dir did not reach the dry-run summary:"
        echo "$out" | tail -8
        failures=$((failures + 1))
    fi
fi

# Tidy the /efi mountpoint the namespace runs may have created.
rmdir /efi 2>/dev/null || true

if [ "$failures" -gt 0 ]; then
    echo "test-artifacts-discovery: $failures failure(s)"
    exit 1
fi
echo "test-artifacts-discovery: all checks passed"
