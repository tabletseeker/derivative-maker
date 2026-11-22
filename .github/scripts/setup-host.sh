#!/usr/bin/env bash

## Copyright (C) 2026-2027 tabletseeker <tabletseeker-git@protonmail.com>
## See the LICENSE for conditions of reproduction or redistribution.
## All rights reserved by the repository maintainer

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

prune_host() {
if [ "${CLEANUP}" == "true" ]; then
  sudo swapoff -a || true
  sudo rm -f /mnt/swapfile
  sudo rm -rf \
    /usr/share/dotnet \
    /usr/local/lib/android \
    /opt/ghc \
    /opt/hostedtoolcache/CodeQL \
    /usr/local/share/powershell \
    /usr/local/share/chromium

  sudo docker image prune --all --force
  sudo apt-get remove --purge -y "node*" "php*" "mysql*" "google*" || true
  sudo apt-get autoremove -y
  sudo apt-get clean

  echo "=== Storage Profile After Cleanup ==="
  df -h /
else
  echo "=== Skipping Cleanup Sequence ==="
fi
}

echo "=== Native Storage Profile ==="
df -h /
prune_host

echo "=== Expose host KVM permissions ==="
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' |
  sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm

echo "=== Install QEMU, cloud-init, and Debian image-build dependencies ==="
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates \
  cloud-image-utils \
  debsums \
  dosfstools \
  fai-server \
  fai-setup-storage \
  genisoimage \
  git \
  make \
  debian-archive-keyring \
  netcat-openbsd \
  fdisk \
  sudo \
  python3 \
  python3-httpx \
  python3-libcloud \
  python3-marshmallow \
  python3-pytest \
  python3-yaml \
  qemu-system-x86 \
  qemu-utils \
  udev

echo "=== Host setup complete ==="
df -h /

