#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ENV_FILE="${ROOT_DIR}/config/build.env"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

load_build_env() {
  [[ -f "${BUILD_ENV_FILE}" ]] || die "missing ${BUILD_ENV_FILE}"
  # shellcheck disable=SC1090
  source "${BUILD_ENV_FILE}"

  export OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
  export OPENWRT_REF="${OPENWRT_REF:-v25.12.3}"
  export OPENWRT_TARGET="${OPENWRT_TARGET:-ath79}"
  export OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:-nand}"
  export OPENWRT_PROFILE="${OPENWRT_PROFILE:-glinet_gl-e750}"
  export OPENWRT_WORKDIR="${OPENWRT_WORKDIR:-workdir}"
  export OPENWRT_SRC_DIR="${OPENWRT_SRC_DIR:-openwrt}"
  export DL_DIR="${DL_DIR:-.cache/openwrt/dl}"
  export CCACHE_DIR="${CCACHE_DIR:-.cache/openwrt/ccache}"
  export BUILD_CACHE_DIR="${BUILD_CACHE_DIR:-.cache/openwrt/build}"
  export KEEP_BUILD_DIR_CACHE="${KEEP_BUILD_DIR_CACHE:-0}"
  export JOBS="${JOBS:-}"

  if [[ "${OPENWRT_WORKDIR}" = /* ]]; then
    export WORKDIR_ABS="${OPENWRT_WORKDIR}"
  else
    export WORKDIR_ABS="${ROOT_DIR}/${OPENWRT_WORKDIR}"
  fi
  export SRC_DIR_ABS="${WORKDIR_ABS}/${OPENWRT_SRC_DIR}"
  export DL_DIR_ABS="${ROOT_DIR}/${DL_DIR}"
  export CCACHE_DIR_ABS="${ROOT_DIR}/${CCACHE_DIR}"
  export BUILD_CACHE_DIR_ABS="${ROOT_DIR}/${BUILD_CACHE_DIR}"
}

require_commands() {
  local cmd
  for cmd in git make rsync find xargs; do
    command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
  done
}

prepare_directories() {
  mkdir -p "${WORKDIR_ABS}" "${DL_DIR_ABS}" "${CCACHE_DIR_ABS}"
  if [[ "${KEEP_BUILD_DIR_CACHE}" == "1" ]]; then
    mkdir -p "${BUILD_CACHE_DIR_ABS}"
  fi
}

clone_or_update_openwrt() {
  if [[ ! -d "${SRC_DIR_ABS}/.git" ]]; then
    log "Cloning ${OPENWRT_REPO} at ${OPENWRT_REF}"
    git clone --filter=blob:none --branch "${OPENWRT_REF}" "${OPENWRT_REPO}" "${SRC_DIR_ABS}"
    return
  fi

  log "Refreshing OpenWrt source tree"
  git -C "${SRC_DIR_ABS}" fetch --tags origin
  if [[ -n "$(git -C "${SRC_DIR_ABS}" status --short)" ]]; then
    die "existing OpenWrt tree at ${SRC_DIR_ABS} has local changes; clean it or use another OPENWRT_WORKDIR"
  fi
  git -C "${SRC_DIR_ABS}" checkout "${OPENWRT_REF}"
}

sync_feeds_config() {
  if [[ -f "${ROOT_DIR}/config/feeds.conf.default" ]]; then
    cp "${ROOT_DIR}/config/feeds.conf.default" "${SRC_DIR_ABS}/feeds.conf.default"
  fi
}

update_and_install_feeds() {
  log "Updating feeds"
  (cd "${SRC_DIR_ABS}" && ./scripts/feeds update -a)

  log "Installing feeds"
  (cd "${SRC_DIR_ABS}" && ./scripts/feeds install -a)
}

copy_custom_packages() {
  if find "${ROOT_DIR}/packages" -mindepth 2 -name Makefile -print -quit | grep -q .; then
    log "Copying custom packages into package/custom"
    rm -rf "${SRC_DIR_ABS}/package/custom"
    mkdir -p "${SRC_DIR_ABS}/package/custom"
    rsync -a --delete "${ROOT_DIR}/packages/" "${SRC_DIR_ABS}/package/custom/"
  fi
}

copy_rootfs_files() {
  if find "${ROOT_DIR}/files" -mindepth 1 -not -name .gitkeep -print -quit | grep -q .; then
    log "Copying rootfs overlay files"
    mkdir -p "${SRC_DIR_ABS}/files"
    rsync -a "${ROOT_DIR}/files/" "${SRC_DIR_ABS}/files/"
  fi
}

apply_local_patches() {
  local patch
  shopt -s nullglob
  for patch in "${ROOT_DIR}"/patches/*.patch; do
    log "Applying patch $(basename "${patch}")"
    (cd "${SRC_DIR_ABS}" && patch -p1 < "${patch}")
  done
  shopt -u nullglob
}

prepare_cache_links() {
  rm -rf "${SRC_DIR_ABS}/dl"
  ln -sfn "${DL_DIR_ABS}" "${SRC_DIR_ABS}/dl"
  export CCACHE_DIR="${CCACHE_DIR_ABS}"
  export CCACHE_BASEDIR="${SRC_DIR_ABS}"
  export CCACHE_COMPRESS=1
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
  command -v ccache >/dev/null 2>&1 && ccache -M "${CCACHE_MAXSIZE}" >/dev/null 2>&1 || true
}

restore_optional_build_cache() {
  if [[ "${KEEP_BUILD_DIR_CACHE}" != "1" ]]; then
    return
  fi

  if [[ -d "${BUILD_CACHE_DIR_ABS}/build_dir" ]]; then
    log "Restoring cached build_dir"
    rsync -a --delete "${BUILD_CACHE_DIR_ABS}/build_dir/" "${SRC_DIR_ABS}/build_dir/"
  fi

  if [[ -d "${BUILD_CACHE_DIR_ABS}/staging_dir" ]]; then
    log "Restoring cached staging_dir"
    rsync -a --delete "${BUILD_CACHE_DIR_ABS}/staging_dir/" "${SRC_DIR_ABS}/staging_dir/"
  fi
}

save_optional_build_cache() {
  if [[ "${KEEP_BUILD_DIR_CACHE}" != "1" ]]; then
    return
  fi

  log "Saving selected build intermediates"
  mkdir -p "${BUILD_CACHE_DIR_ABS}/build_dir" "${BUILD_CACHE_DIR_ABS}/staging_dir"
  rsync -a --delete "${SRC_DIR_ABS}/build_dir/" "${BUILD_CACHE_DIR_ABS}/build_dir/"
  rsync -a --delete "${SRC_DIR_ABS}/staging_dir/" "${BUILD_CACHE_DIR_ABS}/staging_dir/"
}

write_dot_config() {
  log "Generating .config from diffconfig"
  cp "${ROOT_DIR}/config/diffconfig" "${SRC_DIR_ABS}/.config"
  (cd "${SRC_DIR_ABS}" && make defconfig)
}

download_sources() {
  log "Downloading sources"
  (cd "${SRC_DIR_ABS}" && make download -j8)
}

build_firmware() {
  local jobs
  jobs="${JOBS:-$(nproc)}"
  log "Starting build with ${jobs} job(s)"
  if ! (cd "${SRC_DIR_ABS}" && make -j"${jobs}"); then
    log "Parallel build failed, retrying with verbose single-thread build"
    (cd "${SRC_DIR_ABS}" && make -j1 V=s)
  fi
}

print_artifact_hint() {
  log "Artifacts should be under ${SRC_DIR_ABS}/bin/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
}
