#!/bin/bash

set -e

LOG_DIR="${HOME}/docker/logs"
GIT_LOG="${LOG_DIR}/git.log"
BUILD_LOG="${LOG_DIR}/build.log"

cd ~/

{
  if [ -z "${TAG:-}" ]; then
    TAG="master";
  fi
  git pull
  if [ "${TAG}" != 'master' ]; then
    git describe
    git verify-tag "${TAG}"
  fi
  git verify-commit "${TAG}^{commit}"
  git checkout --recurse-submodules "${TAG}"
  git status
} 2>&1 | tee -a -- "${GIT_LOG}"

/home/user/derivative-maker "$@" | tee -a ${BUILD_LOG}
