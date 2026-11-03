#!/usr/bin/env bash
# Static guards for the EFI boot-order flip (2026-11-03): "Linux Boot
# Manager is 4th (last)" after a transition run meant the reorder had been
# silently skipped (old code: info + continue when the entry was not found
# at reorder time) or had not stuck (firmware ignoring the NVRAM write).
# Both must now fail loudly instead of printing "transition: done" on a
# system that still boots GRUB.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
T="$REPO_ROOT/transition/transition.sh"
failures=0

if grep -q "set boot order manually in firmware" "$T"; then
    echo "FAIL: silent boot-order skip still present"
    failures=$((failures + 1))
else
    echo "ok: no silent boot-order skip"
fi
if grep -q "Linux Boot Manager boot entry not found after bootctl install" "$T"; then
    echo "ok: missing boot entry fails loudly"
else
    echo "FAIL: missing boot entry does not fail loudly"
    failures=$((failures + 1))
fi
if grep -q "not first after" "$T"; then
    echo "ok: post-reorder verification present"
else
    echo "FAIL: no post-reorder verification"
    failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
    echo "test-boot-order: $failures failure(s)"
    exit 1
fi
echo "test-boot-order: all checks passed"
