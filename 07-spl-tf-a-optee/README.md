# Chapter 07: SPL, TF-A, and OP-TEE

```
Tested Against:
  - U-Boot SPL: 2023.04 (NXP lf-6.1.55-2.2.0)
  - TF-A (ATF): lf-v2.8 (imx-lf-v2.8)
  - OP-TEE OS: 3.21.0
  - Yocto: kirkstone (NXP lf-6.1.55-2.2.0 BSP)
Last Validated: 2024-Q2
Platform: NXP i.MX8M Plus (phyCORE-i.MX8MP, phyBOARD-Pollux)
```

---

## Overview

Between the ROM handoff and U-Boot reaching the interactive prompt, three separate firmware
components execute in sequence — each in a different CPU privilege level, each performing a
distinct security function. Understanding these three components is not optional for secure boot
engineering: authentication errors are diagnosed here, secure storage is configured here, and the
entire TrustZone separation is established here.

This chapter covers SPL, TF-A BL31, and OP-TEE as a unified system, from their memory
constraints to their interactions with each other and with the hardware security subsystems of the
i.MX8M Plus.

---

## Table of Contents

1. [Boot Stage Context](#1-boot-stage-context)
2. [SPL: Secondary Program Loader](#2-spl-secondary-program-loader)
3. [SPL Memory Constraints](#3-spl-memory-constraints)
4. [SPL Kconfig Security Options](#4-spl-kconfig-security-options)
5. [SPL Build Output](#5-spl-build-output)
6. [SPL Execution Flow](#6-spl-execution-flow)
7. [TF-A Architecture Overview](#7-tf-a-architecture-overview)
8. [TF-A Boot Stages: BL1 through BL33](#8-tf-a-boot-stages-bl1-through-bl33)
9. [ARM Exception Level Transitions](#9-arm-exception-level-transitions)
10. [PSCI Interface](#10-psci-interface)
11. [SMC Calling Convention (SMCCC)](#11-smc-calling-convention-smccc)
12. [OP-TEE: Secure World OS](#12-op-tee-secure-world-os)
13. [OP-TEE Secure Storage: RPMB Backend](#13-op-tee-secure-storage-rpmb-backend)
14. [OP-TEE Cryptographic Services](#14-op-tee-cryptographic-services)
15. [Build Configuration for Each Component](#15-build-configuration-for-each-component)
16. [Authentication Chain Through All Stages](#16-authentication-chain-through-all-stages)
17. [Yocto Recipes](#17-yocto-recipes)
18. [Common Failures and Diagnostics](#18-common-failures-and-diagnostics)

---

## 1. Boot Stage Context

The complete boot sequence from power-on to U-Boot on i.MX8MP:

```
Power-On Reset
  │
  ▼ (immutable ROM)
Boot ROM (EL3)
  │  - Reads BOOT_MODE pins, BOOT_CFG fuses
  │  - Initializes clock, eMMC/SD
  │  - HABv4 authenticates SPL if SEC_CONFIG=Closed
  │  - Loads SPL into OCRAM at 0x920000
  │
  ▼ Jump to 0x920000
SPL (EL3, OCRAM)
  │  - Initializes UART, DDR
  │  - Loads FIT (TF-A + OP-TEE + U-Boot) from eMMC
  │  - Verifies FIT signatures (if CONFIG_SPL_FIT_SIGNATURE=y)
  │  - Extracts BL31, BL32, BL33 into DRAM
  │
  ▼ Jump to TF-A BL31 entry
TF-A BL31 (EL3, secure DRAM)
  │  - Initializes EL3 runtime services
  │  - Sets up PSCI (CPU hotplug, power management)
  │  - Configures GIC-400 interrupt routing
  │  - Establishes Secure Monitor (SMC handling)
  │
  ▼ Launch BL32 (OP-TEE)
OP-TEE OS (Secure EL1, secure DRAM)
  │  - Initializes TEE core
  │  - Registers Trusted Applications (TAs)
  │  - Sets up RPMB secure storage
  │  - Returns to BL31, which then launches BL33
  │
  ▼ Launch BL33 (U-Boot)
U-Boot (Non-secure EL2)
  │  - Board init, network, USB
  │  - Loads kernel FIT image
  │  - Verifies FIT signatures with embedded public key
  │  - bootm → kernel
  │
  ▼
Linux Kernel (EL1)
  OP-TEE runs concurrently in Secure EL1
```

---

## 2. SPL: Secondary Program Loader

SPL (Secondary Program Loader) is a minimal, size-constrained U-Boot variant that runs before
main U-Boot. It exists because the Boot ROM has two hard constraints:

1. The ROM can only load from a raw boot partition — it has no FAT, no ext4, no FIT parser.
2. The ROM must fit the loaded image in OCRAM without DRAM, which limits size to ~128-256 KB.

U-Boot proper (with network stack, USB, filesystem drivers, interactive shell) is far too large
for OCRAM. SPL is a minimal subset that fits in OCRAM and performs exactly the work needed to:
- Initialize DRAM
- Load U-Boot proper (and TF-A, OP-TEE) from the boot device into DRAM
- Hand off execution to TF-A

SPL inherits U-Boot's driver model and Kconfig build system but is compiled as a separate binary
with most features disabled. The build produces `u-boot-spl.bin` as a standalone binary.

### SPL vs U-Boot Proper: Feature Comparison

| Feature | SPL | U-Boot |
|---------|-----|--------|
| Interactive console | No | Yes (disabled in production) |
| DRAM | Not available until SPL initializes it | Always available |
| Filesystem access | Limited (raw eMMC, FIT only) | Full (ext4, FAT, etc.) |
| Network stack | No | Yes |
| USB host | No | Yes |
| FIT image parsing | Yes (with CONFIG_SPL_LOAD_FIT) | Yes |
| FIT signature verification | Yes (with CONFIG_SPL_FIT_SIGNATURE) | Yes |
| OCOTP fuse access | Yes (for HAB check) | Yes |
| DDR init | Yes (primary purpose) | No (DDR already up) |

---

## 3. SPL Memory Constraints

On i.MX8MP, SPL executes entirely in OCRAM (On-Chip RAM) before DRAM is initialized:

```
OCRAM Memory Map on i.MX8MP (total 512KB: 0x900000–0x97FFFF)
─────────────────────────────────────────────────────────────────
Address Range          Size    Content                  Owner
─────────────────────────────────────────────────────────────────
0x900000–0x90FFFF     64KB    ROM reserved (HAB, stack) Boot ROM
0x910000–0x91FFFF     64KB    DDR training workspace    SPL/DDR FW
0x920000–0x93BFFF    112KB    SPL code and rodata       SPL
0x93C000–0x93EFFF     12KB    SPL BSS and data          SPL
0x93F000–0x93FFFF      4KB    SPL stack                 SPL
─────────────────────────────────────────────────────────────────
0x940000–0x97FFFF    256KB    OCRAM upper (available)   SPL staging
─────────────────────────────────────────────────────────────────

DDR Firmware Staging (upper OCRAM):
0x940000–0x95FFFF    128KB    lpddr4_pmu_train_*_imem.bin
0x960000–0x97FFFF    128KB    lpddr4_pmu_train_*_dmem.bin
```

Key constraints derived from this layout:

- `CONFIG_SPL_TEXT_BASE = 0x920000`: SPL must be linked to this address
- Maximum SPL binary size: ~120 KB (includes code, rodata, and some overhead)
- SPL stack is very small (4KB); deep call stacks will corrupt adjacent regions
- DDR firmware blobs are loaded into upper OCRAM before DDR training begins
- The ROM uses OCRAM from 0x900000 to 0x91FFFF; SPL must not overlap this

If the SPL binary exceeds ~120 KB, the build will fail with:
```
spl/u-boot-spl: section '.bss' will not fit in region 'sram'
```

This means you must disable features. Common fixes:
- `CONFIG_SPL_FIT_IMAGE_TINY=y`: reduce FIT parsing overhead
- Disable unused SPL drivers
- `CONFIG_SPL_BOARD_INIT=n` if custom board init code is large
- Use LTO (Link-Time Optimization) in SPL build

---

## 4. SPL Kconfig Security Options

Critical security-relevant Kconfig options for SPL:

### FIT Image Loading and Verification

```kconfig
# Enable FIT image format in SPL (required to load TF-A/OP-TEE/U-Boot)
CONFIG_SPL_FIT=y

# Enable FIT signature verification in SPL
# Without this, SPL loads FIT images without verifying their signatures
# This is the critical option for SPL-level authentication
CONFIG_SPL_FIT_SIGNATURE=y

# Enable the SPL to load a FIT image (as opposed to raw binaries)
# Required to load imx-boot FIT container
CONFIG_SPL_LOAD_FIT=y

# RSA support in SPL (required for FIT signature verification)
CONFIG_SPL_RSA=y

# Software RSA exponentiation (used when no hardware accelerator in SPL context)
CONFIG_SPL_RSA_SOFTWARE_EXP=y

# Cryptographic framework in SPL
CONFIG_SPL_CRYPTO=y

# Hash library in SPL (required for SHA-256 verification)
CONFIG_SPL_HASH=y

# SHA-256 in SPL (required for FIT hash verification)
CONFIG_SPL_SHA256=y

# SHA-384 in SPL (stronger alternative to SHA-256)
CONFIG_SPL_SHA384=y
```

### Driver Model

```kconfig
# Driver model in SPL — required for modern device drivers
# Without this, only legacy drivers are available
CONFIG_SPL_DM=y

# MMC driver via driver model (for loading from eMMC/SD)
CONFIG_SPL_DM_MMC=y

# GPIO support in SPL (required for board control signals)
CONFIG_SPL_DM_GPIO=y
```

### Console and Debug

```kconfig
# Serial (UART) support in SPL — essential for boot-time diagnostics
CONFIG_SPL_SERIAL=y

# Early debug UART — available before driver model init
# Allows output from the very first SPL instructions
CONFIG_DEBUG_UART=y

# i.MX UART driver for debug UART
CONFIG_DEBUG_UART_MX6=y

# UART2 on i.MX8MP: base address 0x30890000
CONFIG_DEBUG_UART_BASE=0x30890000

# UART clock: 24 MHz reference clock
CONFIG_DEBUG_UART_CLOCK=24000000
```

### Board Initialization

```kconfig
# Custom board_init_f() hook in SPL
# Used for i.MX8MP-specific power sequencing before DDR init
CONFIG_SPL_BOARD_INIT=y

# Enable SPL watchdog support (reset on hang)
CONFIG_SPL_WATCHDOG=y

# Pinctrl in SPL (for setting pad configurations before DDR init)
CONFIG_SPL_PINCTRL=y
```

### FIT Verbosity

```kconfig
# Print FIT verification details during boot
# Essential for debugging; disable in production for smaller size and speed
CONFIG_FIT_VERBOSE=y

# Master FIT signature verification flag (for U-Boot proper, set in SPL context)
CONFIG_FIT_SIGNATURE=y
```

---

## 5. SPL Build Output

The SPL build produces several output files in the `spl/` subdirectory:

```
spl/
├── u-boot-spl          # ELF binary (debug symbols, not flashed)
├── u-boot-spl.bin      # Raw binary (what gets flashed)
├── u-boot-spl.map      # Linker map (use for size analysis)
├── u-boot-spl-dtb.bin  # SPL binary with appended device tree
└── u-boot-spl.sym      # Symbol table
```

The `u-boot-spl.bin` file is the binary embedded into the boot container assembled by
`imx-mkimage`. Analyzing the map file is important for size optimization:

```bash
# Check SPL size
wc -c spl/u-boot-spl.bin
# Should be < ~120000 bytes (120 KB)

# Find the largest contributors
grep -E "^\.[a-z]" spl/u-boot-spl.map | sort -k2 -rh | head -20

# Check section sizes explicitly
arm-linux-gnueabihf-size spl/u-boot-spl
```

---

## 6. SPL Execution Flow

Detailed execution trace from ROM handoff to TF-A jump:

```
ROM jumps to 0x920000 (SPL _start)
  │
  ▼
_start (arch/arm/cpu/armv8/start.S)
  │  - Set up exception vectors
  │  - Initialize registers (x0-x28 cleared)
  │  - Set up early stack in OCRAM
  │
  ▼
lowlevel_init() [board/freescale/imx8mp/ or phytec/]
  │  - Minimal early hardware init
  │  - Enable OCRAM ECC (if configured)
  │
  ▼
board_init_f() [common/spl/spl.c → board/]
  │  - Call init_sequence_f[] function array
  │  - Early UART init (debug_uart_init() → 0x30890000)
  │  - First UART output: "U-Boot SPL 2023.04..."
  │
  ▼
spl_early_init() [common/spl/spl.c]
  │  - DM (Driver Model) initialization
  │  - Device tree scan
  │  - Power PMIC initialization (PCA9450 on phyCORE)
  │
  ▼
board_init_r() [board/phytec/phycore_imx8mp/]
  │  - DDR firmware load from eMMC boot partition:
  │      Load lpddr4_pmu_train_1d_imem_202006.bin to 0x7E0000
  │      Load lpddr4_pmu_train_1d_dmem_202006.bin to 0x7E8000
  │      Load lpddr4_pmu_train_2d_imem_202006.bin to 0x7E0000
  │      Load lpddr4_pmu_train_2d_dmem_202006.bin to 0x7E8000
  │
  ▼
ddr_init() [drivers/ddr/imx/]
  │  - Configure DDR controller registers
  │  - Execute 1D training: ~200ms
  │  - Execute 2D training: ~300ms
  │  - DDR now operational at full speed
  │  - Console output: "DDRINFO: DRAM init done"
  │
  ▼
spl_mmc_load_image() [common/spl/spl_mmc.c]
  │  - Open eMMC (mmc 0, boot partition 0)
  │  - Read FIT image header from eMMC offset 0
  │  - Determine FIT image load address (0x48000000 in DRAM)
  │  - Copy FIT image to DRAM
  │
  ▼ (if CONFIG_SPL_FIT_SIGNATURE=y)
fit_image_verify_required_sigs()
  │  - Parse FIT signature node
  │  - Load public key from SPL's embedded key (from u-boot.dtb)
  │  - Verify SHA-256 hash of each FIT image component
  │  - Verify RSA-2048 signature over configuration
  │  - On failure: panic("Failed to verify FIT image")
  │
  ▼
spl_fit_select_fdt() → extract BL31, BL32, BL33 addresses
  │
  ▼
jump_to_image_no_args() [arch/arm/lib/spl.c]
  │  - Flush D-cache
  │  - Jump to TF-A BL31 entry address (e.g., 0x00970000)
```

Console output during a successful boot (with CONFIG_FIT_VERBOSE=y):

```
U-Boot SPL 2023.04 (Oct 01 2024 - 12:00:00 +0000)
PMIC: PMIC_PCA9450 is found
Normal Boot
DDRINFO: start DRAM init
DDRINFO: DRAM rate 4000MTS
DDRINFO: 1D training start...
DDRINFO: 1D training done
DDRINFO: 2D training start...
DDRINFO: 2D training done
DDRINFO: DRAM init done
Trying to boot from MMC1
## Loading kernel from FIT Image at 48000000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ... sha256+ OK
   Verified OK, SIGNATURE sha256,rsa2048:fit-key (1)
## Loading fdt from FIT Image at 48000000 ...
   Verifying Hash Integrity ... sha256+ OK
Jumping to U-Boot via ARM Trusted Firmware
```

---

## 7. TF-A Architecture Overview

TF-A (Trusted Firmware-A, formerly ARM Trusted Firmware or ATF) is an open-source reference
implementation of secure world software for ARMv8-A processors. On i.MX8MP, it serves as:

1. **EL3 Secure Monitor**: The only code that runs at Exception Level 3 after ROM handoff.
   All transitions between secure and non-secure world pass through TF-A's monitor.

2. **PSCI Provider**: Implements the Power State Coordination Interface — the standard mechanism
   for Linux to request CPU hotplug, system suspend/resume, and system reset/shutdown.

3. **Platform Initializer**: Configures GIC (interrupt routing), TZASC (TrustZone Address Space
   Controller), and CAAM (Cryptographic Acceleration and Assurance Module) for secure use.

4. **Boot Orchestrator**: Loads and launches OP-TEE (BL32) in Secure EL1, then launches U-Boot
   (BL33) in Non-secure EL2.

TF-A source tree layout for i.MX8MP:

```
trusted-firmware-a/
├── plat/imx/
│   ├── common/              # Shared i.MX platform code
│   │   ├── imx_bl31_setup.c # Generic BL31 setup
│   │   ├── imx_gpc.c        # General Power Controller
│   │   ├── imx_interrupt_mgmt.c
│   │   └── imx_sip_handler.c # SiP (Silicon Provider) SMC handlers
│   └── imx8mp/
│       ├── imx8mp_bl31_setup.c # i.MX8MP-specific BL31 setup
│       ├── imx8mp_bl2_el3_setup.c # BL2-as-EL3 variant
│       ├── platform.mk         # Build configuration
│       ├── include/
│       │   └── platform_def.h  # Memory map definitions
│       └── imx8mp_caam.c       # CAAM security configuration
├── drivers/
│   ├── auth/                # Authentication framework
│   │   ├── auth_mod.c       # Core authentication logic
│   │   ├── mbedtls/
│   │   │   ├── mbedtls_x509_parser.c # Certificate parsing
│   │   │   └── mbedtls_crypto.c      # Crypto primitives
│   │   └── tbbr/
│   │       └── tbbr_cot.c   # Chain of Trust for Trusted Board Boot
│   ├── imx/
│   │   ├── clk/             # Clock drivers
│   │   └── uart/            # UART driver
│   └── mmc/                 # MMC/eMMC driver (for BL2 image loading)
├── lib/
│   ├── el3_runtime/         # EL3 runtime context management
│   └── psci/                # PSCI implementation
├── include/
│   └── common/
│       └── tbbr/
│           └── tbbr_img_def.h # Image type definitions for CoT
└── Makefile
```

---

## 8. TF-A Boot Stages: BL1 through BL33

TF-A defines a structured boot stage naming convention. On i.MX8MP, not all stages are used in
the classical form:

### BL1: First Boot Loader Stage

**Classical role**: Loaded by ROM into OCRAM, loads BL2 from storage into DRAM.

**i.MX8MP reality**: NXP's implementation does not use a traditional BL1. The Boot ROM loads SPL
directly, and SPL loads the TF-A FIP (Firmware Image Package) or individual binaries. The
"BL1-equivalent" work is performed by the Boot ROM + SPL.

### BL2: Second Boot Loader Stage

**Classical role**: Runs in secure memory, loads BL31/BL32/BL33, performs Trusted Board Boot
authentication.

**i.MX8MP reality**: On i.MX8MP, TF-A is typically built as `BL2_AT_EL3`, meaning BL2 runs
in EL3 mode and does not require a separate BL1. SPL jumps directly to this BL2-at-EL3, which:
- Authenticates subsequent boot images (if TRUSTED_BOARD_BOOT=1)
- Loads BL31, BL32, BL33 from the FIP
- Sets up the memory layout for secure world

For the NXP i.MX8MP BSP flow without TRUSTED_BOARD_BOOT, SPL itself performs the image loading
and the first code in TF-A to execute is BL31.

### BL31: EL3 Runtime Firmware

**Role**: Permanent resident of EL3. This code runs for the entire lifetime of the system.

**Memory**: Typically placed in secure DRAM (e.g., 0x00960000–0x0097FFFF). The TrustZone
Address Space Controller (TZASC) protects this region from non-secure world access.

**Function**:
- Handles all SMC (Secure Monitor Call) exceptions
- Routes SMCs to registered service handlers (PSCI, SiP, OP-TEE dispatcher)
- Manages context switching between secure (EL1-S) and non-secure (EL1-NS/EL2-NS) worlds
- Never returns to SPL; it is the permanent EL3 monitor

### BL32: Secure Payload (OP-TEE)

**Role**: Trusted OS running in Secure EL1. Provides Trusted Execution Environment services.

**Memory**: Placed in a TZASC-protected secure DRAM region (e.g., 0xFE000000–0xFEFFFFFF on
some configurations, or a configurable region based on OP-TEE build options).

**Interaction**: BL31 launches BL32, OP-TEE initializes and signals completion via SMC to BL31,
which then launches BL33.

### BL33: Non-Secure Payload (U-Boot)

**Role**: The non-trusted bootloader that runs in Non-secure EL2.

**Memory**: Placed in non-secure DRAM (e.g., 0x40200000). Accessible from Linux userspace in
principle (though ASLR and other protections apply to the running kernel, not U-Boot).

**Interaction**: BL31 transfers control to BL33 after BL32 initialization completes. From BL33
onward, EL3 is only re-entered via PSCI calls or other SMCs from the OS.

### Stage Summary Table

| Stage | Binary | EL | Memory Region | Purpose |
|-------|--------|----|---------------|---------|
| ROM | (in silicon) | EL3 | ROM | Load and authenticate SPL |
| SPL (BL1-equiv) | u-boot-spl.bin | EL3 | OCRAM 0x920000 | DDR init, load FIT |
| BL31 | bl31.bin | EL3 | Secure DRAM | Permanent EL3 monitor |
| BL32 | tee.bin | Secure EL1 | Secure DRAM | OP-TEE TEE OS |
| BL33 | u-boot-nodtb.bin | Non-secure EL2 | Non-secure DRAM | Load and verify kernel |

---

## 9. ARM Exception Level Transitions

ARMv8-A defines four Exception Levels (EL0–EL3), where higher numbers are more privileged:

```
Exception Level Hierarchy on i.MX8MP
────────────────────────────────────────────────────────────────────────
EL3  (Secure Monitor): TF-A BL31
│    - Highest privilege, can access all memory
│    - Controls EL2/EL1 security state via SCR_EL3.NS bit
│    - Handles all SMC instructions
│    - Runs in AArch64
│
├──► Secure World (SCR_EL3.NS=0)
│    │
│    ├── EL1-S (Secure EL1): OP-TEE OS
│    │   - Trusted OS kernel
│    │   - Controls Secure EL0 via HCR_EL2 (not used in S-EL1 context)
│    │
│    └── EL0-S (Secure EL0): Trusted Applications (TAs)
│        - User-mode code in secure world
│        - Sandboxed from OP-TEE OS by MMU
│
└──► Non-Secure World (SCR_EL3.NS=1)
     │
     ├── EL2-NS (Non-secure EL2): Hypervisor or U-Boot
     │   - U-Boot runs here (no hypervisor)
     │   - Linux hypervisor (KVM) would run here
     │
     ├── EL1-NS (Non-secure EL1): Linux Kernel
     │   - Kernel runs here after hypervisor (or directly if EL2 unused)
     │
     └── EL0-NS (Non-secure EL0): Linux Userspace
         - Normal application processes
```

### Key Transition Mechanisms

**EL3 → Secure EL1 (BL31 → OP-TEE)**:
- BL31 uses `ERET` with `SPSR_EL3` set for Secure EL1 and `ELR_EL3` = OP-TEE entry point
- Sets `SCR_EL3.NS=0`, `SCR_EL3.IRQ=1`, `SCR_EL3.FIQ=1`

**EL3 → Non-secure EL2 (BL31 → U-Boot/Linux)**:
- BL31 uses `ERET` with `SPSR_EL3` set for Non-secure EL2 and `ELR_EL3` = U-Boot entry
- Sets `SCR_EL3.NS=1`

**Non-secure EL1 → Secure EL1 (Linux → OP-TEE)**:
- Linux optee driver issues `SMC` instruction (or `HVC` via OP-TEE in virtualization mode)
- TF-A BL31 traps the SMC at EL3
- BL31 dispatches to `opteed_smc_handler()` in the OP-TEE dispatcher
- BL31 saves non-secure context, restores secure context, ERets to OP-TEE

**Secure EL1 → Non-secure EL1 (OP-TEE → Linux)**:
- OP-TEE issues SMC to signal completion
- BL31 saves secure context, restores non-secure context, ERets to Linux

---

## 10. PSCI Interface

PSCI (Power State Coordination Interface, ARM DEN0022D) is the standard firmware interface for
power management on ARMv8-A systems. It allows the OS to control CPU power states without
requiring platform-specific kernel drivers.

TF-A implements PSCI on i.MX8MP. Linux calls PSCI via SMC instructions.

### Core PSCI Functions Used on i.MX8MP

**CPU_ON (0xC4000003)**:
- Powers on a secondary CPU core
- Parameters: target CPU MPIDR, entry point address, context ID
- Used by Linux SMP initialization when bringing up cores 1-3 of the Cortex-A53
- TF-A implementation: `plat/imx/common/imx_psci.c`

```c
/* Linux kernel call to bring up secondary CPU: */
psci_cpu_on(cpu_mpidr, __pa(secondary_startup), 0);
/* Translates to SMC:
   x0 = 0xC4000003 (CPU_ON)
   x1 = 0x0000000000000100 (MPIDR for CPU1)
   x2 = secondary_startup physical address
   x3 = 0 (context ID)
*/
```

**CPU_OFF (0x84000002)**:
- Powers off the calling CPU core
- Used when Linux CPU hotplug removes a core
- The core is powered off and can only be re-enabled via CPU_ON from another core

**SYSTEM_RESET (0x84000009)**:
- Performs a platform-level system reset
- Used by Linux `reboot` command and kernel panic reboot
- TF-A implementation calls `imx_system_reset()` → writes to WDOG register

**SYSTEM_OFF (0x84000008)**:
- Powers off the system
- Used by Linux `poweroff` command
- TF-A implementation calls `imx_system_off()` → SNVS LPCR register

**AFFINITY_INFO (0xC4000004)**:
- Queries the power state of a CPU
- Returns: CPU_ON (0), CPU_OFF (1), CPU_ON_PENDING (2)

### PSCI Version Return

```
PSCI_VERSION (0x84000000):
  Returns: 0x00020000 = PSCI version 2.0
```

Linux verifies PSCI version compatibility at boot time. If the version is too old, SMP and
power management may not work correctly.

---

## 11. SMC Calling Convention (SMCCC)

The ARM Secure Monitor Call Calling Convention (SMCCC, ARM DEN0028C) defines how software
invokes EL3 services via the `SMC` instruction.

### Register Convention

```
SMC Invocation:
  x0:      Function ID (32-bit, in w0)
           Bits [31]:    1=Fast call, 0=Yielding call
           Bits [30]:    1=SMC64 (64-bit), 0=SMC32 (32-bit)
           Bits [29:24]: Service type (OEN - Owning Entity Number)
           Bits [23:16]: Reserved
           Bits [15:0]:  Function number

  x1-x7:   Arguments (varies by function)

SMC Return:
  x0:      Return value (0=success, negative=error)
  x1-x3:   Additional return values (service-specific)
  x4-x17:  Restored to values at SMC entry (caller-saved, preserved)
```

### Service Type (OEN) Values

| OEN | Bits [29:24] | Service |
|-----|-------------|---------|
| ARM Architecture | 0x00 | PSCI, SDEI, etc. |
| CPU Service | 0x01 | CPU-specific services |
| SiP Service | 0x02 | Silicon Provider (NXP-specific SMCs) |
| OEM Service | 0x03 | OEM-specific services |
| Standard Secure | 0x04 | Trusted OS calls (OP-TEE uses 0x32) |
| Trusted Application | 0x30–0x31 | TA calls via OP-TEE |
| OP-TEE | 0x32 | OP-TEE-specific SMC calls |

### NXP SiP Services on i.MX8MP

NXP implements platform-specific SMCs in TF-A's SiP service layer. These are called by Linux
drivers for platform control:

```c
/* From plat/imx/common/imx_sip_handler.c */
#define IMX_SIP_GPC         0xC2000000  /* GPC (power controller) ops */
#define IMX_SIP_CPUFREQ     0xC2000001  /* CPU frequency control */
#define IMX_SIP_WAKEUP_SRC  0xC2000002  /* Wakeup source configuration */
#define IMX_SIP_DDR_DVFS    0xC2000004  /* DDR DVFS */
```

---

## 12. OP-TEE: Secure World OS

OP-TEE (Open Portable Trusted Execution Environment) is an open-source Trusted OS for the ARM
TrustZone secure world. On i.MX8MP, OP-TEE provides:

- **TEE Core**: The Secure EL1 operating system that manages Trusted Applications
- **TA Framework**: Sandboxed execution environment for Trusted Applications
- **REE Client Interface**: Communication channel between Linux (REE) and OP-TEE (TEE)
- **Secure Storage**: Cryptographically protected persistent storage (RPMB backend)
- **Cryptographic Services**: Hardware-accelerated crypto via CAAM
- **fTPM**: Firmware TPM 2.0 implementation (optional TA)

### Architecture

```
Non-Secure World (Linux)           Secure World (OP-TEE)
─────────────────────────          ─────────────────────
libteec.so                         TEE Core (optee_os)
  │                                  │
  │ ioctl()                          │ TA management
  ▼                                  │
/dev/tee0 (kernel driver)           ├── TA: fTPM
  │                                 ├── TA: Secure Key Storage
  │ SMC                             ├── TA: PKCS#11
  ▼                                 └── TA: Your custom TA
TF-A BL31 (EL3 dispatcher)
  │
  └──► OP-TEE (Secure EL1)

tee-supplicant (userspace daemon)
  │  - Handles OP-TEE requests that need REE resources
  │  - RPMB access, filesystem access for REE-FS storage
  │  - Loads TA binaries from /lib/optee_armtz/
  ▼
/dev/teepriv0 + /dev/rpmb0
```

### Trusted Applications (TAs)

TAs are ELF binaries signed with the OP-TEE TA signing key. They execute in Secure EL0 under
the supervision of the OP-TEE core in Secure EL1.

```
TA locations:
/lib/optee_armtz/          - User-installed TAs (loaded by tee-supplicant)
  <uuid>.ta                  - Signed TA binary
                             Example: ffd2bded-ab7d-4988-95ee-e4962fff7154.ta
                             (PKCS#11 TA from optee_pkcs11)

Built-in TAs (compiled into optee_os):
  - Pseudo-TAs (PTAs): privileged, built-in, no loading needed
  - Examples: RPMB PTA, Benchmark PTA, Stats PTA
```

TA signing command (from OP-TEE build system):

```bash
python3 scripts/sign_encrypt.py \
    --key ta-signing-key.pem \
    --uuid ffd2bded-ab7d-4988-95ee-e4962fff7154 \
    --ta-version 1 \
    --in ta.elf \
    --out ffd2bded-ab7d-4988-95ee-e4962fff7154.ta
```

The TA signing key public component is compiled into `optee_os` during the build. Only TAs
signed with the matching private key can be loaded.

### REE Client Flow

```c
/* Normal world application calling a Trusted Application */
#include <tee_client_api.h>

TEEC_Context ctx;
TEEC_Session sess;
TEEC_UUID uuid = { 0xffd2bded, 0xab7d, 0x4988,
                   { 0x95, 0xee, 0xe4, 0x96, 0x2f, 0xff, 0x71, 0x54 } };

/* 1. Initialize context (opens /dev/tee0) */
TEEC_InitializeContext(NULL, &ctx);

/* 2. Open session with TA (triggers tee-supplicant to load TA) */
TEEC_OpenSession(&ctx, &sess, &uuid, TEEC_LOGIN_PUBLIC, NULL, NULL, &ret_orig);

/* 3. Invoke TA command */
TEEC_Operation op = { 0 };
op.paramTypes = TEEC_PARAM_TYPES(TEEC_VALUE_INPUT, TEEC_MEMREF_TEMP_OUTPUT,
                                  TEEC_NONE, TEEC_NONE);
op.params[0].value.a = command_id;
TEEC_InvokeCommand(&sess, TA_CMD_MY_OPERATION, &op, &ret_orig);

/* 4. Clean up */
TEEC_CloseSession(&sess);
TEEC_FinalizeContext(&ctx);
```

---

## 13. OP-TEE Secure Storage: RPMB Backend

OP-TEE supports two secure storage backends:

### REE Filesystem (CFG_REE_FS=y)

- Stores encrypted files on the normal world filesystem (typically `/data/tee/`)
- Encryption key derived from HUK (Hardware Unique Key) via CAAM
- **Weakness**: Files are stored in the REE; an attacker with write access to the filesystem
  can delete or corrupt secure storage objects. OP-TEE detects corruption but cannot
  distinguish deletion from corruption.
- **Use case**: Development and platforms without eMMC RPMB support

### RPMB (Replay Protected Memory Block, CFG_RPMB_FS=y)

RPMB is a special authenticated storage partition on eMMC devices. Access to RPMB requires
a shared secret (RPMB authentication key) programmed at device provisioning time. All reads
and writes are HMAC-SHA-256 authenticated, and RPMB provides a write counter that prevents
replay attacks.

```
RPMB Architecture
─────────────────
OP-TEE Core (Secure EL1)
  │  - RPMB filesystem implementation
  │  - Generates requests with RPMB authentication key
  │
  ▼ SMC to normal world (via OP-TEE PTA)
tee-supplicant (Normal World)
  │  - Receives RPMB access requests from OP-TEE
  │  - Issues authenticated RPMB commands to eMMC
  │
  ▼ ioctl to kernel MMC driver
/dev/mmcblk0rpmb
  │
  ▼
eMMC RPMB partition (hardware authenticated)
  - Write counter prevents replay
  - HMAC-SHA-256 on all operations
  - Typically 128KB–4MB depending on eMMC part
```

RPMB provisioning during manufacturing:

```bash
# Generate RPMB authentication key (256-bit)
# This key must be stored securely and programmed into every device
# The same key must be provisioned to OP-TEE's secure storage

# From OP-TEE build: the RPMB key is derived from HUK via CAAM on i.MX8MP
# No explicit provisioning needed if CFG_RPMB_KEY_DERIVED_FROM_HUK=y

# Verify RPMB is operational:
tee-supplicant &
# Run OP-TEE test suite:
xtest -t regression 1000-1099

# Check RPMB device:
ls -la /dev/mmcblk*rpmb
# /dev/mmcblk2rpmb -> eMMC RPMB partition on phyCORE-i.MX8MP
```

---

## 14. OP-TEE Cryptographic Services

OP-TEE exposes a GlobalPlatform-compliant TEE cryptographic API to Trusted Applications.
On i.MX8MP, the CAAM hardware accelerator is available to OP-TEE:

```
Cryptographic Services Available to TAs
────────────────────────────────────────
Symmetric Ciphers:  AES-ECB, AES-CBC, AES-CTR, AES-XTS, AES-GCM, AES-CCM
                    DES, 3DES (legacy)
Hash:               MD5, SHA-1, SHA-224, SHA-256, SHA-384, SHA-512
MAC:                HMAC-MD5, HMAC-SHA-*, AES-CMAC
Asymmetric:         RSA-1024/2048/4096 (sign/verify/encrypt/decrypt)
                    ECDSA (P-192, P-256, P-384, P-521)
                    ECDH
Key Derivation:     HKDF, PBKDF2, SP800-56A
RNG:                CAAM DRNG (hardware entropy)
Secure Keys:        Keys stored in OP-TEE secure storage, never exposed to REE
HUK Access:         Via TEE_DeriveKey() from Pseudo-TA only
```

### Hardware Unique Key (HUK)

The HUK is a device-unique key generated by the CAAM from OTP (One-Time Programmable) fuses.
On i.MX8MP:

1. CAAM generates a Master Key from the device's OTP Master Key fuses (512-bit field in OCOTP)
2. The CAAM Master Key is used to derive the HUK via a one-way function
3. HUK is accessible only through the CAAM hardware — never exposed as a readable value to software
4. OP-TEE uses the HUK to derive per-TA storage keys using the TA's UUID as diversification input

```
OTP Master Key (CAAM fuses, provisioned at manufacturing)
    │
    ▼ CAAM one-way derivation
HUK (Hardware Unique Key, never leaves CAAM)
    │
    ├──► OP-TEE RPMB authentication key derivation
    ├──► OP-TEE secure storage encryption key (per-TA)
    │       HUK || TA_UUID → KDF → ta_storage_key
    └──► fTPM seed (for TPM persistent storage)
```

This means device-to-device isolation is hardware-enforced: even if two devices run identical
software and have the same OTA update applied, their secure storage contents cannot be decrypted
on each other's hardware.

---

## 15. Build Configuration for Each Component

### SPL (U-Boot SPL)

```bash
# Set target platform defconfig
make phycore-imx8mp_defconfig

# SPL is built automatically as part of the U-Boot build
make -j$(nproc) \
    CROSS_COMPILE=aarch64-linux-gnu- \
    ARCH=arm64

# SPL binary
ls -la spl/u-boot-spl.bin
```

### TF-A (BL31)

```bash
cd trusted-firmware-a

make \
    PLAT=imx8mp \
    CROSS_COMPILE=aarch64-linux-gnu- \
    BUILD_BASE=build \
    TRUSTED_BOARD_BOOT=0 \
    GENERATE_COT=0 \
    BL33=../u-boot/u-boot-nodtb.bin \
    BL32=../optee_os/out/arm-plat-imx/core/tee-raw.bin \
    SPD=opteed \
    DEBUG=0 \
    LOG_LEVEL=20 \
    all fip

# Output:
ls build/imx8mp/release/
# bl31.bin      - TF-A EL3 runtime
# fip.bin       - Firmware Image Package (BL31+BL32+BL33)
```

For debug builds with console output:

```bash
make PLAT=imx8mp DEBUG=1 LOG_LEVEL=50 all
# LOG_LEVEL: 0=NONE, 10=ERROR, 20=NOTICE, 30=WARNING, 40=INFO, 50=VERBOSE
```

### OP-TEE OS

```bash
cd optee_os

make \
    PLATFORM=imx-mx8mpevk \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_core=aarch64-linux-gnu- \
    CROSS_COMPILE_ta_arm64=aarch64-linux-gnu- \
    CFG_ARM_GICV3=y \
    CFG_RPMB_FS=y \
    CFG_RPMB_FS_DEV_ID=0 \
    CFG_CORE_HEAP_SIZE=0x110000 \
    CFG_TEE_CORE_LOG_LEVEL=2 \
    CFG_WITH_PAGER=n \
    CFG_HWSUPP_MEM_PERM_PXN=y \
    all

# Output:
ls out/arm-plat-imx/core/
# tee.elf            - ELF with debug symbols
# tee-raw.bin        - Raw binary (= BL32 input for TF-A)
# tee-pager.bin      - Paged variant (if CFG_WITH_PAGER=y)
# tee-pageable.bin   - Pageable section
```

---

## 16. Authentication Chain Through All Stages

The complete chain of trust from ROM to kernel:

```
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER 1: HABv4 (ROM-level authentication)                           │
│                                                                      │
│  Root: OTP fuses (SRK hash, 256 bits burned at manufacturing)        │
│  Authenticates: SPL (u-boot-spl.bin)                                 │
│  Mechanism: RSA-2048 + SHA-256 via CAAM                              │
│  Tool: NXP Code Signing Tool (CST)                                   │
│  Failure mode: ROM halts (SEC_CONFIG=Closed), or warning (Open)      │
└──────────────────────────────────────────────────────────────────────┘
                  │ SPL authenticated
                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER 2: SPL FIT Signature Verification                             │
│                                                                      │
│  Root: Public key embedded in SPL binary (from u-boot.dtb)           │
│  Authenticates: FIT image containing TF-A + OP-TEE + U-Boot          │
│  Mechanism: RSA-2048 + SHA-256                                       │
│  Tool: mkimage -F (FIT signing)                                      │
│  Failure mode: SPL panics, boot halts                                │
└──────────────────────────────────────────────────────────────────────┘
                  │ FIT (TF-A+OP-TEE+U-Boot) authenticated
                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER 3: TF-A Trusted Board Boot (optional, TRUSTED_BOARD_BOOT=1)  │
│                                                                      │
│  Root: ROTPK (Root of Trust Public Key) — hash in fuses              │
│  Authenticates: BL32 (OP-TEE), BL33 (U-Boot) via X.509 certificates │
│  Mechanism: RSA-2048 + SHA-256 (mbed TLS)                           │
│  Tool: TF-A cert_create tool                                         │
│  Failure mode: TF-A panics, system halts                            │
│  Note: Not used in standard NXP BSP (SPL handles authentication)     │
└──────────────────────────────────────────────────────────────────────┘
                  │ TF-A+OP-TEE+U-Boot verified
                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER 4: U-Boot FIT Image Verification                              │
│                                                                      │
│  Root: Public key in U-Boot's compiled-in DTB (/signature/key-* node)│
│  Authenticates: Kernel FIT image (kernel + DTB + initramfs)          │
│  Mechanism: RSA-2048 + SHA-256 (software RSA in U-Boot)              │
│  Tool: mkimage -F (FIT signing)                                      │
│  Failure mode: bootm fails, U-Boot does not boot the kernel          │
└──────────────────────────────────────────────────────────────────────┘
                  │ Kernel FIT verified
                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER 5: dm-verity (Runtime filesystem integrity)                   │
│                                                                      │
│  Root: verity root hash embedded in kernel FIT (signed in LAYER 4)   │
│  Authenticates: Root filesystem block-by-block during runtime        │
│  Mechanism: SHA-256 Merkle tree over block device                    │
│  Tool: veritysetup (cryptsetup)                                      │
│  Failure mode: I/O error on tampered blocks, kernel panics or remount│
└──────────────────────────────────────────────────────────────────────┘
```

---

## 17. Yocto Recipes

### imx-atf (TF-A Recipe)

```
meta-imx/meta-bsp/recipes-bsp/imx-atf/
├── imx-atf_2.8.bb      # Main recipe
└── imx-atf_2.8.bbappend (in meta-phytec or meta-bsp)
```

Key recipe variables:
```bitbake
# From imx-atf_2.8.bb:
SRC_URI = "git://github.com/nxp-imx/imx-atf.git;protocol=https;branch=lf_v2.8"
SRCREV = "..."

EXTRA_OEMAKE += "PLAT=imx8mp"
EXTRA_OEMAKE += "SPD=opteed"
EXTRA_OEMAKE += "BUILD_BASE=${B}"

# Output installed to:
do_install() {
    install -d ${D}/firmware
    install -m 0644 ${B}/imx8mp/release/bl31.bin ${D}/firmware/
}
```

### optee-os (OP-TEE OS Recipe)

```
meta-optee/recipes-security/optee/
├── optee-os_3.21.0.bb
└── optee-os-imx_%.bbappend
```

Key recipe variables:
```bitbake
# Platform-specific append:
OPTEEMACHINE = "imx-mx8mpevk"
EXTRA_OEMAKE += "CFG_ARM_GICV3=y"
EXTRA_OEMAKE += "CFG_RPMB_FS=y"
EXTRA_OEMAKE += "CFG_RPMB_FS_DEV_ID=0"
EXTRA_OEMAKE += "CFG_CORE_HEAP_SIZE=0x110000"

# OP-TEE TA signing key (for production, replace with HSM-backed key):
TA_SIGN_KEY = "${TOPDIR}/../keys/optee-ta-signing-key.pem"
```

### optee-client (tee-supplicant Recipe)

```
meta-optee/recipes-security/optee/
└── optee-client_3.21.0.bb
```

```bitbake
# Installs:
# /usr/sbin/tee-supplicant         - daemon for OP-TEE REE services
# /usr/lib/libteec.so.1            - TEEC API library
# /usr/lib/libckteec.so.1          - PKCS#11 interface library
# /usr/include/tee_client_api.h    - API headers
```

### MACHINE_FEATURES for OP-TEE

In your Yocto machine configuration:

```bitbake
# meta-phytec/conf/machine/phyboard-pollux-imx8mp-3.conf
MACHINE_FEATURES += "optee"

# This enables:
# - OP-TEE build (PREFERRED_VERSION_optee-os)
# - tee-supplicant in IMAGE_INSTALL
# - Kernel driver CONFIG_TEE=y, CONFIG_OPTEE=y
# - /dev/tee0, /dev/teepriv0 device nodes
```

---

## 18. Common Failures and Diagnostics

### SPL Does Not Start (No UART Output)

**Cause**: ROM failed to load or authenticate SPL.
**Diagnosis**:
1. In Open mode: use U-Boot `hab_status` to check for ROM HAB events (must boot alternate)
2. Check IVT at correct offset in imx-boot binary
3. Verify `CONFIG_SPL_TEXT_BASE=0x920000`
4. Check eMMC boot partition offset (should write to byte 0 of mmcblk2boot0)

### SPL Prints Then Hangs at DDR Init

```
U-Boot SPL 2023.04 ...
PMIC: PMIC_PCA9450 is found
Normal Boot
DDRINFO: start DRAM init
[ hangs here ]
```

**Cause**: DDR training firmware not found or DDR training failure.
**Diagnosis**:
- Verify DDR training firmware blobs are included in the eMMC image
- Check `CONFIG_IMX8MP_LPDDR4_TRAIN=y`
- Verify DDR timing parameters match the physical LPDDR4 device on the SOM

### SPL FIT Verification Fails

```
## Loading kernel from FIT Image at 48000000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ... sha256+ error
   Bad hash value for 'sha256' hash node in 'kernel@1' image node
```

**Cause**: FIT image corrupted, or FIT was re-signed with a different key than the one
embedded in the SPL binary.
**Diagnosis**:
- Re-sign the FIT with the key whose public half is embedded in `u-boot.dtb`
- Run `dumpimage -l fitImage` to inspect signature nodes
- Verify `keys/fit-signing-key.pem` is the private key matching the embedded public key

### TF-A Does Not Launch OP-TEE

```
NOTICE:  BL31: v2.8(release):...
NOTICE:  BL31: Built : 12:00:00, ...
ERROR:   Error initializing runtime service opteed_fast
```

**Cause**: OP-TEE binary missing, wrong load address, or BL32 verification failure.
**Diagnosis**:
- Verify `SPD=opteed` in TF-A build
- Check `tee.bin` is present in the FIT image
- Verify OP-TEE load address matches `CFG_TZDRAM_START` in OP-TEE config

---

## Chapter Contents

| File | Content |
|------|---------|
| [README.md](README.md) | This overview — full architecture, all components |
| [01-spl-configuration.md](01-spl-configuration.md) | SPL Kconfig reference, memory map, execution flow |
| [02-tf-a-internals.md](02-tf-a-internals.md) | TF-A source structure, TBB, memory layout, build |
| [03-optee-integration.md](03-optee-integration.md) | OP-TEE integration, RPMB, fTPM, Yocto |

---

## References

- ARM TF-A Documentation: https://trustedfirmware-a.readthedocs.io/
- OP-TEE Documentation: https://optee.readthedocs.io/
- ARM PSCI Specification: DEN0022D https://developer.arm.com/documentation/den0022/d/
- ARM SMCCC Specification: DEN0028C https://developer.arm.com/documentation/den0028/c/
- NXP i.MX8M Plus Security Reference Manual: IMX8MPRM Rev. 3
- OP-TEE on i.MX8: https://optee.readthedocs.io/en/latest/building/devices/nxp.html
- TF-A i.MX platform: https://trustedfirmware-a.readthedocs.io/en/latest/plat/imx8mp.html

---

*Chapter 07 — SPL, TF-A, and OP-TEE | Embedded Linux Secure Boot Reference*
