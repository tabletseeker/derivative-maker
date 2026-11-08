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
echo "Generating an ephemeral SSH keypair on the host runner..."
ssh-keygen -t ed25519 -N "" -f ./id_ed25519

cat > user-data <<EOF
#cloud-config
users:
  - name: debian
    ssh_authorized_keys:
      - $(cat ./id_ed25519.pub)
    sudo: ALL=(ALL) NOPASSWD:ALL
EOF

touch meta-data vm_output.log
chmod 666 vm_output.log
cloud-localds cloud-init.img user-data meta-data

# Launch QEMU Instance Engine
echo "Launching hardware-accelerated QEMU instance..."

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

echo "Waiting for guest OS initialization..."
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
    "XDG_RUNTIME_DIR=/run/user/1000 \
     DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus' \
     PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' \
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
     CHOSEN_VERSION='${CHOSEN_VERSION:-}' \
     GIT_URL='${GIT_URL:-}' \
     GIT_BRANCH='${GIT_BRANCH:-}' \
     GITHUB_TOKEN='${GITHUB_TOKEN:-}' \
     CI_PRIVATE_KEY='${CI_PRIVATE_KEY:-}' \
     KEY_DIR='${KEY_DIR:-/home/debian/.key_mnt}' \
     KEY_FILE='${KEY_FILE:-/home/debian/.key_mnt/my-private-key.asc}' \
     DERIVATIVE_APT_REPOSITORY_OPTS='${DERIVATIVE_APT_REPOSITORY_OPTS:-}' \
     flavor_meta_packages_to_install='${FLAVOR_META_PACKAGES:-}' \
     install_package_list='${INSTALL_PACKAGE_LIST:-}' \
     flavors_list='${flavors_list:-}' \
     dist_build_target_arch='${dist_build_target_arch:-}' \
     dist_build_multi_target_list='${dist_build_multi_target_list:-}' \
     dist_build_version_type='${dist_build_version_type:-}' \
     dist_build_freshness='${dist_build_freshness:-}' \
     dist_build_redistributable='${dist_build_redistributable:-}' \
     sudo -E -u debian bash -s" < "${SCRIPT_DIR}/vm-payload.sh" 2>&1 | tee "${SCRIPT_DIR}/build.log"

echo "[+] Workspace artifact build block completed. Keeping VM alive for extraction phase."

