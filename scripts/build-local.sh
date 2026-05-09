#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

main() {
  load_build_env
  require_commands
  prepare_directories
  clone_or_update_openwrt
  sync_feeds_config
  prepare_cache_links
  restore_optional_build_cache
  copy_custom_packages
  update_and_install_feeds
  copy_rootfs_files
  apply_local_patches
  write_dot_config
  download_sources
  build_firmware
  save_optional_build_cache
  print_artifact_hint
}

main "$@"
