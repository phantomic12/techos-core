FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8

# Build tools + minimal dev / kernel package extraction helpers
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        debootstrap squashfs-tools xorriso mtools isolinux syslinux-efi \
        wget curl ca-certificates gnupg2 apt-utils python3 python3-venv \
        binutils debian-archive-keyring ubuntu-keyring \
        flatpak grub-pc-bin grub-efi-amd64-bin dosfstools mtools parted \
        rsync bc zstd qemu-utils ovmf bzip2 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY build-techos.sh /workspace/build-techos.sh
COPY assets /workspace/assets

# Allow the build to write back to /workspace/build
RUN chmod +x /workspace/build-techos.sh

CMD ["bash", "/workspace/build-techos.sh"]
