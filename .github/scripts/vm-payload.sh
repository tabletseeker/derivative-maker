#!/usr/bin/env bash

set -x
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

# Prep signing key for key_mnt
echo "[+] Guest Subsystem: Initializing key space..."
mkdir -p "${KEY_DIR}"
set +x
printf '%s\n' "${CI_PRIVATE_KEY}" > "${KEY_FILE}"
chmod 400 "${KEY_FILE}"
set -x

echo "[+] Pre-configuring package manager for non-interactive automation..."
sudo mkdir -p /etc/apt/apt.conf.d
sudo tee /etc/apt/apt.conf.d/99force-noninteractive > /dev/null << 'EOF'
Dpkg::Options { "--force-confnew"; "--force-confdef"; };
APT::Get::Assume-Yes "true";
APT::Get::List-Cleanup "false";
EOF

# Provision dependencies
echo "[+] Installing compilation system requirements..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y -q git qemu-utils coreutils curl gnupg sq \
  systemd systemd-container iptables sudo lsb-release podman buildah uidmap \
  dbus-user-session haveged moreutils

sudo systemctl start haveged || true

echo "[+] Initializing unprivileged namespace pools..."
if ! grep -q "debian" /etc/subuid; then
  echo "debian:100000:65536" | sudo tee -a /etc/subuid
  echo "debian:100000:65536" | sudo tee -a /etc/subgid
fi

sudo loginctl enable-linger debian

# Extract sources and invoke the compilation matrix
echo "[+] Sourcing repository down into workspace context..."
mkdir -p /home/debian/build-workspace

git clone \
  --single-branch \
  --branch "testing" \
  --recurse-submodules \
  "${GIT_URL}" \
  /home/debian/build-workspace

echo "[+] Launching native build engine context..."
sudo mkdir -p /run/user/1000
sudo chown debian:debian /run/user/1000

mkdir -p /home/debian/.gnupg
chmod 700 /home/debian/.gnupg

cd /home/debian/build-workspace

./oci/derivative-maker-oci-run -- bash -c "
  ./help-steps/ci-signing-setup && \
  ./derivative-maker \
    --flavor '${BUILD_FLAVOR}' \
    --arch '${BUILD_ARCH}' \
    --target '${BUILD_TARGET}' \
    --type '${BUILD_TYPE}' \
    --freshness '${BUILD_FRESHNESS}' \
    --allow-untagged '${ALLOW_UNTAGGED}' \
    --allow-uncommitted '${ALLOW_UNCOMMITTED}'
"
