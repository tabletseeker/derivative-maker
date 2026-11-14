#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

: "${BUILD_MODE:?BUILD_MODE is required}"
: "${VERSION_PREFIX:?VERSION_PREFIX is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ ! "${VERSION_PREFIX}" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  echo "Invalid VERSION_PREFIX: ${VERSION_PREFIX}" >&2
  exit 1
fi

escaped_prefix="${VERSION_PREFIX//./\\.}"
tag_pattern="^${escaped_prefix}\.([0-9]+)-release$"
highest=0

while IFS= read -r tag; do
  if [[ "${tag}" =~ ${tag_pattern} ]]; then
    number="${BASH_REMATCH[1]}"
    if ((10#${number} > highest)); then
      highest=$((10#${number}))
    fi
  fi
done < <(git tag --list "${VERSION_PREFIX}.*-release")

case "${BUILD_MODE}" in
  release)
    version="${VERSION_PREFIX}.$((highest + 1))"
    tag="${version}-release"
    ;;
  nightly)
    if ((highest == 0)); then
      version="${VERSION_PREFIX}.1"
    else
      version="${VERSION_PREFIX}.${highest}"
    fi
    tag="nightly"
    ;;
  *)
    echo "Unsupported BUILD_MODE: ${BUILD_MODE}" >&2
    exit 1
    ;;
esac

cat <<EOF >> "${GITHUB_OUTPUT}"
mode=${BUILD_MODE}
version=${version}
tag=${tag}
EOF

cat <<EOF
Mode: ${BUILD_MODE}
Build version: ${version}
Tag: ${tag}
EOF

