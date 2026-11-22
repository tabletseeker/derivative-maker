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

VM_WORKDIR="/home/debian/build-workspace"

echo "== Guest Subsystem: Initializing key space =="
mkdir -p "${KEY_DIR}"

printf '%s' "${CI_PRIVATE_KEY}" > "${KEY_FILE}"
chmod 400 "${KEY_FILE}"

echo "== Cloning repository into guest workspace =="
mkdir -p "${VM_WORKDIR}"

git clone \
  --single-branch \
  --branch "${GIT_BRANCH}" \
  --recurse-submodules \
  "${GIT_URL}" \
  "${VM_WORKDIR}"

git -C "${VM_WORKDIR}" fetch --tags --force origin "${GITHUB_SHA}"
git -C "${VM_WORKDIR}" checkout --detach "${GITHUB_SHA}"
git -C "${VM_WORKDIR}" submodule update --init --recursive

echo "== Launching release pipeline =="
cd "${VM_WORKDIR}"

./oci/derivative-maker-oci-run -- bash -c "
./help-steps/ci-signing-setup && \
./help-steps/dm-build-official \
  --arch '${BUILD_ARCH}' \
  --type '${BUILD_TYPE}' \
  --freshness '${BUILD_FRESHNESS}' \
  --allow-untagged '${ALLOW_UNTAGGED}' \
  --allow-uncommitted '${ALLOW_UNCOMMITTED}' \
  --remote-derivative-packages '${ALLOW_REMOTE}'
"

