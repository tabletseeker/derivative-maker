#!/usr/bin/env bash

## Copyright (C) 2026-2027 tabletseeker <tabletseeker-git@protonmail.com>
## See the LICENSE for conditions of reproduction or redistribution.
## All rights reserved by the repository maintainer

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

readonly SHA_REGEX='^[[:xdigit:]]{40}$'
readonly SHA512_REGEX='^[[:xdigit:]]{128}$'
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
  ${0##*/} --ref <40-char-sha> [--size <size>] [IMAGE_PATH [BUILDINFO_PATH]]

Options:
  --ref <sha>     Expected 40-character Debian Cloud Team commit SHA.
  --size <size>   Expected virtual disk size (default: 75G).
  -h, --help      Show this help message.
USAGE
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Required command '${cmd}' was not found."
  done
}

EXPECTED_REF=""
EXPECTED_DISK_SIZE="75G"

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --ref)
      (( $# >= 2 )) || die "--ref requires a value."
      EXPECTED_REF="${2,,}"
      shift 2
      ;;
    --size)
      (( $# >= 2 )) || die "--size requires a value."
      EXPECTED_DISK_SIZE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1 (see --help)"
      ;;
    *)
      break
      ;;
  esac
done

(( $# <= 2 )) || { usage >&2; exit 2; }

[[ "${EXPECTED_REF}" =~ ${SHA_REGEX} ]] ||
  die "--ref must be provided as a valid 40-character commit SHA."

[[ "${EXPECTED_DISK_SIZE}" =~ ${SIZE_REGEX} ]] ||
  die "--size must be a positive size ending in G, M, or T."

IMAGE_PATH="${1:-debian-base.qcow2}"
BUILDINFO_PATH="${2:-${IMAGE_PATH}.buildinfo}"

[[ "${IMAGE_PATH}" == /* ]] || IMAGE_PATH="${PWD}/${IMAGE_PATH}"
[[ "${BUILDINFO_PATH}" == /* ]] || BUILDINFO_PATH="${PWD}/${BUILDINFO_PATH}"

require_commands awk jq numfmt qemu-img sha512sum

EXPECTED_VIRTUAL_BYTES="$(numfmt --from=iec "${EXPECTED_DISK_SIZE}")" ||
  die "Invalid --size '${EXPECTED_DISK_SIZE}'."

log "Validate artifact presence and permissions"
[[ -f "${IMAGE_PATH}" && ! -L "${IMAGE_PATH}" && -s "${IMAGE_PATH}" ]] ||
  die "Base image is missing, empty, or a symlink: ${IMAGE_PATH}"

[[ -f "${BUILDINFO_PATH}" && ! -L "${BUILDINFO_PATH}" && -s "${BUILDINFO_PATH}" ]] ||
  die "Buildinfo file is missing, empty, or a symlink: ${BUILDINFO_PATH}"

log "Parse and validate provenance metadata"
[[ "$(wc -l < "${BUILDINFO_PATH}")" -eq 3 ]] ||
  die "Buildinfo file must contain exactly 3 lines."

recorded_ref=""
recorded_size=""
recorded_sha512=""

while IFS='=' read -r key val; do
  case "${key}" in
    CLOUD_IMAGES_REF)
      [[ -z "${recorded_ref}" ]] || die "Duplicate CLOUD_IMAGES_REF key."
      recorded_ref="${val,,}"
      ;;
    DISK_SIZE)
      [[ -z "${recorded_size}" ]] || die "Duplicate DISK_SIZE key."
      recorded_size="${val}"
      ;;
    SHA512)
      [[ -z "${recorded_sha512}" ]] || die "Duplicate SHA512 key."
      recorded_sha512="${val,,}"
      ;;
    *)
      die "Unexpected key in buildinfo file: '${key}'"
      ;;
  esac
done < "${BUILDINFO_PATH}"

[[ "${recorded_ref}" =~ ${SHA_REGEX} ]] ||
  die "Invalid CLOUD_IMAGES_REF format in buildinfo."

[[ "${recorded_sha512}" =~ ${SHA512_REGEX} ]] ||
  die "Invalid SHA512 format in buildinfo."

[[ "${recorded_ref}" == "${EXPECTED_REF}" ]] ||
  die "Provenance mismatch: image built from '${recorded_ref}', expected '${EXPECTED_REF}'."

[[ "${recorded_size}" == "${EXPECTED_DISK_SIZE}" ]] ||
  die "Size mismatch in buildinfo: recorded '${recorded_size}', expected '${EXPECTED_DISK_SIZE}'."

log "Verify cryptographic SHA-512 digest"
actual_sha512="$(sha512sum -- "${IMAGE_PATH}" | awk '{print $1}')"
[[ "${actual_sha512,,}" == "${recorded_sha512}" ]] ||
  die "SHA-512 digest mismatch for ${IMAGE_PATH}."

log "Verify QCOW2 integrity and invariants"
qemu-img check -f qcow2 -- "${IMAGE_PATH}"

image_json="$(qemu-img info --output=json -- "${IMAGE_PATH}")"
image_format="$(jq -r '.format // empty' <<< "${image_json}")"
virtual_size="$(jq -r '.["virtual-size"] // empty' <<< "${image_json}")"
backing_file="$(jq -r '.["backing-filename"] // empty' <<< "${image_json}")"

[[ "${image_format}" == "qcow2" ]] ||
  die "Unexpected image format '${image_format}' (expected 'qcow2')."

[[ -z "${backing_file}" ]] ||
  die "Base image must be self-contained; unexpected backing file '${backing_file}'."

[[ "${virtual_size}" == "${EXPECTED_VIRTUAL_BYTES}" ]] ||
  die "Unexpected virtual size '${virtual_size}' bytes (expected ${EXPECTED_DISK_SIZE})."

printf 'Verified QCOW2 ref=%s size=%s sha512=%s...\n' \
  "${recorded_ref}" "${EXPECTED_DISK_SIZE}" "${recorded_sha512:0:16}"

