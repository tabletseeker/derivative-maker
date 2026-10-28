#!/usr/bin/env bash

set -x
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

echo "Generating an ephemeral SSH keypair natively on the host runner..."
ssh-keygen -t ed25519 -N "" -f ./id_ed25519

cat > user-data <<'EOF'
#cloud-config
users:
  - name: debian
    ssh_authorized_keys:
      - $(cat ./id_ed25519.pub)
    sudo: ALL=(ALL) NOPASSWD:ALL
EOF

touch meta-data
cloud-localds cloud-init.img user-data meta-data

echo "Launching hardware-accelerated QEMU instance..."
rm -f vm_output.log
touch vm_output.log

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

echo "Waiting for virtual machine initialization..."
sleep 20
sudo chown runner:docker vm_output.log || true

echo "=== streaming guest OS compilation log live ==="
tail -f vm_output.log | while read -r line; do
  echo "[VM LOG] $line"
done &
TAIL_PID=$!

echo "Waiting for guest OS network accessibility..."
until nc -z 127.0.0.1 2222; do
  sleep 2
done
echo "SSH handshake completed successfully."

(
  COUNTER=0
  MAX_LOOPS=720
  until grep -q "### VM BUILD ENGINE COMPLETED SUCCESS ###" vm_output.log 2>/dev/null; do
    if ! pgrep -f "qemu-system-x86_64" >/dev/null; then
      echo "CRITICAL HOST ERROR: QEMU simulation engine terminated unexpectedly!"
      exit 1
    fi
    if grep -q "\[FAILED\] Failed to start cloud-final.service" vm_output.log 2>/dev/null; then
      echo "CRITICAL HOST ERROR: Cloud environment automation crashed inside the guest!"
      sudo killall qemu-system-x86_64 || true
      exit 1
    fi
    COUNTER=$((COUNTER + 1))
    if [ "$COUNTER" -ge "$MAX_LOOPS" ]; then
      echo "CRITICAL HOST ERROR: Compilation window timed out waiting for success token!"
      sudo killall qemu-system-x86_64 || true
      exit 1
    fi
    sleep 15
  done
  echo "Background validation daemon: success token captured."
) &
MONITOR_PID=$!

if [ -z "${CI_PRIVATE_KEY:-}" ]; then
  echo "CRITICAL HOST ERROR: CI_PRIVATE_KEY environment secret is empty!" >&2
  exit 1
fi

echo "Host runner: streaming private key securely into Guest VM memory path..."
ssh -i ./id_ed25519 -p 2222 \
  -o StrictHostKeyChecking=no \
  debian@127.0.0.1 \
  "mkdir -p '${KEY_DIR}' && cat > '${KEY_FILE}' && chmod 400 '${KEY_FILE}'" <<< "${CI_PRIVATE_KEY}"

echo "Host runner: main execution block starting..."
ssh -i ./id_ed25519 -p 2222 \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=15 \
  -o ConnectionAttempts=5 \
  debian@127.0.0.1 <<'EOF'
  set -Eeuo pipefail

  echo "=== pre-configuring package manager for automation ==="
  sudo mkdir -p /etc/apt/apt.conf.d
  echo 'Dpkg::Options { "--force-confnew"; "--force-confdef"; };' | sudo tee /etc/apt/apt.conf.d/99force-noninteractive
  echo 'APT::Get::Assume-Yes "true";' | sudo tee -a /etc/apt/apt.conf.d/99force-noninteractive
  echo 'APT::Get::List-Cleanup "false";' | sudo tee -a /etc/apt/apt.conf.d/99force-noninteractive

  echo "=== expanding filesystem inside QEMU ==="
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y -q
  sudo apt-get install -y -q cloud-guest-utils
  sudo growpart /dev/vda 1 || true
  sudo resize2fs /dev/vda 1 || true
  df -h /

  echo "=== installing core build dependencies ==="
  sudo apt-get install -y -q git qemu-utils coreutils curl gnupg sq \
  systemd systemd-container iptables sudo lsb-release podman buildah uidmap \
  dbus-user-session haveged moreutils

  echo "=== ensuring entropy daemon is active ==="
  sudo systemctl start haveged || true

  echo "=== provisioning namespace resource pools ==="
  if ! grep -q "debian" /etc/subuid; then
    echo "debian:100000:65536" | sudo tee -a /etc/subuid
    echo "debian:100000:65536" | sudo tee -a /etc/subgid
  fi

  sudo loginctl enable-linger debian
  
  mkdir -p /home/debian/build-workspace

  git clone \
    --single-branch \
    --branch "testing" \
    --recurse-submodules \
    "$GIT_URL" \
    /home/debian/build-workspace

  cat > /tmp/build_env.sh <<ENVFILE
export BUILD_FLAVOR="${BUILD_FLAVOR}"
export BUILD_ARCH="${BUILD_ARCH}"
export BUILD_TARGET="${BUILD_TARGET}"
export BUILD_TYPE="${BUILD_TYPE}"
export BUILD_FRESHNESS="${BUILD_FRESHNESS}"
export ALLOW_UNCOMMITTED="${ALLOW_UNCOMMITTED}"
export ALLOW_UNFROZEN="${ALLOW_UNFROZEN}"
export ENGINE="${ENGINE}"
export GITHUB_TOKEN="${GITHUB_TOKEN}"
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
export flavor_meta_packages_to_install="${FLAVOR_META_PACKAGES}"
export install_package_list="${INSTALL_PACKAGE_LIST}"
export DERIVATIVE_APT_REPOSITORY_OPTS="${DERIVATIVE_APT_REPOSITORY_OPTS}"
export dist_build_non_interactive=true
export CI=true
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ENVFILE

  echo "=== launching native build engine in unprivileged login context ==="

  sudo mkdir -p /run/user/1000
  sudo chown debian:debian /run/user/1000

  mkdir -p /home/debian/.gnupg
  chmod 700 /home/debian/.gnupg

  sudo -E -u debian bash -c '
    set -Eeuox pipefail
    source /tmp/build_env.sh

    cd /home/debian/build-workspace

    ./oci/derivative-maker-oci-run -- \
    ./help-steps/ci-signing-setup && \
    ./derivative-maker \
      --flavor "$BUILD_FLAVOR" \
      --arch "$BUILD_ARCH" \
      --target "$BUILD_TARGET" \
      --type "$BUILD_TYPE" \
      --freshness "$BUILD_FRESHNESS" \
      --allow-untagged true \
      --allow-uncommitted "$ALLOW_UNCOMMITTED" \
      --allow-unfrozen "$ALLOW_UNFROZEN"
  '
EOF
