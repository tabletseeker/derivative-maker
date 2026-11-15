#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

: "${BUILD_MODE:?BUILD_MODE is required}"
: "${BUILD_VERSION:?BUILD_VERSION is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${CI_PRIVATE_KEY:?CI_PRIVATE_KEY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

if [[ "${BUILD_MODE}" != "nightly" && "${BUILD_MODE}" != "release" ]]; then
  echo "ERROR: Unsupported BUILD_MODE: ${BUILD_MODE}" >&2
  exit 1
fi

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACT_ROOT="${WORKSPACE}/release-artifacts"
MERGED_DIR="${WORKSPACE}/release-merged"
RUN_ID="${GITHUB_RUN_ID:-local}"
NOTES_FILE="${RUNNER_TEMP:-/tmp}/release-notes-${RUN_ID}.md"
GNUPGHOME="$(mktemp -d)"
BACKUP_REF="refs/rollback/nightly-${RUN_ID}"

TAG_WAS_UPDATED=false
TAG_EXISTED=false
RELEASE_CREATED=false
TAG_CREATED=false
PUBLISH_SUCCEEDED=false

export GNUPGHOME
chmod 700 "${GNUPGHOME}"

should_skip_matrix_file() {
  local filename="${1##*/}"

  case "${filename}" in
    mullvad-keyring.asc|\
    oracle_vbox_2016.asc|\
    tbb-team.asc|\
    torprojectarchive.asc)
      return 0
      ;;
  esac

  [[ "${filename}" =~ ^[[:xdigit:]]{40}\.asc$ ]]
}

rollback_publication() {
  echo "ERROR: Publication failed; attempting cleanup." >&2

  if [[ "${RELEASE_CREATED}" == "true" ]]; then
    gh release delete "${RELEASE_TAG}" --yes || true
  fi

  if [[ "${BUILD_MODE}" == "release" && "${TAG_CREATED}" == "true" ]]; then
    git push origin --delete "refs/tags/${RELEASE_TAG}" || true
  elif [[ "${BUILD_MODE}" == "nightly" && "${TAG_WAS_UPDATED}" == "true" ]]; then
    if [[ "${TAG_EXISTED}" == "true" ]]; then
      git push --force origin "${BACKUP_REF}:refs/tags/${RELEASE_TAG}" || true
    else
      git push origin --delete "refs/tags/${RELEASE_TAG}" || true
    fi
  fi
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT

  if ((status != 0)) && [[ "${PUBLISH_SUCCEEDED}" != "true" ]]; then
    rollback_publication || true
  fi

  rm -rf -- "${GNUPGHOME}" || true
  return "${status}"
}
trap cleanup_on_exit EXIT

merge_matrix_artifacts() {
  if [[ ! -d "${ARTIFACT_ROOT}" ]]; then
    echo "ERROR: Downloaded matrix artifacts not found: ${ARTIFACT_ROOT}" >&2
    exit 1
  fi

  rm -rf -- "${MERGED_DIR}"
  mkdir -p -- "${MERGED_DIR}"

  echo "=== Merge matrix artifacts ==="
  mapfile -d '' -t INPUT_FILES < <(
    find "${ARTIFACT_ROOT}" -type f -print0 | sort -z
  )

  if ((${#INPUT_FILES[@]} == 0)); then
    echo "ERROR: No files were downloaded from matrix artifacts." >&2
    exit 1
  fi

  for source in "${INPUT_FILES[@]}"; do
    filename="$(basename -- "${source}")"

    if should_skip_matrix_file "${filename}"; then
      echo "Skipping build-support file: ${filename}"
      continue
    fi

    destination="${MERGED_DIR}/${filename}"

    if [[ -e "${destination}" ]]; then
      if ! cmp -s -- "${source}" "${destination}"; then
        echo "ERROR: Matrix artifacts contain conflicting files named '${filename}'." >&2
        exit 1
      fi
      echo "Deduplicated identical shared asset: ${filename}"
      continue
    fi

    cp -- "${source}" "${destination}"
  done
}

compose_release_notes() {
  mapfile -d '' -t NOTE_FILES < <(
    find "${MERGED_DIR}" -maxdepth 1 -type f \
      -name '*-release-notes.md' -print0 | sort -z
  )

  if ((${#NOTE_FILES[@]} == 0)); then
    echo "ERROR: No per-build release notes were found." >&2
    exit 1
  fi

  for note_file in "${NOTE_FILES[@]}"; do
    printf '\n---\n\n' >> "${NOTES_FILE}"
    cat -- "${note_file}" >> "${NOTES_FILE}"
  done
}

collect_staged_assets() {
  mapfile -d '' -t STAGED_ASSETS < <(
    find "${MERGED_DIR}" -maxdepth 1 -type f \
      ! -name '*-release-notes.md' \
      -print0 | sort -z
  )

  if ((${#STAGED_ASSETS[@]} == 0)); then
    echo "ERROR: No merged assets to publish." >&2
    exit 1
  fi
}

import_signing_key() {
  echo "=== Import signing key and configure Git ==="
  printf '%s' "${CI_PRIVATE_KEY}" | gpg --batch --import

  local fingerprint
  fingerprint="$(
    gpg --batch --with-colons --list-secret-keys |
      awk -F: '$1 == "fpr" { print $10; exit }'
  )"

  if [[ -z "${fingerprint}" ]]; then
    echo "ERROR: No GPG secret key found in CI_PRIVATE_KEY." >&2
    exit 1
  fi

  git config user.name "${DEBFULLNAME:-tabletseeker-ci}"
  git config user.email "${DEBEMAIL:-tabletseeker-ci@github.com}"
  git config user.signingkey "${fingerprint}"
}

tag_release() {
  if [[ "${BUILD_MODE}" == "nightly" ]]; then
    echo "=== Prepare rolling nightly tag ==="

    if git ls-remote --exit-code --tags origin \
      "refs/tags/${RELEASE_TAG}" >/dev/null 2>&1; then
      TAG_EXISTED=true
      git fetch --force origin \
        "refs/tags/${RELEASE_TAG}:${BACKUP_REF}"
    fi

    git tag -s -f "${RELEASE_TAG}" "${GITHUB_SHA}" \
      -m "Nightly build ${BUILD_VERSION}"
    git verify-tag "${RELEASE_TAG}"
    git push --force origin "refs/tags/${RELEASE_TAG}"
    TAG_WAS_UPDATED=true
  else
    echo "=== Create versioned signed release tag ==="

    if git ls-remote --exit-code --tags origin \
      "refs/tags/${RELEASE_TAG}" >/dev/null 2>&1; then
      echo "ERROR: Release tag already exists: ${RELEASE_TAG}" >&2
      exit 1
    fi

    git tag -s "${RELEASE_TAG}" "${GITHUB_SHA}" \
      -m "Release ${RELEASE_TAG}"
    git verify-tag "${RELEASE_TAG}"
    git push origin "refs/tags/${RELEASE_TAG}"
    TAG_CREATED=true
  fi
}

ensure_release_exists() {
  echo "=== Create or update GitHub Release ==="

  if gh release view "${RELEASE_TAG}" >/dev/null 2>&1; then
    if [[ "${BUILD_MODE}" == "release" ]]; then
      echo "ERROR: A release already exists for ${RELEASE_TAG}." >&2
      exit 1
    fi
    return
  fi

  if [[ "${BUILD_MODE}" == "nightly" ]]; then
    gh release create "${RELEASE_TAG}" \
      --verify-tag \
      --title "${RELEASE_TITLE:-Nightly Build:}" \
      --notes-file "${NOTES_FILE}" \
      --prerelease
  else
    gh release create "${RELEASE_TAG}" \
      --verify-tag \
      --title "${RELEASE_TITLE:-Production Release:} ${BUILD_VERSION}" \
      --notes-file "${NOTES_FILE}"
  fi

  RELEASE_CREATED=true
}

build_staged_asset_set() {
  declare -gA STAGED_ASSET_NAMES=()

  for asset in "${STAGED_ASSETS[@]}"; do
    STAGED_ASSET_NAMES["$(basename -- "${asset}")"]=1
  done
}

delete_replaced_nightly_assets() {
  local old_asset

  while IFS= read -r old_asset; do
    [[ -z "${old_asset}" ]] && continue

    if [[ -n "${STAGED_ASSET_NAMES["${old_asset}"]+present}" ]]; then
      gh release delete-asset "${RELEASE_TAG}" "${old_asset}" --yes
    fi
  done < <(
    gh release view "${RELEASE_TAG}" \
      --json assets \
      --jq '.assets[].name'
  )
}

delete_stale_nightly_assets() {
  local old_asset

  while IFS= read -r old_asset; do
    [[ -z "${old_asset}" ]] && continue

    if [[ -z "${STAGED_ASSET_NAMES["${old_asset}"]+present}" ]]; then
      gh release delete-asset "${RELEASE_TAG}" "${old_asset}" --yes
    fi
  done < <(
    gh release view "${RELEASE_TAG}" \
      --json assets \
      --jq '.assets[].name'
  )
}

publish_nightly_assets() {
  echo "=== Replace rolling nightly assets ==="

  build_staged_asset_set
  delete_replaced_nightly_assets
  gh release upload "${RELEASE_TAG}" "${STAGED_ASSETS[@]}"
  delete_stale_nightly_assets

  gh release edit "${RELEASE_TAG}" \
    --title "${RELEASE_TITLE:-Nightly Build:} ${BUILD_VERSION}" \
    --notes-file "${NOTES_FILE}" \
    --prerelease
}

publish_versioned_assets() {
  gh release upload "${RELEASE_TAG}" "${STAGED_ASSETS[@]}"
  gh release edit "${RELEASE_TAG}" --notes-file "${NOTES_FILE}"
}

main() {
  merge_matrix_artifacts
  compose_release_notes
  collect_staged_assets
  import_signing_key
  tag_release
  ensure_release_exists

  if [[ "${BUILD_MODE}" == "nightly" ]]; then
    publish_nightly_assets
  else
    publish_versioned_assets
  fi

  if [[ "${BUILD_MODE}" == "nightly" && "${TAG_EXISTED}" == "true" ]]; then
    git update-ref -d "${BACKUP_REF}" || true
  fi

  PUBLISH_SUCCEEDED=true
  echo "=== Publication completed: ${RELEASE_TAG} ==="
}

main "$@"

