#!/usr/bin/env bash

set -x
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE}")" && pwd)"

# Ephemeral loopback network setup
echo "Generating an ephemeral SSH keypair natively on the host runner..."
ssh-keygen -t ed25519 -N "" -f ./id_ed25519

cat > user-data <<EOF
#cloud-config
users:
  - name: debian
    ssh_authorized_keys:
      - $(cat ./id_ed25519.pub)
    sudo: ALL=(ALL) NOPASSWD:ALL
EOF

touch meta-data
cloud-localds cloud-init.img user-data meta-data

# Launch QEMU Instance Engine
echo "Launching hardware-accelerated QEMU instance..."
touch vm_output.log
chmod 666 vm_output.log

sudo qemu-system-x86_64 \
  -enable-kvm \
  -m 6G \
  -smp 4 \
  -cpu host \
  -drive file=debian-base.qcow2,format=qcow2,if=virtio \
  -drive file=cloud-init.img,format=raw,if=virtio,id=cloud \
  -boot order=c \
  -nographic \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=n0 \
  -serial file:vm_output.log &

echo "Streaming Guest OS /dev/ttyS0"
tail -f vm_output.log | sed 's/^/[VM LOG] /' &
TAIL_PID=$!

echo "Waiting for guest OS initialization and secure user provisioning..."
until ssh -i ./id_ed25519 -p 2222 \
          -o StrictHostKeyChecking=no \
          -o ConnectTimeout=2 \
          -o PasswordAuthentication=no \
          debian@127.0.0.1 "true" 2>/dev/null; do
  sleep 2
done

echo "Host runner: Executing deployment pipeline..."

ssh -i ./id_ed25519 -p 2222 \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o ConnectionAttempts=5 \
    debian@127.0.0.1 \
    "BUILD_FLAVOR='${BUILD_FLAVOR:-}' \
     BUILD_ARCH='${BUILD_ARCH:-}' \
     BUILD_TARGET='${BUILD_TARGET:-}' \
     BUILD_TYPE='${BUILD_TYPE:-}' \
     BUILD_FRESHNESS='${BUILD_FRESHNESS:-}' \
     ALLOW_UNTAGGED='${ALLOW_UNTAGGED:-}' \
     ALLOW_UNCOMMITTED='${ALLOW_UNCOMMITTED:-}' \
     ALLOW_UNFROZEN='${ALLOW_UNFROZEN:-}' \
     ENGINE='${ENGINE:-}' \
     flavor_meta_packages_to_install='${FLAVOR_META_PACKAGES:-}' \
     install_package_list='${INSTALL_PACKAGE_LIST:-}' \
     DERIVATIVE_APT_REPOSITORY_OPTS='${DERIVATIVE_APT_REPOSITORY_OPTS:-}' \
     CHOSEN_VERSION='${CHOSEN_VERSION:-}' \
     GIT_URL='${GIT_URL:-}' \
     GITHUB_REPOSITORY='${GITHUB_REPOSITORY:-}' \
     GITHUB_TOKEN='${GITHUB_TOKEN:-}' \
     CI_PRIVATE_KEY='${CI_PRIVATE_KEY:-}' \
     KEY_DIR='${KEY_DIR:-/home/debian/.key_mnt}' \
     KEY_FILE='${KEY_FILE:-/home/debian/.key_mnt/my-private-key.asc}' \
     XDG_RUNTIME_DIR=/run/user/1000 \
     DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus' \
     PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' \
     sudo -E -u debian bash -s" < "${SCRIPT_DIR}/vm-payload.sh"

echo "[+] Workspace artifact build block completed. Keeping VM alive for extraction phase."

