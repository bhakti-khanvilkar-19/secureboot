# Verified Boot and dm-verity

## Overview

FIT image verification (U-Boot → kernel) and dm-verity (kernel → rootfs) together provide an unbroken cryptographic chain from HABv4-verified U-Boot through to the running application.

## Trust Extension: From Bootloader to Userspace

```
HABv4 verified:
  ROM → imx-boot (SPL + TF-A + OP-TEE + U-Boot)

FIT verified (U-Boot performs):
  U-Boot → fitImage (kernel + DTB + initramfs)
  Key embedded in U-Boot DTB, verified by U-Boot code

dm-verity (kernel performs):
  kernel → rootfs (ext4 block device)
  Merkle tree on read-only partition, root hash in kernel cmdline

Application verified (optional, dm-verity extended):
  rootfs → data partition (LUKS2 + key sealed in OP-TEE/TPM)
```

## dm-verity Architecture

```
Block Device (/dev/mmcblk2p3):
┌──────────────────────────┐
│  rootfs data blocks      │  ← Application data (read-only)
│  (4KB each)              │
│  Block 0: hash in leaf   │
│  Block 1: hash in leaf   │
│  ...                     │
├──────────────────────────┤  ← superblock at end (or separate device)
│  Hash tree:              │
│    Leaf nodes: SHA-256   │
│    of each data block    │
│  Intermediate nodes:     │
│    SHA-256 of children   │
│  Root node: 32 bytes     │
└──────────────────────────┘
        │
        │ SHA-256
        ▼
   Root Hash (32 bytes)
   ↑ This must be signed or embedded in a verified location:
     - Kernel cmdline (in signed FIT image)
     - Signed OTA manifest
     - OP-TEE secure storage
```

## What dm-verity Provides

| Feature | dm-verity | IMA/EVM | AppArmor |
|---------|-----------|---------|----------|
| Per-block integrity | Yes | No | No |
| Catches filesystem-level attacks | Yes | Partial | No |
| Read-only enforcement | Yes | No | Partial |
| Runtime overhead | ~5-10% | ~15-30% | ~5% |
| Works with OTA A/B | Yes | Partial | Yes |
| Rootkit detection | Yes (prevents) | Detects | No |

## Key Security Property

dm-verity is a **one-way ratchet**: once the root hash is placed in a verified location (signed FIT cmdline), any modification to any block on the rootfs partition will cause the kernel to reject that block's read and trigger the `error_behavior` action (default: PANIC).

An attacker who can write to the rootfs but cannot modify the signed FIT image **cannot succeed** — the hash won't match.

## Cross-References

- [01-dmverity-setup.md](01-dmverity-setup.md) — Complete setup guide
- [../08-u-boot-secure-boot/02-uboot-configuration.md](../08-u-boot-secure-boot/02-uboot-configuration.md) — U-Boot cmdline with verity args
- [../09-fit-images/01-its-file-format.md](../09-fit-images/01-its-file-format.md) — Embedding root hash in FIT
- [../20-secure-updates/01-swupdate-integration.md](../20-secure-updates/01-swupdate-integration.md) — Updating dm-verity rootfs
