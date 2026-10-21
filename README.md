# immutable-ubuntu

Scripts that transition an **existing Ubuntu install** into an **immutable
Ubuntu** — a read-only, versioned `/usr` updated atomically via
**systemd-sysupdate**, with the base system built reproducibly by **mkosi**.
The host stays minimal and pristine; everything you do lives in **podman**,
**flatpak**, or **distrobox**.

The contract: `/usr` is read-only and versioned. `/etc`, `/var`, `/home`
stay mutable state. Updates are A/B with trivial rollback.

## Quickstart

```bash
git clone https://github.com/sefuwunder/immutable-ubuntu
cd immutable-ubuntu

# 1. Build versioned artifacts from the Ubuntu archive (needs root + mkosi)
sudo ./publish/publish.sh --release noble --out /srv/immutable

# 2. Transition this machine (additive: the original system is untouched)
sudo ./transition/transition.sh --artifacts /srv/immutable/noble --from-local \
    --with-isolation

# 3. Reboot, pick "Immutable Ubuntu", verify
findmnt /usr
systemd-sysupdate list
```

Updating later: `sudo systemd-sysupdate update` (point the transfer
definitions at your artifact server first — see `transition.sh
--source-url`), then reboot. Rolling back: boot "Ubuntu (original)" from
the boot menu, or `sudo ./transition/rollback.sh`.

## Layout

```
mkosi/            factory: mkosi.conf + skeleton (initramfs hook that mounts
                  the versioned /usr) — builds the UKI and the system tarball
sysupdate/        transfer definitions (system tree + UKI, UKI ordered last)
transition/       transition.sh (the conversion), preflight.sh (checks),
                  rollback.sh (restore EFI boot order)
publish/          publish.sh (build, version, SHA256SUMS, optional GPG sign)
isolation/        setup.sh (podman, flatpak+flathub, distrobox, ufw baseline)
docs/             DESIGN.md (architecture, decisions, honest limitations)
```

## How it works (60 seconds)

1. `publish.sh` builds two artifacts per version `YYYYMMDD.N`: a system
   tree tarball and a Unified Kernel Image whose cmdline carries
   `immutable.version=<v>`.
2. `transition.sh` installs them **through systemd-sysupdate itself** (local
   sources), so the installed state is exactly what later remote updates
   produce. It adds a systemd-boot entry booting the `ubuntu_current.efi`
   symlink, keeps a chainload entry for the original GRUB system, and flips
   the EFI boot order (backed up for rollback).
3. At boot, the UKI's initrd bind-mounts
   `/var/lib/immutable/versions/<v>/usr` over `/usr`, read-only. `/etc`,
   `/var`, `/home` come from your existing install, untouched.
4. `systemd-sysupdate` keeps two versions (`InstancesMax=2`); new versions
   arrive as tarball + UKI and the symlink flips atomically.

## Status and limitations

v1 is honest about what it is not (yet): Secure Boot must be off (UKIs
unsigned), no dm-verity (read-only mounts + hash-verified downloads instead
of measured boot), `/var` must live on the rootfs, no automatic boot
assessment. See `docs/DESIGN.md` for the full list and the reasoning.

Tested on: Ubuntu 24.04 LTS (noble). The transition is additive — worst
case, you reboot into the original system.

## License

MIT — see LICENSE.
