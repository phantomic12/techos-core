#!/bin/bash
set -euo pipefail

# TechOS Core — from-scratch live ISO builder
# Runs inside a stock Ubuntu 24.04 container/VM (GitHub Actions or local)

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

BUILD_ID="techos-core-${GITHUB_RUN_ID:-$(date +%s)}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD_DIR="${WORKSPACE}/build"
ROOTFS="${BUILD_DIR}/rootfs"
IMAGE_DIR="${BUILD_DIR}/image"
ARTIFACT_DIR="${BUILD_DIR}/artifacts"
CACHE_DIR="${BUILD_DIR}/cache"

UBU_CODENAME="noble"           # Ubuntu 24.04 base
UBU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"
# Linux Mint repo disabled: packages.linuxmint.com is not reliably reachable.
# TechOS packages come from Ubuntu + Flathub.

# Kernel to install in the live image
KERNEL_PKG="linux-image-generic"

mkdir -p "${BUILD_DIR}" "${ROOTFS}" "${IMAGE_DIR}" "${ARTIFACT_DIR}" "${CACHE_DIR}"

# -----------------------------------------------------------------------------
# 1. Install build tools on the runner
# -----------------------------------------------------------------------------
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  debootstrap squashfs-tools xorriso mtools isolinux syslinux-efi \
  wget curl ca-certificates gnupg2 apt-utils python3 python3-venv \
  binutils debian-archive-keyring ubuntu-keyring \
  flatpak grub-pc-bin grub-efi-amd64-bin dosfstools mtools parted \
  rsync bc zstd bzip2

# -----------------------------------------------------------------------------
# 2. Bootstrap rootfs (Ubuntu minimal base)
# -----------------------------------------------------------------------------
if [[ ! -f "${ROOTFS}/etc/lsb-release" ]]; then
  rm -rf "${ROOTFS}"/*; rm -f "${ROOTFS}"/.lock || true
  debootstrap --arch=amd64 --variant=minbase "${UBU_CODENAME}" "${ROOTFS}" "${UBU_MIRROR}"
fi

# -----------------------------------------------------------------------------
# 3. Mount pseudo-filesystems for chroot
# -----------------------------------------------------------------------------
mount_pseudo() {
  rm -f "${ROOTFS}/var/lib/dpkg/lock" "${ROOTFS}/var/lib/dpkg/lock-frontend" "${ROOTFS}/var/cache/apt/archives/lock" 2>/dev/null || true
  mount -t proc proc "${ROOTFS}/proc"
  mount -t sysfs sys "${ROOTFS}/sys"
  mount --rbind /dev "${ROOTFS}/dev"
  mount --make-rslave "${ROOTFS}/dev"
  mount -t devpts devpts "${ROOTFS}/dev/pts" 2>/dev/null || true
  mount --rbind /run "${ROOTFS}/run"
  mount --make-rslave "${ROOTFS}/run"
  cp -fL /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"
}

umount_pseudo() {
  umount -R "${ROOTFS}/run" 2>/dev/null || true
  umount -R "${ROOTFS}/dev" 2>/dev/null || true
  umount "${ROOTFS}/dev/pts" 2>/dev/null || true
  umount "${ROOTFS}/sys" 2>/dev/null || true
  umount "${ROOTFS}/proc" 2>/dev/null || true
}

cleanup() { umount_pseudo; }
trap cleanup EXIT INT TERM

mount_pseudo

# -----------------------------------------------------------------------------
# 4. APT sources
# -----------------------------------------------------------------------------
cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${UBU_MIRROR} ${UBU_CODENAME} main restricted universe multiverse
deb ${UBU_MIRROR} ${UBU_CODENAME}-updates main restricted universe multiverse
deb ${UBU_MIRROR} ${UBU_CODENAME}-security main restricted universe multiverse
deb ${UBU_MIRROR} ${UBU_CODENAME}-backports main restricted universe multiverse
EOF

# Import base keys and update inside chroot
chroot "${ROOTFS}" bash -c '
  set -e
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends gnupg ca-certificates wget curl
  apt-get update -qq
'

# -----------------------------------------------------------------------------
# 5. Package manifests
# -----------------------------------------------------------------------------
mkdir -p "${ROOTFS}/tmp/techos-setup" "${WORKSPACE}/assets"

cat > "${ROOTFS}/tmp/remove.manifest" <<'EOF'
firefox
firefox-esr
celluloid
EOF

cat > "${ROOTFS}/tmp/install.manifest" <<'EOF'
# Core
locales
console-setup
keyboard-configuration
sudo
adduser
passwd
# Audio
pipewire
wireplumber
pipewire-pulse
# X + Xfce
xserver-xorg
xserver-xorg-video-all
xserver-xorg-input-all
lightdm
xfce4
xfce4-terminal
thunar
thunar-volman
tango-icon-theme
hicolor-icon-theme
adwaita-icon-theme
# Apps
vlc
kolourpaint
xfce4-screensaver
xfce4-taskmanager
# Installer + boot splash (real distro pieces)
calamares
calamares-settings-ubuntu-common
plymouth
plymouth-themes
plymouth-label
librsvg2-bin
polkitd
pkexec
# Misc
network-manager
network-manager-gnome
net-tools
wireless-tools
iputils-ping
isc-dhcp-client
wpasupplicant
avahi-daemon
openssh-client
bzip2
xz-utils
initramfs-tools
casper
# Package management
flatpak
apt-transport-https
# Kernel
linux-image-generic
# linux-headers-generic is not needed in the live image
# Boot
grub-pc-bin
grub-efi-amd64-bin
shim-signed
mokutil
EOF

# -----------------------------------------------------------------------------
# 6. Chroot customization
# -----------------------------------------------------------------------------
mkdir -p "${ROOTFS}/tmp/techos-setup/assets"
cp -r "${WORKSPACE}/assets/"* "${ROOTFS}/tmp/techos-setup/assets/" 2>/dev/null || true

cat > "${ROOTFS}/tmp/techos-setup/chroot-customize.sh" <<'CHROOT'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

# Enable i386 (best-effort)
dpkg --add-architecture i386 2>/dev/null || true
apt-get update -qq

# Install packages listed in install manifest
xargs -a /tmp/install.manifest -r -I {} sh -c 'apt-get install -y -qq --no-install-recommends {} 2>/dev/null || true'

# Remove unwanted
xargs -a /tmp/remove.manifest -r apt-get purge -y -qq 2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true

# Flatpak + Flathub repository (users can install Mission-Center after boot)
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Optional: attempt to install Mission-Center, but do NOT block/fail the build if it is not available.
# Including the full GNOME runtime would break the <2 GB target, so the default install is skipped here.
# A launcher script is created below so the user can install it with one click in the live session.
# flatpak install -y --noninteractive flathub io.gitlab.MissionCenter 2>/dev/null || true

# Waterfox tarball (does not require installation)
cd /opt
if ! [[ -d /opt/waterfox ]]; then
  WFOX_URL="https://cdn.waterfox.com/waterfox/releases/6.7.3/Linux_x86_64/waterfox-6.7.3.tar.bz2"
  curl -L --retry 3 -o /tmp/waterfox.tar.bz2 "$WFOX_URL" || \
  curl -L --retry 3 -o /tmp/waterfox.tar.bz2 "https://cdn.waterfox.com/waterfox/releases/6.7.0/Linux_x86_64/waterfox-6.7.0.tar.bz2"
  tar -xjf /tmp/waterfox.tar.bz2 -C /opt
  rm -f /tmp/waterfox.tar.bz2
  ln -sf /opt/waterfox/waterfox /usr/local/bin/waterfox
fi

# uBlock Origin pre-install for Waterfox
mkdir -p /opt/waterfox/distribution/extensions
UBO_PATH="/opt/waterfox/distribution/extensions/uBlock0@raymondhill.net.xpi"
if ! [[ -f "$UBO_PATH" ]]; then
  curl -L --retry 3 -o "$UBO_PATH" "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi" || \
  curl -L --retry 3 -o "$UBO_PATH" "https://github.com/gorhill/uBlock/releases/download/1.60.0/uBlock0_1.60.0.firefox.signed.xpi" || true
fi

cat > /usr/share/applications/waterfox.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Name=Waterfox
Comment=Waterfox Web Browser
Exec=/opt/waterfox/waterfox %u
Icon=/opt/waterfox/browser/chrome/icons/default/default128.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
DESKTOP

# TechOS welcome replacement for mint-welcome
if [[ -f /tmp/techos-setup/assets/techos-welcome.py ]]; then
  cp /tmp/techos-setup/assets/techos-welcome.py /usr/local/bin/techos-welcome
  chmod +x /usr/local/bin/techos-welcome
  cat > /usr/share/applications/techos-welcome.desktop <<'DESKTOP'
[Desktop Entry]
Name=Welcome to TechOS
Exec=/usr/local/bin/techos-welcome
Icon=help-info
Type=Application
DESKTOP
fi

# Driver installation utility
cp /tmp/techos-setup/assets/techos-driver-fetcher /usr/local/bin/techos-driver-fetcher 2>/dev/null || \
cat > /usr/local/bin/techos-driver-fetcher <<'DRIVER'
#!/bin/bash
# techos-driver-fetcher: install common proprietary / hardware drivers
set -euo pipefail
pkgs=""
# NVIDIA
if lspci -k 2>/dev/null | grep -qi nvidia; then
  pkgs="$pkgs nvidia-driver-535 nvidia-utils-535"
fi
# Broadcom Wi-Fi
if lspci -k 2>/dev/null | grep -qi broadcom; then
  pkgs="$pkgs bcmwl-kernel-source"
fi
# Intel microcode / firmware
pkgs="$pkgs intel-microcode firmware-linux-nonfree linux-firmware"
echo "Drivers selected: $pkgs"
if [[ -n "$pkgs" ]]; then
  apt-get update -qq
  apt-get install -y -qq $pkgs 2>/dev/null || true
fi
DRIVER
chmod +x /usr/local/bin/techos-driver-fetcher

# Audacity PipeWire default input
mkdir -p /etc/skel/.audacity-data
cat > /etc/skel/.audacity-data/audacity.cfg <<'CFG'
DefaultInputSource=pipewire
Host=pipewire
CFG

# Optional Mission-Center post-install launcher (ISO target <2GB, so not pre-bundled)
cat > /usr/local/bin/techos-install-missioncenter <<'MC'
#!/bin/bash
# One-click Mission-Center install after boot (pulls Flathub runtime; requires network)
set -e
flatpak install -y --noninteractive flathub io.gitlab.MissionCenter
MC
chmod +x /usr/local/bin/techos-install-missioncenter
cat > /usr/share/applications/techos-install-missioncenter.desktop <<'DESKTOP'
[Desktop Entry]
Name=Install Mission-Center
Exec=/usr/local/bin/techos-install-missioncenter
Icon=utilities-system-monitor
Type=Application
DESKTOP

# Visual assets
mkdir -p /usr/share/themes /usr/share/backgrounds /usr/share/icons /etc/xdg/xfce4
if [[ -d /tmp/techos-setup/assets/themes/Aerobird-for-Xfce ]]; then
  cp -r /tmp/techos-setup/assets/themes/Aerobird-for-Xfce /usr/share/themes/techos-aerobird
fi
if [[ -f /tmp/techos-setup/assets/wallpapers/techos-default.jpg ]]; then
  cp /tmp/techos-setup/assets/wallpapers/techos-default.jpg /usr/share/backgrounds/techos-default.jpg
fi
if [[ -f /tmp/techos-setup/assets/icons/tech-logo.svg ]]; then
  mkdir -p /usr/share/icons/techos
  cp /tmp/techos-setup/assets/icons/tech-logo.svg /usr/share/icons/techos/tech-logo.svg
fi

# Xfce defaults: bottom panel, whiskermenu icon, wallpaper
mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml

cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/techos-default.jpg"/>
        </property>
      </property>
    </property>
  </property>
</channel>
XML

cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="theme" type="string" value="techos-aerobird"/>
</channel>
XML

cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="techos-aerobird"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
  </property>
</channel>
XML

# Panel profile (default bottom Windows-like panel)
mkdir -p /etc/skel/.config/xfce4/panel /etc/xdg/xfce4/panel
if [[ -f /tmp/techos-setup/assets/techos-panel.tar.bz2 ]]; then
  tar -xjf /tmp/techos-setup/assets/techos-panel.tar.bz2 -C /etc/xdg/xfce4 2>/dev/null || true
  tar -xjf /tmp/techos-setup/assets/techos-panel.tar.bz2 -C /etc/skel/.config/xfce4 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# Distro identity — TechOS is its own OS, not a respin label
# ------------------------------------------------------------------------------
cat > /etc/os-release <<'OSREL'
NAME="TechOS"
PRETTY_NAME="TechOS Core"
ID=techos
ID_LIKE="ubuntu debian"
VERSION="1.0 (Core)"
VERSION_ID="1.0"
VERSION_CODENAME=core
HOME_URL="https://github.com/phantomic12/techos-core"
SUPPORT_URL="https://github.com/phantomic12/techos-core/issues"
BUG_REPORT_URL="https://github.com/phantomic12/techos-core/issues"
OSREL
cp /etc/os-release /usr/lib/os-release 2>/dev/null || true
cat > /etc/lsb-release <<'LSB'
DISTRIB_ID=TechOS
DISTRIB_RELEASE=1.0
DISTRIB_CODENAME=core
DISTRIB_DESCRIPTION="TechOS Core"
LSB
echo "techos" > /etc/hostname
cat > /etc/hosts <<'HOSTS'
127.0.0.1   localhost
127.0.1.1   techos
::1         localhost ip6-localhost ip6-loopback
HOSTS
cat > /etc/issue <<'ISSUE'
TechOS Core \n \l

ISSUE
cat > /etc/issue.net <<'ISSUENET'
TechOS Core
ISSUENET
cat > /etc/motd <<'MOTD'
Welcome to TechOS Core.
Docs: https://github.com/phantomic12/techos-core
MOTD

# Plymouth boot splash — TechOS text theme (no image assets needed)
mkdir -p /usr/share/plymouth/themes/techos
cat > /usr/share/plymouth/themes/techos/techos.plymouth <<'PLY'
[Plymouth Theme]
Name=TechOS
Description=TechOS Core boot splash
ModuleName=text

[text]
Title=TechOS Core
black=0x0b1220
white=0xe8eefc
brown=0x3b82f6
blue=0x3b82f6
PLY
cat > /usr/share/plymouth/themes/techos/techos.script <<'SCR'
# minimal text splash
SCR
update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
  default.plymouth /usr/share/plymouth/themes/techos/techos.plymouth 100 2>/dev/null || true
update-alternatives --set default.plymouth \
  /usr/share/plymouth/themes/techos/techos.plymouth 2>/dev/null || true

# GRUB branding
cat >> /etc/default/grub <<'GRUB'
GRUB_DISTRIBUTOR="TechOS"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_GFXMODE=auto
GRUB_BACKGROUND=/usr/share/backgrounds/techos-default.jpg
GRUB

# Calamares installer — TechOS branding + live-session autostart
mkdir -p /etc/calamares
cat > /etc/calamares/settings.conf <<'CAL'
---
modules-search: [ local, /usr/lib/x86_64-linux-gnu/calamares/modules ]
instances:
- id:       main
  module:   dummypython
  config:   dummypython.conf
sequence:
- show:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - summary
- exec:
  - partition
  - mount
  - unpackfs
  - networkcfg
  - machineid
  - fstab
  - locale
  - keyboard
  - localecfg
  - users
  - displaymanager
  - packages
  - grubcfg
  - bootloader
  - umount
- show:
  - finished
branding: techos
prompt-install: true
dont-chroot: false
CAL

mkdir -p /etc/calamares/branding/techos
cat > /etc/calamares/branding/techos/branding.desc <<'BRAND'
---
componentName: techos
welcomeStyleCalamares: true
welcomeExpandingLogo: true
strings:
    productName:         TechOS
    shortProductName:    TechOS
    version:             1.0 Core
    shortVersion:        1.0
    versionedName:       TechOS 1.0 Core
    shortVersionedName:  TechOS 1.0
    bootloaderEntryName: TechOS
    productUrl:          https://github.com/phantomic12/techos-core
    supportUrl:          https://github.com/phantomic12/techos-core/issues
    knownIssuesUrl:      https://github.com/phantomic12/techos-core/issues
    releaseNotesUrl:     https://github.com/phantomic12/techos-core/releases
images:
    productLogo:         "logo.png"
    productIcon:         "logo.png"
    productWelcome:      "welcome.png"
    welcome:             "welcome.png"
windowPlacement: center
BRAND

# Simple generated logo for Calamares branding (SVG -> PNG if rsvg available, else skip)
if command -v rsvg-convert >/dev/null 2>&1; then
  cat > /tmp/techos-logo.svg <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><circle cx="128" cy="128" r="120" fill="#0b1220"/><circle cx="128" cy="128" r="118" fill="none" stroke="#3b82f6" stroke-width="4"/><text x="128" y="160" font-family="sans-serif" font-size="110" font-weight="bold" fill="#3b82f6" text-anchor="middle">T</text></svg>
SVG
  rsvg-convert -w 256 -h 256 /tmp/techos-logo.svg -o /etc/calamares/branding/techos/logo.png 2>/dev/null || true
  rsvg-convert -w 640 -h 360 /tmp/techos-logo.svg -o /etc/calamares/branding/techos/welcome.png 2>/dev/null || true
fi
# Fallback: copy any provided asset
cp /tmp/techos-setup/assets/icons/tech-logo.png /etc/calamares/branding/techos/logo.png 2>/dev/null || true
cp /tmp/techos-setup/assets/icons/tech-logo.png /etc/calamares/branding/techos/welcome.png 2>/dev/null || true

# unpackfs module — copy the live squashfs to target
mkdir -p /etc/calamares/modules
cat > /etc/calamares/modules/unpackfs.conf <<'UNPACK'
---
unpack:
    -   source: "/run/medium/casper/filesystem.squashfs"
        sourcefs: "squashfs"
        destination: ""
UNPACK

# packages module — remove live-only packages on installed system
cat > /etc/calamares/modules/packages.conf <<'PKGS'
---
backend: apt
operations:
  - remove:
    - casper
    - calamares
    - calamares-settings-ubuntu-common
PKGS

# "Install TechOS" launcher on live desktop
cat > /usr/share/applications/techos-install.desktop <<'DESKTOP'
[Desktop Entry]
Name=Install TechOS
Comment=Install TechOS Core to this computer
Exec=pkexec calamares
Icon=system-software-install
Type=Application
Categories=System;
DESKTOP
mkdir -p /etc/skel/Desktop
cp /usr/share/applications/techos-install.desktop /etc/skel/Desktop/
chmod +x /etc/skel/Desktop/techos-install.desktop

# Live user
if ! id -u techos >/dev/null 2>&1; then
  for g in sudo adm audio video netdev plugdev users flatpak; do
    getent group "$g" >/dev/null || groupadd -r "$g"
  done
  useradd -m -s /bin/bash -G sudo,adm,audio,video,netdev,plugdev,users,flatpak techos
  echo 'techos:techos' | chpasswd
fi

# LightDM autologin for live session
cat > /etc/lightdm/lightdm.conf <<'CONF'
[Seat:*]
autologin-user=techos
autologin-user-timeout=0
user-session=xfce
CONF

# Final cleanup — keep our modified conffiles (/etc/issue etc.) on upgrade
apt-get -o Dpkg::Options::="--force-confold" upgrade -y -qq 2>/dev/null || true
apt-get autoremove -y -qq
apt-get clean

# Ensure a casper-enabled initrd exists for the live ISO
if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -c -k all 2>/dev/null || true
fi
rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/*
CHROOT

chmod +x "${ROOTFS}/tmp/techos-setup/chroot-customize.sh"
chroot "${ROOTFS}" /tmp/techos-setup/chroot-customize.sh

umount_pseudo
cleanup

# -----------------------------------------------------------------------------
# 7. Build live image layout
# -----------------------------------------------------------------------------
mkdir -p \
  "${IMAGE_DIR}/casper" \
  "${IMAGE_DIR}/isolinux" \
  "${IMAGE_DIR}/boot/grub" \
  "${IMAGE_DIR}/EFI/boot" \
  "${IMAGE_DIR}/.disk"

# Squashfs rootfs
cd "${BUILD_DIR}"
mksquashfs "${ROOTFS}" "${IMAGE_DIR}/casper/filesystem.squashfs" \
  -comp zstd -Xcompression-level 15 -no-recovery -always-use-fragments \
  -wildcards \
  -e "boot/vmlinuz-*" "boot/initrd.img-*" "boot/System.map-*" "boot/config-*" \
  "var/cache/apt/archives/*" "var/lib/apt/lists/*" "tmp/*" "var/tmp/*" "var/log/*"

# Copy kernel / initrd
KVER=$(ls -1 "${ROOTFS}/boot"/vmlinuz-* 2>/dev/null | head -n1 | sed 's|.*/vmlinuz-||')
if [[ -z "${KVER}" ]]; then
  echo "No kernel found in rootfs" >&2
  exit 1
fi
cp "${ROOTFS}/boot/vmlinuz-${KVER}"   "${IMAGE_DIR}/casper/vmlinuz"
cp "${ROOTFS}/boot/initrd.img-${KVER}" "${IMAGE_DIR}/casper/initrd.img"

# -----------------------------------------------------------------------------
# 8. Bootloaders
# -----------------------------------------------------------------------------
cat > "${IMAGE_DIR}/isolinux/isolinux.cfg" <<'EOF'
PROMPT 0
TIMEOUT 50
DEFAULT live

UI menu.c32

MENU TITLE TechOS Core

LABEL live
  MENU LABEL ^Try TechOS Core without installing
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.img boot=casper quiet splash ---

LABEL install
  MENU LABEL ^Install TechOS Core
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.img boot=casper only-ubiquity quiet splash ---
EOF

cp /usr/lib/ISOLINUX/isolinux.bin "${IMAGE_DIR}/isolinux/"
cp /usr/lib/syslinux/modules/bios/menu.c32   "${IMAGE_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/vesamenu.c32 "${IMAGE_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/libutil.c32  "${IMAGE_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/libcom32.c32 "${IMAGE_DIR}/isolinux/" 2>/dev/null || true

cat > "${IMAGE_DIR}/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

menuentry "Try TechOS Core without installing" {
    linux /casper/vmlinuz boot=casper quiet splash
    initrd /casper/initrd.img
}

menuentry "Install TechOS Core" {
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash
    initrd /casper/initrd.img
}
EOF

# EFI boot image (use installed GRUB EFI binaries)
mkdir -p "${IMAGE_DIR}/EFI/boot"
cp /usr/lib/shim/shimx64.efi "${IMAGE_DIR}/EFI/boot/bootx64.efi" 2>/dev/null || true
cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi "${IMAGE_DIR}/EFI/boot/grubx64.efi" 2>/dev/null || true

# GRUB image inside boot catalog
grub-mkimage -O x86_64-efi \
  -o "${IMAGE_DIR}/EFI/boot/bootx64.efi" \
  --prefix=/EFI/boot \
  part_gpt part_msdos fat iso9660 normal boot linux configfile loopback chain \
  efi_gop efi_uga all_video fshelp ext2 ntfs reiserfs hfsplus jpeg png gzio \
  2>/dev/null || true

# .disk metadata
echo "TechOS Core" > "${IMAGE_DIR}/.disk/info"

# -----------------------------------------------------------------------------
# 9. Produce ISO
# -----------------------------------------------------------------------------
OUT_ISO="${ARTIFACT_DIR}/techos-core-amd64.iso"

xorriso -as mkisofs \
  -r -V "TECHOSCORE" -J -joliet-long \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e EFI/boot/bootx64.efi -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o "${OUT_ISO}" "${IMAGE_DIR}"

SIZE_BYTES=$(stat -c%s "${OUT_ISO}")
SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
echo "ISO size: ${SIZE_MB} MB"

if (( SIZE_MB > 2048 )); then
  echo "WARN: ISO exceeds 2.0 GB target (${SIZE_MB} MB)" >&2
fi

cat > "${ARTIFACT_DIR}/techos-core-manifest.txt" <<EOF
TechOS Core build: ${BUILD_ID}
ISO: techos-core-amd64.iso
Size: ${SIZE_MB} MB
Base: Ubuntu ${UBU_CODENAME}
Kernel: ${KVER}
EOF

echo "Done: ${OUT_ISO}"
