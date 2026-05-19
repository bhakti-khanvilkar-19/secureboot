# FIT Images

## Overview

FIT (Flat Image Tree) is a U-Boot image format that packages multiple boot components — kernel, device tree, initramfs — into a single signed container. It replaced the older `uImage` format.

## Why FIT?

| Feature | uImage | FIT Image |
|---------|--------|-----------|
| Multiple components | No (one image) | Yes (kernel+dtb+ramdisk) |
| Cryptographic hashes | No | Yes (per component) |
| Digital signatures | No | Yes (RSA/ECDSA) |
| Multiple configurations | No | Yes (per-board variant) |
| Self-describing | Minimal | Full metadata |
| Compression per component | One type | Per-component |

## FIT as Flattened Device Tree

FIT is literally a Device Tree binary (FDT). It uses the FDT format for its structure, making it parseable by the same code that parses device trees.

```
FIT = Device Tree format
├── Magic: 0xD00DFEED (same as DTB)
├── Properties: description, timestamp
├── images/ subtree
│   ├── kernel@1/ node
│   ├── fdt@1/ node
│   └── ramdisk@1/ node
└── configurations/ subtree
    └── conf@1/ node (with signature)
```

## FIT Image Anatomy

```
fitImage (binary, ~22MB typical):
┌────────────────────────────────────────────────────┐
│ FDT Header (48 bytes)                              │
│   magic: 0xD00DFEED                                │
│   totalsize: 22,847,032                             │
│   off_dt_struct: offset to device tree structure   │
│   off_dt_strings: offset to string table           │
├────────────────────────────────────────────────────┤
│ Device Tree Structure Block                        │
│   /description = "phyCORE-i.MX8MP..."              │
│   /timestamp = <1705401825>                        │
│   /images/kernel@1/data = [20MB kernel Image]      │
│   /images/kernel@1/hash@1/value = [32 bytes SHA]   │
│   /images/fdt@1/data = [50KB DTB]                  │
│   /images/ramdisk@1/data = [5MB initramfs.gz]      │
│   /configurations/conf@1/signature@1/value = [256B]│
├────────────────────────────────────────────────────┤
│ String Table                                       │
│   "data", "type", "arch", "hash", "signature"...  │
└────────────────────────────────────────────────────┘
```

## Node Types

### Image Node (images/kernel@1)

```
Required properties:
  data        = /incbin/("Image")    # Binary data (or external)
  type        = "kernel"             # Image type
  arch        = "arm64"             # CPU architecture
  os          = "linux"             # Operating system
  compression = "none"              # Compression algorithm
  load        = <0x40480000>        # Load address
  entry       = <0x40480000>        # Entry point

Optional:
  description = "Linux Kernel"
  kernel      = "r0"                # Kernel type (reserved for future)
```

Valid `type` values: `kernel`, `standalone`, `firmware`, `ramdisk`, `flat_dt`, `script`, `multi`, `fpga`, `loadable`, `vbmeta`

Valid `compression` values: `none`, `gzip`, `bzip2`, `lzma`, `lzo`, `lz4`, `zstd`

### Hash Node (images/kernel@1/hash@1)

```
  algo  = "sha256"     # or "sha384", "sha512", "crc32"
  value = <...>        # Computed by mkimage, stored as property
```

### Configuration Node (configurations/conf@1)

```
  description = "Secure Boot Config"
  kernel      = "kernel@1"     # Reference to kernel image
  fdt         = "fdt@1"        # Reference to DTB image
  ramdisk     = "ramdisk@1"    # Reference to ramdisk (optional)
```

### Signature Node (configurations/conf@1/signature@1)

```
  algo           = "sha256,rsa2048"    # hash_alg,sig_alg
  key-name-hint  = "fit-signing-key"  # Key name for signing
  sign-images    = "kernel", "fdt", "ramdisk"  # Which images to cover
  value          = <...>              # RSA signature (256 bytes)
  signer-name    = "mkimage"
  signer-version = "2023.04"
  timestamp      = <1705401825>
```

## Cross-References

- [01-its-file-format.md](01-its-file-format.md) — ITS source format
- [02-mkimage-reference.md](02-mkimage-reference.md) — mkimage tool
- [08-u-boot-secure-boot](../08-u-boot-secure-boot/README.md) — Verification in U-Boot
- [10-image-signing](../10-image-signing/README.md) — Signing workflow
- [14-yocto-secure-boot](../14-yocto-secure-boot/README.md) — Yocto FIT generation
