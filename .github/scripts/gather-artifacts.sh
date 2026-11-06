#!/usr/bin/env bash

set -x
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE}")" && pwd)"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
STAGING_DIR="${WORKSPACE_DIR}/release-staging"
REPO_ROOT="${REPO_ROOT:-${WORKSPACE_DIR}}"
BUILD_LOG="${SCRIPT_DIR}/build.log"

mkdir -p "${STAGING_DIR}"

echo "=== Streaming build artifacts out of the guest ==="
ssh -i ./id_ed25519 -p 2222 \
  -o StrictHostKeyChecking=no \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  debian@127.0.0.1 \
  "find /home/debian/binary_mnt -type f \
   \( -name '*Kicksecure*.xz' \
      -o -name '*Whonix*.xz' \
      -o -name '*.iso' \
      -o -name '*.ova' \
      -o -name '*.asc' \
      -o -name '*.sig' \
      -o -name '*.sha512sums' \
      -o -name '*.dm-buildinfo' \
      -o -name '*.torrent' \
      -o -name 'derivative-maker-source-*.xz' \) \
      -print0 | xargs -0 tar -cf -" \
  | tar -xSf - -i --transform='s|.*/||' -C "${STAGING_DIR}"

if [[ -f "${BUILD_LOG}" ]]; then
  cp -- "${BUILD_LOG}" "${STAGING_DIR}/build.log"
fi

echo "=== Fix ownership of container-created build artifacts ==="
cd "${STAGING_DIR}"
sudo chown -R runner:runner .

echo "=== Split oversized files to respect release limits ==="
find . -maxdepth 1 -type f ! -name "SHA256SUMS" -print0 | while IFS= read -r -d '' ASSET; do
FILE_SIZE_MB="$(du -m "${ASSET}" | cut -f1)"
  if [ "${FILE_SIZE_MB}" -gt 2000 ]; then
    echo "Asset '${ASSET}' (${FILE_SIZE_MB} MB) exceeds 2GB threshold; splitting."
    split -b 1500M "${ASSET}" "${ASSET}.part_"
    rm -f "${ASSET}"
  fi
done

echo "=== Generate SHA256SUMS ==="
rm -f SHA256SUMS
find . -maxdepth 1 -type f ! -name "SHA256SUMS" -print0 | xargs -0 sha256sum > SHA256SUMS || true
cat SHA256SUMS || true

if [ "${BUILD_ARCH:-amd64}" = "amd64" ]; then
  ARCH_NAME="Intel_AMD64"
else
  ARCH_NAME="Intel_x86"
fi

if [ "$ALLOW_UNCOMMITTED" = "true" ]; then
  GIT_CLEAN_STR="⚠️ Allowing Uncommitted"
else
  GIT_CLEAN_STR="✅ Clean Tree"
fi

if [ "$ALLOW_UNFROZEN" = "true" ]; then
  FROZEN_SRC_STR="⚠️ Unfrozen Sources"
else
  FROZEN_SRC_STR="✅ Frozen"
fi

echo "INFO: Fetching newly created tag."
git -C "${REPO_ROOT}" fetch origin --tags --force

RELEASE_TAG="$(git -C "${REPO_ROOT}" tag --sort=-v:refname | head -n1)"

if [[ -z "${RELEASE_TAG:-}" ]]; then
  echo "CRITICAL ERROR: Failed to resolve a valid release tag from the Git repository!" >&2
  echo "Aborting to prevent a corrupted or unsigned lightweight fallback release." >&2
  exit 1
fi

RELEASE_TITLE="${RELEASE_FLAVOR} ${RELEASE_TAG%%-*} (${ARCH_NAME} ${dist_build_multi_target_list^^:-} ${BUILD_TYPE^^:-})"

# Generate Download Table
MATRIX_FILE="${WORKSPACE_DIR}/download_matrix.md"
cat << 'EOF' > "${MATRIX_FILE}"

### 📦 Download Artifacts

| Build Artifact / File Type | Download Link | File Size |
| :--- | :--- | :--- |
EOF

find "${STAGING_DIR}" -maxdepth 1 -type f ! -name "SHA256SUMS" -print |
  sort |
  while IFS= read -r FILE_PATH; do
    FILE_NAME="$(basename "${FILE_PATH}")"
    FILE_SIZE="$(du -h "${FILE_PATH}" | cut -f1)"

    case "${FILE_NAME}" in
      *.iso)              TYPE_STR="💿 Live ISO" ;;
      *.ova)              TYPE_STR="🧊 VirtualBox Appliance" ;;
      *.qcow2.xz|*.qcow2.*.xz)
                          TYPE_STR="⚡ KVM / QEMU Image" ;;
      *.torrent)          TYPE_STR="🧲 Torrent File" ;;
      *.asc|*.sig)        TYPE_STR="🔏 Signature Verification" ;;
      *.sha512sums)       TYPE_STR="🔑 SHA-512 Checksums" ;;
      *.dm-buildinfo)     TYPE_STR="🌱 Reproducible Build Manifest" ;;
      *source*.xz)        TYPE_STR="📦 Source Archive" ;;
      *.log)              TYPE_STR="📄 Log File" ;;
      *)                  TYPE_STR="🧩 Supplementary Asset" ;;
    esac

    DOWNLOAD_URL="${GIT_URL}/releases/download/${RELEASE_TAG}/${FILE_NAME}"
    printf '| **%s**<br>`%s` | [Download Direct](%s) | `%s` |\n' \
      "${TYPE_STR}" "${FILE_NAME}" "${DOWNLOAD_URL}" "${FILE_SIZE}" \
      >> "${MATRIX_FILE}"
  done

{
  printf '\n#### 📋 Quick Verification Checksums\n```text\n'
  cat "${STAGING_DIR}/SHA256SUMS"
  printf '```\n\n'
} >> "${MATRIX_FILE}"

[ -n "${flavor_meta_packages:-}" ] && META_ROW="| **Custom Meta Packages Added** | \`$flavor_meta_packages\` |"
[ -n "${install_package_list:-}" ] && PKG_ROW="| **Appended Package List** | \`$install_package_list\` |"
[ -n "${DERIVATIVE_APT_REPOSITORY_OPTS:-}" ] && APT_ROW="| **Custom APT Repository Flags** | \`$DERIVATIVE_APT_REPOSITORY_OPTS\` |"

cat << EOF > "${WORKSPACE_DIR}/release_notes.md"
### 🛠️ Build Manifest

| Parameter | Build Option |
| :--- | :--- |
| **Flavor Configuration** | \`$RELEASE_FLAVOR\` |
| **Target Architecture** | \`$BUILD_ARCH\` |
| **Output Format Target** | \`$dist_build_multi_target_list\` |
| **System Footprint Type** | \`$BUILD_TYPE\` |
| **Repository Freshness** | \`$BUILD_FRESHNESS\` |
| **Container Build Engine** | \`$ENGINE\` |
| **Frozen Sources Status** | $FROZEN_SRC_STR |
| **Enforcing Clean Git** | $GIT_CLEAN_STR |
| **Release Version Tag** | \`$CHOSEN_VERSION\` |
EOF

[[ -n "${META_ROW:-}" ]] && echo "$META_ROW" >> "${WORKSPACE_DIR}/release_notes.md"
[[ -n "${PKG_ROW:-}" ]] && echo "$PKG_ROW" >> "${WORKSPACE_DIR}/release_notes.md"
[[ -n "${APT_ROW:-}" ]] && echo "$APT_ROW" >> "${WORKSPACE_DIR}/release_notes.md"

# Append the visual artifact markdown table directly onto the build configuration document
cat "${MATRIX_FILE}" >> "${WORKSPACE_DIR}/release_notes.md"
rm -f "${MATRIX_FILE}"

echo "=== Final staging layout ==="
ls -lh "${STAGING_DIR}"

# Initialize tracking loop states
RELEASE_EXISTS=true
gh release view "${RELEASE_TAG}" >/dev/null 2>&1 || RELEASE_EXISTS=false

if [ "${RELEASE_EXISTS}" = "true" ]; then
  echo "INFO: Shared tag release found. Appending matrix build notes..."

  gh release view "${RELEASE_TAG}" --json body --template '{{.body}}' > "${WORKSPACE_DIR}/cumulative_notes.tmp"
  echo -e "\n\n---\n" >> "${WORKSPACE_DIR}/cumulative_notes.tmp"

  # Stitch the new build flavor manifest table onto the bottom of the old notes
  cat "${WORKSPACE_DIR}/release_notes.md" >> "${WORKSPACE_DIR}/cumulative_notes.tmp"

  # Update the live GitHub page description with the combined stacked summary
  gh release edit "${RELEASE_TAG}" --notes-file "${WORKSPACE_DIR}/cumulative_notes.tmp" --prerelease=false

  rm -f "${WORKSPACE_DIR}/cumulative_notes.tmp"
else
  echo "INFO: First matrix build detected. Attempting atomic creation..."
  gh release create "${RELEASE_TAG}" \
    --title "${RELEASE_TITLE}" \
    --notes-file "${WORKSPACE_DIR}/release_notes.md" \
    --draft=false \
    --prerelease=false \
    --target "$(git -C "${REPO_ROOT}" rev-parse HEAD)" || echo "INFO: Release container was concurrently initialized by a parallel job."
fi

echo "INFO: Syncing artifact binaries to release panel..."
gh release upload "${RELEASE_TAG}" "${STAGING_DIR}"/* --clobber

echo "=== Release assets processing complete. ==="

