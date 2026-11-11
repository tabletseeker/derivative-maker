#!/usr/bin/env bash

set -x
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="${SCRIPT_DIR}/matrix-assets"

if [[ ! -d "${ASSET_DIR}" ]]; then
  echo "ERROR: Matrix asset directory not found: ${ASSET_DIR}" >&2
  exit 1
fi

read -r -a ASSET_IDS <<< "${MATRIX_ASSETS:-}"

if ((${#ASSET_IDS[@]} == 0)); then
  echo "ERROR: Select at least one matrix asset or use 'all'." >&2
  exit 1
fi

FILES=()
declare -A SEEN_IDS=()

add_asset() {
  local file="$1"
  local expected_id="${2:-}"
  local id

  if ! jq -e '
    type == "object" and
    (.id | type == "string" and length > 0) and
    ([.release_flavor, .flavors_list, .arch, .target, .type, .container_engine]
      | all(.[]; type == "string" and length > 0)) and
    ([.flavor_meta_packages_to_install, .install_package_list, .derivative_apt_repository_opts]
      | all(.[]; type == "string"))
  ' "${file}" >/dev/null; then
    echo "ERROR: Invalid or incomplete matrix asset: ${file}" >&2
    exit 1
  fi

  id="$(jq -r '.id' "${file}")"

  if [[ ! "${id}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "ERROR: Invalid asset ID '${id}' in ${file}." >&2
    exit 1
  fi

  if [[ -n "${expected_id}" && "${id}" != "${expected_id}" ]]; then
    echo "ERROR: Asset ID in ${file} is '${id}', expected '${expected_id}'." >&2
    exit 1
  fi

  if [[ "$(basename -- "${file}")" != "${id}.json" ]]; then
    echo "ERROR: Asset filename must be '${id}.json': ${file}" >&2
    exit 1
  fi

  if [[ -n "${SEEN_IDS[${id}]:-}" ]]; then
    echo "ERROR: Duplicate asset ID '${id}'." >&2
    exit 1
  fi

  SEEN_IDS["${id}"]=1
  FILES+=("${file}")
}

if ((${#ASSET_IDS[@]} == 1)) && [[ "${ASSET_IDS[0]}" == "all" ]]; then
  mapfile -d '' -t ALL_FILES < <(
    find "${ASSET_DIR}" -type f -name '*.json' -print0 | sort -z
  )

  if ((${#ALL_FILES[@]} == 0)); then
    echo "ERROR: No matrix JSON assets found under ${ASSET_DIR}." >&2
    exit 1
  fi

  for file in "${ALL_FILES[@]}"; do
    add_asset "${file}"
  done
else
  for id in "${ASSET_IDS[@]}"; do
    if [[ "${id}" == "all" || ! "${id}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "ERROR: Use 'all' by itself, or provide valid asset IDs." >&2
      exit 1
    fi

    matches=()
    while IFS= read -r -d '' match; do
      matches+=("${match}")
    done < <(find "${ASSET_DIR}" -type f -name "${id}.json" -print0)

    if ((${#matches[@]} == 0)); then
      echo "ERROR: No matrix asset found for '${id}' under ${ASSET_DIR}." >&2
      exit 1
    fi

    if ((${#matches[@]} > 1)); then
      printf "ERROR: Multiple matrix assets found for '%s':\n" "${id}" >&2
      printf '  %s\n' "${matches[@]}" >&2
      exit 1
    fi

    add_asset "${matches[0]}" "${id}"
  done
fi

matrix="$(jq -c -s '.' "${FILES[@]}")"

printf 'Selected %d asset(s): %s\n' "${#FILES[@]}" "${ASSET_IDS[*]}"
printf 'matrix=%s\n' "${matrix}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
