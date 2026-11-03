#!/usr/bin/env bash
# Regression tests for the sysupdate transfer-definition validation errors
# first hit on a resolute host (2026-11-03):
#   20-uki.transfer:1: Target path is not a normalized, absolute path: EFI/Linux
#   10-system.transfer:1: Source path is not a normalized, absolute path: <relative dir>
#
# The first is a repo bug (a relative Target path is invalid even with
# PathRelativeTo set); the second is transition.sh carrying a relative
# --artifacts verbatim into the temp defs. The fixes: an absolute Target
# path in 20-uki.transfer, and canonicalize_dir() in preflight.sh applied
# to --artifacts before the defs are written.
#
# Test 1 validates the (transformed) repo defs against the real
# systemd-sysupdate binary: list is read-only and only parses the defs
# before enumerating, so any path error surfaces without installing.
# Test 2 unit-tests canonicalize_dir via preflight.sh's sourceable library.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0

# --- Test 1: repo defs pass real sysupdate path validation ---------------
SYSUPDATE="$(command -v systemd-sysupdate || true)"
[ -n "$SYSUPDATE" ] || SYSUPDATE=/usr/lib/systemd/systemd-sysupdate
[ -x "$SYSUPDATE" ] || SYSUPDATE=/lib/systemd/systemd-sysupdate
if [ ! -x "$SYSUPDATE" ]; then
    echo "SKIP: no systemd-sysupdate binary on this host"
else
    # Extension the local sysupdate expects: the real probe from preflight.sh
    # (version-based; the old --help probe was wrong on 255).
    EXT="$(bash -c 'source "$1"; PREFLIGHT_SYSUPDATE="$2"; sysupdate_def_ext' \
        _ "$REPO_ROOT/transition/preflight.sh" "$SYSUPDATE")"
    echo "sysupdate def extension on this host: $EXT"
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
    ART="$WORK/art"; mkdir -p "$ART"
    touch "$ART/ubuntu_20261103.1.efi" "$ART/ubuntu_20261103.1.root.tar.zst"
    DEFS="$WORK/defs"; mkdir -p "$DEFS"
    # Same transform transition.sh applies for the initial install,
    # including the probed extension (pre-257 sysupdate ignores .transfer).
    python3 - "$REPO_ROOT/sysupdate" "$DEFS" "$ART" "$EXT" <<'PYEOF'
import sys, configparser, pathlib
srcdir, dstdir, artdir, ext = sys.argv[1:5]
local_type = {"url-tar": "tar", "url-file": "regular-file"}
for src in sorted(pathlib.Path(srcdir).glob("*.transfer")):
    cp = configparser.ConfigParser()
    cp.optionxform = str
    cp.read(src)
    cp["Source"]["Type"] = local_type[cp["Source"]["Type"]]
    cp["Source"]["Path"] = artdir
    if "Verify" in cp["Transfer"]:
        del cp["Transfer"]["Verify"]
    with open(pathlib.Path(dstdir) / (src.stem + ext), "w") as f:
        cp.write(f)
PYEOF
    out="$("$SYSUPDATE" list --definitions="$DEFS" 2>&1 || true)"
    if echo "$out" | grep -q "No transfer definitions found"; then
        echo "FAIL: sysupdate did not load the definitions (extension $EXT?)"
        failures=$((failures + 1))
    elif echo "$out" | grep -q "not a normalized, absolute path"; then
        echo "FAIL: sysupdate still reports a path error:"
        echo "$out" | grep "not a normalized" | head -3
        failures=$((failures + 1))
    else
        echo "ok: transformed repo defs pass sysupdate path validation (defs loaded, no path errors)"
    fi
fi

# --- Test 2: canonicalize_dir (preflight.sh library, sourced) ------------
run_canon() {
    bash -c 'source "$1"; canonicalize_dir "$2"' _ "$REPO_ROOT/transition/preflight.sh" "$1"
}
WORK2="$(mktemp -d)"; trap 'rm -rf "$WORK2"' EXIT
mkdir -p "$WORK2/good" "$WORK2/sub"
got="$(cd "$WORK2" && run_canon "good")"
if [ "$got" = "$WORK2/good" ]; then
    echo "ok: relative dir resolves to an absolute path"
else
    echo "FAIL: relative dir -> '$got' (want $WORK2/good)"; failures=$((failures + 1))
fi
got="$(run_canon "$WORK2/good/")"
if [ "$got" = "$WORK2/good" ]; then
    echo "ok: trailing slash stripped"
else
    echo "FAIL: trailing slash -> '$got'"; failures=$((failures + 1))
fi
got="$(cd "$WORK2" && run_canon "sub/../good")"
if [ "$got" = "$WORK2/good" ]; then
    echo "ok: .. components resolved"
else
    echo "FAIL: .. components -> '$got'"; failures=$((failures + 1))
fi
got="$(run_canon "$WORK2/nope" 2>/dev/null || true)"
if [ -z "$got" ]; then
    echo "ok: missing dir fails with empty output"
else
    echo "FAIL: missing dir -> '$got'"; failures=$((failures + 1))
fi

# --- Test 3: no vfat-symlink remnants (2026-11-03) -----------------------
# The ESP is vfat, which has no symlinks: a CurrentSymlink on the UKI
# transfer fails the whole update ("Operation not permitted"), and no
# entry may point at the old ubuntu_current.efi name. The default is the
# ubuntu_*.efi glob instead.
if [ -z "${DEFS:-}" ]; then
    echo "SKIP: no transformed defs (sysupdate missing); CurrentSymlink check skipped"
elif grep -q "CurrentSymlink" "$DEFS/20-uki$EXT"; then
    echo "FAIL: transformed 20-uki def still carries CurrentSymlink"
    failures=$((failures + 1))
else
    echo "ok: transformed 20-uki def carries no CurrentSymlink"
fi
if grep -rq "ubuntu_current" "$REPO_ROOT/transition/transition.sh" \
    "$REPO_ROOT/sysupdate/20-uki.transfer"; then
    echo "FAIL: ubuntu_current still referenced in transition.sh or 20-uki.transfer"
    failures=$((failures + 1))
else
    echo "ok: no ubuntu_current reference in transition.sh or 20-uki.transfer"
fi
if grep -qF "set-default 'ubuntu_*.efi'" "$REPO_ROOT/transition/transition.sh"; then
    echo "ok: default is the ubuntu_*.efi glob"
else
    echo "FAIL: transition.sh does not set the ubuntu_*.efi default glob"
    failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
    echo "test-sysupdate-defs: all checks passed"
else
    echo "test-sysupdate-defs: $failures check(s) FAILED"
    exit 1
fi
