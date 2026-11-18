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

readonly REMOTE_CACHE_DIR="/home/debian/approx_cache_mnt"
readonly REMOTE_BINARY_DIR="/home/debian/binary_mnt"
readonly APPROX_OWNER="101:102"
readonly APPROX_MODE="770"

readonly ARTIFACT_PATTERNS=(
  '*Kicksecure*.xz'
  '*Whonix*.xz'
  'derivative-maker-source-*.xz'
  '*.iso'
  '*.ova'
  '*.asc'
  '*.sig'
  '*.sha512sums'
  '*.dm-buildinfo'
  '*.torrent'
  '*.log'
)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '=== %s ===\n' "$*" >&2; }

usage() {
  cat <<USAGE
Usage:
  ${0##*/} restore-cache  [ARCHIVE_PATH]
  ${0##*/} save-cache     [ARCHIVE_PATH]
  ${0##*/} pull-artifacts [STAGING_DIR]
  ${0##*/} shutdown-vm    [PID_FILE]
  ${0##*/} exec           <COMMAND> [ARGS...]
USAGE
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Required command '${cmd}' was not found."
  done
}

resolve_path() {
  if [[ "$1" == /* ]]; then
    printf '%s\n' "$1"
  else
    printf '%s/%s\n' "${PWD}" "$1"
  fi
}

# --- Guest-side functions (passed through SSH via declare -f) ---

_guest_restore_cache() {
  set -euo pipefail
  local cache_dir="$1" owner="$2" mode="$3"

  sudo rm -rf -- "${cache_dir}"
  sudo mkdir -p -- "${cache_dir}"
  sudo chown "${owner}" "${cache_dir}"
  sudo chmod "${mode}" "${cache_dir}"
  sudo tar --numeric-owner --no-overwrite-dir -xf - -C "${cache_dir}"
}

_guest_save_cache() {
  set -euo pipefail
  local cache_dir="$1"

  sudo test -d "${cache_dir}" || exit 10
  sudo find "${cache_dir}" -mindepth 1 -print -quit | grep -q . || exit 10
  sudo tar --numeric-owner -cf - -C "${cache_dir}" .
}

_guest_pull_artifacts() {
  set -euo pipefail
  local binary_dir="$1"
  shift

  if [[ ! -d "${binary_dir}" ]]; then
    printf 'ERROR: Remote binary directory not found: %s\n' "${binary_dir}" >&2
    exit 1
  fi

  cd -- "${binary_dir}"
  local file_list
  file_list="$(mktemp)"
  trap 'rm -f -- "${file_list}"' RETURN

  find . -type f \( "$@" \) -print0 > "${file_list}"
  tar --create --file=- --null --files-from="${file_list}"
}

_guest_poweroff() {
  set -euo pipefail
  sudo poweroff
}

_guest_exec() {
  set -euo pipefail
  "$@"
}

# --- Host-side SSH transport & orchestration ---

run_on_guest() {
  local fn="$1"
  shift

  local remote_cmd
  printf -v remote_cmd '%s; %s' "$(declare -f "${fn}")" "${fn}"
  if (( $# > 0 )); then
    printf -v remote_cmd '%s %s' "${remote_cmd}" "$(printf '%q ' "$@")"
  fi

  ssh \
    -i "${SSH_KEY}" \
    -p "${SSH_PORT}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=10 \
    "${SSH_USER}@${SSH_HOST}" \
    "bash -c ${remote_cmd@Q}"
}

restore_cache() {
  local archive="$1"

  if [[ ! -f "${archive}" || -L "${archive}" || ! -s "${archive}" ]]; then
    log "No approx cache archive present to restore"
    return 0
  fi

  if ! zstd --test --quiet -- "${archive}"; then
    printf 'WARNING: Cached approx archive failed zstd integrity check; discarding.\n' >&2
    rm -f -- "${archive}"
    return 0
  fi

  log "Restoring verified approx package cache into guest VM"
  zstd -d --stdout -- "${archive}" | \
    run_on_guest _guest_restore_cache "${REMOTE_CACHE_DIR}" "${APPROX_OWNER}" "${APPROX_MODE}"
}

save_cache() {
  local archive="$1"
  local tmp_archive="${archive}.tmp.$$"
  local rc=0

  mkdir -p -- "$(dirname -- "${archive}")"
  trap 'rm -f -- "${tmp_archive}"' EXIT

  log "Streaming approx package cache out of guest VM"
  run_on_guest _guest_save_cache "${REMOTE_CACHE_DIR}" | \
    zstd -T0 -3 -f -o "${tmp_archive}" || rc=$?

  if (( rc == 0 )) && [[ -s "${tmp_archive}" ]]; then
    mv -f -- "${tmp_archive}" "${archive}"
    ls -lh -- "${archive}"
  elif (( rc == 10 )); then
    rm -f -- "${tmp_archive}"
    log "Guest approx cache is empty; skipping archive creation"
  else
    rm -f -- "${tmp_archive}"
    printf 'WARNING: Failed to export approx cache (exit %d); continuing.\n' "${rc}" >&2
  fi

  trap - EXIT
}

pull_artifacts() {
  local staging_dir="$1"
  local -a find_expr=()
  local pattern

  for pattern in "${ARTIFACT_PATTERNS[@]}"; do
    if (( ${#find_expr[@]} > 0 )); then
      find_expr+=( -o )
    fi
    find_expr+=( -name "${pattern}" )
  done

  mkdir -p -- "${staging_dir}"

  log "Streaming build artifacts out of guest VM"
  run_on_guest _guest_pull_artifacts "${REMOTE_BINARY_DIR}" "${find_expr[@]}" | \
    tar --extract --file=- --directory="${staging_dir}" --transform='s|.*/||'
}

shutdown_vm() {
  local pid_file="$1"

  if ! sudo test -f "${pid_file}"; then
    log "No VM PID file found at ${pid_file}; skipping shutdown"
    return 0
  fi

  local pid
  pid="$(sudo cat "${pid_file}")"

  if [[ "${pid}" =~ ^[0-9]+$ ]] && sudo kill -0 "${pid}" 2>/dev/null; then
    log "Shutting down guest VM cleanly (PID: ${pid})"
    run_on_guest _guest_poweroff 2>/dev/null || true

    if ! sudo timeout 30s pidwait "${pid}" 2>/dev/null; then
      log "Guest shutdown timed out; stopping QEMU (PID: ${pid})"
      sudo kill -TERM "${pid}" 2>/dev/null || true
      sudo timeout 5s pidwait "${pid}" 2>/dev/null || sudo kill -KILL "${pid}" 2>/dev/null || true
    fi
  fi

  sudo rm -f -- "${pid_file}"
  sync
}

main() {
  local action="${1:-}"
  local workspace_dir="${GITHUB_WORKSPACE:-${PWD}}"

  SSH_KEY="${SSH_KEY:-${workspace_dir}/id_ed25519}"
  SSH_PORT="${SSH_PORT:-2222}"
  SSH_HOST="${SSH_HOST:-127.0.0.1}"
  SSH_USER="${SSH_USER:-debian}"

  case "${action}" in
    -h|--help)
      usage
      exit 0
      ;;
    restore-cache|save-cache)
      require_commands ssh tar zstd
      local archive
      archive="$(resolve_path "${2:-${workspace_dir}/approx-cache.tar.zst}")"
      if [[ "${action}" == "restore-cache" ]]; then
        restore_cache "${archive}"
      else
        save_cache "${archive}"
      fi
      ;;
    pull-artifacts)
      require_commands ssh tar
      pull_artifacts "$(resolve_path "${2:-${workspace_dir}/release-staging}")"
      ;;
    shutdown-vm)
      require_commands ssh timeout pidwait
      shutdown_vm "$(resolve_path "${2:-${PID_FILE:-${workspace_dir}/qemu.pid}}")"
      ;;
    exec)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      require_commands ssh
      shift
      run_on_guest _guest_exec "$@"
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"

