#!/bin/bash
# rollback.sh — undo transition.sh's boot changes.
#
# Restores the pre-transition EFI boot order from
# /var/lib/immutable/boot-order.backup. The original Ubuntu system was never
# modified, so rebooting after this returns you to it exactly.
#
# This does NOT remove the installed artifacts (/var/lib/immutable/versions,
# ESP UKIs, /etc/sysupdate.d). They are inert once the original system boots.
# Re-run transition.sh to go immutable again.
set -euo pipefail

fail() { echo "rollback: ERROR: $*" >&2; exit 1; }
info() { echo "rollback: $*"; }

[ "$(id -u)" = "0" ] || fail "must run as root (sudo)"

BACKUP=/var/lib/immutable/boot-order.backup
[ -f "$BACKUP" ] || fail "no boot-order backup found at $BACKUP (was transition.sh run?)"

orig_order="$(grep '^BootOrder:' "$BACKUP" | cut -d: -f2 | tr -d ' ')"
[ -n "$orig_order" ] || fail "could not parse BootOrder from $BACKUP"

info "restoring EFI boot order to: $orig_order"
efibootmgr -o "$orig_order" >/dev/null
info "done. Reboot to return to the original system."
