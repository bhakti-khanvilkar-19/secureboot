# PHYTEC securiPHY

## Overview

securiPHY is PHYTEC's production-ready secure boot framework for phyCORE-i.MX8MP and related platforms. It provides an opinionated, tested implementation of the full secure boot chain: HABv4 image signing, FIT image verification, dm-verity rootfs protection, OP-TEE integration, and factory provisioning tooling.

## What securiPHY Provides

```
┌─────────────────────────────────────────────────────────┐
│                    securiPHY Stack                      │
├─────────────────────────────────────────────────────────┤
│  HABv4 signed imx-boot (CST)                            │
│  ↓                                                      │
│  FIT image signed with RSA-2048 (mkimage)               │
│  ↓                                                      │
│  dm-verity protected rootfs (read-only ext4)            │
│  ↓                                                      │
│  OP-TEE: secure storage, HUK, fTPM                      │
│  ↓                                                      │
│  LUKS2 data partition (optional, TPM-sealed key)        │
│  ↓                                                      │
│  SWUpdate signed OTA packages (CMS/RSA-2048)            │
└─────────────────────────────────────────────────────────┘
```

## Two-Image Model

securiPHY uses a two-image approach for factory provisioning:

| Image | Purpose | Secure Boot? |
|-------|---------|-------------|
| `phytec-provisioning-image` | Factory only; programs fuses, verifies device | No (needs to run before secure boot) |
| `phytec-securiphy-image` | Production firmware; fully signed and verified | Yes |

## Key Features

- **HABv4 with 4 SRK slots**: 3 backup slots available for key revocation
- **FIT image verification**: Kernel, DTB, and ramdisk covered by RSA signature
- **dm-verity rootfs**: SHA-256 per-block verification on boot
- **OP-TEE 3.x**: Trusted OS with RPMB secure storage
- **Anti-rollback**: OCOTP fuse counter enforced in SWUpdate
- **Audit trail**: SWUpdate signing with operator logging

## Prerequisites

- phyCORE-i.MX8MP SOM with PHYTEC phyBOARD-Pollux carrier
- Yocto Kirkstone (or Scarthgap) build environment
- NXP CST (Code Signing Tool)
- Air-gapped key generation workstation
- HSM (YubiHSM2 recommended for PHYTEC scale)

## Cross-References

- [01-securiphy-build.md](01-securiphy-build.md) — Building securiPHY images
- [02-securiphy-provisioning.md](02-securiphy-provisioning.md) — Factory provisioning flow
- [../15-meta-layers-and-bsp/02-meta-phytec-analysis.md](../15-meta-layers-and-bsp/02-meta-phytec-analysis.md) — meta-phytec layer
- [../11-key-management/README.md](../11-key-management/README.md) — Key management
- [../19-manufacturing-security/README.md](../19-manufacturing-security/README.md) — Manufacturing pipeline
