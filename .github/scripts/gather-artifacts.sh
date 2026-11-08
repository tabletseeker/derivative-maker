#!/usr/bin/env bash

set -x
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
  debian@127.0.0.1 bash -s <<'REMOTE' \
  | tar --extract --file=- --directory="${STAGING_DIR}" --transform='s|.*/||'
set -euo pipefail

cd /home/debian/binary_mnt
file_list="$(mktemp)"
trap 'rm -f "${file_list}"' EXIT

find . -type f \
  \( -name '*Kicksecure*.xz' \
     -o -name '*Whonix*.xz' \
     -o -name 'derivative-maker-source-*.xz' \
     -o -name '*.iso' \
     -o -name '*.ova' \
     -o -name '*.asc' \
     -o -name '*.sig' \
     -o -name '*.sha512sums' \
     -o -name '*.dm-buildinfo' \
     -o -name '*.torrent' \
     -o -name '*.log' \) \
  -print0 > "${file_list}"

tar --create --file=- --null --files-from="${file_list}"
REMOTE

if [[ -f "${BUILD_LOG}" ]]; then
  cp -- "${BUILD_LOG}" "${STAGING_DIR}/build.log"
else
  echo "WARNING: build log not found at ${BUILD_LOG}" >&2
fi

echo "=== Fix ownership of container-created build artifacts ==="
cd "${STAGING_DIR}"
sudo chown -R runner:runner .

echo "=== Split oversized files to respect release limits ==="
find . -maxdepth 1 -type f ! -name "SHA256SUMS" -print0 |
  while IFS= read -r -d '' ASSET; do
    FILE_SIZE_MB="$(du -m "${ASSET}" | cut -f1)"
    if [ "${FILE_SIZE_MB}" -gt 2000 ]; then
      echo "Asset '${ASSET}' (${FILE_SIZE_MB} MB) exceeds 2GB threshold; splitting."
      split -b 1500M "${ASSET}" "${ASSET}.part_"
      rm -f "${ASSET}"
    fi
  done

echo "=== Generate SHA256SUMS ==="
rm -f SHA256SUMS
find . -maxdepth 1 -type f ! -name "SHA256SUMS" -print0 |
  xargs -0 -r sha256sum > SHA256SUMS
cat SHA256SUMS

if [ "${BUILD_ARCH:-amd64}" = "amd64" ]; then
  ARCH_NAME="Intel_AMD64"
else
  ARCH_NAME="Intel_x86"
fi

if [ "${ALLOW_UNCOMMITTED:-false}" = "true" ]; then
  GIT_CLEAN_STR="⚠️ Allowing Uncommitted"
else
  GIT_CLEAN_STR="✅ Clean Tree"
fi

if [ "${ALLOW_UNFROZEN:-false}" = "true" ] || [ "${BUILD_FRESHNESS}" != "frozen" ]; then
  FROZEN_SRC_STR="⚠️ Unfrozen"
else
  FROZEN_SRC_STR="✅ Frozen"
fi

echo "INFO: Fetching newly created tag."
git -C "${REPO_ROOT}" fetch origin --tags --force

if [[ -n "${CHOSEN_VERSION:-}" ]]; then
  RELEASE_TAG="${CHOSEN_VERSION}-nightly"
else
  mapfile -t RELEASE_TAGS < <(git -C "${REPO_ROOT}" tag --sort=-v:refname)
  RELEASE_TAG="${RELEASE_TAGS[0]:-}"
fi

if [[ -z "${RELEASE_TAG:-}" ]]; then
  echo "CRITICAL ERROR: Failed to resolve a valid release tag from the Git repository!" >&2
  echo "Aborting to prevent a corrupted or unsigned lightweight fallback release." >&2
  exit 1
fi

BUILD_TARGET_UPPER="${dist_build_multi_target_list:-}"
BUILD_TARGET_UPPER="${BUILD_TARGET_UPPER^^}"
BUILD_TYPE_UPPER="${BUILD_TYPE:-}"
BUILD_TYPE_UPPER="${BUILD_TYPE_UPPER^^}"

RELEASE_TITLE="${RELEASE_FLAVOR} ${RELEASE_TAG%%-*} (${ARCH_NAME} ${BUILD_TARGET_UPPER} ${BUILD_TYPE_UPPER})"

MATRIX_FILE="${WORKSPACE_DIR}/download_matrix.md"

{
  printf '### 🏁 Primary Downloads\n\n'
  printf '| Artifact | File | Size |\n'
  printf '|---|---|---:|\n'
} > "${MATRIX_FILE}"

{
  printf '\n### 🔐 Verification & Supporting Files\n\n'
  printf '| File | Purpose | Size |\n'
  printf '|---|---|---:|\n'
} >> "${MATRIX_FILE}"

# Primary downloads
while IFS= read -r -d '' FILE_PATH; do
  FILE_NAME="${FILE_PATH#./}"
  FILE_SIZE="$(du -h "${FILE_PATH}" | cut -f1)"
  DOWNLOAD_URL="${GIT_URL%/}/releases/download/${RELEASE_TAG}/${FILE_NAME}"

  case "${FILE_NAME}" in
    derivative-maker-source-*.xz)
      ARTIFACT_TYPE="📦 Source Archive"
      printf '| **%s** | [`%s`](%s) | %s |\n' \
        "${ARTIFACT_TYPE}" "${FILE_NAME}" "${DOWNLOAD_URL}" "${FILE_SIZE}" \
        >> "${MATRIX_FILE}"
      ;;
    *.qcow2.libvirt.xz)
      ARTIFACT_TYPE="⚡ KVM / QEMU image"
      printf '| **%s** | [`%s`](%s) | %s |\n' \
        "${ARTIFACT_TYPE}" "${FILE_NAME}" "${DOWNLOAD_URL}" "${FILE_SIZE}" \
        >> "${MATRIX_FILE}"
      ;;
    *.ova)
      ARTIFACT_TYPE="🧊 VirtualBox Appliance"
      printf '| **%s** | [`%s`](%s) | %s |\n' \
        "${ARTIFACT_TYPE}" "${FILE_NAME}" "${DOWNLOAD_URL}" "${FILE_SIZE}" \
        >> "${MATRIX_FILE}"
      ;;
    *.iso)
      if [[ "${FILE_NAME}" == "VBoxGuestAdditions.iso" ]]; then
        ARTIFACT_TYPE="📀 VBox Guest ISO"
      else
        ARTIFACT_TYPE="💿 Live ISO"
      fi
      printf '| **%s** | [`%s`](%s) | %s |\n' \
        "${ARTIFACT_TYPE}" "${FILE_NAME}" "${DOWNLOAD_URL}" "${FILE_SIZE}" \
        >> "${MATRIX_FILE}"
      ;;
  esac
done < <(find . -maxdepth 1 -type f -print0 | sort -z)

# Verification / support files
while IFS= read -r -d '' FILE_PATH; do
  FILE_NAME="${FILE_PATH#./}"
  FILE_SIZE="$(du -h "${FILE_PATH}" | cut -f1)"
  DOWNLOAD_URL="${GIT_URL%/}/releases/download/${RELEASE_TAG}/${FILE_NAME}"

  case "${FILE_NAME}" in
    *.asc)
      PURPOSE="OpenPGP signature"
      ;;
    *.sig)
      PURPOSE="Signify signature"
      ;;
    *.sha512sums)
      PURPOSE="SHA-512 checksums"
      ;;
    *.dm-buildinfo)
      PURPOSE="Reproducible-build metadata"
      ;;
    *.torrent)
      PURPOSE="Torrent"
      ;;
    *.log)
      PURPOSE="Build log"
      ;;
    *)
      PURPOSE="Supporting file"
      ;;
  esac

  case "${FILE_NAME}" in
    derivative-maker-source-*.xz|*.qcow2.libvirt.xz|*.ova|*.iso)
      continue
      ;;
  esac

  printf '| [`%s`](%s) | %s | %s |\n' \
    "${FILE_NAME}" "${DOWNLOAD_URL}" "${PURPOSE}" "${FILE_SIZE}" \
    >> "${MATRIX_FILE}"
done < <(find . -maxdepth 1 -type f -print0 | sort -z)

{
  printf '\n#### 📋 SHA-256 checksums\n\n'
  printf 'Download [SHA256SUMS](%s) to verify the staged assets.\n\n' \
    "${GIT_URL%/}/releases/download/${RELEASE_TAG}/SHA256SUMS"
} >> "${MATRIX_FILE}"

if [[ -n "${flavor_meta_packages:-}" ]]; then
  META_ROW="| **Custom Meta Packages Added** | \`${flavor_meta_packages}\` |"
fi
if [[ -n "${install_package_list:-}" ]]; then
  PKG_ROW="| **Appended Package List** | \`${install_package_list}\` |"
fi
if [[ -n "${DERIVATIVE_APT_REPOSITORY_OPTS:-}" ]]; then
  APT_ROW="| **Custom APT Repository Flags** | \`${DERIVATIVE_APT_REPOSITORY_OPTS}\` |"
fi

cat << EOF > "${WORKSPACE_DIR}/release_notes.md"
### 🛠️ Build Manifest

| Parameter | Build Option |
| :--- | :--- |
| **Flavor Configuration** | \`${RELEASE_FLAVOR:-${flavors_list:-unknown}}\` |
| **Target Architecture** | \`${BUILD_ARCH}\` |
| **Output Format Target** | \`${dist_build_multi_target_list}\` |
| **System Footprint Type** | \`${BUILD_TYPE}\` |
| **Repository Freshness** | \`${BUILD_FRESHNESS}\` |
| **Container Build Engine** | \`${ENGINE}\` |
| **Frozen Sources Status** | ${FROZEN_SRC_STR} |
| **Enforcing Clean Git** | ${GIT_CLEAN_STR} |
| **Release Version Tag** | \`${CHOSEN_VERSION:-${RELEASE_TAG}}\` |
EOF

[[ -z "${META_ROW:-}" ]] || printf '%s\n' "${META_ROW}" >> "${WORKSPACE_DIR}/release_notes.md"
[[ -z "${PKG_ROW:-}" ]] || printf '%s\n' "${PKG_ROW}" >> "${WORKSPACE_DIR}/release_notes.md"
[[ -z "${APT_ROW:-}" ]] || printf '%s\n' "${APT_ROW}" >> "${WORKSPACE_DIR}/release_notes.md"

cat "${MATRIX_FILE}" >> "${WORKSPACE_DIR}/release_notes.md"
rm -f "${MATRIX_FILE}"

echo "=== Final staging layout ==="
ls -lh "${STAGING_DIR}"

RELEASE_EXISTS=true
gh release view "${RELEASE_TAG}" >/dev/null 2>&1 || RELEASE_EXISTS=false

if [ "${RELEASE_EXISTS}" = "true" ]; then
  echo "INFO: Shared tag release found. Appending matrix build notes..."

  gh release view "${RELEASE_TAG}" --json body --template '{{.body}}' \
    > "${WORKSPACE_DIR}/cumulative_notes.tmp"
  printf '\n\n---\n' >> "${WORKSPACE_DIR}/cumulative_notes.tmp"
  cat "${WORKSPACE_DIR}/release_notes.md" >> "${WORKSPACE_DIR}/cumulative_notes.tmp"

  gh release edit "${RELEASE_TAG}" \
    --notes-file "${WORKSPACE_DIR}/cumulative_notes.tmp" \
    --prerelease=false

  rm -f "${WORKSPACE_DIR}/cumulative_notes.tmp"
else
  echo "INFO: First matrix build detected. Attempting atomic creation..."
  gh release create "${RELEASE_TAG}" \
    --title "${RELEASE_TITLE}" \
    --notes-file "${WORKSPACE_DIR}/release_notes.md" \
    --draft=false \
    --prerelease=false \
    --target "$(git -C "${REPO_ROOT}" rev-parse HEAD)" \
    || echo "INFO: Release container was concurrently initialized by a parallel job."
fi

echo "INFO: Syncing artifact binaries to release panel..."
gh release upload "${RELEASE_TAG}" "${STAGING_DIR}"/* --clobber

echo "=== Release assets processing complete. ==="
