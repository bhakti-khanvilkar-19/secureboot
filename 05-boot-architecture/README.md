# i.MX8MP Boot Architecture

## Learning Objectives

After completing this chapter you will be able to:
- Describe the complete boot sequence from power-on to userspace
- Identify the purpose of ROM, SPL, TF-A, OP-TEE, and U-Boot
- Explain the ARM exception level transitions
- Understand the memory layout at each boot stage
- Read and interpret UART boot output

## Prerequisites

- [04-chain-of-trust](../04-chain-of-trust/README.md)
- [03-root-of-trust](../03-root-of-trust/README.md)

---

## Boot Sequence Overview

```
Power-On Reset (POR)
        │
        ▼ ~0ms
   ROM Code (EL3)
   └─ Boot device detection
   └─ IVT parse at eMMC:0x0
   └─ HABv4 authentication
   └─ Load SPL to OCRAM
        │
        ▼ ~5ms
   SPL (EL3, OCRAM 0x900000)
   └─ Early UART init
   └─ Clock and power init
   └─ DDR firmware load
   └─ DDR training (~500ms)
   └─ Load imx-boot FIT from eMMC
   └─ Extract TF-A + OP-TEE + U-Boot
        │
        ▼ ~600ms
   TF-A BL31 (EL3, 0x960000)
   └─ Secure Monitor setup
   └─ GIC init
   └─ TZASC: memory security config
   └─ Start OP-TEE (BL32)
        │
        ▼ ~650ms
   OP-TEE (EL1-S, 0xFE000000)
   └─ Secure OS init
   └─ TA framework setup
   └─ Return to BL31
        │
        ▼ ~700ms
   U-Boot (EL1-NS, 0x40200000)
   └─ Full board initialization
   └─ MMC, USB, Ethernet probe
   └─ Load fitImage from /boot
   └─ FIT signature verification
   └─ bootm: set up kernel args
        │
        ▼ ~3000ms
   Linux Kernel (EL1-NS, 0x40480000)
   └─ ARM64 startup
   └─ Device tree parse
   └─ Driver initialization
   └─ initramfs execution
   └─ dm-verity mount
   └─ switch_root
        │
        ▼ ~8000ms
   Userspace (EL0-NS)
   └─ systemd PID 1
   └─ Service startup
   └─ Application ready
```

---

## ROM Boot Loader

The ROM bootloader is **immutable** — burned into the SoC at manufacture by NXP. It is the unconditional root of trust.

### Boot Device Selection

Boot mode is selected by `BOOT_MODE[1:0]` pins:
```
BOOT_MODE[1:0] = 00: Boot from fuses (BT_FUSE_SEL=1) or TEST mode
BOOT_MODE[1:0] = 01: Serial download (USB/UART) — recovery mode
BOOT_MODE[1:0] = 10: Internal boot (normal operation)
BOOT_MODE[1:0] = 11: Reserved
```

For production: BOOT_MODE = 10 (Internal Boot) from fuses.

### Boot Device Scanning (Internal Boot)

ROM scans in priority order based on `BOOT_CFG` fuses:
1. eMMC (USDHC3, boot0 partition preferred)
2. SD card (USDHC2)
3. SPI NOR flash
4. USB serial download (fallback)

### IVT Location

ROM reads the IVT (Image Vector Table) from:
- **SD card:** offset `0x400` from partition start
- **eMMC boot0/boot1 partition:** offset `0x0`
- **eMMC user partition:** offset `0x8400`

### HABv4 Authentication

If `SEC_CONFIG[1] = 1` (CLOSED mode):
1. ROM calls `hab_rvt.authenticate_image()`
2. HABv4 parses CSF pointed to by IVT
3. Installs SRK, verifies certificate chain vs fuse hash
4. Verifies image data hash using IMG key
5. **Failure → ROM enters infinite loop (HALT)**

---

## SPL (Secondary Program Loader)

SPL is the first stage executed from flash. It runs in OCRAM (on-chip SRAM, 256KB).

### SPL Responsibilities
1. **Early platform init:** clocks, PMIC, power domains
2. **UART init:** debug console at 115200 baud
3. **DDR initialization:** load DDR firmware, run 1D/2D training
4. **Load boot components:** read full boot image from eMMC
5. **FIT verification:** verify signatures if `CONFIG_SPL_FIT_SIGNATURE=y`
6. **Handoff:** jump to TF-A BL31 entry point

### SPL Memory Constraints

```
OCRAM Total: 256KB (0x900000 – 0x93FFFF)
SPL code:    ~128KB (must fit!)
SPL stack:   16KB
DDR fw buf:  ~64KB (temporary)
```

### DDR Initialization

i.MX8MP uses LPDDR4. Training process:
```
1. Load DDR PHY firmware from eMMC:
   lpddr4_pmu_train_1d_imem.bin (~64KB)
   lpddr4_pmu_train_1d_dmem.bin (~4KB)
   lpddr4_pmu_train_2d_imem.bin (~64KB)
   lpddr4_pmu_train_2d_dmem.bin (~4KB)

2. Run 1D training (read leveling, write leveling)
   ~200ms

3. Run 2D training (eye optimization)
   ~300ms

4. Total DDR init: ~500ms
```

PHYTEC phyCORE-i.MX8MP: 2GB LPDDR4 at 1600 MT/s

---

## TF-A (Trusted Firmware-A)

TF-A implements the ARM Trusted Firmware reference implementation.

### BL31 — EL3 Runtime Firmware

BL31 remains resident at EL3 throughout device operation. It:
- Handles all SMC (Secure Monitor Calls) from lower ELs
- Implements PSCI (Power State Coordination Interface)
- Manages transitions between Secure and Non-Secure worlds

```
BL31 Memory: 0x960000 (Secure OCRAM)
BL31 Size:   ~128KB
EL3 Stack:   Per-CPU, in secure OCRAM
```

### PSCI Services (available to Linux via SMC)
```
PSCI_CPU_ON:          wake secondary cores
PSCI_CPU_OFF:         power down current core
PSCI_SYSTEM_RESET:    system reset
PSCI_SYSTEM_POWEROFF: power off
PSCI_MIGRATE:         not implemented (OP-TEE handles)
```

---

## OP-TEE

OP-TEE runs as BL32 in ARM Secure EL1.

### Services Provided
- **Secure Storage:** files encrypted with HUK-derived key, backed by RPMB
- **Cryptographic Services:** AES, RSA, ECC, SHA via CAAM
- **Trusted Applications:** sandboxed secure services (PKI, key storage, fTPM)
- **HUK (Hardware Unique Key):** device-unique key, never leaves OP-TEE

### Memory Layout

```
OP-TEE: 0xFE000000 – 0xFFFFFFFF (32MB, Secure DRAM)
TEE core: 0xFE000000
TA area:  0xFF000000 (Trusted Applications loaded here)
```

---

## U-Boot

U-Boot is BL33 — the Non-Secure World bootloader. It runs at EL1-NS.

### Key Tasks for Secure Boot

```bash
# U-Boot boot command for secure boot:
setenv bootcmd "run load_fit; run boot_fit"
setenv load_fit "load mmc 2:1 ${fit_addr} fitImage"
setenv boot_fit "bootm ${fit_addr}"
setenv fit_addr "0x40400000"
```

### FIT Verification Flow
1. Load FIT image from /boot partition (MMC 2:1)
2. `fit_check_format()`: validate FIT magic and structure
3. `bootm_find_images()`: locate configuration node
4. `fit_image_verify_required_sigs()`: RSA signature verification
5. `fit_image_hash_verify()`: SHA-256 hash per image
6. Pass verified kernel, DTB, ramdisk addresses to boot

---

## Linux Kernel Boot

The ARM64 Linux kernel is loaded at `0x40480000` (TEXT_OFFSET = 0).

### Startup Sequence
```
arch/arm64/kernel/head.S: _start
→ __primary_switch
→ __primary_switched
→ start_kernel() (init/main.c)
→ setup_arch()
→ of_flat_dt_init_machine()  (device tree)
→ driver init (via initcalls)
→ rest_init()
→ kernel_init() (PID 1 in kernel)
→ ramdisk_execute_command ("/init")
```

### initramfs Execution

The initramfs `/init` script:
1. Mounts proc, sys, dev
2. Loads dm-verity kernel module (if not built-in)
3. Runs `veritysetup open` with root hash
4. Mounts `/dev/mapper/vroot` at `/sysroot`
5. Calls `switch_root /sysroot /sbin/init`

---

## Memory Map During Boot

```
Physical Memory Map (after DDR init):

0x00000000 – 0x0007FFFF: ROM (512KB, NXP ROM code)
0x00900000 – 0x0093FFFF: OCRAM (256KB, SPL runs here)
0x00960000 – 0x0097FFFF: OCRAM (TF-A BL31)
0x40000000 – 0x40200000: DDR (TF-A BL2 temporary)
0x40200000 – 0x403FFFFF: DDR (U-Boot)
0x40400000 – 0x42FFFFFF: DDR (FIT image load area)
0x40480000 – 0x53FFFFFF: DDR (Linux kernel decompressed)
0x60000000 – 0xBFFFFFFF: DDR (Linux user processes)
0xFE000000 – 0xFFFFFFFF: DDR (OP-TEE, Secure only)
```

---

## Cross-References

- [06-rom-and-boot-stages](../06-rom-and-boot-stages/README.md) — ROM and IVT detail
- [07-spl-tf-a-optee](../07-spl-tf-a-optee/README.md) — SPL/TF-A/OP-TEE internals
- [08-u-boot-secure-boot](../08-u-boot-secure-boot/README.md) — U-Boot FIT verification
- [09-fit-images](../09-fit-images/README.md) — FIT image format
