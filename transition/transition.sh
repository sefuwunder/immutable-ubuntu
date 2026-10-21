#!/bin/bash
# transition.sh — convert a running Ubuntu install into immutable-ubuntu.
#
# ADDITIVE by design: the original system is never modified in place. The
# script installs versioned artifacts (UKI + system tree) via
# systemd-sysupdate itself, adds a systemd-boot entry, and flips the EFI
# boot order. The original GRUB boot path is untouched: rebooting into
# "Ubuntu (original)" — or running rollback.sh — returns you to the
# pre-transition system byte-for-byte.
#
# Usage:
#   sudo ./transition.sh --artifacts <dir> [--source-url <url> | --from-local]
#                        [--with-isolation] [--yes] [--dry-run]
#
#   --artifacts   directory holding ubuntu_<version>.efi and
#                 ubuntu_<version>.root.tar.xz (as produced by publish.sh)
#   --source-url  HTTPS base URL for FUTURE updates (the release codename is
#                 appended, e.g. https://host/x -> https://host/x/noble/).
#                 Use --from-local to skip remote updates entirely: transfer
#                 defs are installed with local tar/regular-file sources
#                 pointed at /var/lib/immutable/incoming/.
#   --with-isolation  also run ../isolation/setup.sh (podman/flatpak/distrobox)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/preflight.sh"

ARTIFACTS=""
SOURCE_URL=""
FROM_LOCAL=0
WITH_ISOLATION=0
YES=0
DRY_RUN=0

VERSION=""
ESP=""
TRANSFER_EXT=""

fail() { echo "transition: ERROR: $*" >&2; exit 1; }
info() { echo "transition: $*"; }
run() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "dry-run: $*"
    else
        "$@"
    fi
}
confirm() {
    [ "$YES" = "1" ] && return 0
    read -r -p "$1 [y/N] " ans
    case "$ans" in [yY][eE][sS]|[yY]) ;; *) fail "aborted by user";; esac
}

usage() {
    sed -n '2,20p' "$0"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts) ARTIFACTS="$2"; shift 2;;
        --source-url) SOURCE_URL="$2"; shift 2;;
        --from-local) FROM_LOCAL=1; shift;;
        --with-isolation) WITH_ISOLATION=1; shift;;
        --yes) YES=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage 0;;
        *) fail "unknown argument: $1";;
    esac
done

[ -n "$ARTIFACTS" ] || { usage 1; }
[ -d "$ARTIFACTS" ] || fail "artifacts directory not found: $ARTIFACTS"
if [ "$FROM_LOCAL" = "0" ] && [ -z "$SOURCE_URL" ]; then
    fail "set --source-url <https-url> for future updates, or --from-local to skip remote updates"
fi

# ---------------------------------------------------------------- preflight
run_preflight
ESP="$PREFLIGHT_ESP"
TRANSFER_EXT="$PREFLIGHT_TRANSFER_EXT"

# Pick the newest artifact version present (sort -V on the @v field).
mapfile -t _efis < <(ls "$ARTIFACTS"/ubuntu_*.efi 2>/dev/null || true)
[ "${#_efis[@]}" -gt 0 ] || fail "no ubuntu_*.efi found in $ARTIFACTS"
VERSION="$(printf '%s\n' "${_efis[@]}" | sed 's/.*ubuntu_//; s/\.efi$//' | sort -V | tail -1)"
info "artifact version: $VERSION"
[ -f "$ARTIFACTS/ubuntu_${VERSION}.root.tar.xz" ] \
    || fail "missing $ARTIFACTS/ubuntu_${VERSION}.root.tar.xz"

# The artifacts must be built for THIS Ubuntu release (/usr must match /etc).
if [ -f "$ARTIFACTS/release" ]; then
    art_release="$(tr -d ' \n' < "$ARTIFACTS/release")"
    [ "$art_release" = "$PREFLIGHT_RELEASE" ] \
        || fail "artifacts built for '$art_release' but this system is '$PREFLIGHT_RELEASE' (refusing: /usr and /etc must come from the same release)"
    info "artifact release matches this system ($art_release)"
else
    echo "transition: WARNING: no release file in artifacts dir; cannot verify release match" >&2
fi

# Space: tarball + unpacked tree + margin.
_tar_kb="$(du -k "$ARTIFACTS/ubuntu_${VERSION}.root.tar.xz" | cut -f1)"
check_versions_dir_space "$((_tar_kb * 3 * 1024))"

confirm "Transition this system to immutable-ubuntu $VERSION?"

# ------------------------------------------------- install via sysupdate
# The first install goes through systemd-sysupdate itself, with the [Source]
# sections rewritten to the local artifacts dir, so the installed state is
# exactly what later remote updates produce.
info "installing version $VERSION through systemd-sysupdate (local source)"
_tmpdefs="$(mktemp -d)"
trap 'rm -rf "$_tmpdefs"' EXIT
python3 - "$REPO_ROOT/sysupdate" "$_tmpdefs" "$ARTIFACTS" <<'PYEOF'
import sys, configparser, pathlib
srcdir, dstdir, artdir = sys.argv[1], sys.argv[2], sys.argv[3]
local_type = {"url-tar": "tar", "url-file": "regular-file"}
for src in sorted(pathlib.Path(srcdir).glob("*.transfer")):
    cp = configparser.ConfigParser()
    cp.optionxform = str
    cp.read(src)
    stype = cp["Source"]["Type"]
    cp["Source"]["Type"] = local_type[stype]
    cp["Source"]["Path"] = artdir
    if "Verify" in cp["Transfer"]:
        del cp["Transfer"]["Verify"]  # local sources are not verified
    with open(pathlib.Path(dstdir) / src.name, "w") as f:
        cp.write(f)
print("local transfer definitions written")
PYEOF

run systemd-sysupdate --definitions="$_tmpdefs" update
run systemd-sysupdate --definitions="$_tmpdefs" vacuum 2>/dev/null || true

# Sanity: the installed version must now be visible.
if [ "$DRY_RUN" = "0" ]; then
    systemd-sysupdate list --definitions="$_tmpdefs" | grep -q "$VERSION" \
        || fail "version $VERSION not listed after install"
    [ -L "$ESP/EFI/Linux/ubuntu_current.efi" ] \
        || fail "CurrentSymlink $ESP/EFI/Linux/ubuntu_current.efi missing after install"
    [ -d "/var/lib/immutable/versions/$VERSION" ] \
        || fail "versioned tree /var/lib/immutable/versions/$VERSION missing after install"
fi
info "artifacts installed"

# ------------------------------------------- persistent transfer definitions
# Future updates come from the remote URL, or from a local incoming dir with
# --from-local (url-* source types require HTTP/HTTPS, so local mode rewrites
# them to tar/regular-file — same transform as the initial install).
info "installing transfer definitions to /etc/sysupdate.d/"
run mkdir -p /etc/sysupdate.d
if [ "$FROM_LOCAL" = "1" ]; then
    _mode="local"; _path="/var/lib/immutable/incoming"
    run mkdir -p /var/lib/immutable/incoming
else
    _mode="url"; _path="$SOURCE_URL"
fi
if [ "$DRY_RUN" = "1" ]; then
    echo "dry-run: generate transfer defs (mode=$_mode, path=$_path) -> /etc/sysupdate.d/*${TRANSFER_EXT}"
else
    python3 - "$REPO_ROOT/sysupdate" "/etc/sysupdate.d" "$TRANSFER_EXT" "$_mode" "$_path" <<'PYEOF'
import sys, configparser, pathlib
srcdir, dstdir, ext, mode, path = sys.argv[1:6]
local_type = {"url-tar": "tar", "url-file": "regular-file"}
for src in sorted(pathlib.Path(srcdir).glob("*.transfer")):
    cp = configparser.ConfigParser()
    cp.optionxform = str
    cp.read(src)
    if mode == "local":
        stype = cp["Source"]["Type"]
        cp["Source"]["Type"] = local_type[stype]
        cp["Source"]["Path"] = path
        if "Verify" in cp["Transfer"]:
            del cp["Transfer"]["Verify"]  # local sources are not verified
    else:
        old = cp["Source"]["Path"]
        assert old.startswith("https://immutable-ubuntu.example.com/"), old
        cp["Source"]["Path"] = old.replace(
            "https://immutable-ubuntu.example.com/", path.rstrip("/") + "/", 1)
    dest = pathlib.Path(dstdir) / (src.stem + ext)
    with open(dest, "w") as f:
        cp.write(f)
    dest.chmod(0o644)
print("transfer definitions installed")
PYEOF
fi
# Protect the just-installed (and soon booted) version from garbage collection.
# (%A cannot be used: os-release VERSION_ID does not follow our YYYYMMDD.N scheme.)
run mkdir -p "/etc/sysupdate.d/10-system${TRANSFER_EXT}.d" "/etc/sysupdate.d/20-uki${TRANSFER_EXT}.d"
if [ "$DRY_RUN" = "0" ]; then
    printf '[Transfer]\nProtectVersion=%s\n' "$VERSION" > "/etc/sysupdate.d/10-system${TRANSFER_EXT}.d/protect.conf"
    printf '[Transfer]\nProtectVersion=%s\n' "$VERSION" > "/etc/sysupdate.d/20-uki${TRANSFER_EXT}.d/protect.conf"
else
    echo "dry-run: write ProtectVersion=$VERSION drop-ins"
fi
run systemctl enable --now systemd-sysupdate.timer 2>/dev/null || \
    info "systemd-sysupdate.timer not available; run 'systemd-sysupdate update' manually"

# ---------------------------------------------------------------- bootloader
info "installing systemd-boot to $ESP (GRUB left untouched)"
run bootctl install --esp-path="$ESP" >/dev/null
# Immutable entry (boots the CurrentSymlink UKI).
run mkdir -p "$ESP/loader/entries"
if [ "$DRY_RUN" = "0" ]; then
    cat > "$ESP/loader/entries/immutable-ubuntu.conf" <<'EOF'
title   Immutable Ubuntu
sort-key immutable-ubuntu
efi     /EFI/Linux/ubuntu_current.efi
EOF
    # Original system entry (chainloads the untouched GRUB).
    grub_efi=""
    for g in "$ESP/EFI/ubuntu/grubx64.efi" "$ESP/EFI/ubuntu/shimx64.efi"; do
        if [ -f "$g" ]; then grub_efi="${g#"$ESP"}"; break; fi
    done
    if [ -n "$grub_efi" ]; then
        cat > "$ESP/loader/entries/ubuntu-original.conf" <<EOF
title   Ubuntu (original system)
sort-key ubuntu-original
efi     ${grub_efi}
EOF
        info "original-system chainload entry written"
    else
        info "no Ubuntu GRUB binary found on ESP; skipping original-system entry"
    fi
    # Back up boot order, then prefer systemd-boot. Roll back with rollback.sh.
    run mkdir -p /var/lib/immutable
    if [ "$DRY_RUN" = "0" ]; then
        efibootmgr -v > /var/lib/immutable/boot-order.backup
    else
        echo "dry-run: back up EFI boot order to /var/lib/immutable/boot-order.backup"
    fi
    sb_num="$(efibootmgr | grep -i 'Linux Boot Manager' | grep -oE 'Boot[0-9A-Fa-f]+' | head -1 | sed 's/Boot//')"
    if [ -n "$sb_num" ]; then
        cur_order="$(efibootmgr | grep '^BootOrder:' | cut -d: -f2 | tr -d ' ')"
        new_order="${sb_num},$(echo "$cur_order" | tr ',' '\n' | grep -v "^${sb_num}$" | paste -sd, -)"
        run efibootmgr -o "$new_order" >/dev/null
        info "EFI boot order updated (backup at /var/lib/immutable/boot-order.backup)"
    else
        info "could not find 'Linux Boot Manager' boot entry; set boot order manually in firmware"
    fi
    run bootctl set-default immutable-ubuntu.conf
else
    echo "dry-run: write loader entries + update EFI boot order"
fi

# ------------------------------------------------- stop host mutation sources
info "disabling apt-based background mutation (unattended-upgrades)"
if systemctl list-unit-files 2>/dev/null | grep -q '^unattended-upgrades.service'; then
    run systemctl disable --now unattended-upgrades.service
fi
for u in apt-daily.service apt-daily-upgrade.service; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
        run systemctl disable --now "$u" 2>/dev/null || true
    fi
done

# Friendly apt guard: host /usr is read-only; installs belong in containers.
run mkdir -p /etc/profile.d
if [ "$DRY_RUN" = "0" ]; then
    cat > /etc/profile.d/immutable-ubuntu.sh <<'EOF'
# immutable-ubuntu: host /usr is read-only and version-managed by
# systemd-sysupdate. Install software with flatpak, distrobox or podman
# instead of apt. Bypass with IMMUTABLE_APT_BYPASS=1 if you know why.
apt() {
    if [ "${IMMUTABLE_APT_BYPASS:-0}" = "1" ]; then
        command apt "$@"
    else
        echo "immutable-ubuntu: host /usr is read-only." >&2
        echo "Use flatpak / distrobox / podman, or IMMUTABLE_APT_BYPASS=1." >&2
        return 1
    fi
}
EOF
    chmod 0644 /etc/profile.d/immutable-ubuntu.sh
fi

# ------------------------------------------------- state backup (cheap insurance)
info "backing up /etc to /var/lib/immutable/state-backup/"
run mkdir -p /var/lib/immutable/state-backup
run tar -czf "/var/lib/immutable/state-backup/etc-$(date +%Y%m%d-%H%M%S).tar.gz" \
    --exclude=/etc/sysupdate.d /etc 2>/dev/null || true

# ------------------------------------------------- isolation stack (optional)
if [ "$WITH_ISOLATION" = "1" ]; then
    info "installing container/isolation stack"
    run "$REPO_ROOT/isolation/setup.sh"
else
    info "skipping isolation stack (re-run with --with-isolation, or run isolation/setup.sh later)"
fi

# ------------------------------------------------------------------ summary
cat <<EOF

transition: done. Next steps:
  1. Reboot and pick "Immutable Ubuntu" (now the default).
  2. Verify:  findmnt /usr   # should show the read-only versioned bind mount
              systemd-sysupdate list
  3. Update later:  sudo systemd-sysupdate update   (then reboot)
     (local mode: drop new artifacts into /var/lib/immutable/incoming/ first)
  4. Roll back any time: boot "Ubuntu (original)" from the boot menu,
     or run:  sudo ./rollback.sh

Notes:
  - /usr is now read-only and versioned; /etc, /var, /home stay mutable state.
  - unattended-upgrades is disabled: updates come from systemd-sysupdate.
  - The apt() shell guard points at flatpak/distrobox/podman (IMMUTABLE_APT_BYPASS=1 to bypass).
EOF
