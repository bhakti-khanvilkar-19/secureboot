# DDR Initialization Deep Dive

## Overview

On every ARM SoC, external DRAM is completely uninitialized at power-on. The boot ROM runs
entirely from on-chip SRAM (OCRAM), which is too small to hold the full bootloader. Before any
substantial code can execute, the DRAM controller and PHY must be trained and initialized.

On i.MX8MP with LPDDR4, this initialization is among the most complex operations in the boot
sequence, requiring firmware blobs, a multi-phase training process, and careful timing calibration.
A failed or miscalibrated DDR initialization will cause unpredictable behavior — random crashes,
memory corruption, or complete failure to boot.

---

## Table of Contents

1. [Why DDR Init Happens in SPL](#1-why-ddr-init-happens-in-spl)
2. [LPDDR4 Architecture Overview](#2-lpddr4-architecture-overview)
3. [LPDDR4 Training Sequence on i.MX8MP](#3-lpddr4-training-sequence-on-imx8mp)
4. [SPL DDR Init Code Flow](#4-spl-ddr-init-code-flow)
5. [DDR Timing Parameters](#5-ddr-timing-parameters)
6. [board_init_f() → spl_dram_init() Call Chain](#6-board_init_f--spl_dram_init-call-chain)
7. [DDR Training Failure Modes](#7-ddr-training-failure-modes)
8. [PHYTEC phyCORE-i.MX8MP DDR Configuration](#8-phytec-phycore-imx8mp-ddr-configuration)
9. [DDR Firmware Loading](#9-ddr-firmware-loading)
10. [Eye Diagram and Timing Margins](#10-eye-diagram-and-timing-margins)
11. [DDR ECC Configuration](#11-ddr-ecc-configuration)

---

## 1. Why DDR Init Happens in SPL

### The Cold Boot Problem

At power-on:
- DRAM cells have unknown/indeterminate charge state
- DRAM clock is not running
- DRAM controller registers are in hardware reset state
- DRAM bus timing is not calibrated for this specific board, temperature, and process

The ROM has two options for initializing DRAM:
1. **DCD (Device Configuration Data)**: ROM executes a static list of register writes
2. **Execute code from OCRAM**: Load a small program (SPL) that performs initialization

i.MX6/i.MX7 used DCD for DRAM initialization — a list of register writes scripted into the
image. This works for simpler DRAM types (DDR3) where initialization is primarily static
register configuration.

LPDDR4 on i.MX8MP requires **training** — a dynamic calibration process where the memory
controller sends test patterns and measures the DRAM's responses to determine optimal timing
parameters. This cannot be expressed as static register writes.

### Why OCRAM is Sufficient for SPL

The SPL binary for i.MX8MP is typically 100–200KB. OCRAM provides 256KB available to the SPL.
This is tight but sufficient for:

- SPL code and data: ~80–150KB
- DDR training firmware: loaded into special PHY instruction/data SRAM (not OCRAM)
- Stack: ~8KB
- Heap: ~16KB

After SPL initializes DRAM, all subsequent code (TF-A, OP-TEE, U-Boot) is loaded into the
now-available gigabytes of DRAM.

---

## 2. LPDDR4 Architecture Overview

### LPDDR4 vs DDR4

| Property | DDR4 | LPDDR4 |
|----------|------|--------|
| Voltage | 1.2V | 1.1V (VDD2), 0.6V (VDDQ) |
| Interface | Parallel address/data | Serialized command protocol |
| Channels | Single | Dual channel (2×16 or 1×32) |
| Training | Simple | Multi-phase, firmware-driven |
| Clock | Single-ended | Differential, per-channel |
| ZQ calibration | Periodic | Required at init |
| CA bus | Traditional | 6-bit Command/Address |
| DFI width | 64-bit | 32-bit per channel |

### i.MX8MP LPDDR4 Controller Structure

```
i.MX8MP LPDDR4 Subsystem
─────────────────────────────────────────────────────────────────
┌─────────────────────────────────────────────────────────────────┐
│  DDRC (DDR Controller)                                          │
│  - AXI slave interface (from NoC/bus fabric)                    │
│  - Arbitration, scheduling, ECC logic                           │
│  - Register base: 0x3D400000                                    │
└────────────────────────┬────────────────────────────────────────┘
                         │ DFI (DDR PHY Interface)
┌────────────────────────▼────────────────────────────────────────┐
│  DDR PHY (Physical Layer)                                       │
│  - Two independent channels (Ch0, Ch1)                          │
│  - Each channel: 16 DQ bits + DQS                               │
│  - PLL for DQ/DQS timing                                        │
│  - Register base: 0x3C000000                                    │
│                                                                 │
│  Internal firmware memory:                                      │
│  - IMEM (Instruction Memory): 0x3C000000 + 0x50000             │
│  - DMEM (Data Memory):        0x3C000000 + 0x54000             │
└────────────────────────┬────────────────────────────────────────┘
                         │ LPDDR4 interface (differential)
                         │ Channel 0 + Channel 1
┌────────────────────────▼────────────────────────────────────────┐
│  LPDDR4 DRAM Chips (on-module, phyCORE-i.MX8MP)                 │
│  Typically: 2× 16Gbit (Samsung K4UBE3D4AA-MGCL or equivalent)  │
│  Configuration: 2 channels × 16 bits = 32-bit bus               │
│  Total: 4GB (common config for phyCORE-i.MX8MP)                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. LPDDR4 Training Sequence on i.MX8MP

### Training Phases

LPDDR4 initialization on i.MX8MP uses NXP's DDR training firmware which runs through
two main phases:

```
Phase 0: Controller + PHY Reset
  - Assert/deassert DDR_PWRok
  - DDRC software reset (CSR PWRCTL.selfref_type)
  - PHY reset via DDRC_INIT0

Phase 1: DRAM Initialization (DRAM MR writes via DFI init)
  - MR1: Drive strength, ZQ calibration
  - MR2: Write leveling, Read DBI
  - MR3: Pull-up calibration
  - MR11: DQ ODT, CA ODT
  - MR13: Data mask, FSPOP

Phase 2: PHY 1D Training (1D = single data rate training)
  Load 1D firmware into PHY IMEM/DMEM
  Firmware executes training sequence:
  
  ┌─────────────────────────────────────────────────────────────┐
  │  1D Training Sub-phases:                                    │
  │                                                             │
  │  a. DCT (Data Channel Training): validates DFI signals      │
  │  b. Write Leveling: calibrates DQS vs CK phase alignment    │
  │  c. RxEn Training: DQS gate calibration (read enable)       │
  │  d. Read Deskew: per-DQ bit timing calibration              │
  │  e. Write Deskew: per-DQ bit timing calibration             │
  │  f. Read MRD/Cycle Time: fine-tune read latency              │
  │  g. BIST (Built-in Self Test): validates all lanes          │
  └─────────────────────────────────────────────────────────────┘

Phase 3: PHY 2D Training (2D = frequency + voltage margin)
  Load 2D firmware into PHY IMEM/DMEM
  Firmware sweeps voltage and timing simultaneously:
  
  ┌─────────────────────────────────────────────────────────────┐
  │  2D Training Results:                                       │
  │  - Optimal DQ/DQS timing at target frequency                │
  │  - Voltage margin map (2D eye diagram)                      │
  │  - Results stored in DMEM for SPL to extract                │
  └─────────────────────────────────────────────────────────────┘

Phase 4: Load Training Results
  SPL reads 2D training output from PHY DMEM
  Applies resulting timing parameters to DDRC/PHY registers

Phase 5: Frequency Set Point (FSP) Setup
  Configure FSP0 (low frequency, ~100MHz) for self-refresh
  Configure FSP1 (operational frequency, typically 1600MHz)

Phase 6: Final DRAM Configuration
  Enable DRAM auto-refresh
  Enable ECC (if configured)
  Run final write + read test via BIST

Phase 7: Training Complete
  DDRC enters normal operational mode
  SPL continues with loading boot images
```

### Training Firmware Files

NXP provides pre-compiled training firmware blobs (closed-source):

```
lpddr4_pmu_train_1d_imem_202006.bin  — 1D training instruction memory
lpddr4_pmu_train_1d_dmem_202006.bin  — 1D training data memory
lpddr4_pmu_train_2d_imem_202006.bin  — 2D training instruction memory
lpddr4_pmu_train_2d_dmem_202006.bin  — 2D training data memory
```

The `202006` suffix is a date code (June 2020). NXP periodically releases updated firmware
with bug fixes and improved training algorithms. Always use the firmware version paired with
your U-Boot BSP.

These blobs are embedded in the `imx-boot` container by imx-mkimage at the beginning of the
output image (before the container headers), so the SPL can load them from a known offset.

---

## 4. SPL DDR Init Code Flow

### Source File Locations

```
u-boot/
├── drivers/
│   └── ddr/
│       └── imx/
│           ├── imx8mp/
│           │   ├── ddr.c              — Main DDR init driver
│           │   ├── ddr_init.c         — board-level DDR init call
│           │   └── ddrphy_train.c     — PHY training sequence
│           ├── phy-training/
│           │   └── ddr_init.c         — Generic PHY init
│           └── Kconfig
├── board/
│   └── phytec/
│       └── phycore_imx8mp/
│           └── spl.c                  — board_init_f(), dram_init()
└── arch/
    └── arm/
        └── mach-imx/
            └── imx8mp/
                └── spl.c              — i.MX8MP-specific SPL helpers
```

### Call Chain: Power-On to DRAM Ready

```c
/* arch/arm/cpu/armv8/start.S */
_start:
    /* Exception vector setup, stack pointer init */
    bl  lowlevel_init    /* very early hardware init */
    bl  board_init_f     /* main SPL initialization */

/* common/spl/spl.c */
void board_init_f(ulong boot_flags)
{
    /* 1. Initialize global data structure */
    gd = &gdata;
    gd->flags = boot_flags;
    
    /* 2. Run init sequence (array of function pointers) */
    if (initcall_run_list(init_sequence_f))
        hang();
    
    /* init_sequence_f includes (simplified): */
    /*   setup_mon_len()    — calculate monitor length    */
    /*   arch_cpu_init()    — CPU/SoC early init          */
    /*   timer_init()       — set up system timer         */
    /*   env_init()         — environment initialization  */
    /*   serial_init()      — UART initialization         */
    /*   display_banner()   — print version string        */
    /*   dram_init()        → calls spl_dram_init()       */
}

/* board/phytec/phycore_imx8mp/spl.c */
int dram_init(void)
{
    /* Set DRAM size from device tree or hardcoded */
    gd->ram_size = PHYS_SDRAM_SIZE;  /* e.g., 0x100000000 = 4GB */
    return 0;
}

/* This is called from board_init_f via init_sequence_f */
/* Actual DDR initialization: */
void spl_dram_init(void)
{
    /* Load DDR training firmware from eMMC into PHY IMEM/DMEM */
    ddr_init(dram_timing);   /* dram_timing: board-specific timing struct */
}

/* drivers/ddr/imx/imx8mp/ddr.c */
void ddr_init(struct dram_timing_info *timing_info)
{
    /* Step 1: DDR controller reset and clock init */
    ddr_pll_init(DRAM_PLL_OUT_800M);   /* 800MHz DRAM PLL → 1600MT/s */
    
    /* Step 2: Initialize DDRC registers (pre-training) */
    ddrc_config(timing_info);
    
    /* Step 3: PHY reset */
    ddr_phy_init();
    
    /* Step 4: Load and execute 1D training firmware */
    load_ddr_firmware(1D_IMEM, 1D_DMEM);
    run_ddr_firmware();    /* Blocks until 1D training complete */
    
    /* Step 5: Load and execute 2D training firmware */
    load_ddr_firmware(2D_IMEM, 2D_DMEM);
    run_ddr_firmware();    /* Blocks until 2D training complete */
    
    /* Step 6: Apply training results */
    ddr_load_train_result(timing_info);
    
    /* Step 7: Final DDRC configuration */
    ddrc_post_init_cfg(timing_info);
    
    /* Step 8: Enable ECC if configured */
    if (timing_info->ddrphy_trained_csr_cfg)
        enable_ddr_ecc();
    
    /* DDR is now operational */
}
```

### Waiting for PHY Firmware Completion

The PHY firmware executes on a small Cortex-M0 within the DDR PHY block. The SPL must
poll a mailbox register to detect completion:

```c
/* drivers/ddr/imx/imx8mp/ddrphy_train.c (simplified) */

void run_ddr_firmware(void)
{
    uint32_t msg;
    
    /* Assert firmware start */
    dwc_ddrphy_apb_wr(0xd0000, 0x0);  /* Reset APBONLY enable */
    dwc_ddrphy_apb_wr(0xd0099, 0x9);  /* Start microcontroller */
    
    /* Poll MailboxBusy register until firmware signals completion */
    do {
        /* Read message from firmware mailbox */
        while (dwc_ddrphy_apb_rd(0xd0004) != 0) {
            /* Wait for mailbox not busy */
        }
        msg = dwc_ddrphy_apb_rd(0xd0032);  /* Read message */
        
        if (msg == 0x07)  /* Training DONE message */
            break;
        if (msg == 0xFF)  /* Training FAILED message */
            hang();       /* Fatal: DDR training failed */
            
        dwc_ddrphy_apb_wr(0xd0031, 0x0);  /* ACK the message */
        
    } while (1);
}
```

---

## 5. DDR Timing Parameters

### Key Timing Parameters for LPDDR4

The `dram_timing_info` structure encodes board-specific DRAM configuration:

```c
/* drivers/ddr/imx/ddr.h (simplified) */
struct dram_timing_info {
    /* DDR PHY trained CSR array */
    struct ddrphy_cfg_param *ddrphy_trained_csr_cfg;
    uint32_t ddrphy_trained_csr_cfg_num;
    
    /* DDRC configuration */
    struct ddrc_cfg_param *ddrc_cfg;
    uint32_t ddrc_cfg_num;
    
    /* FSP (Frequency Set Point) timing tables */
    struct dram_fsp_msg   *fsp_msg;
    uint32_t fsp_msg_num;
    
    /* Timing parameters */
    struct dram_timing_cfg {
        uint32_t rddata_en;     /* Read data enable timing */
        uint32_t rddbi_en;      /* Read DBI enable */
        uint32_t mr0;           /* Mode Register 0 value */
        uint32_t mr1;           /* Mode Register 1: Drive strength */
        uint32_t mr2;           /* Mode Register 2: RL/WL settings */
        uint32_t mr3;           /* Mode Register 3: CA calibration */
        uint32_t mr4;           /* Mode Register 4 */
        uint32_t mr5;           /* Mode Register 5 */
        uint32_t mr6;           /* Mode Register 6 */
        uint32_t mr11;          /* ODT control */
        uint32_t mr12;          /* Vref CA calibration */
        uint32_t mr13;          /* Data Mask, FSPOP */
        uint32_t mr14;          /* Vref DQ calibration */
        uint32_t mr22;          /* ODT control */
        /* ... many more parameters ... */
    } cfg;
};
```

### Critical Timing Parameters Explained

| Parameter | Typical Value | Description |
|-----------|--------------|-------------|
| `tRCD` | 18ns | RAS to CAS Delay — row activation to column command |
| `tRP` | 18ns | Row Precharge time — precharge to activation |
| `tRC` | 63ns | Row Cycle time — activate to activate same bank |
| `tRAS` | 45ns | Row Active Strobe — minimum row active time |
| `tCL` | 36ns (RL=16) | CAS Latency — read command to data valid |
| `tCWL` | 18ns (WL=8) | CAS Write Latency — write command to DQS |
| `tDQSCK` | 1.5–2.5ns | DQS output delay from CK |
| `tWR` | 18ns | Write Recovery — write to precharge |
| `tRFC` | 280ns | Refresh Cycle time — 8Gb device |
| `tREFI` | 3.9µs | Refresh Interval (1x mode, 85°C max) |

At 1600MT/s (800MHz DDR clock, 1600 million transfers per second):
- 1 clock cycle = 1.25ns
- RL=16 means 16 clock cycles = 20ns read latency
- WL=8 means 8 clock cycles = 10ns write latency

### Timing Derating for Temperature

LPDDR4 requires timing derating at high temperatures. The derating values are applied to
critical timing parameters:

```
tRCD_derating = tRCD + 1.875ns (above 85°C)
tRP_derating  = tRP  + 1.875ns (above 85°C)
tRC_derating  = tRC  + 3.75ns  (above 85°C)
```

The DDRC DERATEEN register enables hardware automatic derating based on a temperature sensor
reading from the DRAM's MR4 mode register.

---

## 6. board_init_f() → spl_dram_init() Call Chain

### Complete Init Sequence (i.MX8MP SPL)

```
_start (arch/arm/cpu/armv8/start.S)
└── board_init_f (common/spl/spl.c)
    └── initcall_run_list(init_sequence_f)
        ├── setup_mon_len
        ├── arch_cpu_init          → clock_init(), GIC disable, MMU disable
        ├── spl_early_init         → DM initialization, device tree parsing
        ├── timer_init             → ARM generic timer configuration
        ├── env_init               → environment subsystem
        ├── serial_init            → UART0 at 115200 baud
        ├── display_banner         → "U-Boot SPL 2024.04..."
        ├── announce_dram_init     → "DDRINFO: start DRAM init"
        ├── dram_init              → calls board-specific spl_dram_init()
        │   └── spl_dram_init (board/phytec/phycore_imx8mp/spl.c)
        │       └── ddr_init(&dram_timing)
        │           ├── ddr_pll_init(800MHz)
        │           ├── ddrc_config(&dram_timing)
        │           ├── ddr_phy_init()
        │           ├── load_firmware(1D_IMEM_PATH, 1D_DMEM_PATH)
        │           │   └── [reads from eMMC offset, copies to PHY SRAM]
        │           ├── run_ddr_firmware()
        │           │   └── [polls PHY mailbox until 1D complete]
        │           ├── load_firmware(2D_IMEM_PATH, 2D_DMEM_PATH)
        │           ├── run_ddr_firmware()
        │           │   └── [polls PHY mailbox until 2D complete]
        │           ├── ddr_load_train_result()
        │           └── ddrc_post_init_cfg()
        ├── show_dram              → "DDRINFO: DRAM init done" + size
        └── [continues with SPL boot device detection...]
```

### UART Output During DDR Init

A healthy DDR initialization produces:

```
U-Boot SPL 2024.04-00054-g3a4c7f8d (Oct 01 2024 - 12:00:00 +0000)
DDRINFO: start DRAM init
DDRINFO: 1D Training Start
DDRINFO: 1D Training Complete
DDRINFO: 2D Training Start
DDRINFO: 2D Training Complete
DDRINFO: DRAM init done
DRAM:  4 GiB
```

If training hangs after "1D Training Start", the likely causes are:
1. Wrong DDR firmware blobs for this DRAM type
2. DRAM hardware failure or solder issue
3. Power supply instability (VDD_DRAM rail)
4. Clock initialization failure (800MHz PLL not locked)

---

## 7. DDR Training Failure Modes

### Failure Category 1: Firmware Load Failure

**Symptom:** No output after "DDRINFO: start DRAM init", or garbage after DDR init starts.

**Cause:** DDR training firmware not found at expected offset in eMMC/SD, or firmware corrupt.

**Diagnosis:**
```bash
# Check that firmware blobs are present in imx-boot image
# They should be at offset 0x0 in flash.bin, before container headers
hexdump -C flash.bin | head -8
# Should see non-zero data starting at offset 0x0

# Verify firmware file sizes
ls -la lpddr4_pmu_train_1d_imem_202006.bin  # typically ~42KB
ls -la lpddr4_pmu_train_1d_dmem_202006.bin  # typically ~4KB
ls -la lpddr4_pmu_train_2d_imem_202006.bin  # typically ~42KB
ls -la lpddr4_pmu_train_2d_dmem_202006.bin  # typically ~4KB
```

### Failure Category 2: Training Algorithm Failure

**Symptom:** "1D Training Complete" then hang at "2D Training Start", or:
`ERROR: DDR PHY training failed, msg=0xFF`

**Cause:** DRAM doesn't respond correctly to training patterns. This indicates:
- Wrong timing parameters (tRCD, tRP, etc.) for the installed DRAM
- Wrong DRAM density/organization settings (8Gb vs 16Gb device)
- DRAM chip failure
- PCB signal integrity issues (too long traces, impedance mismatch)

**Resolution:**
1. Verify DRAM part number matches `dram_timing` configuration
2. Run NXP DDR Stress Test Tool (separate NXP download)
3. Inspect DDRC and PHY training result registers:

```bash
# In U-Boot (if it boots far enough), check PHY training results
md.l 0x3c040040 8   # PHY Ch0 trained Vref values
md.l 0x3c050040 8   # PHY Ch1 trained Vref values
```

### Failure Category 3: Post-Training Memory Corruption

**Symptom:** DDR init appears successful (passes BIST), but Linux crashes with BUG/Oops
during memory-intensive operations.

**Cause:** Marginal timing — training produced parameters that work at room temperature but
fail under load or at high temperature.

**Diagnosis:**
```bash
# From Linux, run memtester
memtester 3500M 5

# Or use the NXP DDR stress test image
# (boot it before Linux, runs comprehensive timing margin tests)
```

**Resolution:**
- Add timing margin (relax tRCD, tRP by 1-2 clocks)
- Check DDR Vref settings (MR12, MR14)
- Verify PCB layout meets LPDDR4 signal integrity requirements
- Contact NXP support with DDR PHY training log

---

## 8. PHYTEC phyCORE-i.MX8MP DDR Configuration

### Module Memory Configuration

The PHYTEC phyCORE-i.MX8MP SoM is available in multiple DRAM configurations:

| SKU | DRAM Size | DRAM Type | DRAM Chips |
|-----|-----------|-----------|-----------|
| PCM-068-3 | 1GB | LPDDR4 | 2× 4Gbit Samsung |
| PCM-068-5 | 2GB | LPDDR4 | 2× 8Gbit Samsung |
| PCM-068-7 | 4GB | LPDDR4 | 2× 16Gbit Samsung |
| PCM-068-9 | 8GB | LPDDR4X | 4× 16Gbit Samsung |

Each configuration requires different `dram_timing` parameters.

### PHYTEC BSP DDR Configuration Files

```
u-boot/board/phytec/phycore_imx8mp/
├── lpddr4_timing_B0_4GB.c      — 4GB LPDDR4 timing (B0 silicon rev)
├── lpddr4_timing_B0_2GB.c      — 2GB LPDDR4 timing
├── lpddr4_timing_B0_1GB.c      — 1GB LPDDR4 timing
└── spl.c                       — Runtime DRAM config selection
```

PHYTEC uses runtime detection to select the correct timing:

```c
/* board/phytec/phycore_imx8mp/spl.c (simplified) */

/* DRAM size detection based on PHYTEC EEPROM (KSZ87XX) */
void spl_dram_init(void)
{
    struct phytec_eeprom_data eeprom;
    int dram_size_gb;
    
    /* Read EEPROM to determine DRAM configuration */
    phytec_eeprom_data_setup(&eeprom, 0, EEPROM_ADDR);
    dram_size_gb = phytec_get_dram_size(&eeprom);
    
    switch (dram_size_gb) {
    case 1:
        ddr_init(&lpddr4_timing_1GB);
        break;
    case 2:
        ddr_init(&lpddr4_timing_2GB);
        break;
    case 4:
    default:
        ddr_init(&lpddr4_timing_4GB);
        break;
    }
}
```

### Timing Configuration Example (4GB)

Key registers from `lpddr4_timing_B0_4GB.c`:

```c
/* DDRC INIT3: MR1/MR2 write at initialization */
/* MR1[5:3] = 001b: Drive Strength 40 ohm (default) */
/* MR1[6] = 0: Burst Length 16 */
/* MR2[5:3] = RL/WL selection based on speed grade */
/* At 1600MT/s: RL=16, WL=8, nWR=20 → MR2[5:3]=010 */

static struct ddrc_cfg_param ddrc_cfg[] = {
    { DDRC_MSTR(0),    0xA3080020 }, /* LPDDR4, 32-bit bus, BL=16 */
    { DDRC_RFSHCTL0(0), 0x00210000 }, /* Refresh control */
    { DDRC_INIT0(0),   0xC0030001 }, /* Init timing */
    { DDRC_INIT3(0),   0x00D4002D }, /* MR1=0x34, MR2=0x2D */
    { DDRC_INIT4(0),   0x00330008 }, /* MR3=0x33, MR13=0x08 */
    /* ... ~100 more register entries ... */
};
```

---

## 9. DDR Firmware Loading

### Where Firmware Lives in flash.bin

imx-mkimage places the DDR training firmware at the beginning of `flash.bin`, before the
container headers. The SPL knows the offsets at compile time via hardcoded values:

```c
/* drivers/ddr/imx/imx8mp/ddr.c or similar */
#define DDR_FW_1D_IMEM_OFFSET  0x000000  /* offset in flash.bin */
#define DDR_FW_1D_DMEM_OFFSET  0x008000
#define DDR_FW_2D_IMEM_OFFSET  0x010000
#define DDR_FW_2D_DMEM_OFFSET  0x018000

#define DDR_FW_IMEM_SIZE  0x8000  /* 32KB per firmware image */
#define DDR_FW_DMEM_SIZE  0x1000  /* 4KB per data memory image */
```

### Firmware Loading Function

```c
/* drivers/ddr/imx/imx8mp/ddrphy_train.c (simplified) */

static void load_ddr_firmware(uint32_t imem_offset, uint32_t dmem_offset)
{
    uint32_t *src;
    uint32_t *dst;
    size_t i;
    
    /* Load IMEM firmware (32KB) from eMMC raw offset */
    src = (uint32_t *)(uintptr_t)(CONFIG_SPL_LOAD_FIT_ADDRESS + imem_offset);
    dst = (uint32_t *)DDR_PHY_BASE + IMEM_OFFSET;
    
    for (i = 0; i < DDR_FW_IMEM_SIZE / 4; i++) {
        /* PHY registers are 16-bit wide, accessed as 32-bit with upper 16=0 */
        /* Write via APB interface (dwc_ddrphy_apb_wr) */
        dwc_ddrphy_apb_wr(IMEM_OFFSET + i, src[i] & 0xFFFF);
    }
    
    /* Load DMEM firmware (4KB) */
    src = (uint32_t *)(uintptr_t)(CONFIG_SPL_LOAD_FIT_ADDRESS + dmem_offset);
    dst = (uint32_t *)DDR_PHY_BASE + DMEM_OFFSET;
    
    for (i = 0; i < DDR_FW_DMEM_SIZE / 4; i++) {
        dwc_ddrphy_apb_wr(DMEM_OFFSET + i, src[i] & 0xFFFF);
    }
}
```

### PHY Instruction Memory Map

```
DDR PHY IMEM (0x3C000000 + 0x50000 via APB):
  0x0000–0x7FFF  Training firmware code (32KB)
  
DDR PHY DMEM (0x3C000000 + 0x54000 via APB):
  0x0000–0x0FFF  Training firmware data (4KB)
  0x1000–0x1FFF  Message Block (firmware output: trained parameters)
  
Message Block contains:
  - Per-rank timing results (DQ delays, DQS delays)
  - Per-lane voltage results
  - Training status (pass/fail per lane)
  - Eye width measurements (optional, for logging)
```

---

## 10. Eye Diagram and Timing Margins

### What an Eye Diagram Measures

An eye diagram is a visualization of the timing and voltage margins of a digital signal.
For DDR training, the 2D training algorithm produces a 2D eye diagram for each DQ lane:

```
Voltage
  ▲                                   
  │    ───────────────────────────    
  │   ╱                         ╲   
  │  ╱     ╔═══════════════╗     ╲  
  │ ╱      ║               ║      ╲ 
  │╱       ║    PASSING     ║       ╲
  │        ║    REGION      ║       
  │        ╚═══════════════╝       
  │         ╲                     ╱ 
  │          ╲                   ╱  
  └──────────────────────────────────→ Time (Delay offset in ps)
             ←── Eye Width ────→
             ↑                  ↑
          Left                Right
          margin               margin
```

The SPL uses the center of the passing region as the optimal operating point. Marginal designs
have narrow eye openings.

### Interpreting Training Results

After 2D training completes, the SPL can read training results from the PHY message block:

```c
/* After 2D training, read per-lane DQ delay results */
for (int ch = 0; ch < 2; ch++) {  /* 2 channels */
    for (int byte = 0; byte < 2; byte++) {  /* 2 bytes per channel */
        uint32_t rxclkdly = dwc_ddrphy_apb_rd(
            DMEM_OFFSET + MSG_BLK_RXCLKDLY + ch*8 + byte);
        uint32_t txdqdly = dwc_ddrphy_apb_rd(
            DMEM_OFFSET + MSG_BLK_TXDQDLY + ch*8 + byte);
        printf("CH%d BYTE%d: RxClkDly=%d TxDQDly=%d\n",
               ch, byte, rxclkdly, txdqdly);
    }
}
```

### Stress Testing for Eye Margin

The NXP DDR Stress Test is a standalone binary that performs extensive memory testing:

```bash
# Download from NXP: https://www.nxp.com/ddr-stress-test
# Flash to SD and boot it as the only program
dd if=ddr_stress_test.bin of=/dev/mmcblk0 bs=512 seek=2

# When run, it:
# 1. Runs 1D and 2D training
# 2. Sweeps timing parameters ±10% around trained values
# 3. Runs memory tests at each point
# 4. Reports eye width and timing margin
```

---

## 11. DDR ECC Configuration

### Why DDR ECC Matters for Security

DDR ECC (Error Correcting Code) is security-relevant because:

1. **DRAM Rowhammer attacks**: An attacker who can flip bits in DRAM via repeated row
   accesses (Rowhammer) can potentially compromise the system. ECC makes single-bit
   rowhammer attacks impractical.

2. **Silent data corruption**: Cosmic rays cause single-event upsets (SEUs) in DRAM cells.
   In safety-critical applications, undetected bit flips can cause incorrect decisions.

3. **Key material protection**: If cryptographic keys are stored in DRAM, bit flips can
   cause authentication bypasses or key material leakage.

### i.MX8MP ECC Support

The i.MX8MP DDRC supports inline ECC for the LPDDR4 bus. ECC uses dedicated DRAM capacity:

```
Without ECC: Full address space available (e.g., 4GB)
With ECC:    ~12.5% of DRAM used for ECC → 3.5GB usable from 4GB installed
```

ECC mode requires specific DRAM configuration (separate ECC lanes), which is a board-level
design decision. The PHYTEC phyCORE-i.MX8MP does **not** have dedicated ECC DRAM lanes in
standard configurations — ECC must be enabled at the software level using inline ECC within
the DDRC, which provides error detection (not correction) without extra DRAM.

### Enabling DDRC Inline ECC

```c
/* drivers/ddr/imx/imx8mp/ddr.c */

void enable_ddr_ecc(struct dram_timing_info *timing)
{
    /* Enable SECDED (Single Error Correct, Double Error Detect) */
    /* This uses 1/8 of the DRAM bandwidth for ECC parity */
    
    /* ECCCTL register: enable ECC */
    writel(0x00000004, DDRC_BASE + DDRC_ECCCTL(0));
    /* Bit 2: ecc_mode = 4 (enable SECDED) */
    
    /* Scrub the entire memory to clear ECC state */
    /* (uninitialized ECC bits cause false correctable errors) */
    scrub_ecc_memory();
    
    /* Enable ECC interrupt on uncorrectable error */
    writel(0x00000001, DDRC_BASE + DDRC_ECCERRCNT(0));
}
```

### Linux Kernel ECC Reporting

With ECC enabled, the Linux kernel can report ECC errors via the EDAC (Error Detection And
Correction) framework:

```bash
# Check for ECC errors
cat /sys/bus/platform/drivers/imx_ddr/*/ecc_ce_count  # correctable errors
cat /sys/bus/platform/drivers/imx_ddr/*/ecc_ue_count  # uncorrectable errors

# Enable ECC error logging
dmesg | grep -i "ecc\|DRAM error"
```

An uncorrectable ECC error in a production system should trigger an alert and potentially
a controlled shutdown, as the data integrity cannot be guaranteed.

---

## Cross-References

- `../README.md` — Chapter 06 overview, OCRAM memory map
- `01-ivt-and-boot-container.md` — Why DCD is not used for DDR on i.MX8MP
- `../07-spl-tf-a-optee/01-spl-configuration.md` — SPL Kconfig options
- `../07-spl-tf-a-optee/README.md` — Full SPL architecture

---

*Chapter 06 / 02 — DDR Initialization | Embedded Linux Secure Boot Reference*
