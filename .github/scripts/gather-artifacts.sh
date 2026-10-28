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
ssh -i ./id_ed25519 -p 2222 \
  -o StrictHostKeyChecking=no \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o ConnectTimeout=10 \
  -q debian@127.0.0.1 "tar -cf - -C /home/debian/binary_mnt ." | \
  tar -xf - -C "${ARTIFACT_DIR}"

echo "=== Fix ownership of container-created build artifacts ==="
cd "${ARTIFACT_DIR}"
sudo chown -R runner:runner .

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

[ -n "${flavor_meta_packages:-}" ] && META_ROW="| **Custom Meta Packages Added** | \`$flavor_meta_packages\` |"
[ -n "${install_package_list:-}" ] && PKG_ROW="| **Appended Package List** | \`$install_package_list\` |"
[ -n "${DERIVATIVE_APT_REPOSITORY_OPTS:-}" ] && APT_ROW="| **Custom APT Repository Flags** | \`$DERIVATIVE_APT_REPOSITORY_OPTS\` |"

cat << EOF > "${WORKSPACE_DIR}/release_notes.md"
### 🛠️ Build Manifest

| Parameter | Build Option |
| :--- | :--- |
| **Flavor Configuration** | \`$BUILD_FLAVOR\` |
| **Target Architecture** | \`$BUILD_ARCH\` |
| **Output Format Target** | \`$BUILD_TARGET\` |
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

echo "=== Final workspace layout ==="
ls -lh "${WORKSPACE_DIR}"

echo "INFO: Fetching newly created tag."
git -C "${REPO_ROOT}" fetch origin --tags --force

RELEASE_TAG="$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null || true)"
RELEASE_TITLE="${FLAVOR_NAME} ${CHOSEN_VERSION:-unknown} (${ARCH_NAME}/${BUILD_TARGET^^:-unknown}/${BUILD_TYPE^^:-unknown})"

if [[ -z "${RELEASE_TAG:-}" ]]; then
  echo "CRITICAL ERROR: Failed to resolve a valid release tag from the Git repository!" >&2
  echo "Aborting to prevent a corrupted or unsigned lightweight fallback release." >&2
  exit 1
fi

echo "Target release tag resolved: ${RELEASE_TAG}"
echo "Target release title resolved: ${RELEASE_TITLE}"

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
  gh release edit "${RELEASE_TAG}" --title "${RELEASE_TITLE}" --notes-file "${WORKSPACE_DIR}/cumulative_notes.tmp" --prerelease=false

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

