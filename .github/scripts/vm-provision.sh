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

echo "[+] Pre-configuring package manager for non-interactive automation..."
sudo mkdir -p /etc/apt/apt.conf.d
sudo tee /etc/apt/apt.conf.d/99force-noninteractive > /dev/null <<'EOF'
Dpkg::Options { "--force-confnew"; "--force-confdef"; };
APT::Get::Assume-Yes "true";
APT::Get::List-Cleanup "false";
EOF

echo "[+] Installing compilation system requirements..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y -q \
  git qemu-utils coreutils curl gnupg sq \
  systemd systemd-container iptables sudo lsb-release podman buildah uidmap \
  dbus-user-session moreutils

sudo loginctl enable-linger debian

echo "[+] Initializing unprivileged namespace pools..."
if ! grep -q "^debian:" /etc/subuid; then
  echo "debian:100000:65536" | sudo tee -a /etc/subuid >/dev/null
  echo "debian:100000:65536" | sudo tee -a /etc/subgid >/dev/null
fi

