# Meta Layers and BSP Configuration

## Overview

The Yocto build system for i.MX8MP secure boot relies on a stack of OE/Yocto meta layers. Understanding each layer's role, the variables they export, and how they interact is essential for customizing secure boot behavior and debugging build failures.

## Layer Stack (i.MX8MP + PHYTEC)

```
Layer Priority (higher = overrides lower):
┌─────────────────────────────────────────────────────────┐
│  meta-phytec-security    (priority 15) ← Your customization
├─────────────────────────────────────────────────────────┤
│  meta-phytec             (priority 14) ← PHYTEC BSP
├─────────────────────────────────────────────────────────┤
│  meta-imx               (priority 13) ← NXP BSP
├─────────────────────────────────────────────────────────┤
│  meta-security           (priority 12) ← OE Security
├─────────────────────────────────────────────────────────┤
│  meta-openembedded/meta-oe (priority 7)
├─────────────────────────────────────────────────────────┤
│  openembedded-core (meta)  (priority 5) ← Base OE
└─────────────────────────────────────────────────────────┘
```

## Key Security-Related Classes

| Class | Layer | Purpose |
|-------|-------|---------|
| `kernel-fitimage` | oe-core | FIT image creation and signing |
| `uboot-sign` | oe-core | U-Boot FIT key embedding |
| `ima-evm-rootfs` | meta-security | IMA/EVM rootfs labeling |
| `dm-verity-image` | meta-security | dm-verity hash tree generation |
| `sign-file` | meta-imx | NXP CST HABv4 signing |

## Key Variables Summary

| Variable | Layer | Effect |
|----------|-------|--------|
| `UBOOT_SIGN_ENABLE` | oe-core | Enable FIT signing |
| `UBOOT_SIGN_KEYDIR` | oe-core | Path to FIT signing key dir |
| `UBOOT_SIGN_KEYNAME` | oe-core | Key file basename |
| `UBOOT_MKIMAGE_DTCOPTS` | oe-core | DTB build flags (add padding) |
| `UBOOT_DTB_BINARY` | oe-core | U-Boot DTB to embed key into |
| `HAB_ENABLE` | meta-imx | Trigger HABv4 CST signing |
| `HAB_CST_KEY` | meta-imx | Path to CSF key |
| `HAB_CST_IMG_KEY` | meta-imx | Path to IMG key |
| `EXTRA_IMAGE_FEATURES` | oe-core | Add `read-only-rootfs`, etc. |

## Cross-References

- [01-meta-imx-analysis.md](01-meta-imx-analysis.md) — NXP BSP layer deep dive
- [02-meta-phytec-analysis.md](02-meta-phytec-analysis.md) — PHYTEC BSP layer analysis
- [../14-yocto-secure-boot/README.md](../14-yocto-secure-boot/README.md) — Yocto build configuration
- [../14-yocto-secure-boot/02-kernel-fitimage-class.md](../14-yocto-secure-boot/02-kernel-fitimage-class.md) — kernel-fitimage class
