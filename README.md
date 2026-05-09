# OpenWrt Build Repo for GL.iNet GL-E750 / GL-E750V2

This repository is a minimal build scaffold for producing custom OpenWrt firmware for `glinet_gl-e750` with two execution paths:

- GitHub Actions for repeatable cloud builds with cache reuse
- `scripts/build-local.sh` for local Linux builds

The default firmware source is pinned to `openwrt/openwrt` tag `v25.12.3`.

## Repository Layout

- `.github/workflows/build-firmware.yml` - full firmware build in GitHub Actions
- `.github/workflows/build-packages-sdk.yml` - optional package/feed CI via `openwrt/gh-action-sdk`
- `config/build.env` - source repo, ref, target profile and cache defaults
- `config/diffconfig` - OpenWrt diffconfig for `GL.iNet GL-E750`
- `config/feeds.conf.default` - optional feeds override
- `files/` - files copied into OpenWrt build root
- `patches/` - local patches applied before build
- `packages/` - optional custom feed packages for SDK/package CI
- `scripts/build-local.sh` - local build entrypoint

## Default Target

The scaffold is configured for:

- Target: `ath79`
- Subtarget: `nand`
- Profile: `glinet_gl-e750`

GL.iNet documents that `GL-E750` and `GL-E750V2` use the same firmware line, and the OpenWrt device page currently exposes official images for `glinet_gl-e750`.

## GitHub Actions

The main workflow is `Build Firmware`.

It is optimized for GitHub-hosted runners by:

- caching `dl/` downloads
- caching `ccache/`
- keeping build logic in the same script used locally
- uploading only the useful target artifacts and build metadata

### Manual Run

Use `Actions -> Build Firmware -> Run workflow`.

Optional inputs:

- `openwrt_ref` - override the OpenWrt tag/branch
- `keep_build_dir_cache` - enable experimental cache for selected build intermediates

### Package SDK Workflow

`Build Packages (SDK)` is separate on purpose.

Use it only when you place custom OpenWrt packages in `packages/<name>/Makefile`. It uses `openwrt/gh-action-sdk`, which is appropriate for package/feed CI, but not for full firmware image builds.

## Local Build

Run from the repository root:

```bash
./scripts/build-local.sh
```

Useful overrides:

```bash
OPENWRT_REF=v25.12.3 JOBS=$(nproc) ./scripts/build-local.sh
OPENWRT_WORKDIR=$HOME/work/openwrt-e750 ./scripts/build-local.sh
KEEP_BUILD_DIR_CACHE=1 ./scripts/build-local.sh
```

Build output will appear under:

```text
<workdir>/openwrt/bin/targets/ath79/nand/
```

## Local Prerequisites

You need the usual OpenWrt build dependencies installed on Linux. See the OpenWrt build system documentation for the distro-specific package list:

- https://openwrt.org/docs/guide-developer/toolchain/use-buildsystem
- https://openwrt.org/docs/guide-developer/build-system/install-buildsystem

At minimum, expect to need packages such as `build-essential`, `clang`, `flex`, `gawk`, `gcc-multilib`, `g++-multilib`, `gettext`, `git`, `libncurses5-dev`, `libssl-dev`, `python3`, `rsync`, `subversion`, `unzip`, `zlib1g-dev`, and `ccache`.

## Customization Points

Use the repo like this:

1. Edit `config/diffconfig` to change target packages or image features.
2. Replace `config/feeds.conf.default` if you need custom feeds.
3. Put rootfs overlay files into `files/`.
4. Put OpenWrt source patches into `patches/`.
5. Put custom feed packages into `packages/`.

## Notes

- `openwrt/gh-action-sdk` is included for package/feed CI only.
- Full firmware builds use the normal OpenWrt buildroot because SDK cannot build full device images.
- The workflow defaults are pinned to OpenWrt `v25.12.3`, which was the latest GitHub release on May 7, 2026.
