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
- `patches/openwrt/` - patches against the OpenWrt buildroot tree itself
- `patches/kernel/<target>/<patchver>/` - kernel patches copied into OpenWrt patchsets
- `packages/` - optional custom feed packages for SDK/package CI
- `scripts/build-local.sh` - local build entrypoint

The repository already vendors AmneziaVPN `awg-openwrt` packages under `packages/`:

- `kmod-amneziawg`
- `amneziawg-tools`
- `luci-proto-amneziawg`
- `luci-app-epm`

## Default Target

The scaffold is configured for:

- Target: `ath79`
- Subtarget: `nand`
- Profile: `glinet_gl-e750`

GL.iNet documents that `GL-E750` and `GL-E750V2` use the same firmware line, and the OpenWrt device page currently exposes official images for `glinet_gl-e750`.

## GitHub Actions

The main workflow is `Build Firmware`.

It is optimized for GitHub-hosted runners by:

- using a shallow OpenWrt clone (`--depth=1`)
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

Use it only when you place custom OpenWrt packages in `packages/<name>/Makefile`.
It uses `openwrt/gh-action-sdk`, which is appropriate for package/feed CI, but
not for full firmware image builds.

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

You need the usual OpenWrt build dependencies installed on Linux. See the
OpenWrt build system documentation for the distro-specific package list:

- https://openwrt.org/docs/guide-developer/toolchain/use-buildsystem
- https://openwrt.org/docs/guide-developer/build-system/install-buildsystem

At minimum, expect to need packages such as `build-essential`, `clang`, `flex`,
`gawk`, `gcc-multilib`, `g++-multilib`, `gettext`, `git`, `libncurses5-dev`, 
`libssl-dev`, `python3`, `rsync`, `subversion`, `unzip`, `zlib1g-dev`, and `ccache`.

## Customization Points

Use the repo like this:

1. Edit `config/diffconfig` to change target packages or image features.
2. Replace `config/feeds.conf.default` if you need custom feeds.
3. Put rootfs overlay files into `files/`.
4. Put buildroot patches into `patches/openwrt/`.
5. Put custom feed packages into `packages/`.

Default runtime config overlays belong in `files/`, for example:

```text
files/etc/uci-defaults/99-default-wifi
```

This repository already uses that mechanism to create two default APs on first boot:

- `openwrt` / `12345678` on 2.4 GHz
- `openwrt_5g` / `12345678` on 5 GHz

## Included Extra Packages

AmneziaWG is included in the image by default through vendored package
definitions from `Slava-Shchipunov/awg-openwrt`:

- `kmod-amneziawg`
- `amneziawg-tools`
- `luci-proto-amneziawg`

These package definitions live under `packages/` and are copied
into `package/custom/` during the build.

For eSIM management:

- `lpac` comes from the upstream OpenWrt `packages` feed and currently tracks `2.3.0`
- `luci-app-epm` is vendored locally under `packages/` for testing
- `curl` is included in the firmware explicitly
- this repo overrides the upstream `lpac` package locally only to fix the OpenWrt wrapper/env mapping for `uqmi` on `GL-E750`
- `modemmanager`, `modemmanager-rpcd`, and `luci-proto-modemmanager` are included in the image

## Vendored Package Sources

- `packages/amneziawg-tools`
  Source: https://github.com/Slava-Shchipunov/awg-openwrt/tree/431f9ceecc1e6bf7fff322330842c25f8164483e/amneziawg-tools
  Vendored from `awg-openwrt` commit `431f9ceecc1e6bf7fff322330842c25f8164483e`
  Package version: `1.0.20260223-1`
  Upstream source used by the package recipe: `amnezia-vpn/amneziawg-tools` tag `v1.0.20260223`

- `packages/kmod-amneziawg`
  Source: https://github.com/Slava-Shchipunov/awg-openwrt/tree/431f9ceecc1e6bf7fff322330842c25f8164483e/kmod-amneziawg
  Vendored from `awg-openwrt` commit `431f9ceecc1e6bf7fff322330842c25f8164483e`
  Package version: `1.0.20260329-1`
  Upstream source used by the package recipe: `amnezia-vpn/amneziawg-linux-kernel-module` tag `v1.0.20260329-2`

- `packages/luci-proto-amneziawg`
  Source: https://github.com/Slava-Shchipunov/awg-openwrt/tree/431f9ceecc1e6bf7fff322330842c25f8164483e/luci-proto-amneziawg
  Vendored from `awg-openwrt` commit `431f9ceecc1e6bf7fff322330842c25f8164483e`
  Package version: `2.0.4`

- `packages/luci-app-epm`
  Source: https://github.com/stich86/luci-app-epm/tree/0ec637f55f1c5621bd232496766795b71c798664/luci-app-epm
  Vendored from `luci-app-epm` commit `0ec637f55f1c5621bd232496766795b71c798664`
  Package version: `1.0.1`

- `packages/lpac`
  Source: OpenWrt packages feed `utils/lpac`
  Local override based on upstream OpenWrt `lpac` package `2.3.0-1`
  This repo carries only a local wrapper/config adjustment for backend selection and GL-E750 defaults

Kernel driver patches should not be placed into `build_dir/`.

Instead, put them into the repo in the matching OpenWrt patchset path, for example:

```text
patches/kernel/ath79/6.12/990-local-my-driver-fix.patch
patches/kernel/generic/6.12/990-local-my-shared-kernel-fix.patch
```

The build script copies them into `target/linux/<...>/patches-*` before the
build starts.
Use the `9xx-local-*.patch` naming pattern for repo-managed kernel patches
so stale copies can be cleaned safely on the next run.

## Notes

- `openwrt/gh-action-sdk` is included for package/feed CI only.
- Full firmware builds use the normal OpenWrt buildroot because SDK cannot build full device images.
- The workflow defaults are pinned to OpenWrt `v25.12.3`, which was the latest GitHub release on May 7, 2026.
