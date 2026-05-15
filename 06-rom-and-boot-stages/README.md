# Chapter 06: ROM Code and Boot Stages

## Overview

The Boot ROM is the immutable foundation of every secure boot chain. It is the first code executed
after power-on reset, and its correct operation is a prerequisite for every subsequent security
guarantee. This chapter covers the i.MX8MP Boot ROM architecture, its authentication capabilities,
the binary formats it parses, and the precise sequence of events from power-on to SPL handoff.

Understanding the ROM is not optional for secure boot engineering. When a device fails to boot,
or when a signed image is rejected, the failure trace begins here.

---

## Table of Contents

1. [ROM Bootloader: Role and Constraints](#1-rom-bootloader-role-and-constraints)
2. [i.MX8MP Boot ROM Address Space](#2-imx8mp-boot-rom-address-space)
3. [Boot ROM Capabilities](#3-boot-rom-capabilities)
4. [IVT: Image Vector Table Structure](#4-ivt-image-vector-table-structure)
5. [Boot Data Structure](#5-boot-data-structure)
6. [DCD: Device Configuration Data](#6-dcd-device-configuration-data)
7. [Container Format for i.MX8M](#7-container-format-for-imx8m)
8. [Boot Device Order and Scanning](#8-boot-device-order-and-scanning)
9. [HABv4 Authentication Flow](#9-habv4-authentication-flow)
10. [Secondary Image Table and Recovery Boot](#10-secondary-image-table-and-recovery-boot)
11. [Boot Mode Pin Configuration](#11-boot-mode-pin-configuration)
12. [eMMC Boot Partitions](#12-emmc-boot-partitions)
13. [Boot Stage State Machine](#13-boot-stage-state-machine)
14. [Debug Register Reading](#14-debug-register-reading)
15. [Common Boot Failures at ROM Stage](#15-common-boot-failures-at-rom-stage)

---

## 1. ROM Bootloader: Role and Constraints

### What the ROM Is

The Boot ROM is a small, read-only memory region programmed at silicon manufacturing time. On the
i.MX8MP, it is mapped at address `0x00000000` and is approximately 96KB in size. It cannot be
modified, patched, or updated in the field. This immutability is not a limitation — it is the
entire point.

The ROM is the **root of trust anchor**. Every cryptographic guarantee in the subsequent boot chain
depends on the ROM behaving correctly. NXP has had the ROM code audited and the HAB engine within
it is the basis for FIPS-validated implementations on some product lines.

Key properties of the Boot ROM:

| Property | Value |
|----------|-------|
| Base address | `0x00000000` |
| Size | ~96KB (varies by i.MX8M variant) |
| Modifiability | None — burned at fab |
| Execution privilege | EL3 / Privileged mode |
| Stack location | OCRAM (internal SRAM) |
| First code after reset vector | ROM exception vector table |

### What the ROM Does

The Boot ROM performs this work sequence at power-on:

1. **System initialization**: Configures clocks to minimum viable frequencies, initializes
   internal SRAM (OCRAM), sets up a minimal stack.
2. **Boot mode detection**: Reads the `BOOT_MODE[1:0]` pin state and `BT_FUSE_SEL` fuse to
   determine whether to boot from internal boot, serial download, or test mode.
3. **Boot device enumeration**: Based on `BOOT_CFG` fuses (or pins if `BT_FUSE_SEL=0`),
   identifies the primary boot device (eMMC, SD, SPI-NOR, NAND, etc.).
4. **Image location**: Reads the boot device at the expected offset to find the IVT or container
   header.
5. **HAB authentication**: If `SEC_CONFIG` fuses indicate closed configuration, authenticates the
   image using the HAB engine before executing any non-ROM code.
6. **DCD execution**: Optionally executes Device Configuration Data (DCD) commands to initialize
   peripherals such as DRAM controllers.
7. **Image loading**: Copies the first-stage loader (SPL) from boot device into OCRAM.
8. **Handoff**: Jumps to the entry point specified in the IVT.

### What the ROM Cannot Do

The ROM operates under severe constraints:

- **No DRAM access**: External DRAM is uninitialized. All ROM operations occur in OCRAM.
- **No filesystem awareness**: The ROM reads raw sectors, not FAT or ext4 files.
- **No network**: No PXE, no TFTP. Only on-device storage.
- **Limited crypto**: HAB engine provides RSA signature verification and hash computation, but
  not AES decryption of images.
- **No error recovery UI**: On authentication failure, the ROM can only halt, reset, or enter
  serial download mode (if not disabled by fuses).
- **Fixed algorithms**: HAB engine algorithm support is determined at silicon revision. For
  i.MX8MP, supported algorithms include RSA-2048/4096 and SHA-256/SHA-384.

### ROM as Root of Trust

The security guarantee of the entire boot chain is:

> The ROM will not execute code that has not been authenticated against the key hash burned into
> fuses, when SEC_CONFIG is set to Closed.

This is a strong guarantee with important nuances:

- It protects against an attacker who can modify files on the boot device (SD card theft,
  eMMC read-write access via USB).
- It does **not** protect against an attacker who can modify fuse values (physical access to
  JTAG interface combined with a ROM exploit — known to exist historically).
- It does **not** protect against supply chain compromise of the ROM itself.
- It does **not** protect against hardware-level attacks (fault injection, power glitching).

---

## 2. i.MX8MP Boot ROM Address Space

### Memory Map at Power-On

Immediately after reset, before any initialization code runs, the i.MX8MP memory map is:

```
Address Range          Size    Description
─────────────────────────────────────────────────────────────
0x00000000–0x0001FFFF  128KB   Boot ROM (read-only, aliased)
0x00900000–0x0093FFFF  256KB   OCRAM (internal SRAM, available)
0x00940000–0x0097FFFF  256KB   OCRAM (upper region, RDC controlled)
0x007E0000–0x007FFFFF  128KB   OCRAM S (secure SRAM, EL3 only)
0x40000000–0x...       DRAM    External DRAM (uninitialized at reset)
0x30000000–0x3FFFFFFF  256MB   Peripheral registers
0x38000000–0x383FFFFF          OCOTP (fuse registers)
0x30AF0000             4KB     SNVS (secure non-volatile storage)
```

### OCRAM Layout During ROM Execution

The Boot ROM partitions OCRAM for its own use as follows:

```
OCRAM Layout (0x00900000 – 0x0093FFFF)
─────────────────────────────────────────────────────────
0x00900000  ┌─────────────────────────────────┐
            │  ROM stack                      │  ~4KB
0x00901000  ├─────────────────────────────────┤
            │  ROM BSS / data                 │  ~4KB
0x00902000  ├─────────────────────────────────┤
            │  HAB internal workspace         │  ~8KB
            │  (CSF parsing, signature verify)│
0x00904000  ├─────────────────────────────────┤
            │  Boot data buffers              │  ~4KB
            │  (IVT, Boot Data, DCD staging)  │
0x00905000  ├─────────────────────────────────┤
            │                                 │
            │  AVAILABLE FOR SPL LOADING      │  ~220KB
            │  (0x00905000 to ~0x0093FFFF)    │
            │                                 │
0x0093FFFF  └─────────────────────────────────┘
```

> **Note:** The exact OCRAM partitioning is ROM-version dependent. Do not hard-code ROM internal
> addresses in application code. Only the SPL load region is documented as stable across ROM
> revisions.

### SPL Load Address

On i.MX8MP, the SPL is loaded by the ROM into OCRAM starting at `0x920000`. The SPL must be
linked to execute at this address. The U-Boot SPL `CONFIG_SPL_TEXT_BASE` must be set to
`0x920000` for i.MX8MP:

```kconfig
CONFIG_SPL_TEXT_BASE=0x920000
```

The maximum SPL size is determined by available OCRAM:

```
Max SPL size = OCRAM top - SPL load base - ROM reserved
             = 0x940000 - 0x920000 - overhead
             ≈ 128KB practical limit
```

---

## 3. Boot ROM Capabilities

### HAB Engine

The High Assurance Boot (HAB) engine is a hardware-accelerated cryptographic subsystem embedded
in the i.MX8MP Boot ROM. It provides:

| Capability | Algorithm | Notes |
|-----------|-----------|-------|
| Public key verification | RSA-2048, RSA-4096 | PKCS#1 v1.5 |
| Hash computation | SHA-256, SHA-384 | Hardware accelerated |
| SRK hash comparison | SHA-256 | Compared against OCOTP_SRK |
| CSF command interpretation | HABv4 protocol | Sequential command processing |
| Key revocation | Per-SRK via fuse | SRK_REVOKE[3:0] |

The HAB engine is invoked by the ROM when:
1. `SEC_CONFIG` fuses indicate Closed configuration (mandatory authentication)
2. Or explicitly via `hab_rvt_authenticate_image()` call from SPL/U-Boot

### Boot Device Detection

The ROM implements a device driver stack for each supported boot device type:

```
Boot Device Drivers in ROM
──────────────────────────
- eMMC (USDHC1, USDHC2, USDHC3): HS200/HS400, boot partition support
- SD Card (USDHC1, USDHC2): UHS-I, SD 3.0
- Serial NOR Flash (ECSPI, FlexSPI): 1/2/4 bit modes
- Raw NAND Flash: 8-bit, with ECC
- USB Serial Download (USB0): Recovery/manufacturing mode
- UART Serial Download: Minimal recovery interface
```

The boot device and port are selected by `BOOT_CFG` fuse values (covered in detail in
`03-boot-mode-and-fuse-configuration.md`).

### Minimal Peripheral Initialization

The ROM initializes only what is necessary to read the boot device:

- **Clock initialization**: PLL configuration for minimum boot frequency (~400 MHz A53)
- **IOMUX configuration**: GPIO/pad configuration for boot device pins
- **USDHC initialization**: eMMC or SD card controller (if applicable)
- **FlexSPI initialization**: SPI-NOR controller (if applicable)

The ROM does **not** initialize:
- External DRAM (done by DCD or SPL)
- USB (except for serial download mode)
- Display or video subsystems
- Any application peripherals

---

## 4. IVT: Image Vector Table Structure

### Structure Definition

The IVT is a fixed-size (32-byte) data structure that tells the Boot ROM where to find all
components of a bootable image. It is located at a fixed offset from the start of the boot
device, parsed before any image loading occurs.

```c
/**
 * IVT (Image Vector Table) for i.MX8M / HABv4
 * Located at fixed offset from boot media start
 * Total size: 32 bytes
 */
struct ivt {
    uint32_t header;       /* HABv4 header: tag=0xD1, length=0x0020, version=0x40 */
                           /* Packed: 0xD1002040 (HABv4 format) */
    uint32_t entry;        /* Absolute address of image entry point */
                           /* Must be within loaded image bounds */
    uint32_t reserved1;    /* Must be 0x00000000 */
    uint32_t dcd_ptr;      /* Absolute address of DCD structure, or 0x00000000 */
                           /* DCD runs before image entry if non-zero */
    uint32_t boot_data;    /* Absolute address of Boot Data structure */
                           /* Always required, must point to valid boot_data_t */
    uint32_t self;         /* Absolute address of this IVT structure */
                           /* Used by ROM to compute load offsets */
    uint32_t csf;          /* Absolute address of CSF (Command Sequence File) */
                           /* Required for HAB authentication, 0 if unsigned */
    uint32_t reserved2;    /* Must be 0x00000000 */
};
```

### IVT Header Field Encoding

The `header` field is a HABv4 header tag with embedded length and version:

```
Bits 31:24  Tag      = 0xD1  (HABv4 IVT tag)
Bits 23:08  Length   = 0x0020 (32 bytes, big-endian in this field)
Bits 07:00  Version  = 0x40  (HABv4 version 4.0)

Full value: 0xD1002040
```

Some older documentation lists `0xD1002041` — the LSB difference reflects minor HAB version
variants. For i.MX8MP with HABv4.6, use `0xD1002041` where the `0x41` encodes version 4.1.
Always check the current NXP ROM errata for your silicon revision.

### IVT Location on Boot Media

The IVT is placed at a fixed, device-specific offset:

| Boot Device | IVT Offset | Reason |
|-------------|-----------|--------|
| SD Card | `0x400` (1 KB) | Sector 2; sector 0-1 reserved for MBR/GPT |
| eMMC User Area | `0x8400` (33 KB) | Avoids MBR and GPT partition table |
| eMMC Boot Partition | `0x0` | Boot partitions have no partition table |
| SPI-NOR | `0x400` | Same convention as SD |
| NAND | `0x400` | Page-aligned, after bad-block table area |

Example IVT as it appears in a hex dump of an SPL at SD offset `0x400`:

```
Offset  00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F
000400  D1 00 20 40 00 29 02 09 00 00 00 00 00 00 00 00
000410  00 10 92 00 00 04 92 00 00 00 92 00 00 38 95 00
        ─────────────────────────────────────────────
        header=0xD1002040  entry=0x09020900
        reserved1=0         dcd_ptr=0x00000000 (no DCD)
        boot_data=0x00921000  self=0x00920400
        csf=0x00953800      reserved2=0
```

### Annotated Example: i.MX8MP SPL IVT

For an SPL loaded to OCRAM at `0x920000`, with the IVT placed at `0x920400`:

```c
struct ivt spl_ivt = {
    .header    = 0xD1002041,   /* HABv4.1 IVT tag */
    .entry     = 0x00920000,   /* SPL entry point (linked address) */
    .reserved1 = 0x00000000,
    .dcd_ptr   = 0x00000000,   /* No DCD for i.MX8MP SPL — DDR init in SPL */
    .boot_data = 0x00921000,   /* Points to boot_data struct in OCRAM */
    .self      = 0x00920400,   /* This IVT's load address */
    .csf       = 0x00953800,   /* CSF appended after padded SPL image */
    .reserved2 = 0x00000000,
};
```

> **Note on DCD for i.MX8MP:** Unlike i.MX6 and i.MX7, the i.MX8MP SPL does not use DCD for
> DDR initialization. DDR initialization is performed by the SPL itself using NXP's DDR training
> firmware. The `dcd_ptr` in the i.MX8MP SPL IVT is typically `0x00000000`.

---

## 5. Boot Data Structure

The Boot Data structure provides the ROM with the loading parameters for the image:

```c
/**
 * Boot Data structure for HABv4
 * Located immediately after IVT, or at dcd_ptr-aligned address
 */
struct boot_data {
    uint32_t start;    /* Absolute load address of the image */
                       /* Must match self field in IVT */
    uint32_t length;   /* Total image size in bytes, including IVT, DCD, */
                       /* image data, and CSF. Must include padding. */
    uint32_t plugin;   /* Plugin flag: 0x00000000 for regular images */
                       /* 0x00000001 for plugin images (not used for SPL) */
};
```

Example Boot Data for the SPL image:

```c
struct boot_data spl_boot_data = {
    .start  = 0x00920000,   /* Load address: OCRAM SPL base */
    .length = 0x00033800,   /* 206KB: SPL + IVT + CSF with padding */
    .plugin = 0x00000000,   /* Regular image, not plugin */
};
```

The `length` field is critical. It must encompass the entire signed image, including:
- The IVT itself (32 bytes)
- Any DCD structure (if present)
- The actual image binary
- Padding between image end and CSF
- The CSF itself

If `length` is incorrect, HAB authentication will fail because the hash computed by the ROM
will not match the hash in the CSF.

---

## 6. DCD: Device Configuration Data

### Purpose

The DCD allows the Boot ROM to execute a sequence of register writes before jumping to the
image entry point. This mechanism was introduced to allow DRAM initialization to be performed
by the ROM, without requiring any code in the loaded image to run first.

On i.MX8MP, the DCD is **not used for SPL** because the LPDDR4 training firmware requires
full code execution, not just register writes. However, understanding DCD is essential for
understanding i.MX6/i.MX7 images and some i.MX8MP configurations.

### DCD Structure

```c
/**
 * DCD Header
 */
struct dcd_header {
    uint8_t  tag;      /* 0xD2 — DCD tag */
    uint16_t length;   /* Total DCD size in bytes (big-endian) */
    uint8_t  version;  /* 0x41 — HABv4.1 */
};

/**
 * DCD Command: Write Data
 * Allows: write, set bits, clear bits, check bits
 */
struct dcd_write_cmd {
    uint8_t  tag;      /* 0xCC — Write Data command */
    uint16_t length;   /* Length of this command block */
    uint8_t  param;    /* Bits [3:2]: width (1/2/4 bytes) */
                       /* Bits [4]:   set/clear bits mode  */
                       /* Bits [5]:   mask/and mode        */
    /* Followed by (address, value) pairs */
    struct {
        uint32_t address;
        uint32_t value;
    } data[];
};

/**
 * DCD Command: Check Data
 * Polls a register until a bit condition is met
 */
struct dcd_check_cmd {
    uint8_t  tag;      /* 0xCF — Check Data command */
    uint16_t length;
    uint8_t  param;
    uint32_t address;
    uint32_t mask;
    /* Optional: count (poll count before timeout) */
};
```

### Example DCD for i.MX6 DRAM Init

To illustrate DCD usage (from an i.MX6 reference):

```
DCD Header: D2 01 2C 41   (tag=0xD2, length=0x012C=300 bytes, version=0x41)

Write Data Command: CC 00 AC 04   (tag=0xCC, length=0x00AC, param=0x04 = 4-byte writes)
  CCM_CCGR0:      30384000 FFFFFFFF   (enable all clocks)
  IOMUXC_DDR_...: 30340020 00020000   (DDR pad configuration)
  ... (many more register writes)

Check Data Command: CF 00 0C 04   (poll DRAM_CTL_REG until PHY ready)
  Address: 30391000
  Mask:    00000001
```

### Why i.MX8MP Avoids DCD for DRAM

LPDDR4 initialization on i.MX8MP requires:
1. Loading the DDR training firmware (binary blobs: `lpddr4_pmu_train_1d_imem.bin`, etc.)
2. Executing the firmware on the DDR PHY subsystem
3. Processing training results
4. Applying timing parameters

This cannot be reduced to a set of static register writes. The DCD mechanism is insufficient.
Instead, the SPL contains the full DDR initialization code, executed after the ROM jumps to the
SPL entry point.

---

## 7. Container Format for i.MX8M

### Why Containers?

NXP introduced a new "Container" format for the i.MX8M family (distinct from the IVT-based
format used by i.MX6/i.MX7). The container format is more flexible, supports multiple images
in a single container, and integrates better with AHAB (Advanced HAB) used on later devices.

On i.MX8MP specifically:
- **SPL** uses the IVT format (HABv4)
- **imx-boot container** (assembled by imx-mkimage) uses the container format
- **TF-A and OP-TEE** are packaged within the imx-boot container

### Container Header Structure

```c
/**
 * i.MX8M Container Header
 * See: imx-mkimage source, mkimage_imx8.h
 */
struct container_hdr {
    uint8_t  version;       /* Container format version */
    uint16_t length;        /* Header length (little-endian) */
    uint8_t  tag;           /* 0x87 — container tag */
    uint32_t flags;         /* Container flags */
    uint16_t sw_version;    /* Software version for anti-rollback */
    uint8_t  fuse_version;  /* Fuse version */
    uint8_t  num_images;    /* Number of image entries that follow */
    uint16_t sig_blk_offset;/* Offset to signature block */
    uint16_t reserved;
};

/**
 * Image Entry in Container
 */
struct boot_img_t {
    uint32_t offset;        /* Offset of image data from container start */
    uint32_t size;          /* Image size in bytes */
    uint64_t dst;           /* Destination load address (64-bit) */
    uint64_t entry;         /* Entry point address (64-bit) */
    uint32_t hab_flags;     /* HAB flags: core ID, image type */
    uint32_t meta;          /* Metadata */
    uint8_t  hash[64];      /* SHA-512 hash of image (zero if not used) */
    uint8_t  iv[32];        /* AES-IV for encrypted images */
};
```

### imx-boot Container Assembly

The `imx-mkimage` tool assembles the container from individual binary components:

```makefile
# Makefile target from imx-mkimage for i.MX8MP
flash_evk: $(MKIMG) $(AHAB_IMG) spl/u-boot-spl.bin u-boot-nodtb.bin \
           signed_hdmi_imx8m.bin bl31.bin tee.bin u-boot.dtb
    ./$(MKIMG) -soc iMX8MP -rev B0 -append $(AHAB_IMG) \
               -c -ap spl/u-boot-spl.bin a53 0x920000 \
               -out imx-boot-imx8mp.bin
```

The resulting `imx-boot-imx8mp.bin` structure:

```
imx-boot-imx8mp.bin
├── Padding (to offset 0x8400 for eMMC, 0x400 for SD)
├── Primary Container
│   ├── Container Header (with num_images=1)
│   ├── Image Entry 0: SPL → load to 0x920000, entry 0x920000
│   └── Signature Block (AHAB signatures if SEC_CONFIG=Closed)
├── Secondary Container (for TF-A + OP-TEE + U-Boot)
│   ├── Container Header (with num_images=3-4)
│   ├── Image Entry 0: BL31 (TF-A) → EL3
│   ├── Image Entry 1: BL32 (OP-TEE) → Secure EL1
│   ├── Image Entry 2: BL33 (U-Boot) → Non-secure EL2/EL1
│   └── Signature Block
└── Actual image data (SPL binary, BL31, BL32, BL33)
```

---

## 8. Boot Device Order and Scanning

### Boot Device Priority

The i.MX8MP ROM scans boot devices in a fuse-programmed priority order. The `BOOT_CFG` fuses
encode the primary and secondary boot device. If the primary device fails to produce a valid
image, the ROM can fall back to the secondary device.

Primary boot device selection (BOOT_CFG[7:4]):

```
BOOT_CFG[7:4]  Device
─────────────────────────────────────────────────────────
0000           eMMC (USDHC3, boot partition)
0001           SD Card (USDHC2)
0010           SD Card (USDHC1)
0011           eMMC (USDHC2, user partition)
0100           SPI NOR (ECSPI1)
0101           NAND Flash
0110           SPI NOR (FlexSPI)
1111           USB Serial Download (unconditional)
```

### ROM Boot Scan Sequence

```
Power-On Reset
     │
     ▼
Read BOOT_MODE[1:0] pins and BT_FUSE_SEL fuse
     │
     ├──[BOOT_MODE=10, Internal Boot]──────────────────────────────────┐
     │                                                                 │
     ├──[BOOT_MODE=00, Boot from Fuses]──→ Read BOOT_CFG fuses ───────┤
     │                                                                 │
     └──[BOOT_MODE=01, Serial Download]──→ USB/UART serial download    │
                                                                       │
                                           ┌───────────────────────────┘
                                           │
                                           ▼
                                  Read Primary Boot Device
                                  (BOOT_CFG determines device)
                                           │
                                           ▼
                              Find IVT/Container at expected offset
                                           │
                              ┌────────────┴────────────┐
                              │                         │
                         [Found valid header]    [Invalid or missing]
                              │                         │
                              ▼                         ▼
                       Load image to OCRAM      Try Secondary Boot Device
                              │                         │
                              ▼                    [If enabled by fuse]
                  [SEC_CONFIG = Closed?]               │
                    Yes │      No │               [Still fails?]
                        │         │                    │
                        ▼         │                    ▼
                  HAB Authenticate│            Enter Serial Download
                        │         │            (if not fuse-disabled)
                  [Pass?]│ [Fail?] │
                    Yes  │   No   │
                         │    │   │
                         │    ▼   │
                         │  Halt/Reset
                         │
                    ┌────┘───────┘
                    │
                    ▼
              Execute DCD (if dcd_ptr != 0)
                    │
                    ▼
              Jump to Entry Point
              (SPL begins execution)
```

---

## 9. HABv4 Authentication Flow

### Overview

When `SEC_CONFIG` fuses are burned to Closed (0x2), the ROM **must** successfully authenticate
every image before executing it. Authentication is performed by the HAB engine using:

1. The **SRK hash** burned into OCOTP fuses (8 × 32-bit words)
2. The **CSF** (Command Sequence File) appended to the signed image
3. The **image data** itself (hashed during verification)

### Authentication Step-by-Step

```
ROM loads image to OCRAM
         │
         ▼
ROM reads IVT from image
         │
         ▼
ROM reads csf_ptr from IVT
         │
         ▼
         ┌─────────────────────────────────────────┐
         │  HAB Engine: Parse CSF                  │
         │                                         │
         │  CSF Commands (in order):               │
         │  1. Header       — HAB version          │
         │  2. Install SRK  — loads SRK table,     │
         │                    computes SHA-256 of   │
         │                    SRK table, compares   │
         │                    against OCOTP_SRK*    │
         │  3. Install CSFK — installs CSF signing  │
         │                    key (signed by SRK)  │
         │  4. Authenticate — verifies CSF itself   │
         │                    against CSFK          │
         │  5. Install Key  — installs image signing│
         │                    key (IMG key)         │
         │  6. Authenticate Data — hashes image     │
         │                         data regions,    │
         │                         verifies against │
         │                         IMG key          │
         │  7. Unlock       — optional, unlocks HAB │
         │                    features              │
         └─────────────────────────────────────────┘
                  │
         [SRK hash matches fuses?]
                  │
         [CSF signature valid?]
                  │
         [Image hash matches?]
                  │
                  ▼
         Authentication PASS → Execute image
```

### SRK Hash Computation

The SRK table contains the public key data for up to 4 SRK certificates. The ROM computes
a SHA-256 hash over the entire SRK table and compares it against the 256-bit hash burned in
OCOTP_SRK0–SRK7:

```
SRK Table Content (example, 4 keys):
┌─────────────────────────┐
│ SRK1 Public Key (2048b) │
│ SRK2 Public Key (2048b) │
│ SRK3 Public Key (2048b) │
│ SRK4 Public Key (2048b) │
└─────────────────────────┘
        │
        ▼ SHA-256
        │
   256-bit hash
        │
        ▼
   Compare against OCOTP_SRK[0..7]
   (8 × 32-bit fuse words = 256 bits)
        │
   Match? → Continue
   No match? → HAB failure event, halt
```

### HAB Events

The HAB engine logs events to a RAM buffer accessible via the `hab_rvt_report_status()` function.
These events are invaluable for debugging authentication failures. The HAB event buffer is in
OCRAM and can be read by U-Boot via:

```
u-boot=> hab_status
Secure boot disabled
HAB Configuration: 0xf0, HAB State: 0x66
No HAB Events Found!
```

When authentication fails, events appear as:

```
HAB Configuration: 0xf0, HAB State: 0x66
--------- HAB Event 1 -----------------
event data:
0xdb 0x00 0x14 0x43 0x33 0x11 0x61 0x00 0xc5 0x02 0x00 0x00
0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00

STS = HAB_FAILURE (0x33)
RSN = HAB_INV_SIGNATURE (0x18)
CTX = HAB_CTX_AUTHENTICATE (0x0a)
ENG = HAB_ENG_ANY (0x00)
```

Event code reference:

| Code | Constant | Meaning |
|------|----------|---------|
| `0x33` | `HAB_FAILURE` | Authentication failed |
| `0x69` | `HAB_WARNING` | Non-fatal warning |
| `0x18` | `HAB_INV_SIGNATURE` | Signature verification failed |
| `0x20` | `HAB_INV_CERTIFICATE` | Certificate invalid |
| `0x1C` | `HAB_INV_KEY` | Key invalid or not found |
| `0xA8` | `HAB_INV_RETURN` | Return address mismatch |
| `0x1D` | `HAB_INV_DATUM` | Data integrity failure |

---

## 10. Secondary Image Table and Recovery Boot

### Secondary Image Table

If the primary boot attempt fails (corrupt image, read error, authentication failure in open
mode), the ROM can attempt to load from a secondary image location. The Secondary Image Table
(SIT) is located after the primary image in the boot media.

For eMMC User Area:

```
eMMC User Area Layout
──────────────────────────────────────────────────────────────
Offset    Size      Content
──────────────────────────────────────────────────────────────
0x0000    0x400     GPT protective MBR + GPT header
0x0400    4 bytes   Secondary Image Table flag (0x00040000)
0x0800    varies    Secondary boot image (SPL backup)
0x8400    varies    Primary boot image (SPL)
```

The ROM checks the flag at offset `0x0400`. If set, it attempts the secondary image first.

### Recovery Boot Mechanism

The full recovery flow:

```
Primary Boot Attempt
         │
    [Success?] ──Yes──→ Execute
         │ No
         ▼
Check Secondary Image Table
         │
    [SIT present?] ──No──→ [Serial Download if enabled]
         │ Yes                      or Halt
         ▼
Load Secondary Image
         │
    [Success?] ──Yes──→ Execute
         │ No
         ▼
Serial Download Mode
(if not disabled by DISABLE_SDOF fuse)
```

---

## 11. Boot Mode Pin Configuration

### BOOT_MODE Pins

The i.MX8MP has two boot mode selection pins: `BOOT_MODE[1:0]`. These pins are sampled at the
rising edge of the first POR reset (Power-On Reset). Their state determines the ROM's top-level
behavior:

| BOOT_MODE[1:0] | Mode | Description |
|----------------|------|-------------|
| `00` | Boot from Fuses | Use BOOT_CFG fuses to select boot device |
| `01` | Serial Downloader | USB/UART serial download (manufacturing) |
| `10` | Internal Boot | Use boot pins or fuses (BT_FUSE_SEL determines which) |
| `11` | Test Mode | Factory test (disabled in production fusing) |

### BT_FUSE_SEL Fuse

The `BT_FUSE_SEL` fuse at OCOTP_CFG4[4] controls whether boot configuration comes from pins
or fuses when `BOOT_MODE[1:0] = 10`:

```
BT_FUSE_SEL = 0: Boot configuration from BOOT_CFG pins (NAND_DATA[7:0])
BT_FUSE_SEL = 1: Boot configuration from BOOT_CFG fuses (OCOTP_CFG4)
```

In production, `BT_FUSE_SEL` must be `1` to prevent an attacker from forcing alternative
boot by physically manipulating pins.

### phyBOARD-Pollux Boot Mode Jumpers

On the PHYTEC phyBOARD-Pollux carrier board, the boot mode is configured via:

| Jumper | Signal | Closed = 1, Open = 0 |
|--------|--------|----------------------|
| J3 | BOOT_MODE0 | Controls BOOT_MODE[0] |
| J4 | BOOT_MODE1 | Controls BOOT_MODE[1] |

For normal boot (Internal Boot from fuses): J3=open, J4=closed → BOOT_MODE=10

For serial download (recovery/programming): J3=closed, J4=open → BOOT_MODE=01

---

## 12. eMMC Boot Partitions

### eMMC Boot Architecture

eMMC devices provide dedicated boot partitions (`boot0` and `boot1`) that are separate from
the main user data area. These boot partitions have properties that make them preferable for
bootloader storage:

- **Fixed starting address**: Always readable from offset 0x0 regardless of partition table
- **Write protection**: Can be write-protected independently of user area
- **Pre-boot access**: The eMMC sends the boot partition contents automatically on power-up
  (eMMC hardware boot mode)
- **Smaller, dedicated**: Typically 4MB or 8MB per partition

### Boot Partition Layout

```
eMMC Boot Partition 0 (mmcblk2boot0) — Typical Layout
────────────────────────────────────────────────────────────
Offset      Size      Content
────────────────────────────────────────────────────────────
0x000000    0x000400  Empty (reserved)
0x000400    varies    imx-boot-imx8mp.bin
                      ├── Container 0 (SPL)
                      └── Container 1 (TF-A + OP-TEE + U-Boot FIT)
0x200000    varies    (Optional: redundant copy of boot image)
────────────────────────────────────────────────────────────

eMMC User Area — Typical Layout
────────────────────────────────────────────────────────────
0x000000    0x004000  GPT Header + Partition Table
0x004000    2MB       FIT Image partition (kernel + DTB + ramdisk)
0x204000    varies    Root filesystem partition
```

### Accessing Boot Partitions

Boot partitions are accessed as separate block devices:

```bash
# List eMMC partitions
ls -la /dev/mmcblk2*

# Enable write access to boot partition 0 (needed for programming)
echo 0 > /sys/class/block/mmcblk2boot0/force_ro

# Write imx-boot to boot partition 0
dd if=imx-boot-imx8mp.bin of=/dev/mmcblk2boot0 bs=1024 seek=0

# Re-enable read-only
echo 1 > /sys/class/block/mmcblk2boot0/force_ro

# Configure eMMC to boot from boot0 partition
mmc bootpart enable 1 1 /dev/mmcblk2
```

### eMMC Extended CSD: Boot Configuration

The eMMC controller's Extended CSD register controls boot behavior:

```
EXT_CSD[179] PARTITION_CONFIG:
  Bits [5:3]: BOOT_ACK — Boot acknowledge setting
  Bits [5:3]: BOOT_PARTITION_ENABLE
               000: Not boot enabled
               001: Boot from boot0
               010: Boot from boot1
               111: Boot from user area
  Bits [2:0]: PARTITION_ACCESS
```

Reading current boot configuration:

```bash
mmc extcsd read /dev/mmcblk2 | grep -A2 "Boot configuration"
```

---

## 13. Boot Stage State Machine

Full system boot progression from power-on to Linux userspace:

```
POWER-ON RESET
     │
     ▼ ~1ms
┌─────────────────────────────────────────────────────┐
│  STAGE 1: BOOT ROM (0x00000000)                     │
│  Duration: ~200ms                                   │
│  Location: ROM (immutable)                          │
│  CPU state: AArch64 EL3, single core (A53 #0)       │
│  Memory: OCRAM only (no DRAM)                       │
│                                                     │
│  Actions:                                           │
│  - Initialize clocks (~400MHz)                      │
│  - Read BOOT_MODE pins, BOOT_CFG fuses              │
│  - Initialize boot device (eMMC/SD)                 │
│  - Read IVT from boot device                        │
│  - HAB authenticate if SEC_CONFIG=Closed            │
│  - Execute DCD (if present)                         │
│  - Load SPL to OCRAM (0x920000)                     │
│  - Jump to SPL entry                                │
└─────────────────────┬───────────────────────────────┘
                      │ Jump to 0x920000
                      ▼ ~200ms
┌─────────────────────────────────────────────────────┐
│  STAGE 2: SPL (Secondary Program Loader)            │
│  Duration: ~500ms (includes DDR training)           │
│  Location: OCRAM (0x920000)                         │
│  CPU state: AArch64 EL3, single core                │
│  Memory: OCRAM + initializes DRAM                   │
│  Binary: u-boot-spl.bin                             │
│                                                     │
│  Actions:                                           │
│  - Initialize UART (console output starts)          │
│  - Initialize DDR (load training FW, run training)  │
│  - Initialize eMMC/SD                               │
│  - Load FIT image (TF-A + OP-TEE + U-Boot) to DRAM │
│  - Verify FIT signature (if CONFIG_SPL_FIT_SIGNATURE)│
│  - Jump to TF-A BL31 entry point                    │
└─────────────────────┬───────────────────────────────┘
                      │ Jump to BL31 (0x00970000)
                      ▼ ~10ms
┌─────────────────────────────────────────────────────┐
│  STAGE 3: TF-A BL31 (Trusted Firmware-A)            │
│  Duration: ~50ms                                    │
│  Location: DRAM (secure region, e.g. 0x00970000)    │
│  CPU state: AArch64 EL3                             │
│  Binary: bl31.bin                                   │
│                                                     │
│  Actions:                                           │
│  - Initialize EL3 runtime services                  │
│  - Set up PSCI (CPU power management)               │
│  - Configure GIC (interrupt controller)             │
│  - Load BL32 (OP-TEE)                               │
│  - Initialize secure monitor / EL3 handlers         │
│  - Launch OP-TEE (BL32) in Secure EL1               │
│  - Prepare BL33 (U-Boot) launch                     │
└─────────────────────┬───────────────────────────────┘
                      │ SMC to OP-TEE, then to U-Boot
                      ▼ ~30ms (OP-TEE) + ~5ms (U-Boot start)
┌─────────────────────────────────────────────────────┐
│  STAGE 4: OP-TEE (Optional, BL32)                   │
│  Duration: ~30ms initialization                     │
│  Location: DRAM (secure partition)                  │
│  CPU state: AArch64 Secure EL1                      │
│  Binary: tee.bin                                    │
│                                                     │
│  Actions:                                           │
│  - Initialize TEE core                              │
│  - Initialize secure storage                        │
│  - Prepare REE (U-Boot) launch                      │
│  - Runs permanently as secure world OS              │
└─────────────────────┬───────────────────────────────┘
                      │ Return to BL31 → launch BL33
                      ▼ ~5ms
┌─────────────────────────────────────────────────────┐
│  STAGE 5: U-Boot (BL33)                             │
│  Duration: ~2-5 seconds (typical)                   │
│  Location: DRAM (non-secure, e.g. 0x40200000)       │
│  CPU state: AArch64 Non-secure EL2                  │
│  Binary: u-boot-nodtb.bin + u-boot.dtb              │
│                                                     │
│  Actions:                                           │
│  - Complete board initialization                    │
│  - Initialize network, USB (if needed)              │
│  - Load FIT image from boot device                  │
│  - Verify FIT image signature                       │
│  - Set up kernel boot arguments                     │
│  - Boot Linux kernel via bootm                      │
└─────────────────────┬───────────────────────────────┘
                      │ bootm → kernel entry
                      ▼ ~30-60 seconds to userspace
┌─────────────────────────────────────────────────────┐
│  STAGE 6: Linux Kernel + Userspace                  │
│  Location: DRAM                                     │
│  CPU state: EL1 (kernel), EL0 (userspace)           │
│  OP-TEE still running in Secure EL1                 │
│                                                     │
│  Security mechanisms active:                        │
│  - dm-verity: root filesystem integrity             │
│  - dm-crypt: root filesystem encryption (optional)  │
│  - Kernel lockdown mode                             │
│  - OP-TEE services (RPMB, secure storage, fTPM)     │
└─────────────────────────────────────────────────────┘
```

---

## 14. Debug Register Reading for Boot Status

### HAB Status Registers

The SNVS (Secure Non-Volatile Storage) subsystem maintains boot state registers readable
after boot:

```bash
# Read SNVS_HPSR (HP Status Register) — shows secure boot state
devmem2 0x30370014 w

# Output interpretation:
# Bit [31]: SSM_ST[3:0] — Security State Machine state
#   0x0: Init
#   0x8: Non-secure
#   0x9: Trusted
#   0xD: Secure
#   0xF: Fail-secure
# Bit [8]: HAC_STOP — High Assurance Clock
# Bit [0]: RNG_DRVSTOP
```

### Reading Boot Fuse Configuration in U-Boot

```bash
# Read BOOT_CFG1 fuse (Bank 1, Word 3)
fuse read 1 3

# Read SEC_CONFIG fuse (Bank 1, Word 3, bits[1:0])
fuse read 1 3
# If output is: 0x00000002, SEC_CONFIG = Closed (secure boot enforced)
# If output is: 0x00000000, SEC_CONFIG = Open (secure boot NOT enforced)

# Read SRK hash fuses (Bank 3, Words 0-7)
fuse read 3 0
fuse read 3 1
fuse read 3 2
fuse read 3 3
fuse read 3 4
fuse read 3 5
fuse read 3 6
fuse read 3 7
```

### HAB Status Check in U-Boot

```bash
# Check HAB status and list any authentication events
hab_status

# Expected output on secure-booted system:
# HAB Configuration: 0xf0, HAB State: 0x66
# No HAB Events Found!

# Output on failed authentication:
# HAB Configuration: 0xf0, HAB State: 0x66
# --------- HAB Event 1 -----------------
# event data: ...
# STS = HAB_FAILURE (0x33)
# RSN = HAB_INV_SIGNATURE (0x18)
```

---

## 15. Common Boot Failures at ROM Stage

### Failure Mode Matrix

| Symptom | Possible Cause | Diagnostic |
|---------|---------------|------------|
| No UART output at all | ROM not running; clock failure; bad power | Check power rails, crystal |
| UART silent after ~200ms | ROM running, SPL fails to initialize UART | Check SPL IVT/entry address |
| `HAB_INV_SIGNATURE` event | CSF signature mismatch | Re-sign, check key alignment |
| `HAB_INV_CERTIFICATE` event | SRK cert not matching fuse hash | Verify SRK fuse values |
| `HAB_INV_DATUM` event | Image data hash mismatch | Image modified or padded wrong |
| Infinite reset loop | Authentication failure + no serial download | Check SEC_CONFIG, DISABLE_SDOF |
| ROM enters serial download | No valid IVT at expected offset | Check imx-boot write offset |
| SPL loads, then hard faults | SPL linked to wrong address | Check CONFIG_SPL_TEXT_BASE |
| DDR init fails in SPL | Incorrect DDR training firmware | Check DDR firmware blobs |
| `HAB_STS = 0xf0 0x66` | Not actually secure booting (normal!) | Check SEC_CONFIG fuse |

### Debugging with UART

The Boot ROM itself does not produce UART output (the UART is not initialized by ROM). The
first UART output appears from the SPL. If no UART output appears at all after ~500ms, the
ROM is failing before SPL loads.

```
[ 0.000] SPL: U-Boot SPL 2024.04 (Oct 01 2024 - 12:00:00 +0000)
[ 0.100] Normal Boot
[ 0.101] Trying to boot from MMC1
[ 0.200] DDRINFO: start DRAM init
[ 0.700] DDRINFO: DRAM init done
[ 0.701] Trying to boot from MMC1 FIT: found
[ 0.750] ## Loading kernel from FIT Image at 48000000 ...
[ 0.760]    Using 'conf@1' configuration
[ 0.761]    Verifying Hash Integrity ... sha256+ OK
[ 0.800] ## Flattened Device Tree from FIT Image ...
[ 0.810]    Verifying Hash Integrity ... sha256+ OK
[ 0.811] Jumping to U-Boot via ARM Trusted Firmware
```

The key line is `Verifying Hash Integrity ... sha256+ OK`. If this shows `Bad Data CRC` or
`sha256+ error`, the FIT signature verification has failed.

---

## Cross-References

- `01-ivt-and-boot-container.md` — Detailed IVT and container format reference
- `02-ddr-initialization.md` — DDR training deep dive
- `03-boot-mode-and-fuse-configuration.md` — Fuse map and boot mode configuration
- `../07-spl-tf-a-optee/README.md` — SPL, TF-A, and OP-TEE architecture
- `../08-u-boot-secure-boot/README.md` — U-Boot FIT verification
- `../10-image-signing/01-signing-workflows.md` — CSF creation and signing workflow

---

*Chapter 06 — ROM and Boot Stages | Embedded Linux Secure Boot Reference*
