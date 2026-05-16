# IVT and Boot Container Technical Reference

## Overview

The Boot ROM parses binary structures to locate and authenticate boot images. On i.MX8M Plus,
two formats coexist: the older **IVT (Image Vector Table)** format inherited from i.MX6/i.MX7
for HABv4-signed components, and the newer **Container format** used for multi-image packaging
by imx-mkimage. This document covers both formats with byte-level precision.

---

## Table of Contents

1. [IVT Structure: Complete Field Reference](#1-ivt-structure-complete-field-reference)
2. [ROM IVT Parsing from eMMC/SD](#2-rom-ivt-parsing-from-emmc-sd)
3. [Image Offsets from Device Start](#3-image-offsets-from-device-start)
4. [i.MX8M Boot Container Format](#4-imx8m-boot-container-format)
5. [imx-mkimage: Creating Boot Containers](#5-imx-mkimage-creating-boot-containers)
6. [U-Boot SPL Integration into Container](#6-u-boot-spl-integration-into-container)
7. [Inspecting Container with hexdump](#7-inspecting-container-with-hexdump)
8. [Container vs IVT: Component Mapping](#8-container-vs-ivt-component-mapping)
9. [ROM Error Codes on Container Rejection](#9-rom-error-codes-on-container-rejection)

---

## 1. IVT Structure: Complete Field Reference

### C Structure Definition

```c
/*
 * HABv4 Image Vector Table
 * NXP i.MX8M Plus Reference Manual, Section: Boot ROM
 * Size: 32 bytes (0x20), must be 4-byte aligned
 */
struct hab_ivt {
    uint32_t hdr;       /* Offset 0x00: HABv4 header tag */
    uint32_t entry;     /* Offset 0x04: Absolute image entry point */
    uint32_t rsv1;      /* Offset 0x08: Reserved, must be 0 */
    uint32_t dcd;       /* Offset 0x0C: Absolute pointer to DCD, or 0 */
    uint32_t boot_data; /* Offset 0x10: Absolute pointer to boot_data_t */
    uint32_t self;      /* Offset 0x14: Absolute address of this IVT */
    uint32_t csf;       /* Offset 0x18: Absolute pointer to CSF, or 0 */
    uint32_t rsv2;      /* Offset 0x1C: Reserved, must be 0 */
};
```

### Field-by-Field Description

#### `hdr` — HAB Header (Offset 0x00)

```
Bit Layout (MSB first, stored little-endian in memory):
┌─────────┬──────────────┬──────────┐
│  [31:24]│    [23:08]   │  [07:00] │
│  tag    │   length     │ version  │
│  0xD1   │  0x0020 (BE) │  0x41    │
└─────────┴──────────────┴──────────┘
```

The HAB header tag `0xD1` identifies this as an IVT structure. The length `0x0020` (32) is
stored in big-endian byte order within the 16-bit field, giving bytes `0x00 0x20`. The version
`0x41` encodes HABv4.1.

In memory (little-endian), the `hdr` field value is `0xD1002041`:
- Byte 0 (lowest addr): `0x41` (version)
- Byte 1: `0x20` (length LSB)
- Byte 2: `0x00` (length MSB)
- Byte 3: `0xD1` (tag)

The full 32-bit little-endian value: `0xD1002041`

> **Silicon Revision Note:** Some i.MX8MP silicon revisions use `0xD1002040` (version 4.0).
> The ROM accepts both. When generating IVTs with CST, the version field is set automatically.

#### `entry` — Image Entry Point (Offset 0x04)

The 32-bit absolute address where the ROM jumps after successful authentication. For the SPL
on i.MX8MP:

```
entry = 0x00920000  (OCRAM SPL base, == CONFIG_SPL_TEXT_BASE)
```

The entry point must be:
- Within the loaded image bounds (defined by `boot_data.start` + `boot_data.length`)
- A valid ARM64 instruction address (4-byte aligned)
- The actual C entry point after assembly startup (in U-Boot SPL: `_start` in
  `arch/arm/cpu/armv8/start.S`)

#### `rsv1` — Reserved (Offset 0x08)

Must be `0x00000000`. The ROM will reject the IVT if this is non-zero (behavior depends on
ROM version; some ROMs tolerate non-zero values here but this is not documented behavior).

#### `dcd` — DCD Pointer (Offset 0x0C)

Absolute address of the Device Configuration Data structure, or `0x00000000` if no DCD is
present. On i.MX8MP SPL builds, this is always `0x00000000`.

If non-zero, the ROM:
1. Reads the DCD header at the given address
2. Validates the DCD tag (`0xD2`) and version
3. Executes DCD commands sequentially before jumping to `entry`
4. Includes DCD address range in HAB authentication scope

#### `boot_data` — Boot Data Pointer (Offset 0x10)

Absolute address of the `hab_boot_data` structure. This must always be set to a valid
structure. The Boot Data tells the ROM the full extent of the image to load.

#### `self` — IVT Self-Pointer (Offset 0x14)

The absolute address where **this IVT itself** will be loaded in memory. The ROM uses this
to compute relocation offsets. If the image is loaded to `0x920000` and the IVT is at offset
`0x400` within the image binary, then:

```
self = 0x920000 + 0x400 = 0x920400
```

The ROM validates that `self` matches the actual address at which it found the IVT. A mismatch
causes an authentication failure.

#### `csf` — CSF Pointer (Offset 0x18)

Absolute address of the Command Sequence File. The CSF contains the HAB commands that direct
the HAB engine through the authentication process (key installation, signature verification,
etc.).

In Open configuration (`SEC_CONFIG = Open`), this field may be `0x00000000`. In Closed
configuration, a valid CSF is mandatory; `csf=0` causes immediate authentication failure.

#### `rsv2` — Reserved (Offset 0x1C)

Must be `0x00000000`.

### Boot Data Structure (Complete)

```c
/*
 * HABv4 Boot Data Structure
 * Immediately follows IVT in image layout (recommended)
 * Size: 12 bytes
 */
struct hab_boot_data {
    uint32_t start;     /* Load address of the entire signed image */
                        /* Must equal IVT.self for single image */
    uint32_t length;    /* Total byte count of signed image region */
                        /* Includes: IVT + DCD + image + padding + CSF */
    uint32_t plugin;    /* 0x00000000: regular image */
                        /* 0x00000001: plugin image (loads another image) */
};
```

**Computing `length`:**

```
image_start = 0x920000   (= self, = start)
ivt_offset  = 0x400      (within the binary file)
spl_size    = 0x1F000    (SPL binary, 124KB example)
csf_offset  = 0x33800    (padded to this offset within binary)
csf_size    = 0x3000     (CSF binary, typically 2-4KB)

length = csf_offset + csf_size
       = 0x33800 + 0x3000
       = 0x36800  (218KB total signed region)
```

The `length` must include all bytes from `start` through the end of the CSF, inclusive.
If `length` is too small, HAB will not include the CSF in the authentication scope and
will compute an incorrect hash.

---

## 2. ROM IVT Parsing from eMMC/SD

### ROM Boot Sequence for IVT-Based Images

```
1. ROM reads 512 bytes from boot device at IVT offset
   (offset depends on device type, see Section 3)

2. ROM checks bytes [0x00..0x03] for IVT tag:
   if (data[0] != 0xD1) → not an IVT, try next format

3. ROM extracts length from bytes [0x01..0x02] (big-endian):
   length = (data[1] << 8) | data[2]
   if (length != 0x0020) → invalid IVT length

4. ROM validates version byte [0x03]:
   if (version != 0x40 && version != 0x41) → unknown version

5. ROM reads boot_data pointer from IVT[0x10..0x13]
   Loads hab_boot_data structure from that address

6. ROM reads total_size from hab_boot_data.length
   ROM reads load_addr from hab_boot_data.start

7. ROM copies `total_size` bytes from boot device to `load_addr`
   (This loads the entire signed image including CSF into OCRAM)

8. ROM reads entry point from IVT[0x04..0x07]
   ROM reads csf pointer from IVT[0x18..0x1B]

9. If SEC_CONFIG == Closed:
   ROM calls hab_rvt_authenticate_image(IVT_address, total_size)
   This invokes HAB engine with the loaded CSF

10. If authentication passes (or SEC_CONFIG == Open):
    ROM jumps to IVT.entry
```

### IVT Validation Rules

The ROM applies these checks before any data copy:

| Check | Condition | Action on Failure |
|-------|-----------|------------------|
| IVT tag | `hdr[31:24] == 0xD1` | Try container format |
| IVT length | `hdr[23:8] == 0x0020` | Reject |
| IVT version | `hdr[7:0] == 0x40 or 0x41` | Reject |
| Entry aligned | `entry % 4 == 0` | Reject |
| Self valid | `self == ivt_load_address` | HAB failure |
| Boot data range | `start <= entry < start+length` | Reject |
| Reserved fields | `rsv1 == 0 && rsv2 == 0` | ROM-version dependent |

---

## 3. Image Offsets from Device Start

### Critical Offsets by Device Type

The ROM reads the IVT (or container header) from a device-specific offset. These offsets are
**hard-coded in ROM** and cannot be changed without a ROM update (impossible in production).

| Boot Device | IVT/Container Offset | Rationale |
|-------------|---------------------|-----------|
| SD Card (any) | `0x400` (1024 bytes) | After sector 0 (MBR) and sector 1 |
| eMMC User Area | `0x8400` (33,792 bytes) | After 64KB MBR/GPT area |
| eMMC Boot0/Boot1 | `0x0` (0 bytes) | No partition table in boot partitions |
| SPI NOR (ECSPI) | `0x400` | After 1KB header area |
| SPI NOR (FlexSPI) | `0x1000` | After 4KB for FlexSPI configuration |
| NAND Flash | `0x400` | After bad block table |

> **Warning:** Writing imx-boot to the wrong offset is one of the most common mistakes.
> For SD cards: `dd if=imx-boot.bin of=/dev/sdX bs=1024 seek=1` (seek=1 for 1KB offset)
> For eMMC boot0: `dd if=imx-boot.bin of=/dev/mmcblk2boot0 bs=512 seek=0` (offset 0)

### Programmatically Determining the Correct Offset

From U-Boot, the offset used to flash is visible in the board defconfig:

```bash
# In configs/imx8mp_phycore_defconfig or board-specific config:
grep -r "CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR\|CONFIG_SECONDARY_BOOT_SECTOR_OFFSET" \
     u-boot/configs/imx8mp_phycore_defconfig
```

In Yocto, the `wic` image creator uses this offset from the machine configuration:

```bash
# meta-phytec/conf/machine/phyboard-pollux-imx8mp-3.conf
UBOOT_BINARY = "imx-boot-imx8mp.bin-flash_evk"
BOOTLOADER_SEEK = "32"   # 32 × 512 = 16KB? No — this is in 512-byte units
# Actual: for eMMC user area, seek to block 66 = 66 × 512 = 33792 = 0x8400
```

---

## 4. i.MX8M Boot Container Format

### Container Header (Detailed)

The container format is used for i.MX8M family images assembled by imx-mkimage. It is parsed
by both the Boot ROM and the SECO firmware (on i.MX8QM) or AHAB (on i.MX9).

```c
/*
 * imx-mkimage container header
 * See: imx-mkimage/src/mkimage_imx8.h
 * Tag: 0x87 (container), 0x8B (message block)
 * Version: 0x00
 */

/* Container Header: 16 bytes */
struct container_hdr {
    uint8_t  version;         /* 0x00 */
    uint16_t length_le;       /* Total container length (little-endian) */
    uint8_t  tag;             /* 0x87 = Container */
    uint32_t flags;           /* Container flags (see below) */
    uint16_t sw_version;      /* SW version for anti-rollback (SWVER) */
    uint8_t  fuse_version;    /* Minimum fuse version required */
    uint8_t  num_images;      /* Count of image entries (1 to 8) */
    uint16_t sig_blk_offset;  /* Offset from container start to SigBlock */
    uint16_t reserved;        /* 0x0000 */
};

/* Flags field bit definitions */
#define CONTAINER_FLAG_BOOT_IMG   (1 << 0)  /* bootable image */
#define CONTAINER_FLAG_IMG_AUTH   (1 << 8)  /* image authentication enabled */

/* Image Entry: 128 bytes */
struct boot_img_t {
    uint32_t offset;    /* Offset from container start to image data */
    uint32_t size;      /* Image size in bytes */
    uint64_t dst;       /* Destination load address (64-bit physical) */
    uint64_t entry;     /* Entry point (64-bit physical) */
    uint32_t hab_flags; /* Image-specific HAB flags */
    uint32_t meta;      /* Metadata (0 for most images) */
    uint8_t  hash[64];  /* SHA-512 hash of image, or zeros */
    uint8_t  iv[32];    /* AES-CBC IV if encrypted, zeros if not */
};

/* Signature Block: variable size */
struct sig_blk_hdr {
    uint8_t  version;     /* 0x00 */
    uint16_t length_le;   /* Signature block length */
    uint8_t  tag;         /* 0x90 = Signature block */
    uint16_t cert_offset; /* Offset to SRK table (from sig block start) */
    uint16_t srk_table_offset;
    uint16_t sig_offset;  /* Offset to actual signature */
    uint16_t blob_offset; /* Offset to DEK blob (if encrypted) */
    uint32_t reserved;
};
```

### hab_flags Field Encoding

The `hab_flags` field in each image entry encodes:

```
Bits [3:0]:  Image type
   0x3 = Executable (will be executed)
   0x4 = Data (loaded but not executed)
   0x5 = DCD image
   0x7 = Seco firmware

Bits [7:4]:  Core ID (target processor)
   0x1 = Cortex-M4 / M7
   0x2 = Cortex-A (A35/A53/A55)
   0x4 = SECO
   0x6 = V2X

Bits [8]:    Hash type
   0 = SHA-256
   1 = SHA-384

Example: Cortex-A executable image = 0x23
```

---

## 5. imx-mkimage: Creating Boot Containers

### Tool Overview

`imx-mkimage` is NXP's open-source tool for assembling multi-image boot containers. It
produces the final `imx-boot-*.bin` file that gets written to the boot device.

Repository: `https://github.com/nxp-imx/imx-mkimage`

### Build imx-mkimage

```bash
git clone https://github.com/nxp-imx/imx-mkimage.git
cd imx-mkimage
# No configure needed, simple Makefile
make SOC=iMX8MP
```

### i.MX8MP Flash Targets

```bash
# List available targets for i.MX8MP
make SOC=iMX8MP help

# Key targets:
# flash_evk         - eMMC boot (2KB offset)
# flash_evk_emmc    - eMMC boot partition (0 offset)  
# flash_dp_evk      - DisplayPort variant
# print_fit_hab     - Print HAB blocks for CST signing
```

### Assembling imx-boot for eMMC boot partition

```bash
# Prerequisites — place these in the imx-mkimage directory:
#   spl/u-boot-spl.bin          (from U-Boot build)
#   u-boot-nodtb.bin            (from U-Boot build)
#   u-boot.dtb                  (from U-Boot build, with embedded FIT key)
#   bl31.bin                    (from TF-A build: build/imx8mp/release/bl31.bin)
#   tee.bin                     (from OP-TEE build: core/tee-pager_v2.bin)
#   lpddr4_pmu_train_1d_dmem_202006.bin  (DDR firmware)
#   lpddr4_pmu_train_1d_imem_202006.bin
#   lpddr4_pmu_train_2d_dmem_202006.bin
#   lpddr4_pmu_train_2d_imem_202006.bin
#   signed_hdmi_imx8m.bin       (HDMI firmware, if display needed)

# Assemble unsigned boot container
make SOC=iMX8MP flash_evk

# Output: iMX8MP/flash.bin
# This file written to eMMC boot0 at offset 0
dd if=iMX8MP/flash.bin of=/dev/mmcblk2boot0 bs=1024 seek=0
```

### Makefile Logic: What imx-mkimage Does

The `flash_evk` target invokes the `mkimage_imx8` binary with:

```bash
./mkimage_imx8 \
    -soc iMX8MP \
    -rev B0 \
    -append lpddr4_pmu_train_1d_imem_202006.bin \
    -c \
    -ap spl/u-boot-spl.bin a53 0x920000 \
    -out flash.bin

# Then appends second container for TF-A + OP-TEE + U-Boot
./mkimage_imx8 \
    -soc iMX8MP \
    -rev B0 \
    -c \
    -ap bl31.bin a53 0x00970000 \
    -ap tee.bin a53 0xfe000000 \
    -ap u-boot-nodtb.bin a53 0x40200000 \
    --data u-boot.dtb 0x43000000 \
    -out u-boot-container.bin
```

The `-c` flag creates a new container. The `-ap` flag adds an executable image entry (AP = Application Processor). The layout in the output file:

```
flash.bin (final imx-boot image):
┌─────────────────────────────────────────────────────────┐
│ Offset 0x0000: DDR firmware (lpddr4_pmu_train_*)        │
│                (Several hundred KB)                     │
│                                                         │
│ Offset 0x8000: Container 0 Header                       │
│   Image 0: SPL (u-boot-spl.bin)                         │
│             dst=0x920000, entry=0x920000                 │
│   Signature Block (unsigned for dev, signed for prod)   │
│                                                         │
│ After Container 0 + SPL data:                           │
│ Container 1 Header                                      │
│   Image 0: BL31/TF-A → dst=0x00970000, entry=0x00970000│
│   Image 1: OP-TEE    → dst=0xfe000000, entry=0xfe000000 │
│   Image 2: U-Boot    → dst=0x40200000, entry=0x40200000 │
│   Image 3: U-Boot DTB→ dst=0x43000000 (data, no entry) │
│   Signature Block (unsigned for dev, signed for prod)   │
│                                                         │
│ After Container 1 header: actual image binaries         │
│   SPL binary data                                       │
│   BL31 binary data                                      │
│   OP-TEE binary data                                    │
│   U-Boot binary data                                    │
│   U-Boot DTB data                                       │
└─────────────────────────────────────────────────────────┘
```

---

## 6. U-Boot SPL Integration into Container

### SPL's Role in the Container

U-Boot SPL (`u-boot-spl.bin`) is the first user-supplied code to execute. It is packaged as
the sole image in Container 0. The ROM loads it based on the container's image entry:

```
Container 0, Image 0:
  offset: <distance from container start to SPL data>
  size:   <SPL binary size>
  dst:    0x920000        (must match CONFIG_SPL_TEXT_BASE)
  entry:  0x920000        (SPL entry point = _start)
  flags:  0x23            (A53 core, executable)
```

### SPL Build Output Files

The U-Boot build produces several SPL-related files:

```
u-boot/spl/
├── u-boot-spl           (ELF, with debug symbols)
├── u-boot-spl.bin       (raw binary, used by imx-mkimage)
├── u-boot-spl.map       (linker map — useful for debugging)
└── u-boot-spl-dtb.bin   (SPL + appended device tree)
```

The `u-boot-spl.bin` is produced by `objcopy` from the ELF:

```bash
aarch64-linux-gnu-objcopy -I elf64-aarch64 -O binary \
    --gap-fill=0x00 spl/u-boot-spl spl/u-boot-spl.bin
```

### Verifying SPL Entry Point

```bash
# Check the SPL entry point matches CONFIG_SPL_TEXT_BASE
aarch64-linux-gnu-readelf -h spl/u-boot-spl | grep "Entry point"
# Expected: Entry point address: 0x920000

# Check symbol table for _start
aarch64-linux-gnu-nm spl/u-boot-spl | grep " _start"
# Expected: 0000000000920000 T _start
```

---

## 7. Inspecting Container with hexdump

### Examining the Container Header

After building `flash.bin`, inspect it with hexdump to verify the container structure:

```bash
# Show first 256 bytes of flash.bin (container header area)
# Container 0 is typically at offset 0x8000 in the full flash.bin
hexdump -C flash.bin | head -64

# Jump to container header (skip DDR firmware at start)
# Find container tag 0x87
hexdump -C flash.bin | grep -m1 "87"
```

### Annotated Container Header Hex

```
Offset  Bytes                                   ASCII
──────────────────────────────────────────────────────────────────
008000  00 38 00 87 00 00 00 00  00 00 01 00 00 00 00 00  .8......  ........
                                 
        └─ version=0x00
           └─ length=0x3800 (14336 bytes, little-endian: 38 00)
              └─ tag=0x87 (Container)
                 └─ flags=0x00000000
                          └─ sw_version=0x0000
                             └─ fuse_version=0x01
                                └─ num_images=0x00...wait

# Let me show a correctly annotated example:
# Byte 0: version = 0x00
# Bytes 1-2: length = 0x0038 = 56 bytes (LE: 38 00) [small example]
# Byte 3: tag = 0x87
# Bytes 4-7: flags = 0x00000000
# Bytes 8-9: sw_version = 0x0000
# Byte 10: fuse_version = 0x00
# Byte 11: num_images = 0x01 (one image)
# Bytes 12-13: sig_blk_offset = 0x0060 (96 bytes from container start)
# Bytes 14-15: reserved = 0x0000
```

### Reading Image Entry from Container

Image entries start at offset 16 (0x10) from the container header:

```bash
# Show image entry at container_start + 0x10
# (128 bytes per image entry)
python3 << 'EOF'
import struct

with open('flash.bin', 'rb') as f:
    # Skip to container 0 (at 0x8000 in typical flash.bin)
    f.seek(0x8000)
    # Read container header (16 bytes)
    ver, length, tag, flags, sw_ver, fuse_ver, num_img, sig_off, rsv = \
        struct.unpack('<BHBIHHBHH', f.read(16))
    print(f"Container: version={ver:#x} tag={tag:#x} num_images={num_img}")
    print(f"  sig_blk_offset={sig_off:#x}")
    
    # Read first image entry (128 bytes)
    offset, size = struct.unpack('<II', f.read(8))
    dst, entry = struct.unpack('<QQ', f.read(16))
    hab_flags, meta = struct.unpack('<II', f.read(8))
    hash_bytes = f.read(64)
    iv_bytes = f.read(32)
    
    print(f"Image 0: offset={offset:#x} size={size:#x}")
    print(f"  dst={dst:#018x} entry={entry:#018x}")
    print(f"  hab_flags={hab_flags:#x}")
EOF
```

Expected output for SPL container:

```
Container: version=0x0 tag=0x87 num_images=1
  sig_blk_offset=0x90
Image 0: offset=0x200 size=0x1e800
  dst=0x0000000000920000 entry=0x0000000000920000
  hab_flags=0x23
```

### Verifying IVT within SPL Binary

The SPL binary itself contains an IVT (for HABv4 compatibility). Find it at offset 0x400
within the SPL binary:

```bash
# Extract SPL from container (at the image data offset)
dd if=flash.bin bs=1 skip=$((0x8000 + 0x200)) count=$((0x1e800)) \
   of=spl_extracted.bin

# Check IVT at offset 0x400
hexdump -C spl_extracted.bin | sed -n '4,6p'
# Expect:
# 00000400  41 20 00 d1 00 00 92 00  00 00 00 00 00 00 00 00
#           └─ 0xD1002041 (IVT header, LE)
#                        └─ entry = 0x00920000
```

---

## 8. Container vs IVT: Component Mapping

### Which Format Each Component Uses

| Component | Format | Signed By | Location in flash.bin |
|-----------|--------|-----------|----------------------|
| DDR training firmware | Raw binary (no header) | Not signed (ROM loads before auth) | Start of flash.bin |
| SPL (u-boot-spl.bin) | Container (+ embedded IVT) | AHAB/HABv4 CST | Container 0 |
| TF-A BL31 (bl31.bin) | Container image entry | TF-A CoT + optional AHAB | Container 1 |
| OP-TEE (tee.bin) | Container image entry | TF-A CoT + optional AHAB | Container 1 |
| U-Boot (u-boot.bin) | Container image entry | SPL FIT signature | Container 1 |
| U-Boot DTB | Container data entry | Part of U-Boot auth | Container 1 |
| Linux FIT image | FIT (not in imx-boot) | mkimage FIT signing | Separate partition |

### Container Format Versioning

```
i.MX6 / i.MX7:   IVT + DCD (no container, HABv4 only)
i.MX8MM / 8MN:   Container v1 (imx-mkimage)
i.MX8MP:         Container v1 (imx-mkimage) for secondary container
                 IVT embedded in SPL for HABv4 primary authentication
i.MX8QM:         Container v2 (SECO firmware)
i.MX93 / i.MX95: Container + AHAB (Advanced HAB)
```

### Authentication Chain for Each Format

**IVT path (SPL HABv4):**
```
ROM → reads IVT → loads image → invokes HAB engine → parses CSF → verifies SRK hash → verifies signature
```

**Container path (Container 1, TF-A/U-Boot):**
```
SPL → reads container header → loads images to DRAM → calls hab_rvt_authenticate_image()
  for each image → HAB engine verifies container signature block
```

---

## 9. ROM Error Codes on Container Rejection

### HAB Status Codes

The ROM stores HAB events in an internal log buffer. These are accessible via the HAB RVT
(ROM Vector Table) API. U-Boot exposes them via `hab_status`:

| HAB Status | Value | Meaning |
|-----------|-------|---------|
| `HAB_STS_ANY` | `0x00` | Match any status |
| `HAB_FAILURE` | `0x33` | Authentication failure |
| `HAB_WARNING` | `0x69` | Non-fatal warning |
| `HAB_SUCCESS` | `0xF0` | Authentication success |

### HAB Reason Codes

| Reason Code | Value | Description |
|------------|-------|-------------|
| `HAB_RSN_ANY` | `0x00` | Match any reason |
| `HAB_INV_ADDRESS` | `0x22` | Invalid address |
| `HAB_INV_ASSERTION` | `0x0C` | Invalid assertion |
| `HAB_INV_CALL` | `0x28` | Invalid function call |
| `HAB_INV_CERTIFICATE` | `0x21` | Certificate invalid |
| `HAB_INV_COMMAND` | `0x06` | CSF command invalid |
| `HAB_INV_CSF` | `0x11` | CSF invalid |
| `HAB_INV_DCD` | `0xDD` | DCD invalid |
| `HAB_INV_INDEX` | `0x1F` | Invalid index |
| `HAB_INV_IVT` | `0x05` | IVT invalid |
| `HAB_INV_KEY` | `0x1D` | Key not valid |
| `HAB_INV_RETURN` | `0x1E` | Invalid return |
| `HAB_INV_SIGNATURE` | `0x18` | Signature invalid |
| `HAB_INV_SIZE` | `0x17` | Invalid size |
| `HAB_MEM_FAIL` | `0x2E` | Memory failure |
| `HAB_OVR_COUNT` | `0x2B` | Counter overflow |
| `HAB_OVR_STORAGE` | `0x2D` | Storage overflow |
| `HAB_UNS_ALGORITHM` | `0x12` | Algorithm not supported |
| `HAB_UNS_COMMAND` | `0x03` | Command not supported |
| `HAB_UNS_ENGINE` | `0x0A` | Engine not supported |
| `HAB_UNS_ITEM` | `0x24` | Item not supported |
| `HAB_UNS_KEY` | `0x27` | Key type not supported |
| `HAB_UNS_PROTOCOL` | `0x14` | Protocol not supported |
| `HAB_UNS_STATE` | `0x09` | State not supported |

### Context Codes

| Context | Value | Description |
|---------|-------|-------------|
| `HAB_CTX_ANY` | `0x00` | Any context |
| `HAB_CTX_ENTRY` | `0xE1` | hab_rvt_entry() |
| `HAB_CTX_TARGET` | `0x33` | Target check |
| `HAB_CTX_AUTHENTICATE` | `0x0A` | authenticate_image() |
| `HAB_CTX_DCD` | `0xDD` | DCD processing |
| `HAB_CTX_CSF` | `0xCF` | CSF processing |
| `HAB_CTX_COMMAND` | `0xC0` | Command processing |
| `HAB_CTX_AUT_DAT` | `0xDB` | Authenticate data |
| `HAB_CTX_ASSERT` | `0xA0` | Assert |
| `HAB_CTX_EXIT` | `0xEE` | hab_rvt_exit() |

### Typical Error Sequences and Root Causes

**Error: `HAB_FAILURE / HAB_INV_SIGNATURE / HAB_CTX_AUTHENTICATE`**
```
Root causes:
- Image was modified after signing (common: padding changed by flash tool)
- Wrong key used to sign (dev key vs prod key mismatch)
- CSF generated for different image binary than what's loaded
- Image length in boot_data does not match actual signed region

Fix: Regenerate CSF from same image binary that will be deployed.
     Verify with: openssl dgst -sha256 -verify srk_pub.pem -signature sig.bin image_region.bin
```

**Error: `HAB_FAILURE / HAB_INV_CERTIFICATE / HAB_CTX_CSF`**
```
Root causes:
- SRK table in CSF does not match hash burned in OCOTP_SRK fuses
- Wrong SRK certificate selected (SRK2 used but SRK1 is in fuses)
- SRK fuses not yet burned (all zeros) but SEC_CONFIG = Closed

Fix: Run srktool to regenerate SRK_fuse.bin, verify against fuse readback.
     fuse read 3 0  through  fuse read 3 7
     Compare against srktool output.
```

**Error: `HAB_FAILURE / HAB_INV_IVT / HAB_CTX_AUTHENTICATE`**
```
Root causes:
- IVT self-pointer does not match load address
- IVT found at wrong offset (written to wrong media offset)
- IVT corrupt or header tag wrong

Fix: Verify IVT self = IVT load address
     hexdump -C spl.bin | grep -A1 "d1 00 20"
     Check that value at offset 0x14 of IVT matches expected load address.
```

**Error: `HAB_WARNING / HAB_INV_RETURN / HAB_CTX_EXIT`** (warning, not failure)
```
This warning appears in open systems and indicates the CSF field is 0
(unsigned image). In SEC_CONFIG=Open, this is logged but not fatal.
In SEC_CONFIG=Closed, this becomes a failure.
```

---

## Cross-References

- `../README.md` — Chapter 06 overview and HABv4 authentication flow
- `02-ddr-initialization.md` — Why DCD is not used for DDR on i.MX8MP
- `03-boot-mode-and-fuse-configuration.md` — SEC_CONFIG and BOOT_CFG fuse map
- `../10-image-signing/01-signing-workflows.md` — CSF creation with NXP CST

---

*Chapter 06 / 01 — IVT and Boot Container | Embedded Linux Secure Boot Reference*
