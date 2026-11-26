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

: "${EVENT_NAME:?EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# Defaults (used when inputs are empty)
build_mode="${INPUT_BUILD_MODE:-release}"
matrix_assets="${INPUT_MATRIX_ASSETS:-all}"
version_prefix="${INPUT_VERSION_PREFIX:-${DEFAULT_VERSION_PREFIX:-}}"
version_override="${INPUT_VERSION_OVERRIDE:-}"
release_name="${INPUT_RELEASE_NAME:-Production Release:}"
freshness="${INPUT_FRESHNESS:-frozen}"
dist_build_redistributable="${INPUT_DIST_BUILD_REDISTRIBUTABLE:-true}"
allow_untagged="${INPUT_ALLOW_UNTAGGED:-false}"
allow_uncommitted="${INPUT_ALLOW_UNCOMMITTED:-false}"
remote_derivative_packages="${INPUT_REMOTE_DERIVATIVE_PACKAGES:-false}"
debfullname="${INPUT_DEBFULLNAME:-tabletseeker-ci}"
debemail="${INPUT_DEBEMAIL:-tabletseeker-ci@github.com}"
cleanup="${INPUT_CLEANUP:-false}"

# Event-specific overrides
case "${EVENT_NAME}:${EVENT_SCHEDULE:-}" in
  "push:")
    build_mode="cache"
    matrix_assets="frozen-cache-amd64"
    dist_build_redistributable="false"
    freshness="frozen"
    allow_untagged="true"
    allow_uncommitted="true"
    remote_derivative_packages="true"
    ;;
  "schedule:0 6 * * *")
    build_mode="nightly"
    matrix_assets="cli-vm-amd64 kicksecure-lxqt-amd64-vm whonix-lxqt-amd64-vm"
    release_name="Nightly Build:"
    dist_build_redistributable="false"
    freshness="current"
    ;;
  "schedule:5 0 * * 1")
    build_mode="cache"
    matrix_assets="current-cache-amd64"
    dist_build_redistributable="false"
    freshness="current"
    allow_untagged="true"
    allow_uncommitted="true"
    remote_derivative_packages="true"
    ;;
  "schedule:"*)
    echo "Unsupported schedule: ${EVENT_SCHEDULE:-<empty>}" >&2
    exit 1
    ;;
esac

cat <<EOF >> "${GITHUB_OUTPUT}"
build_mode=${build_mode}
matrix_assets=${matrix_assets}
version_prefix=${version_prefix}
version_override=${version_override}
release_name=${release_name}
freshness=${freshness}
dist_build_redistributable=${dist_build_redistributable}
allow_untagged=${allow_untagged}
allow_uncommitted=${allow_uncommitted}
remote_derivative_packages=${remote_derivative_packages}
debfullname=${debfullname}
debemail=${debemail}
cleanup=${cleanup}
EOF

