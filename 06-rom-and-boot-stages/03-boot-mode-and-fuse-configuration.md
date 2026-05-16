# Boot Mode and Fuse Configuration Reference

## Overview

Fuse configuration controls the fundamental security posture of an i.MX8MP device. Incorrectly
programmed fuses can permanently render a device insecure, un-bootable, or both. This document
provides the complete fuse map for boot configuration and security, with exact register addresses,
valid values, and programming procedures.

> **Warning:** Fuse programming is permanent and irreversible. Every value in this document
> that is described as "program to enable security" will lock that configuration in silicon
> forever. A mistake requires replacing the SoC. Always validate on a sacrificial device first.

---

## Table of Contents

1. [BOOT_MODE Pin States](#1-boot_mode-pin-states)
2. [Internal Boot Device Selection via BOOT_CFG](#2-internal-boot-device-selection-via-boot_cfg)
3. [Boot Device Fuse Settings](#3-boot-device-fuse-settings)
4. [SPEED_GRADING Fuses](#4-speed_grading-fuses)
5. [Secondary Boot Path](#5-secondary-boot-path)
6. [Disabling JTAG via Fuses](#6-disabling-jtag-via-fuses)
7. [Disabling Serial Download Mode](#7-disabling-serial-download-mode)
8. [BT_FUSE_SEL: Fuse vs Pin Selection](#8-bt_fuse_sel-fuse-vs-pin-selection)
9. [Complete Fuse Map: Boot and Security](#9-complete-fuse-map-boot-and-security)
10. [Reading Boot Fuses with U-Boot](#10-reading-boot-fuses-with-u-boot)

---

## 1. BOOT_MODE Pin States

### Pin Definition

The `BOOT_MODE[1:0]` pins are two GPIO pins that are sampled by the Boot ROM at every
Power-On Reset (POR). They determine the top-level boot behavior before any fuses are read.

| BOOT_MODE[1] | BOOT_MODE[0] | Mode | Description |
|:---:|:---:|------|-------------|
| 0 | 0 | Boot from Fuses | Use `BOOT_CFG` fuses for device selection |
| 0 | 1 | Serial Download | USB OTG or UART serial loader |
| 1 | 0 | Internal Boot | Use BOOT_CFG fuses or pins (BT_FUSE_SEL decides) |
| 1 | 1 | Test Mode | Factory silicon test (never use in production) |

### Pin-to-Hardware Mapping

On i.MX8MP, the boot mode pins are multiplexed with GPIO functions:

```
BOOT_MODE0 → GPIO1_IO00 (pad: BOOT_MODE0)
BOOT_MODE1 → GPIO1_IO01 (pad: BOOT_MODE1)
```

These pads have internal weak pull-down resistors. External pull-up to 3.3V = logic 1.
For the phyBOARD-Pollux: jumpers J3 and J4 select these levels.

### Boot Mode 10 vs 00: The Difference

**BOOT_MODE = 00 (Boot from Fuses):** The ROM ignores `BT_FUSE_SEL` and always reads boot
configuration from fuses. The `BOOT_CFG` fuses determine the boot device. This mode is
used for the final production configuration.

**BOOT_MODE = 10 (Internal Boot):** The ROM checks `BT_FUSE_SEL`:
- `BT_FUSE_SEL = 0`: Read `BOOT_CFG` from **pins** (GPIO/NAND_DATA pads)
- `BT_FUSE_SEL = 1`: Read `BOOT_CFG` from **fuses** (same as mode 00)

In practice for production: both mode 00 and mode 10 with `BT_FUSE_SEL=1` achieve the same
result. The distinction matters during development when you want pin-controlled boot selection.

---

## 2. Internal Boot Device Selection via BOOT_CFG

### BOOT_CFG Fuses vs Pins

When the ROM reads "boot configuration," it comes from one of two sources:

**From Fuses:** OCOTP_CFG4 (Bank 1, Word 3) contains the boot configuration:

```
OCOTP_CFG4 bit field map:
┌───────────────────────────────────────────────────────────┐
│ Bit  │ Field           │ Description                      │
├───────────────────────────────────────────────────────────┤
│ [7]  │ BOOT_CFG1[7]   │ eMMC Speed (0=HS400, 1=HS200)   │
│ [6]  │ BOOT_CFG1[6]   │ eMMC 4-bit boot                 │
│ [5]  │ BOOT_CFG1[5]   │ eMMC DDR mode enable             │
│ [4]  │ BT_FUSE_SEL    │ 0=boot from pins, 1=from fuses   │
│ [3:0]│ BOOT_CFG1[3:0] │ Boot device selector (see table) │
└───────────────────────────────────────────────────────────┘
```

**From Pins:** When `BT_FUSE_SEL=0`, the ROM reads `NAND_DATA[7:0]` GPIO pins at boot time.
The encoding is the same as fuse bits.

---

## 3. Boot Device Fuse Settings

### Boot Device Encoding

The `BOOT_CFG1[3:0]` field (OCOTP_CFG4[3:0]) selects the boot device:

| BOOT_CFG1[3:0] | BOOT_CFG1[7:4] | Boot Device | Interface |
|:--------------:|:--------------:|-------------|-----------|
| `0000` | `0000` | eMMC | USDHC3 (8-bit, boot partition) |
| `0000` | `0010` | eMMC | USDHC3 (8-bit, HS200) |
| `0000` | `0100` | eMMC | USDHC3 (8-bit, HS400) |
| `0001` | `xxxx` | SD Card | USDHC2 |
| `0010` | `xxxx` | SD Card | USDHC1 |
| `0011` | `xxxx` | eMMC User Area | USDHC3 |
| `0100` | `xxxx` | SPI NOR | ECSPI1 |
| `0101` | `xxxx` | NAND | 8-bit NAND |
| `0110` | `xxxx` | SPI NOR | FlexSPI |
| `1111` | `xxxx` | USB Serial DL | Unconditional USB boot |

### eMMC-Specific Configuration Bits

For eMMC boot (BOOT_CFG1[3:0] = 0000), additional bits configure the eMMC interface:

```
OCOTP_CFG4[7]:  eMMC_SPEED
  0 = HS400 (best performance, requires calibration)
  1 = HS200 (good performance, simpler)

OCOTP_CFG4[6]:  EMMC_4BIT
  0 = 8-bit bus (default for i.MX8MP)
  1 = 4-bit bus

OCOTP_CFG4[5]:  EMMC_DDR
  0 = Single Data Rate
  1 = DDR (Double Data Rate)

OCOTP_CFG4[8]:  EMMC_RESET
  0 = EMMC_HW_RST_L not used
  1 = EMMC_HW_RST_L used during eMMC init
```

### Recommended Production Fuse Configuration for eMMC

For PHYTEC phyCORE-i.MX8MP booting from eMMC (USDHC3) boot partition at HS200:

```
OCOTP_CFG4:
  Bit 7 (eMMC_SPEED) = 1   → HS200
  Bit 6 (EMMC_4BIT)  = 0   → 8-bit bus
  Bit 5 (EMMC_DDR)   = 0   → SDR mode
  Bit 4 (BT_FUSE_SEL)= 1   → boot from fuses
  Bits 3:0           = 0000 → eMMC on USDHC3

Full OCOTP_CFG4 value: 0x000000B0
  Binary: 1011 0000
  Bit 7=1, Bit 5=1, Bit 4=1, Bits 3:0=0000
  Wait: Bit 5 = DDR enable — for HS200 SDR: Bit 5 should be 0
  Corrected: 0x00000090 (bits [7]=1, [4]=1, others=0)
```

> Always verify the exact bit field encoding against the current NXP i.MX8M Plus Reference
> Manual (IMX8MPRM). Register bit field interpretations may differ between silicon revisions.

---

## 4. SPEED_GRADING Fuses

### What SPEED_GRADING Controls

The `SPEED_GRADING` fuse determines the maximum rated operating frequency of the ARM cores.
NXP bins silicon after testing — chips that pass higher-frequency testing get higher speed
grades burned in at the factory.

```
OCOTP_SPEED_GRADING field location: OCOTP_CFG8, Bits [7:6]
  (Bank 1, Word 7 — but check specific register for your SoC revision)

Values:
  00 = 1.6 GHz rated
  01 = 1.8 GHz rated
  10 = 2.0 GHz rated (i.MX8MP only, high-performance variant)
  11 = Reserved
```

The kernel and U-Boot read this fuse to configure the maximum CPU OPP (Operating Performance
Point). An attempt to run the CPU above its rated speed grade will cause reliability issues.

### Reading Speed Grade in Linux

```bash
# CPU frequency scaling
cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
# Output: 1800000 (1.8GHz) or 1600000 (1.6GHz)

# Speed grade from OCOTP
cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem | \
    dd bs=1 skip=$((0x7C)) count=4 2>/dev/null | hexdump -e '"%08x\n"'
```

---

## 5. Secondary Boot Path

### Secondary Boot Device Configuration

The i.MX8MP ROM supports a secondary boot device as a fallback when the primary boot device
fails. The secondary boot device is configured in `OCOTP_CFG5`:

```
OCOTP_CFG5[3:0]: SECONDARY_BOOT_CFG — secondary boot device
  Encoding is same as BOOT_CFG1[3:0]

OCOTP_CFG5[6]:   SECONDARY_BOOT_OVERRIDE
  0 = Secondary boot only on failure of primary
  1 = Always boot from secondary device
```

### When Secondary Boot Activates

The ROM initiates secondary boot when:
1. Primary boot device not detected (no eMMC, SD not inserted)
2. Invalid IVT/container at expected offset
3. DCD execution failure
4. HAB authentication failure **only in Open configuration**
   (In Closed configuration, authentication failure → halt, not fallback)

> **Security Critical:** In Closed (SEC_CONFIG=Closed) configuration, the ROM does NOT fall
> back to the secondary boot device on authentication failure. This is intentional — allowing
> fallback to a secondary device would let an attacker replace the primary image with an
> invalid one, force the ROM to fall back, and boot from a malicious secondary image.
>
> If your design requires redundant boot, both primary and secondary images must be signed
> with the same key, and the fallback must be triggered by application software (U-Boot or
> Linux watchdog) after authentication, not by ROM authentication failure.

---

## 6. Disabling JTAG via Fuses

### JTAG Security Risk

JTAG (Joint Test Action Group) debug access provides near-complete control over the processor:
memory read/write, register access, code execution halt, and single-step. If JTAG remains
enabled on a production device, an attacker with physical access can:

1. Attach a JTAG debugger
2. Halt the CPU
3. Read cryptographic keys from OCRAM or DRAM
4. Bypass secure boot by setting PC to attacker-controlled code
5. Modify fuse shadow registers (though not the fuses themselves)

### JTAG Fuse Settings

```
JTAG control fuses are in OCOTP_CFG5 / OCOTP_MISC_CONF:

JTAG_SMODE (OCOTP_CFG5[21:20]):
  00 = JTAG enabled (default, all modes work)
  01 = Secure JTAG: challenge-response authentication required
  10 = No debug: JTAG disabled until next POR
  11 = No debug: JTAG permanently disabled

JTAG_HEO (OCOTP_CFG5[23]):
  0 = JTAG disable clears on POR (re-enabled at each boot)
  1 = JTAG disable persists across POR

KTE (Key Transfer Enable, OCOTP_CFG5[9]):
  1 = HAB key programming via JTAG disabled
```

### Recommended Production JTAG Configuration

For a device in production with no debug requirement:

```
JTAG_SMODE = 11  (permanent disable)
JTAG_HEO   = 1   (survives reset)
KTE        = 1   (no key transfer)
```

Programming via U-Boot:

```bash
# OCOTP_CFG5 = Bank 1, Word 5 — VERIFY this against your reference manual
# Set JTAG_SMODE=11, JTAG_HEO=1, KTE=1

# Read current value first:
fuse read 1 5

# The actual bit positions in OCOTP_CFG5 for your silicon revision
# must be verified in IMX8MPRM before programming.
# Example only — do not run without verification:
# fuse prog -y 1 5 0x00E00000   (if JTAG bits are [23:20])
```

> **Warning:** Disabling JTAG eliminates a significant debugging capability. You will not
> be able to use JTAG to recover a soft-bricked device. Ensure your system has other recovery
> paths (serial download mode, if not also disabled) before burning JTAG disable fuses.

---

## 7. Disabling Serial Download Mode

### Why Serial Download Is a Security Risk

Serial Download Mode (SDP - Serial Download Protocol) via USB is a powerful recovery feature.
When `BOOT_MODE[1:0] = 01` or when boot from all storage devices fails, the ROM enters SDP
mode and accepts new firmware via USB.

In Open configuration, SDP can:
- Write a new bootloader to storage
- Execute code directly in OCRAM from USB
- Read memory contents via USB

This is a complete bypass of secure boot in open configuration, and a potential bypass even
in closed configuration if the ROM has exploitable vulnerabilities.

### Disabling SDP via Fuses

```
OCOTP_CFG5[18]: DISABLE_SDOF (Disable Serial Download Over FAB)
  Hmm, the actual bit name is implementation-specific.

The correct fuse to disable USB serial download:
OCOTP_CFG5[6]:  SDP_DISABLE  (check reference manual for exact bit)
  0 = Serial download enabled (default)
  1 = Serial download disabled

For i.MX8MP, the fuse to burn is:
OCOTP_MISC_CONF0[22]: SDP_DISABLE
```

The actual fuse register and bit position **must** be verified against the NXP i.MX8M Plus
Reference Manual for your silicon revision. NXP has changed this across i.MX8 variants.

### Consequence of Disabling SDP

With SDP disabled:
- Serial download mode pin configuration (`BOOT_MODE=01`) is ignored
- If all boot devices fail, the device **halts permanently**
- Recovery from a corrupt bootloader requires:
  - JTAG access (if not also disabled)
  - Alternative boot media (SD card in a different slot, if not fused-out)
  - Hardware reset and alternative boot pin configuration

> **Recommendation:** Disable SDP only after verifying that:
> 1. The bootloader is correctly installed and authenticated
> 2. You have an alternative recovery mechanism (JTAG, alternative boot partition)
> 3. Your manufacturing process does not require post-installation SDP recovery

---

## 8. BT_FUSE_SEL: Fuse vs Pin Selection

### Function

`BT_FUSE_SEL` (Boot Fuse Select) is a single fuse bit that determines whether the BOOT_CFG
configuration comes from GPIO pins or from fuses when `BOOT_MODE = 10`.

```
BT_FUSE_SEL location: OCOTP_CFG4[4]
  (Bank 1, Word 3, Bit 4)

0 = Boot configuration from BOOT_CFG pins (GPIO pads NAND_DATA[7:0])
1 = Boot configuration from BOOT_CFG fuses (OCOTP_CFG4[7:0] and related)
```

### Development vs Production Workflow

**Development phase** (`BT_FUSE_SEL = 0`, factory default):
- Boot device can be changed by physically switching pins/jumpers
- Useful for trying different boot configurations without programming fuses
- The phyBOARD-Pollux has jumpers for this purpose

**Production phase** (`BT_FUSE_SEL = 1`):
- Boot device is fixed by fuses
- Pin state is ignored for boot configuration
- An attacker cannot redirect boot by manipulating board signals

### Programming BT_FUSE_SEL

This is a low-risk fuse to burn (it does not affect authentication, only configuration source).
Always burn this early in the production fuse-programming sequence.

```bash
# Read OCOTP_CFG4 current value (Bank 1, Word 3)
fuse read 1 3

# Typical initial value: 0x00000000 (all default)

# Program BT_FUSE_SEL (bit 4 of Bank 1 Word 3)
# The OR of current value with 0x00000010
fuse prog -y 1 3 0x00000010

# Verify
fuse read 1 3
# Should show bit 4 set
```

---

## 9. Complete Fuse Map: Boot and Security

### OCOTP (On-Chip One-Time Programmable) Register Map

The OCOTP base address on i.MX8MP is `0x30350000`. Each fuse word is 32 bits.
The shadow register address = `0x30350000 + (bank * 0x200) + (word * 0x10) + 0x400`.

**Critical Security Fuses:**

| Fuse Name | Bank | Word | Bits | Values | Description |
|-----------|------|------|------|--------|-------------|
| `SEC_CONFIG` | 1 | 3 | [1:0] | 00=Open, 10=Closed | Secure boot enforcement |
| `BT_FUSE_SEL` | 1 | 3 | [4] | 0=pins, 1=fuses | Boot config source |
| `JTAG_SMODE` | 1 | 7 | [21:20] | 00=en, 11=dis | JTAG mode control |
| `JTAG_HEO` | 1 | 7 | [23] | 0/1 | JTAG disable persist |
| `SDP_DISABLE` | 0 | 6 | [22] | 0=en, 1=dis | USB serial DL disable |
| `KTE` | 1 | 5 | [9] | 0/1 | Key transfer enable |
| `SRK_LOCK` | 0 | 0 | [2] | 0/1 | Lock SRK fuses after burn |
| `SRK_REVOKE` | 3 | 8 | [3:0] | per-bit | Revoke individual SRKs |

**Boot Configuration Fuses:**

| Fuse Name | Bank | Word | Bits | Description |
|-----------|------|------|------|-------------|
| `BOOT_CFG1` | 1 | 3 | [15:8] | Boot device + speed config |
| `BOOT_CFG2` | 1 | 4 | [7:0] | Secondary boot device |
| `SPEED_GRADING` | 1 | 7 | [7:6] | CPU max frequency |
| `MFG_MODE` | 0 | 6 | [0] | Manufacturing mode flag |

**SRK Hash Fuses:**

| Fuse Name | Bank | Word | Address | Description |
|-----------|------|------|---------|-------------|
| `OCOTP_SRK0` | 3 | 0 | `0x30350580` | SRK hash bits [31:0] |
| `OCOTP_SRK1` | 3 | 1 | `0x30350590` | SRK hash bits [63:32] |
| `OCOTP_SRK2` | 3 | 2 | `0x303505A0` | SRK hash bits [95:64] |
| `OCOTP_SRK3` | 3 | 3 | `0x303505B0` | SRK hash bits [127:96] |
| `OCOTP_SRK4` | 3 | 4 | `0x303505C0` | SRK hash bits [159:128] |
| `OCOTP_SRK5` | 3 | 5 | `0x303505D0` | SRK hash bits [191:160] |
| `OCOTP_SRK6` | 3 | 6 | `0x303505E0` | SRK hash bits [223:192] |
| `OCOTP_SRK7` | 3 | 7 | `0x303505F0` | SRK hash bits [255:224] |

### SEC_CONFIG: The Pivotal Security Fuse

```
SEC_CONFIG location: OCOTP_CFG5 Bits [1:0]
(Some references say OCOTP_CFG1 or OCOTP_LOCK — CHECK YOUR SILICON REVISION MANUAL)

For i.MX8MP specifically, SEC_CONFIG is in:
  OCOTP_HDCP_KEY0 — No, this is wrong for i.MX8MP.
  
Correct location: Bank 1, Word 3, Bits [1:0]
  OCOTP_CFG4[1:0] or equivalently accessible as fuse word (bank=1, word=3, bits[1:0])

Values:
  0b00 = Open: HAB authentication disabled, all images boot regardless of signature
  0b10 = Closed: HAB authentication mandatory. Unsigned/incorrectly-signed images rejected.
  0b11 = Field Return: Device returned to NXP for analysis (requires special key)
```

> **Burning SEC_CONFIG = Closed is the most significant single action in the secure boot
> deployment process.** After this:
> - The device will reject any image not signed with the SRK key(s) in OCOTP_SRK fuses
> - If the SRK hash is wrong, the device cannot boot any code
> - This cannot be undone
>
> The correct procedure: burn SRK hash fuses FIRST, verify boot works with the signed image,
> THEN burn SEC_CONFIG = Closed.

### Fuse Programming Order

```
Recommended production fuse burning sequence:

Step 1: OCOTP_SRK0 through OCOTP_SRK7
  Burn the SHA-256 hash of the SRK table.
  Verify by reading back and comparing to srktool output.

Step 2: Verify secure boot works (without SEC_CONFIG=Closed)
  Boot the signed image. Check HAB events: should be zero events.
  This validates the SRK hash is correct before locking.

Step 3: SRK_LOCK (if desired)
  Prevents further writes to SRK fuse rows.
  (Note: the fuses themselves are OTP — already one-time writable.
   SRK_LOCK provides additional protection against fuse blow reset attacks.)

Step 4: BT_FUSE_SEL = 1
  Lock boot configuration to fuses.

Step 5: JTAG_SMODE = 11 (if disabling JTAG)
  Disable JTAG debug access.

Step 6: SEC_CONFIG = Closed (0b10)
  Enable mandatory authentication.
  *** THIS IS THE POINT OF NO RETURN ***

Step 7: SDP_DISABLE = 1 (if disabling serial download)
  Only after verifying all other steps succeeded.
```

---

## 10. Reading Boot Fuses with U-Boot

### fuse Command Reference

The U-Boot `fuse` command reads and programs OCOTP fuses:

```bash
# Syntax:
# fuse read <bank> <word> [<count>]
# fuse prog [-y] <bank> <word> <hex_value>
# fuse override <bank> <word> <hex_value>  ← shadow register only, NOT PERMANENT

# Read OCOTP_CFG4 (Bank 1, Word 3) — boot config, BT_FUSE_SEL, SEC_CONFIG
fuse read 1 3
# Output: Reading bank 1 word 0x00000003... 00000000

# Read all SRK hash fuses (Bank 3, Words 0-7)
fuse read 3 0 8
# Output: Reading bank 3 word 0x00000000... AABBCCDD EEFF0011 ...

# Read chip serial (Bank 0, Words 1-2)
fuse read 0 1 2
```

### Interpreting SEC_CONFIG in U-Boot Output

```bash
fuse read 1 3

# If output is: Reading bank 1 word 0x00000003... 00000002
# Binary: ...0000 0010
#                ^^^^
#                Bit 1 set = SEC_CONFIG = Closed
# Device is in secure boot mode.

# If output is: Reading bank 1 word 0x00000003... 00000000
# All zeros = Open configuration = NOT secure booting
```

### Complete Boot Status Dump Script

```bash
#!/bin/bash
# Run from U-Boot prompt (paste into serial console)
# Or adapt for U-Boot scripting

echo "=== Boot Configuration Fuses ==="
echo "OCOTP_CFG4 (Bank 1, Word 3): Boot device, BT_FUSE_SEL, SEC_CONFIG"
fuse read 1 3

echo ""
echo "=== SRK Hash Fuses ==="
echo "Bank 3, Words 0-7 (SHA-256 of SRK table):"
fuse read 3 0
fuse read 3 1
fuse read 3 2
fuse read 3 3
fuse read 3 4
fuse read 3 5
fuse read 3 6
fuse read 3 7

echo ""
echo "=== Security Configuration ==="
echo "OCOTP_CFG5 (Bank 1, Word 5): JTAG, KTE"
fuse read 1 5

echo ""
echo "=== HAB Status ==="
hab_status
```

### Reading Fuses from Linux

```bash
# Via sysfs nvmem interface
# OCOTP fuse words are at offset: bank * 0x200 + word * 0x10

# Read SEC_CONFIG (Bank 1, Word 3 = offset 0x200 + 0x30 = 0x230)
dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem bs=4 skip=$((0x230/4)) count=1 2>/dev/null | \
    hexdump -e '"SEC_CONFIG: 0x%08x\n"'

# Read SRK hash (Bank 3, Words 0-7 = offset 0x600 to 0x670)
for i in 0 1 2 3 4 5 6 7; do
    offset=$(( (3 * 0x200 + i * 0x10) / 4 ))
    val=$(dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem bs=4 skip=$offset count=1 2>/dev/null | \
          hexdump -e '"%08x"')
    echo "OCOTP_SRK$i = 0x$val"
done

# Via devmem2 (direct register access — reads shadow registers)
# Shadow registers are at: OCOTP_BASE + 0x400 + bank*0x200 + word*0x10
OCOTP_BASE=0x30350000
SHADOW_OFFSET=0x400
BANK=3
WORD=0
ADDR=$((OCOTP_BASE + SHADOW_OFFSET + BANK * 0x200 + WORD * 0x10))
devmem2 $ADDR w
```

### Fuse Programming via U-Boot: Example Sequence

This example demonstrates programming one SRK fuse word. **Do not run this on production
hardware without completing the full validation sequence described in Chapter 11.**

```bash
# From U-Boot prompt:

# 1. Read and record current fuse state
u-boot=> fuse read 3 0 8
Reading bank 3 word 0x00000000...
00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000

# 2. Confirm SRK fuses are all zero (factory default)
# If not zero: STOP. These fuses have already been programmed.

# 3. Program SRK word 0 (from srktool output)
# srktool output: SRK_1_2_3_4_fuse.bin
# Read the values using: hexdump -e '4/4 "0x%08x\n"' SRK_1_2_3_4_fuse.bin
# Example values (REPLACE WITH ACTUAL srktool output):
u-boot=> fuse prog -y 3 0 0xAABBCCDD  # Word 0
u-boot=> fuse prog -y 3 1 0xEEFF0011  # Word 1
u-boot=> fuse prog -y 3 2 0x22334455  # Word 2
u-boot=> fuse prog -y 3 3 0x66778899  # Word 3
u-boot=> fuse prog -y 3 4 0xAABBCCDD  # Word 4
u-boot=> fuse prog -y 3 5 0xEEFF0011  # Word 5
u-boot=> fuse prog -y 3 6 0x22334455  # Word 6
u-boot=> fuse prog -y 3 7 0x66778899  # Word 7

# 4. Read back and verify (must match srktool output exactly)
u-boot=> fuse read 3 0 8
Reading bank 3 word 0x00000000...
AABBCCDD EEFF0011 22334455 66778899 AABBCCDD EEFF0011 22334455 66778899

# 5. Check HAB status with signed image
u-boot=> hab_status
HAB Configuration: 0xf0, HAB State: 0x66
No HAB Events Found!

# 6. (Only after successful boot verification) Close the device:
u-boot=> fuse prog -y 1 3 0x00000002  # SEC_CONFIG = Closed

# 7. Reset and verify secure boot is enforced
u-boot=> reset
```

---

## Cross-References

- `../README.md` — Chapter 06 overview and HABv4 authentication sequence
- `01-ivt-and-boot-container.md` — IVT structure and boot media offsets
- `../11-key-management/02-srk-fuse-programming.md` — Complete SRK fuse programming guide
- `../10-image-signing/01-signing-workflows.md` — Image signing before fuse programming

---

*Chapter 06 / 03 — Boot Mode and Fuse Configuration | Embedded Linux Secure Boot Reference*
