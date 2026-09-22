# TechOS Core

A real, installable Linux distribution — built from scratch, not a respin of an existing ISO.

- **Base:** Ubuntu 24.04 (noble) packages, debootstrap-built rootfs
- **Edition:** TechOS Core — Xfce desktop, x86_64, < 2.0 GB ISO
- **Target hardware:** low-spec PCs, i5-5200U / 8 GB RAM and up
- **Identity:** own `os-release` (`ID=techos`), hostname, issue, motd, Plymouth splash, GRUB branding
- **Installer:** Calamares with TechOS branding — "Install TechOS" icon on the live desktop
- **Live session:** autologin user `techos`, bottom-panel Windows-style Xfce layout

## Included software

| Category | Software |
|---|---|
| Browser | Waterfox 6.7 + uBlock Origin (pre-installed) |
| Media | VLC, Audacity (PipeWire defaults) |
| Graphics | Kolourpaint |
| System | xfce4-taskmanager, xfce4-screensaver, PipeWire + WirePlumber |
| Packaging | APT + Flatpak (Flathub pre-configured), i386 enabled |
| Tools | techos-welcome, techos-driver-fetcher, techos-install-missioncenter |

Mission-Center is not bundled (GNOME Flatpak runtime would break the 2 GB target) — a one-click installer is included.

## Build

Requires Docker with `--privileged` (chroot + mounts):

    sudo docker build -t techos-builder .
    sudo docker run --rm --privileged \
      -v "$(pwd)/build:/workspace/build" \
      -e UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu \
      techos-builder

Output: `build/artifacts/techos-core-amd64.iso`

## CI

GitHub Actions builds the ISO on every push, weekly (Sundays 04:00 UTC), and on manual dispatch. Weekly/dispatch runs publish a GitHub Release with the ISO attached. The workflow frees ~30-40 GB of runner disk before building.

## Testing

    sudo qemu-system-x86_64 -enable-kvm -m 2048 \
      -cdrom build/artifacts/techos-core-amd64.iso

## Repo layout

    build-techos.sh                     main builder (debootstrap → chroot → squashfs → xorriso)
    Dockerfile                          isolated build container
    .github/workflows/build-techos.yml  CI: push + weekly + dispatch → artifact + release
    assets/                             welcome GUI, driver fetcher, optional theme/wallpaper/logo

## Assets

Drop real artwork into `assets/` before building and the script picks it up:

    assets/themes/Aerobird-for-Xfce/     → /usr/share/themes/techos-aerobird
    assets/wallpapers/techos-default.jpg → default wallpaper + GRUB background
    assets/icons/tech-logo.png           → Calamares branding + whiskermenu icon
    assets/techos-panel.tar.bz2          → full Xfce panel profile
