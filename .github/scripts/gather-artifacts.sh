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
RENDERER="${SCRIPT_DIR}/release_display.py"
RELEASE_NOTES_FILE="${WORKSPACE_DIR}/release_notes.md"
RUNNER_USER="$(id -un)"
RUNNER_GROUP="$(id -gn)"
GIT_URL="${GIT_URL:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-tabletseeker/derivative-maker}}"

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
  cp -- "${BUILD_LOG}" "${STAGING_DIR}/build.log"
else
  echo "WARNING: Build log not found at ${BUILD_LOG}" >&2
fi

echo "=== Fix ownership of container-created build artifacts ==="
sudo chown -R "${RUNNER_USER}:${RUNNER_GROUP}" "${STAGING_DIR}"

echo "=== Split oversized files to respect release limits ==="
find "${STAGING_DIR}" -maxdepth 1 -type f ! -name "SHA256SUMS" -print0 |
  while IFS= read -r -d '' asset; do
    file_size_mb="$(du -m -- "${asset}" | cut -f1)"
    if [[ "${file_size_mb}" -gt 2000 ]]; then
      echo "Asset '${asset}' (${file_size_mb} MB) exceeds 2GB threshold; splitting."
      split -b 1500M -- "${asset}" "${asset}.part_"
      rm -f -- "${asset}"
    fi
  done

echo "=== Generate SHA256SUMS ==="
(
  cd -- "${STAGING_DIR}"
  rm -f -- SHA256SUMS
  find . -maxdepth 1 -type f ! -name "SHA256SUMS" -print0 |
    xargs -0 -r sha256sum > SHA256SUMS
  cat SHA256SUMS
)

if [[ ! -f "${RENDERER}" ]]; then
  echo "ERROR: Release display renderer not found: ${RENDERER}" >&2
  exit 1
fi

if [[ "${BUILD_ARCH:-amd64}" == "amd64" ]]; then
  ARCH_NAME="Intel_AMD64"
else
  ARCH_NAME="Intel_x86"
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

echo "INFO: Fetching newly created tag."
git -C "${REPO_ROOT}" fetch origin --tags --force

RELEASE_TAG="${RELEASE_TAG:-}"
if [[ -z "${RELEASE_TAG}" ]]; then
  if [[ -n "${CHOSEN_VERSION:-}" ]]; then
    RELEASE_TAG="${CHOSEN_VERSION}-nightly"
  else
    mapfile -t RELEASE_TAGS < <(
      git -C "${REPO_ROOT}" tag --sort=-v:refname
    )
    RELEASE_TAG="${RELEASE_TAGS[0]:-}"
  fi
fi

if [[ -z "${RELEASE_TAG}" ]]; then
  echo "CRITICAL ERROR: Failed to resolve a valid release tag." >&2
  echo "Aborting to prevent a corrupted or unsigned fallback release." >&2
  exit 1
fi

BUILD_TARGET_UPPER="${dist_build_multi_target_list:-}"
BUILD_TARGET_UPPER="${BUILD_TARGET_UPPER^^}"
BUILD_TYPE_UPPER="${BUILD_TYPE:-}"
BUILD_TYPE_UPPER="${BUILD_TYPE_UPPER^^}"

RELEASE_TITLE="${RELEASE_FLAVOR} ${RELEASE_TAG%%-*} (${ARCH_NAME} ${BUILD_TARGET_UPPER} ${BUILD_TYPE_UPPER})"

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
### 🛠️ Build Manifest

| Parameter | Build Option |
| :--- | :--- |
| **Flavor Configuration** | \`${RELEASE_FLAVOR:-${flavors_list}}\` |
| **Target Architecture** | \`${BUILD_ARCH}\` |
| **Output Format Target** | \`${dist_build_multi_target_list}\` |
| **System Footprint Type** | \`${BUILD_TYPE}\` |
| **Repository Freshness** | \`${BUILD_FRESHNESS}\` |
| **Container Build Engine** | \`${ENGINE}\` |
| **Frozen Sources Status** | ${FROZEN_SRC_STR} |
| **Enforcing Clean Git** | ${GIT_CLEAN_STR} |
| **Release Version Tag** | \`${CHOSEN_VERSION:-${RELEASE_TAG}}\` |

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

echo "=== Final staging layout ==="
ls -lh "${STAGING_DIR}"

RELEASE_EXISTS=true
gh release view "${RELEASE_TAG}" >/dev/null 2>&1 || RELEASE_EXISTS=false

if [[ "${RELEASE_EXISTS}" == "true" ]]; then
  echo "INFO: Shared tag release found. Appending build notes..."

  cumulative_notes="${WORKSPACE_DIR}/cumulative_notes.tmp"
  gh release view "${RELEASE_TAG}" --json body --template '{{.body}}' \
    > "${cumulative_notes}"
  printf '\n\n---\n' >> "${cumulative_notes}"
  cat "${RELEASE_NOTES_FILE}" >> "${cumulative_notes}"

  gh release edit "${RELEASE_TAG}" \
    --notes-file "${cumulative_notes}" \
    --prerelease=false

  rm -f -- "${cumulative_notes}"
else
  echo "INFO: First matrix build detected. Attempting release creation..."

  if ! gh release create "${RELEASE_TAG}" \
    --title "${RELEASE_TITLE}" \
    --notes-file "${RELEASE_NOTES_FILE}" \
    --draft=false \
    --prerelease=false \
    --target "$(git -C "${REPO_ROOT}" rev-parse HEAD)"; then
    echo "INFO: Release creation did not complete; checking whether a parallel job created it."
    gh release view "${RELEASE_TAG}" >/dev/null
  fi
fi

echo "INFO: Uploading staged artifacts to the release..."
mapfile -d '' -t STAGED_ASSETS < <(
  find "${STAGING_DIR}" -maxdepth 1 -type f -print0 | sort -z
)
gh release upload "${RELEASE_TAG}" "${STAGED_ASSETS[@]}" --clobber

echo "=== Release assets processing complete. ==="
