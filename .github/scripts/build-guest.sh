#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE}")" && pwd)"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
VM_HELPER="${SCRIPT_DIR}/vm-sync-helper.sh"

# Ephemeral loopback network setup
echo "Generating an ephemeral SSH keypair on the host runner..."
ssh-keygen -t ed25519 -N "" -f ./id_ed25519

cat > user-data <<EOF
#cloud-config
users:
  - name: debian
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ./id_ed25519.pub)
    sudo: ALL=(ALL) NOPASSWD:ALL
EOF

touch meta-data vm_output.log
cloud-localds cloud-init.img user-data meta-data

# Create copy-on-write overlay to enable caching of base debian-base.qcow2
rm -f -- build-work.qcow2
qemu-img create -f qcow2 -F qcow2 -b debian-base.qcow2 build-work.qcow2

# Launch QEMU Instance Engine
echo "Launching hardware-accelerated QEMU instance..."
sudo qemu-system-x86_64 \
  -enable-kvm \
  -m 8G \
  -smp 4 \
  -cpu host \
  -pidfile "${WORKSPACE_DIR}/qemu.pid" \
  -drive file=build-work.qcow2,format=qcow2,if=virtio \
  -drive file=cloud-init.img,format=raw,if=virtio,id=cloud \
  -boot order=c \
  -nographic \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=n0 \
  -serial file:vm_output.log &

echo "Streaming Guest OS /dev/ttyS0"
tail -f vm_output.log > >(sed 's/^/[VM LOG] /') &
TAIL_PID=$!

echo "Waiting for guest OS initialization..."
until "${VM_HELPER}" exec true >/dev/null 2>&1; do
  sleep 2
done

# Wait for actual cloud init pass
"${VM_HELPER}" exec cloud-init status --wait >/dev/null || true

echo "VM Boot completed successfully. Ending tty stream."
kill "${TAIL_PID}" 2>/dev/null || true

# Load saved approx cache
"${VM_HELPER}" restore-cache "${WORKSPACE_DIR}/approx-cache.tar.zst"

echo "Host runner: Executing deployment pipeline..."
ssh -i ./id_ed25519 -p 2222 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=15 \
    -o ConnectionAttempts=5 \
    debian@127.0.0.1 \
    "XDG_RUNTIME_DIR=/run/user/1000 \
     DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus' \
     PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' \
     BUILD_MODE='${BUILD_MODE:-}' \
     BUILD_ARCH='${BUILD_ARCH:-}' \
     BUILD_TYPE='${BUILD_TYPE:-}' \
     DEBFULLNAME='${DEBFULLNAME:-}' \
     DEBEMAIL='${DEBEMAIL:-}' \
     BUILD_FRESHNESS='${BUILD_FRESHNESS:-}' \
     ALLOW_UNTAGGED='${ALLOW_UNTAGGED:-}' \
     ALLOW_UNCOMMITTED='${ALLOW_UNCOMMITTED:-}' \
     ALLOW_UNFROZEN='${ALLOW_UNFROZEN:-}' \
     ALLOW_REMOTE='${ALLOW_REMOTE:-}' \
     ENGINE='${ENGINE:-}' \
     RELEASE_TAG='${RELEASE_TAG:-}' \
     CHOSEN_VERSION='${CHOSEN_VERSION:-}' \
     GIT_URL='${GIT_URL:-}' \
     GIT_BRANCH='${GIT_BRANCH:-}' \
     GITHUB_TOKEN='${GITHUB_TOKEN:-}' \
     GITHUB_SHA='${GITHUB_SHA:-}' \
     CI_PRIVATE_KEY='${CI_PRIVATE_KEY:-}' \
     KEY_DIR='${KEY_DIR:-/home/debian/.key_mnt}' \
     KEY_FILE='${KEY_FILE:-/home/debian/.key_mnt/my-private-key.asc}' \
     DERIVATIVE_APT_REPOSITORY_OPTS='${DERIVATIVE_APT_REPOSITORY_OPTS:-}' \
     flavor_meta_packages_to_install='${flavor_meta_packages_to_install:-}' \
     install_package_list='${install_package_list:-}' \
     flavors_list='${flavors_list:-}' \
     dist_build_target_arch='${dist_build_target_arch:-}' \
     dist_build_multi_target_list='${dist_build_multi_target_list:-}' \
     dist_build_version_type='${dist_build_version_type:-}' \
     dist_build_freshness='${dist_build_freshness:-}' \
     dist_build_redistributable='${dist_build_redistributable:-}' \
     sudo -E -u debian bash -s" < "${SCRIPT_DIR}/vm-payload.sh" 2>&1 | tee "${WORKSPACE_DIR}/build.log"

echo "[+] Workspace artifact build block completed. Keeping VM alive for extraction phase."

