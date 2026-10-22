# DESIGN.md — immutable-ubuntu architecture

## The contract

An immutable-ubuntu system makes one promise: **/usr is read-only and
versioned; everything else is state.**

| Path | Mutable? | Managed by | Notes |
|------|----------|------------|-------|
| `/usr` | No (bind-mounted read-only from the versioned tree) | systemd-sysupdate | All distro binaries live here |
| `/etc` | Yes | You (state) | Config; survives updates |
| `/var` | Yes | You (state) | Also hosts `/var/lib/immutable/versions/` |
| `/home`, `/opt`, `/srv` | Yes | You (state) | Untouched by updates |
| `/usr/local` | Shadowed | — | Part of `/usr`: anything installed here is invisible after transition. Use distrobox/flatpak. |
| ESP (`/efi`) | Versioned files | systemd-sysupdate | UKIs + CurrentSymlink |

## Boot flow

```
firmware -> systemd-boot -> ubuntu_current.efi (UKI, CurrentSymlink)
  -> kernel + initrd (mkosi-built, contains immutable-usr hook)
  -> initrd mounts state root at $rootmnt (normal root= handling)
  -> local-premount/immutable-usr:
       bind-mounts $rootmnt/var/lib/immutable/versions/<v>/usr over $rootmnt/usr (ro)
       reads <v> from the immutable.version= kernel cmdline baked into the UKI
  -> switch-root. /usr is now the versioned tree, read-only.
```

The UKI and the system tree are always version-locked: each UKI embeds
`immutable.version=<v>`, and systemd-sysupdate updates both transfers as one
target sharing the same `@v`. The UKI transfer (`20-uki.transfer`) sorts
alphabetically last, so the boot entry point is only established after the
tree it boots is fully in place.

## Why file-based, not partition-based

The systemd-native "full" design (see `sysupdate.d(5)`, the foobarOS
example) uses GPT partitions per version with UAPI type UUIDs. That is the
right end state, but it requires free disk space and repartitioning a live
system — the most dangerous operation in this repo. v1 deliberately uses
`regular-file` (UKI in the ESP) and `directory` (unpacked tree) targets:
**the transition is fully additive and reversible.** The original GRUB boot
path is never modified; rollback is just booting it.

## Key decisions and their tradeoffs

- **mkosi as the factory.** Reproducible Ubuntu trees from the archive, no
  snowflake build host. `publish.sh` runs mkosi twice (`--format=tar` for the
  tree, `--format=uki` for the kernel image) and version-locks them.
- **initramfs-tools hook, not a custom initrd.** The `/usr` mount must happen
  before switch-root, so it lives in the initrd. The hook is shipped in the
  mkosi skeleton and `publish.sh` *verifies* it landed in the built UKI
  (objcopy + lsinitramfs gate). Assumption: mkosi builds the initrd with
  initramfs-tools honoring `/etc/initramfs-tools/{hooks,scripts}`. If your
  mkosi uses mkosi-initrd instead, the equivalent is a systemd mount unit in
  the initrd — the failure will be loud (the gate fails) rather than silent.
- **Fail-open hook.** If the versioned tree is missing at boot (e.g. `/var`
  on a separate partition, or a non-immutable boot), the hook warns and
  continues with the state's own `/usr`. An immutable system that refuses to
  boot is worse than one that boots mutable.
- **Read-only without `nosuid`.** `/usr/bin/sudo` is setuid and must keep
  working; `nodev`/`nosuid` would break it. Read-only alone is the correct
  immutability primitive here.
- **`.transfer` vs `.conf`.** systemd renamed transfer definitions at some
  point; `preflight.sh` probes `systemd-sysupdate --help` for the expected
  extension instead of guessing from the version number.
- **apt is guarded, not removed.** A shell function in
  `/etc/profile.d/immutable-ubuntu.sh` redirects to flatpak/distrobox/podman
  (`IMMUTABLE_APT_BYPASS=1` to override). `unattended-upgrades` and the
  apt-daily timers are disabled: updates come from sysupdate now.
- **No dm-verity in v1.** Integrity rests on read-only mounts + the immutable
  file attribute + (for remote sources) SHA256SUMS manifests with optional
  GPG. Verity partitions are the documented hardening path.

## Daily image builds (the publisher side)

Clients check for updates daily, but a check is only meaningful if someone
publishes. `publish/daily-build.sh` (with the bundled
`immutable-daily-build.{service,timer}`, 03:00 daily) closes that loop on
the build host:

1. Builds a fresh image from **whatever the Ubuntu archives contain right
   now** — no pinned package versions, so security updates flow in with the
   next build. mkosi's package cache means only changed `.deb`s download.
2. Compares the new build's **package manifest** (`ManifestFormat=json`)
   against the last published one. Unchanged package set → no new version
   published at all, so clients don't download a redundant full tarball.
   (mkosi builds aren't bit-reproducible, so artifact hashes would always
   "differ"; the manifest is the deterministic signal. If the manifest
   can't be parsed, the script fails open toward freshness: it publishes.)
3. On change: versions (`YYYYMMDD.N`), signs, publishes, prunes to the
   newest `--keep` (default 14) versions, and **regenerates + re-signs
   SHA256SUMS** so the index always matches what's on disk.
4. A failed build publishes nothing; a second instance exits quietly
   (flock); a disk-space guard refuses to build under 15G free.

Unattended signing needs a non-interactive GPG setup (passwordless
dedicated subkey or preset gpg-agent passphrase) — without it the manifest
goes out unsigned and clients with `Verify=` reject the update. The build
host holding the signing key is the trust root of the whole system; treat
it accordingly.

## Honest limitations (v1)

1. **Secure Boot: must be off.** UKIs are unsigned in v1; preflight aborts if
   SB is enabled. Signing (mkosi `SecureBoot=` + MOK enrollment) is the
   follow-up.
2. **No dm-verity.** See above. A tampered tree would still mount (it is
   read-only, not verified). Remote downloads are hash-verified; local
   artifacts are trusted.
3. **`/var` must live on the rootfs.** The hook runs before separate
   filesystems mount. Preflight warns; the boot fails open (mutable).
4. **ProtectVersion is managed, not automatic.** `%A` (os-release
   `VERSION_ID`) does not follow our `YYYYMMDD.N` scheme, so
   `transition.sh` writes an explicit `ProtectVersion=` drop-in for the
   installed version. `publish.sh` does not yet update it — re-run
   transition or edit the drop-in when adopting a new version as your daily
   driver. (With `InstancesMax=2` you always keep two versions regardless.)
5. **No automatic boot assessment.** Failed boots are not detected and rolled
   back automatically (`@l`/`@d` try-counters are a follow-up). Rollback is
   manual: pick "Ubuntu (original)" or the previous entry.
6. **The initrd assumption above.** Loud failure, documented, but real.
7. **Single-arch, single-release per publish dir.** Multi-arch/multi-release
   is a matter of more publish dirs, not a redesign.

## Threat model (one paragraph)

Immutability here is an *integrity* story, not an *isolation* story: it
shrinks the persistence surface for malware and makes "reboot into
yesterday" a real incident response. Runtime isolation comes from the
unchanged Ubuntu stack — Wayland, PipeWire/portals, flatpak/bubblewrap,
AppArmor, unprivileged user namespaces — which is exactly why the
container/isolation setup ships alongside, not underneath.
