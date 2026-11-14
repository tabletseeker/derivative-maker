#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

if [[ "${TRACE:-false}" == "true" ]]; then
  set -x
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
STAGING_DIR="${WORKSPACE_DIR}/release-staging"
REPO_ROOT="${REPO_ROOT:-${WORKSPACE_DIR}}"
BUILD_LOG="${SCRIPT_DIR}/build.log"
RENDERER="${SCRIPT_DIR}/release-display.py"
RELEASE_NOTES_FILE="${WORKSPACE_DIR}/release_notes.md"
RUNNER_USER="$(id -un)"
RUNNER_GROUP="$(id -gn)"
GIT_URL="${GIT_URL:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-tabletseeker/derivative-maker}}"
BUILD_LABEL="${RELEASE_FLAVOR:-${flavors_list:-build}}"
BUILD_ID="${BUILD_LABEL,,}-${GITHUB_RUN_ID:-local}"
CHECKSUM_FILE="SHA256SUMS-${BUILD_ID}"
BUILD_LOG_FILE="build-${BUILD_ID}.log"
BUILD_NOTES_FILE="${BUILD_ID}-release-notes.md"

# Start clean so a previous run cannot add stale assets to this release.
rm -rf -- "${STAGING_DIR}"
mkdir -p -- "${STAGING_DIR}"

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
  cp -- "${BUILD_LOG}" "${STAGING_DIR}/${BUILD_LOG_FILE}"
else
  echo "WARNING: Build log not found at ${BUILD_LOG}" >&2
fi

echo "=== Fix ownership of container-created build artifacts ==="
sudo chown -R "${RUNNER_USER}:${RUNNER_GROUP}" "${STAGING_DIR}"

echo "=== Split oversized files to respect release limits ==="
find "${STAGING_DIR}" -maxdepth 1 -type f -print0 |
  while IFS= read -r -d '' asset; do
    file_size_mb="$(du -m -- "${asset}" | cut -f1)"
    if [[ "${file_size_mb}" -gt 2000 ]]; then
      echo "Asset '${asset}' (${file_size_mb} MB) exceeds 2GB threshold; splitting."
      split -b 1500M -- "${asset}" "${asset}.part_"
      rm -f -- "${asset}"
    fi
  done

if [[ ! -f "${RENDERER}" ]]; then
  echo "ERROR: Release display renderer not found: ${RENDERER}" >&2
  exit 1
fi

if [[ "${BUILD_ARCH:-amd64}" == "amd64" ]]; then
  ARCH_NAME="Intel_AMD64"
elif [[ "${BUILD_ARCH:-}" == "arm64" ]]; then
  ARCH_NAME="ARM64"
else
  ARCH_NAME="${BUILD_ARCH:-unknown}"
fi

if [[ "${ALLOW_UNCOMMITTED:-false}" == "true" ]]; then
  GIT_CLEAN_STR="⚠️ Allowing Uncommitted"
else
  GIT_CLEAN_STR="✅ Clean Tree"
fi

if [[ "${ALLOW_UNFROZEN:-false}" == "true" ||
      "${BUILD_FRESHNESS:-unknown}" != "frozen" ]]; then
  FROZEN_SRC_STR="⚠️ Unfrozen"
else
  FROZEN_SRC_STR="✅ Frozen"
fi

if [[ -z "${RELEASE_TAG:-}" ]]; then
  echo "ERROR: RELEASE_TAG must be provided by the workflow." >&2
  exit 1
fi

BUILD_TARGET_UPPER="${dist_build_multi_target_list:-}"
BUILD_TARGET_UPPER="${BUILD_TARGET_UPPER^^}"
BUILD_TYPE_UPPER="${BUILD_TYPE:-}"
BUILD_TYPE_UPPER="${BUILD_TYPE_UPPER^^}"

if [[ -n "${flavor_meta_packages:-}" ]]; then
  META_ROW="| **Custom Meta Packages Added** | \`${flavor_meta_packages}\` |"
fi
if [[ -n "${install_package_list:-}" ]]; then
  PKG_ROW="| **Appended Package List** | \`${install_package_list}\` |"
fi
if [[ -n "${DERIVATIVE_APT_REPOSITORY_OPTS:-}" ]]; then
  APT_ROW="| **Custom APT Repository Flags** | \`${DERIVATIVE_APT_REPOSITORY_OPTS}\` |"
fi

cat <<EOF > "${RELEASE_NOTES_FILE}"
<!-- matrix-build:${BUILD_ID} -->

## ${RELEASE_FLAVOR:-${flavors_list:-}} ${RELEASE_TAG%%-*} (${ARCH_NAME} ${BUILD_TARGET_UPPER} ${BUILD_TYPE_UPPER})

| Parameter | Build Option |
| :--- | :--- |
| **Flavor Configuration** | \`${RELEASE_FLAVOR:-${flavors_list:-unknown}}\` |
| **Target Architecture** | \`${BUILD_ARCH:-unknown}\` |
| **Output Format Target** | \`${dist_build_multi_target_list:-unknown}\` |
| **System Footprint Type** | \`${BUILD_TYPE:-unknown}\` |
| **Repository Freshness** | \`${BUILD_FRESHNESS:-unknown}\` |
| **Container Build Engine** | \`${ENGINE:-unknown}\` |
| **Frozen Sources Status** | ${FROZEN_SRC_STR} |
| **Enforcing Clean Git** | ${GIT_CLEAN_STR} |
| **Release Version Tag** | \`${CHOSEN_VERSION:-${RELEASE_TAG%%-*}}\` |

EOF

[[ -z "${META_ROW:-}" ]] || printf '%s\n' "${META_ROW}" >> "${RELEASE_NOTES_FILE}"
[[ -z "${PKG_ROW:-}" ]] || printf '%s\n' "${PKG_ROW}" >> "${RELEASE_NOTES_FILE}"
[[ -z "${APT_ROW:-}" ]] || printf '%s\n' "${APT_ROW}" >> "${RELEASE_NOTES_FILE}"

echo "=== Render flavor menus and SHA-512 summary ==="
python3 "${RENDERER}" \
  "${STAGING_DIR}" \
  "${GIT_URL}" \
  "${RELEASE_TAG}" \
  >> "${RELEASE_NOTES_FILE}"

# Unique asset is downloaded by the single publisher job after
# all matrix jobs finish.
cp -- "${RELEASE_NOTES_FILE}" "${STAGING_DIR}/${BUILD_NOTES_FILE}"

echo "=== Generate build-specific SHA256SUMS ==="
(
  cd -- "${STAGING_DIR}"
  rm -f -- "${CHECKSUM_FILE}"
  find . -maxdepth 1 -type f ! -name "${CHECKSUM_FILE}" -print0 |
    xargs -0 -r sha256sum > "${CHECKSUM_FILE}"
  cat "${CHECKSUM_FILE}"
)

echo "=== Final staging layout ==="
ls -lh "${STAGING_DIR}"

# The prepare-release job must create this release before the matrix begins.
if ! gh release view "${RELEASE_TAG}" >/dev/null 2>&1; then
  echo "ERROR: Expected release '${RELEASE_TAG}' to exist before artifact upload." >&2
  echo "Check the prepare-release job and GITHUB_TOKEN permissions." >&2
  exit 1
fi

mapfile -d '' -t STAGED_ASSETS < <(
  find "${STAGING_DIR}" -maxdepth 1 -type f -print0 | sort -z
)

if [[ "${#STAGED_ASSETS[@]}" -eq 0 ]]; then
  echo "ERROR: No staged assets to upload." >&2
  exit 1
fi

echo "INFO: Uploading this runner's assets to release '${RELEASE_TAG}'."
gh release upload "${RELEASE_TAG}" "${STAGED_ASSETS[@]}"

echo "=== Release assets processing complete. ==="
