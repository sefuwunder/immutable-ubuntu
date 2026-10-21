#!/bin/bash
# setup.sh — install the container/isolation stack on an immutable-ubuntu
# host (or any Ubuntu system).
#
# Concept: the host base is immutable and minimal. Everything you *do* lives
# in one of three places:
#   podman      rootless containers for services and servers
#   flatpak     desktop applications (sandboxed via bubblewrap)
#   distrobox   a mutable "pet" shell with apt for development
set -euo pipefail

fail() { echo "isolation: ERROR: $*" >&2; exit 1; }
info() { echo "isolation: $*"; }

[ "$(id -u)" = "0" ] || fail "must run as root (sudo)"

export DEBIAN_FRONTEND=noninteractive
info "installing podman, buildah, skopeo, flatpak, distrobox, ufw"
apt-get update -qq
apt-get install -y -qq podman buildah skopeo flatpak distrobox ufw apparmor-utils

info "adding Flathub remote"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Rootless containers need unprivileged user namespaces.
if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
    v="$(cat /proc/sys/kernel/unprivileged_userns_clone)"
    [ "$v" = "1" ] || fail "unprivileged user namespaces disabled (kernel.unprivileged_userns_clone=$v); rootless podman will not work"
    info "unprivileged user namespaces: enabled"
else
    info "unprivileged user namespaces: no sysctl knob (enabled by default on this kernel)"
fi

if command -v aa-status >/dev/null 2>&1; then
    if aa-status --enabled 2>/dev/null; then
        info "AppArmor: enabled"
    else
        info "AppArmor: not enabled (isolation would be stronger with it on)"
    fi
fi

# Baseline firewall: deny incoming, allow outgoing. Prompt before enabling
# so we never lock out an active SSH session unattended.
if ufw status 2>/dev/null | grep -q "Status: active"; then
    info "ufw already active"
else
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    echo "isolation: ufw defaults set (deny incoming / allow outgoing)."
    read -r -p "Enable ufw now? (skips if you are on SSH without care) [y/N] " ans
    case "$ans" in
        [yY][eE][sS]|[yY]) ufw --force enable;;
        *) info "ufw left disabled; enable later with: sudo ufw enable";;
    esac
fi

cat <<'EOF'

isolation: done. The workflow from here:
  podman run ...        services and servers, rootless by default
  flatpak install ...   desktop apps, bubblewrap-sandboxed
  distrobox create      a mutable shell with apt for development work

The host itself stays pristine: /usr is read-only and versioned, updates
arrive via systemd-sysupdate, and nothing you install can wedge the base.
EOF
