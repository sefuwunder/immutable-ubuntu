#!/bin/bash
# Regression test: preflight must find systemd-sysupdate on Ubuntu hosts
# that HAVE it installed, even though the binary is not in PATH.
#
# The bug: preflight checked `command -v systemd-sysupdate`, but on Ubuntu
# the binary ships inside the systemd package at
# /usr/lib/systemd/systemd-sysupdate and is never in PATH, so the check
# failed on every Ubuntu host with "systemd-sysupdate not found".
# The fix resolves the path once (PREFLIGHT_SYSUPDATE) and every caller
# uses it instead of the bare name.
#
# Run from anywhere: bash transition/tests/test-sysupdate-path.sh
# Requires: an Ubuntu host with systemd-sysupdate installed (systemd >= 251).
# Lab note: the lab host has no ESP mounted, so preflight stops at the ESP
# check AFTER passing the sysupdate check. That is the assertion: the
# failure must be the ESP one, never the sysupdate one.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
failures=0

# 1. Control: with a scrubbed PATH the bare name must NOT resolve.
#    (This is what the old check tripped over.)
if env PATH=/usr/bin:/bin command -v systemd-sysupdate >/dev/null 2>&1; then
    echo "SKIP: systemd-sysupdate is in PATH on this host; control not applicable"
else
    echo "ok: control confirms systemd-sysupdate is not in PATH (scrubbed PATH)"
fi

# 2. Preflight with a scrubbed PATH must pass the sysupdate check.
#    Needs root: preflight requires it before anything else.
if [ "$(id -u)" != "0" ]; then
    echo "SKIP: preflight run needs root; re-run with sudo"
else
    out="$(env PATH=/usr/bin:/bin bash "$REPO_ROOT/transition/preflight.sh" 2>&1 || true)"
    if echo "$out" | grep -q "systemd-sysupdate not found"; then
        echo "FAIL: preflight still reports systemd-sysupdate missing with scrubbed PATH"
        echo "$out"
        failures=$((failures + 1))
    elif echo "$out" | grep -qE "systemd-sysupdate v[0-9]+"; then
        echo "ok: preflight resolves systemd-sysupdate with scrubbed PATH"
        if echo "$out" | grep -q "no mounted ESP found"; then
            echo "ok: preflight advanced past the sysupdate check to the ESP check"
        fi
    else
        echo "FAIL: preflight output shows neither a version nor the old error:"
        echo "$out"
        failures=$((failures + 1))
    fi
fi

# 3. Static guard: transition.sh must not invoke the bare name.
#    (Comment lines starting with # are exempt.)
if grep -nE '^[[:space:]]*(run )?systemd-sysupdate([[:space:]]|$)' \
        "$REPO_ROOT/transition/transition.sh"; then
    echo "FAIL: bare systemd-sysupdate invocation remains in transition.sh"
    failures=$((failures + 1))
else
    echo "ok: no bare systemd-sysupdate invocations in transition.sh"
fi

# 4. Static guard: preflight's probes must use the resolved path. The
# extension probe is version-based (sysupdate_def_ext); the old --help
# probe was wrong on 255, so its presence here would be a regression.
if grep -q '"$PREFLIGHT_SYSUPDATE" --version' "$REPO_ROOT/transition/preflight.sh" \
    && grep -q 'sysupdate_def_ext' "$REPO_ROOT/transition/preflight.sh" \
    && ! grep -q '"$PREFLIGHT_SYSUPDATE" --help' "$REPO_ROOT/transition/preflight.sh"; then
    echo "ok: preflight probes use the resolved path (version-based extension probe)"
else
    echo "FAIL: preflight probes do not use PREFLIGHT_SYSUPDATE, or the old --help probe is back"
    failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
    echo "test-sysupdate-path: $failures failure(s)"
    exit 1
fi
echo "test-sysupdate-path: all checks passed"
