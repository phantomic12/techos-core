TechOS Core — from-scratch live ISO builder

Target: Ubuntu 24.04 + Xfce, x86_64, < 2.0 GB ISO, low-spec PCs.

Files:
- build-techos.sh    one-shot ISO builder
- Dockerfile         isolated build container
- .github/workflows/build-techos.yml  GitHub Actions runner
- assets/            placeholder/welcome icon/wallpaper/theme assets

Run on garlic-clove (or any Ubuntu 24.04 host with Docker):

    cd /home/yoav/techos-build
    sudo docker build -t techos-builder .
    sudo docker run --rm --privileged \
      -v "$(pwd)/build:/workspace/build" \
      -e UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu \
      techos-builder

ISO lands in `build/artifacts/techos-core-amd64.iso`.

Known trade-offs vs the original spec:
- Base is Ubuntu + Xfce, not Linux Mint. `packages.linuxmint.com` was unreachable from the build container, so Linux Mint repo was dropped.
- Mission-Center is not pre-bundled (its GNOME runtime would break the 2 GB target). A one-click Flathub installer is included instead.
- xfce4-taskmanager is installed as the default task manager.
- Waterfox + uBlock Origin, xfce4-screensaver, kolourpaint, vlc, pipewire/wireplumber, i386, flatpak, techos-welcome, and techos-driver-fetcher are present.

QEMU smoke-test (requires sudo + KVM):

    sudo qemu-system-x86_64 -enable-kvm -m 2048 \
      -cdrom build/artifacts/techos-core-amd64.iso

Current build:
- /home/yoav/techos-build/build/artifacts/techos-core-amd64.iso  (1558 MB, bootable)
- /home/yoav/techos-build/build/artifacts/techos-core-manifest.txt
