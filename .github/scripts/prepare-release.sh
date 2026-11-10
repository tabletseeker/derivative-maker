#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

export GNUPGHOME
GNUPGHOME="$(mktemp -d)"
chmod 700 "${GNUPGHOME}"
trap 'rm -rf "${GNUPGHOME}"' EXIT

printf '%s' "${CI_PRIVATE_KEY}" |
  gpg --batch --import

fingerprint="$(
  gpg --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"
if [[ -z "${fingerprint}" ]]; then
  echo "ERROR: No GPG secret key found in CI_PRIVATE_KEY." >&2
  exit 1
fi

git config user.name "${DEBFULLNAME}"
git config user.email "${DEBEMAIL}"
git config user.signingkey "${fingerprint}"

if git ls-remote --exit-code --tags origin "refs/tags/${RELEASE_TAG}" >/dev/null 2>&1; then
  echo "Tag ${RELEASE_TAG} already exists; verifying it."
  git fetch origin "refs/tags/${RELEASE_TAG}:refs/tags/${RELEASE_TAG}"
  git verify-tag "${RELEASE_TAG}"

  tag_commit="$(git rev-list -n 1 "${RELEASE_TAG}")"
  if [[ "${tag_commit}" != "${GITHUB_SHA}" ]]; then
    echo "ERROR: Existing tag ${RELEASE_TAG} points to a different commit." >&2
    exit 1
  fi
else
  git tag -s "${RELEASE_TAG}" "${GITHUB_SHA}" -m "Release ${RELEASE_TAG}"
  git verify-tag "${RELEASE_TAG}"
  git push origin "refs/tags/${RELEASE_TAG}"
fi

if gh release view "${RELEASE_TAG}" >/dev/null 2>&1; then
  echo "Release ${RELEASE_TAG} already exists."
else
  if ! gh release create "${RELEASE_TAG}" \
    --verify-tag \
    --title "${RELEASE_TITLE}" \
    --notes "Build assets and per-build manifests will be attached after the matrix builds complete."; then
    echo "Release creation did not complete; checking whether it now exists."
  fi

  gh release view "${RELEASE_TAG}" >/dev/null
fi

