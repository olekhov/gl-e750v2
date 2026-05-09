# Custom OpenWrt Packages

Put custom package feed content here if you want to use the `Build Packages (SDK)` workflow.

Expected layout:

```text
packages/
  my-package/
    Makefile
    files/
    patches/
```

The SDK workflow only makes sense when at least one package Makefile exists below this directory.

This repository already vendors:

- `amneziawg-tools`
- `kmod-amneziawg`
- `luci-proto-amneziawg`

Source:

- https://github.com/Slava-Shchipunov/awg-openwrt
