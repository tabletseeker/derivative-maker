#!/usr/bin/env bash

set -x
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACT_DIR="${WORKSPACE_DIR}/extracted-binaries"
STAGING_DIR="${WORKSPACE_DIR}/release-staging"
REPO_ROOT="${REPO_ROOT:-${WORKSPACE_DIR}}"

mkdir -p "${ARTIFACT_DIR}" "${STAGING_DIR}"

echo "=== Streaming build artifacts out of the guest ==="
ssh -i ./id_ed25519 -p 2222 -o StrictHostKeyChecking=no debian@127.0.0.1 \
  "tar -cf - -C /home/debian/binary_mnt ." | \
  tar -xf - -C "${ARTIFACT_DIR}"

echo "=== Copy only release artifacts into the staging directory ==="
find "${ARTIFACT_DIR}" -type f -regextype posix-extended \
  -regex '.*(Kicksecure.*\.xz|Whonix.*\.xz|\.(iso|raw|qcow2|ova|asc|sig|torrent))$' \
  -exec cp -n -t "${STAGING_DIR}/" {} +

echo "=== Generate SHA256SUMS ==="
cd "${STAGING_DIR}"
find . -maxdepth 1 -type f ! -name "SHA256SUMS" -print0 | xargs -0 sha256sum > SHA256SUMS || true
cat SHA256SUMS || true

echo "=== Split oversized files to respect release limits ==="
cd "${STAGING_DIR}"
find . -maxdepth 1 -type f ! -name "SHA256SUMS" -print0 | while IFS= read -r -d '' ASSET; do
FILE_SIZE_MB="$(du -m "${ASSET}" | cut -f1)"
  if [ "${FILE_SIZE_MB}" -gt 2000 ]; then
    echo "Asset '${ASSET}' (${FILE_SIZE_MB} MB) exceeds 2GB threshold; splitting."
    split -b 1500M "${ASSET}" "${ASSET}.part_"
    rm -f "${ASSET}"
  fi
done

echo "=== Prepare release metadata ==="
case "${BUILD_FLAVOR:-}" in
  "kicksecure-lxqt") FLAVOR_NAME="Kicksecure-LXQt" ;;
  "kicksecure-cli") FLAVOR_NAME="Kicksecure-CLI" ;;
  "whonix-gateway-lxqt") FLAVOR_NAME="Whonix-Gateway-LXQt" ;;
  "whonix-workstation-lxqt") FLAVOR_NAME="Whonix-Workstation-LXQt" ;;
  *) FLAVOR_NAME="Derivative-Image" ;;
esac

if [ "${BUILD_ARCH:-amd64}" = "amd64" ]; then
  ARCH_NAME="Intel_AMD64"
else
  ARCH_NAME="Intel_x86"
fi

META_ROW=""
PKG_ROW=""
APT_ROW=""
[ -n "${FLAVOR_META_PACKAGES:-}" ] && META_ROW="| **Custom Meta Packages Added** | \`$FLAVOR_META_PACKAGES\` |"
[ -n "${INSTALL_PACKAGE_LIST:-}" ] && PKG_ROW="| **Appended Package List** | \`$INSTALL_PACKAGE_LIST\` |"
[ -n "${DERIVATIVE_APT_OPTS:-}" ] && APT_ROW="| **Custom APT Repository Flags** | \`$DERIVATIVE_APT_OPTS\` |"

{
  echo "### 🛠️ Build Manifest"
  echo ""
  echo "| Parameter | Build Option |"
  echo "| :--- | :--- |"
  echo "| **Flavor Configuration** | \`$BUILD_FLAVOR\` |"
  echo "| **Target Architecture** | \`$BUILD_ARCH\` |"
  echo "| **Output Format Target** | \`$BUILD_TARGET\` |"
  echo "| **System Footprint Type** | \`$BUILD_TYPE\` |"
  echo "| **Repository Freshness** | \`$BUILD_FRESHNESS\` |"
  echo "| **Container Build Engine** | \`$ENGINE\` |"
  echo "| **Frozen Sources Status** | $FROZEN_SRC_STR |"
  echo "| **Enforcing Clean Git** | $GIT_CLEAN_STR |"
  echo "| **Release Version Tag** | \`$CHOSEN_VERSION\` |"
  [ -n "$META_ROW" ] && echo "$META_ROW"
  [ -n "$PKG_ROW" ] && echo "$PKG_ROW"
  [ -n "$APT_ROW" ] && echo "$APT_ROW"
  echo ""
  echo "---"
  echo "Automated system deployment binaries generated successfully. Verify downloads using the attached SHA256SUMS file."
} > "${WORKSPACE_DIR}/release_notes.md"

echo "=== Final workspace layout ==="
ls -lh "${WORKSPACE_DIR}"

echo "INFO: Fetching newly created tag."
git -C "${REPO_ROOT}" fetch origin --tags --force

RELEASE_TAG="$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null || true)"
RELEASE_TITLE="${FLAVOR_NAME} ${CHOSEN_VERSION:-unknown} (${ARCH_NAME} ${BUILD_TARGET^^:-unknown} ${BUILD_TYPE^^:-unknown})"

if [[ -z "${RELEASE_TAG:-}" ]]; then
  echo "CRITICAL ERROR: Failed to resolve a valid release tag from the Git repository!" >&2
  echo "Aborting to prevent a corrupted or unsigned lightweight fallback release." >&2
  exit 1
fi

echo "Target release tag resolved: ${RELEASE_TAG}"
echo "Target release title resolved: ${RELEASE_TITLE}"

# Create the GitHub release using the new tag.
gh release create "${RELEASE_TAG}" \
  --title "${RELEASE_TITLE}" \
  --notes-file "${WORKSPACE_DIR}/release_notes.md" \
  --draft=false \
  --prerelease=false \
  --target "${GITHUB_SHA:-$(git -C "${REPO_ROOT}" rev-parse HEAD)}" \
  "${STAGING_DIR}"/*

echo "=== Release creation complete. ==="
