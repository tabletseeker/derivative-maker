#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

readonly CLOUD_IMAGES_REPO="https://salsa.debian.org/cloud-team/debian-cloud-images.git"
readonly CLOUD_IMAGES_BRANCH="master"
readonly SHA_REGEX='^[[:xdigit:]]{40}$'
readonly SIZE_REGEX='^[1-9][0-9]*[GMT]$'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n=== %s ===\n' "$*"
}

usage() {
  cat <<USAGE
Usage:
  ${0##*/} --resolve
  ${0##*/} --validate
  ${0##*/} [OUTPUT_QCOW2 [DISK_SIZE]]

Options:
  --resolve     Print the current ${CLOUD_IMAGES_BRANCH} commit SHA.
  --validate    Ensure CLOUD_IMAGES_REF is valid or resolvable.
  -h, --help    Show this help message.
USAGE
}

is_valid_sha() {
  [[ "${1:-}" =~ ${SHA_REGEX} ]]
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Required command '${cmd}' was not found."
  done
}

resolve_cloud_images_ref() {
  require_commands git

  local ref
  ref="$(
    git ls-remote \
      --exit-code \
      --refs \
      "${CLOUD_IMAGES_REPO}" \
      "refs/heads/${CLOUD_IMAGES_BRANCH}" |
      awk 'NR == 1 { print $1 }'
  )"

  is_valid_sha "${ref}" || die "Could not resolve a full commit SHA for ${CLOUD_IMAGES_BRANCH}."
  printf '%s\n' "${ref}"
}

get_cloud_images_ref() {
  if [[ -n "${CLOUD_IMAGES_REF:-}" ]]; then
    is_valid_sha "${CLOUD_IMAGES_REF}" || die "CLOUD_IMAGES_REF must be a full 40-character commit SHA."
    printf '%s\n' "${CLOUD_IMAGES_REF}"
  else
    resolve_cloud_images_ref
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --resolve)
    resolve_cloud_images_ref
    exit 0
    ;;
  --validate)
    CLOUD_IMAGES_REF="$(get_cloud_images_ref)"
    printf 'Using Debian Cloud Team Revision: %s\n' "${CLOUD_IMAGES_REF}"
    exit 0
    ;;
  -*)
    die "Unknown option: $1 (see --help)"
    ;;
esac

(( $# <= 2 )) || { usage >&2; exit 2; }

OUT_QCOW2="${1:-debian-base.qcow2}"
DISK_SIZE="${2:-75G}"
CLOUD_IMAGES_REF="$(get_cloud_images_ref)"

[[ "${DISK_SIZE}" =~ ${SIZE_REGEX} ]] || die "DISK_SIZE must be a positive size ending in G, M, or T."
require_commands git make qemu-img sha512sum sudo

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
  die "This script builds the generic amd64 image and requires an amd64 runner."
fi

[[ "${OUT_QCOW2}" == /* ]] || OUT_QCOW2="${PWD}/${OUT_QCOW2}"
mkdir -p -- "$(dirname -- "${OUT_QCOW2}")"

WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/debian-cloud-image.XXXXXX")"
SOURCE_DIR="${WORK_DIR}/source"
BUILD_OUTPUT_DIR="${WORK_DIR}/output"
TEMP_QCOW2="${OUT_QCOW2}.tmp.$$"
BUILDINFO_TMP="${OUT_QCOW2}.buildinfo.tmp.$$"

cleanup() {
  local status=$?
  trap - EXIT
  sudo rm -rf -- "${WORK_DIR}" || true
  sudo rm -f -- "${TEMP_QCOW2}" "${BUILDINFO_TMP}" || true
  exit "${status}"
}
trap cleanup EXIT

mkdir -p -- "${SOURCE_DIR}" "${BUILD_OUTPUT_DIR}"

log "Fetch pinned Debian Cloud Team sources"
git -C "${SOURCE_DIR}" init --quiet
git -C "${SOURCE_DIR}" remote add origin "${CLOUD_IMAGES_REPO}"
git -C "${SOURCE_DIR}" fetch --quiet --depth=1 origin "${CLOUD_IMAGES_REF}"
git -C "${SOURCE_DIR}" checkout --quiet --detach FETCH_HEAD

actual_ref="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
expected_ref="${CLOUD_IMAGES_REF,,}"

[[ "${actual_ref}" == "${expected_ref}" ]] || die "Fetched commit '${actual_ref}' does not match requested '${expected_ref}'."

printf 'Using Debian Cloud Team commit: %s\n' "${actual_ref}"

if [[ ! -x "${SOURCE_DIR}/bin/debian-cloud-images" || ! -f "${SOURCE_DIR}/Makefile" ]]; then
  die "Pinned checkout is missing the expected image builder or Makefile."
fi

log "Build Trixie generic amd64 raw image"
# This repository documents the target name as:
#   make image_<DIST>_<CLOUD>_<ARCH>
# e.g. image_trixie_generic_amd64
sudo make \
  --directory="${SOURCE_DIR}" \
  image_trixie_generic_amd64 \
  "DESTDIR=${BUILD_OUTPUT_DIR}"

# The upstream output is not guaranteed to be a single file with a fixed name.
# We therefore detect all files under DESTDIR after the build and keep only the
# actual raw image(s) we plan to convert.
mapfile -d '' -t RAW_IMAGES < <(
  find "${BUILD_OUTPUT_DIR}" \
    -type f \
    -name '*.raw' \
    -print0
)

if (( ${#RAW_IMAGES[@]} == 0 )); then
  printf 'ERROR: No raw image files were produced in %s.\n' "${BUILD_OUTPUT_DIR}" >&2
  echo "Files present under the build output directory:" >&2
  find "${BUILD_OUTPUT_DIR}" -maxdepth 3 -print >&2 || true
  exit 1
fi

# Prefer the generic Trixie image if multiple raw images exist.
RAW_IMAGE=""
for candidate in "${RAW_IMAGES[@]}"; do
  case "${candidate}" in
    *trixie*generic*amd64*.raw|*generic*amd64*trixie*.raw)
      RAW_IMAGE="${candidate}"
      break
      ;;
  esac
done

if [[ -z "${RAW_IMAGE}" ]]; then
  RAW_IMAGE="${RAW_IMAGES[0]}"
fi

log "Convert upstream raw image to QCOW2"
sudo qemu-img convert \
  -p \
  -f raw \
  -O qcow2 \
  "${RAW_IMAGE}" \
  "${TEMP_QCOW2}"

sudo qemu-img resize -f qcow2 "${TEMP_QCOW2}" "${DISK_SIZE}"
sudo qemu-img check -f qcow2 "${TEMP_QCOW2}"

[[ -s "${TEMP_QCOW2}" ]] || die "QCOW2 output is missing or empty."

sudo chown "$(id -u):$(id -g)" "${TEMP_QCOW2}"
mv -f -- "${TEMP_QCOW2}" "${OUT_QCOW2}"

image_sha512="$(sha512sum -- "${OUT_QCOW2}" | awk '{print $1}')"

cat <<EOF > "${BUILDINFO_TMP}"
CLOUD_IMAGES_REF=${actual_ref}
DISK_SIZE=${DISK_SIZE}
SHA512=${image_sha512}
EOF

mv -f -- "${BUILDINFO_TMP}" "${OUT_QCOW2}.buildinfo"

log "Base image ready"
qemu-img info "${OUT_QCOW2}"
cat -- "${OUT_QCOW2}.buildinfo"
