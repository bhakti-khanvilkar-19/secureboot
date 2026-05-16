# SPL Security Configuration: Kconfig Reference and Memory Map

```
Component: U-Boot SPL
Platform:  NXP i.MX8M Plus (phyCORE-i.MX8MP SOM, phyBOARD-Pollux carrier)
U-Boot:    2023.04 (NXP lf-6.1.55-2.2.0)
Defconfig: phycore-imx8mp_defconfig
```

---

## Overview

SPL configuration has direct security implications. Enabling or disabling the wrong Kconfig
options can silently break the authentication chain — SPL may boot successfully while skipping
signature verification entirely. This document covers every security-relevant SPL option with
full explanation of what enabling or disabling each option means at runtime.

---

## Critical Kconfig Options

### Core SPL Enable

```kconfig
# Enable SPL subsystem (mandatory for i.MX8MP — no SPL means no boot)
CONFIG_SPL=y

# Enable SPL framework (provides spl_init(), spl_load_image(), etc.)
CONFIG_SPL_FRAMEWORK=y
```

### FIT Image Support

```kconfig
# Enable FIT (Flat Image Tree) image format in SPL
# Without this, SPL can only load raw binaries — not the multi-component
# imx-boot container that includes TF-A, OP-TEE, and U-Boot
CONFIG_SPL_FIT=y

# Enable FIT signature verification in SPL
#
# SECURITY CRITICAL: This is the option that makes SPL actually enforce
# authentication of the FIT image. If this is disabled, SPL will load
# and execute FIT images without verifying their RSA signatures.
#
# When enabled:
# - SPL reads the public key from its embedded device tree
# - For each FIT configuration, verifies the RSA signature
# - Panics if verification fails: "Failed to verify required signature"
#
# When disabled:
# - SPL loads FIT images with no signature check
# - Even if mkimage signed the FIT, SPL ignores the signatures
# - Authentication chain is broken at the SPL stage
CONFIG_SPL_FIT_SIGNATURE=y

# Enable FIT-based image loading in SPL
# This selects the SPL code path that reads a FIT image from the boot device,
# parses the FIT structure, and loads each sub-image (TF-A, OP-TEE, U-Boot)
# into its destination address.
CONFIG_SPL_LOAD_FIT=y

# Minimal FIT image info output (saves ~2KB vs full FIT_VERBOSE)
# Use FIT_VERBOSE=y during development for detailed verification output
CONFIG_SPL_FIT_IMAGE_TINY=n
```

### Cryptographic Libraries

```kconfig
# RSA support in SPL
# Required for FIT signature verification (RSA-2048 or RSA-4096)
# This compiles the RSA key parsing and verification code into SPL
CONFIG_SPL_RSA=y

# Software RSA modular exponentiation
# Used when no hardware RSA accelerator is available in SPL context
# On i.MX8MP, CAAM is not yet fully initialized when SPL runs FIT verification,
# so software RSA is used for the FIT verification step
CONFIG_SPL_RSA_SOFTWARE_EXP=y

# Cryptographic framework in SPL
# Provides the common crypto API layer used by FIT verification
CONFIG_SPL_CRYPTO=y

# Hash computation framework
# Required for SHA-256/384 hash verification of FIT image components
CONFIG_SPL_HASH=y

# SHA-256 hash algorithm
# Standard algorithm for FIT image hash verification
CONFIG_SPL_SHA256=y

# SHA-384 hash algorithm (stronger, larger output)
# Use if FIT images are signed with sha384,rsa4096 algorithm
CONFIG_SPL_SHA384=y

# SHA-512 hash algorithm
CONFIG_SPL_SHA512=n
```

### Driver Model

```kconfig
# Driver Model in SPL
# Modern U-Boot driver framework. Required for most SPL drivers.
# Without DM, only legacy non-DM drivers are available.
CONFIG_SPL_DM=y

# DM-based MMC driver (required for eMMC/SD access via driver model)
CONFIG_SPL_DM_MMC=y

# DM-based GPIO driver (required for board control signals)
CONFIG_SPL_DM_GPIO=y

# DM-based sequential storage (for FIT image loading from MMC)
CONFIG_SPL_DM_SEQ_STORE=y

# Pincontrol in SPL (set pad configurations before DDR init)
CONFIG_SPL_PINCTRL=y

# PMIC support in SPL (power sequencing for DDR and core rails)
CONFIG_SPL_POWER=y
CONFIG_SPL_POWER_I2C=y

# Regulator framework in SPL
CONFIG_SPL_DM_REGULATOR=y
```

### Debug UART Configuration

```kconfig
# Enable early debug UART
# This UART is initialized via a direct register write sequence,
# before the driver model UART is set up. It produces output from
# the very first printable SPL instruction.
CONFIG_DEBUG_UART=y

# Select the UART driver variant (i.MX UART = LPUART with MX6 compatibility)
CONFIG_DEBUG_UART_MX6=y

# UART2 base address on i.MX8MP
# UART1: 0x30860000 (often used for debug on some boards)
# UART2: 0x30890000 (phyBOARD-Pollux default debug console)
# UART3: 0x308C0000
# UART4: 0x30A60000
CONFIG_DEBUG_UART_BASE=0x30890000

# UART reference clock on i.MX8MP
# The 24 MHz OSC clock is available before PLL initialization
# Do NOT use a PLL-derived clock here — PLLs are not yet configured
CONFIG_DEBUG_UART_CLOCK=24000000

# UART baud rate for debug output
CONFIG_BAUDRATE=115200

# Serial support in SPL (high-level UART framework)
CONFIG_SPL_SERIAL=y
```

### Board Initialization Hook

```kconfig
# Enable board-specific SPL initialization hook
# When enabled, the build expects a spl_board_init() function in
# board/<vendor>/<board>/spl.c or board/<vendor>/<board>/<board>.c
#
# For phyCORE-i.MX8MP, spl_board_init() performs:
# - Power enable for DDR VDD rails via PMIC
# - Enable of external oscillators
# - Any board-specific early hardware configuration
CONFIG_SPL_BOARD_INIT=y
```

### FIT Signature Verbosity

```kconfig
# Master FIT signature flag (for U-Boot proper, set in SPL context too)
CONFIG_FIT_SIGNATURE=y

# Print detailed FIT verification information during boot
# Produces output like:
#   Using 'conf@1' configuration
#   Verifying Hash Integrity ... sha256+ OK
#   Verified OK, SIGNATURE sha256,rsa2048:fit-key (1)
#
# Disable in production for minimal boot time and output
CONFIG_FIT_VERBOSE=y
```

---

## SPL Memory Map on i.MX8MP

### Physical OCRAM Layout

The i.MX8MP has 512 KB of OCRAM (On-Chip RAM) at physical address range 0x900000–0x97FFFF.
This is the only RAM available before DDR training completes.

```
OCRAM Map (0x900000 – 0x97FFFF, 512 KB total)
────────────────────────────────────────────────────────────────────────
Address             Size    Content                         Access
────────────────────────────────────────────────────────────────────────
0x900000–0x90FFFF   64KB    Boot ROM workspace              ROM only
                             (ROM stack, HAB working area,
                              IVT/Boot Data parsing buffers)

0x910000–0x91FFFF   64KB    DDR PHY training workspace      ROM/SPL
                             (DDR controller registers,
                              training result staging)

0x920000–0x93BFFF  112KB    SPL: code (.text) + rodata     SPL
                             - Linked to execute here
                             - CONFIG_SPL_TEXT_BASE=0x920000
                             - This region must fit u-boot-spl.bin

0x93C000–0x93DFFF    8KB    SPL: BSS (zero-initialized)    SPL
                             - global variables, static data

0x93E000–0x93EFFF    4KB    SPL: heap                      SPL

0x93F000–0x93FFFF    4KB    SPL: stack                     SPL
                             - Stack grows downward from 0x940000
────────────────────────────────────────────────────────────────────────
0x940000–0x95FFFF  128KB    DDR training firmware staging  SPL
                             lpddr4_pmu_train_1d_imem.bin loaded here

0x960000–0x97FFFF  128KB    DDR training firmware staging  SPL
                             lpddr4_pmu_train_2d_imem.bin loaded here
────────────────────────────────────────────────────────────────────────

OCRAM S (Secure OCRAM, EL3 only):
0x7E0000–0x7FFFFF  128KB    Secure OCRAM                   EL3 only
                             Used by TF-A BL31 for EL3 stack and data
```

### Linker Script and Size Limits

The SPL linker script (`arch/arm/cpu/armv8/u-boot-spl.lds`) enforces these regions:

```ld
MEMORY {
    sram (rwx) : ORIGIN = CONFIG_SPL_TEXT_BASE, LENGTH = CONFIG_SPL_SIZE
}
/* CONFIG_SPL_TEXT_BASE = 0x920000 */
/* CONFIG_SPL_SIZE      = 0x1C000 (112KB for i.MX8MP) */
```

If the SPL binary exceeds `CONFIG_SPL_SIZE`, the linker will fail with:

```
ld.bfd: spl/u-boot-spl section `.text' will not fit in region `sram'
ld.bfd: region `sram' overflowed by 4096 bytes
```

### Size Analysis Tools

```bash
# Total SPL binary size
wc -c spl/u-boot-spl.bin

# Section sizes (code, data, BSS)
aarch64-linux-gnu-size spl/u-boot-spl

# Largest functions contributing to size
nm --size-sort -r spl/u-boot-spl | head -30

# Largest object files contributing to size
# (parse from .map file)
grep -E "^\s+[0-9a-f]" spl/u-boot-spl.map | \
    awk '{size=strtonum("0x"$2); print size, $NF}' | \
    sort -rn | head -20

# Check if FIT signature verification code is present
nm spl/u-boot-spl | grep fit_image_verify_required_sigs
# If this symbol is absent, CONFIG_SPL_FIT_SIGNATURE is not active
```

---

## SPL Execution Flow: Detailed Trace

### Phase 1: ARM Entry Point

```
Entry: 0x920000 (arch/arm/cpu/armv8/start.S: _start)
───────────────────────────────────────────────────────

_start:
    /* Save x0 (boot info from ROM) */
    adr x0, vectors
    msr vbar_el3, x0        /* Set EL3 exception vector */

    /* Clear registers */
    mov x0, #0
    ...
    mov x28, #0

    /* Set up early stack */
    ldr x0, =0x00940000     /* Stack top (OCRAM end of SPL region) */
    mov sp, x0

    /* Branch to lowlevel_init */
    bl  lowlevel_init
    bl  _main               /* → board_init_f → board_init_r */
```

### Phase 2: Early Hardware Initialization

```
lowlevel_init() [board/phytec/phycore_imx8mp/spl.c]
───────────────────────────────────────────────────
1. arch_cpu_init()
   - Enable instruction cache
   - Disable EL3 data cache (not safe until MMU configured)
   - Set EL3 stack pointer to 0x93F800

2. init_uart_clk(2)   [UART2 = console on phyBOARD-Pollux]
   - Program UART2 clock gate in CCM
   - Set UART2 clock source to 24MHz OSC

3. debug_uart_init()  [drivers/serial/serial_mxc.c]
   - Write directly to UART2 registers at 0x30890000
   - Set baud rate divisor for 115200 @ 24MHz
   - Enable UART transmitter
```

### Phase 3: Board Init F (Pre-DDR)

```
board_init_f() [common/spl/spl.c → init_sequence_f[]]
──────────────────────────────────────────────────────
Calls init functions in sequence:
  setup_mon_len()         → compute SPL memory bounds
  initf_malloc()          → initialize heap
  arch_cpu_init()         → CPU-level initialization
  board_early_init_f()    → board-specific pre-DDR init
    → i2c_init()          → initialize I2C for PMIC
    → pmic_init()         → PCA9450 initialization
        Write BUCK1 = 0.9V  (VDD_SOC)
        Write BUCK4 = 3.3V  (VDD_3P3)
        Write LDO1  = 1.8V  (VDD_SNVS)
  timer_init()            → ARM generic timer
  board_init_f()          → enable WDOG1
  console_init_f()        → redirect console to UART2
```

Output at this point:
```
U-Boot SPL 2023.04-lf-5.15.71-2.2.0+g98abc1234 (Oct 01 2024 - 12:00:00 +0000)
PMIC: PMIC_PCA9450 is found
Normal Boot
```

### Phase 4: DDR Initialization

```
ddr_init() [drivers/ddr/imx/imx8mp_ddr_init.c]
───────────────────────────────────────────────
DDRINFO: start DRAM init

1. Load DDR training firmware into OCRAM staging area:
   Source: eMMC offset (embedded in SPL image or loaded from boot partition)
   lpddr4_pmu_train_1d_imem_202006.bin → 0x940000 (128KB max)
   lpddr4_pmu_train_1d_dmem_202006.bin → 0x960000 (128KB max)

2. ddr_cfg_phy() → configure DDR PHY controller registers
   Write ~800 register values for LPDDR4 at 4000MT/s (phyCORE specification)

3. Execute 1D training:
   Release DDR PHY microcontroller from reset
   Microcontroller runs lpddr4_pmu_train_1d_*
   Poll mailbox for completion: ~200ms
   Read training results from DMem

4. Load 2D firmware:
   lpddr4_pmu_train_2d_imem_202006.bin → 0x940000
   lpddr4_pmu_train_2d_dmem_202006.bin → 0x960000

5. Execute 2D training:
   Additional training for read/write eye margin optimization
   ~300ms

6. Load training results into DDR controller shadow registers

7. Configure DDRC (DDR Controller):
   Set timing parameters from training results
   Enable DDR SDRAM controller
   Configure address mapping

DDRINFO: DRAM rate 4000MTS
DDRINFO: 1D training done
DDRINFO: 2D training done
DDRINFO: DRAM init done
```

After this step, DDR is operational and SPL can use the full 4GB (or configured size) of DRAM.

### Phase 5: FIT Image Load

```
spl_load_image_fit() [common/spl/spl_fit.c]
────────────────────────────────────────────
Trying to boot from MMC1

1. Open eMMC: mmc_init(mmc_dev=0)
   Device: USDHC3 (eMMC on phyCORE-i.MX8MP)
   Boot partition: mmcblk2boot0

2. Read FIT header:
   mmc_bread(0, 0, 2, buf)  → read first 1KB from boot partition
   fit_check_header(buf)     → verify FDT magic 0xD00DFEED

3. Determine FIT load address:
   Default: 0x48000000 (configured in DTS or Kconfig)
   Must not overlap with SPL OCRAM region

4. Load entire FIT image to DRAM:
   fit_image_get_data() → get FIT total size
   mmc_bread(0, 0, nblocks, 0x48000000) → copy FIT to DRAM
   → FIT size is typically 20-50MB (kernel + DTB + modules in initramfs)

Trying to boot from MMC1
```

### Phase 6: FIT Signature Verification (CONFIG_SPL_FIT_SIGNATURE=y)

```
fit_image_verify_required_sigs() [common/image-fit-sig.c]
──────────────────────────────────────────────────────────
## Loading kernel from FIT Image at 48000000 ...
   Using 'conf@1' configuration

For each image referenced by conf@1:
  1. Locate image hash node (hash@1 with algo="sha256")
  2. Compute SHA-256 of image data in DRAM
  3. Compare against hash value stored in FIT

  Verifying Hash Integrity ... sha256+ OK

4. Locate configuration signature node (signature@1)
5. Get key-name-hint: "fit-signing-key"
6. Find public key in SPL's compiled-in DTB:
   /signature/key-fit-signing-key
7. Extract RSA-2048 modulus, exponent from key node
8. Compute SHA-256 over signed data (all sign-images)
9. Perform RSA-2048 software verification:
   result = rsa_verify(public_key, signature, digest)
10. If verification passes:
    Verified OK, SIGNATURE sha256,rsa2048:fit-signing-key (1)

If any verification fails:
  ERROR: Failed to validate required signature
  ### ERROR ### failed to verify FIT signature
  ### ERROR ### can't get kernel image!
  [SPL panics → reset]
```

### Phase 7: Image Extraction and Jump

```
spl_fit_select_fdt() + jump
────────────────────────────
## Loading fdt from FIT Image at 48000000 ...
   Verifying Hash Integrity ... sha256+ OK

Extract from FIT:
  BL31 (TF-A): load to 0x00970000 (secure DRAM)
  BL32 (OP-TEE): load to 0xFE000000 (secure DRAM partition)
  BL33 (U-Boot): load to 0x40200000 (non-secure DRAM)

Flush D-cache (ensure TF-A sees correct data in DRAM):
  flush_dcache_range(0x00970000, ...)
  flush_dcache_range(0xFE000000, ...)
  flush_dcache_range(0x40200000, ...)

Jumping to U-Boot via ARM Trusted Firmware

jump_to_image_no_args(spl_image):
  x0 = spl_image->entry_point  (= TF-A BL31 entry: 0x00970000)
  br  x0
  [SPL ends, TF-A begins]
```

---

## phyCORE-i.MX8MP Defconfig: Security Options

The complete security-relevant section of `phycore-imx8mp_defconfig`:

```kconfig
# arch/arm/Kconfig
CONFIG_ARCH_IMX8M=y
CONFIG_TARGET_PHYCORE_IMX8MP=y

# === SPL Core ===
CONFIG_SPL=y
CONFIG_SPL_FRAMEWORK=y
CONFIG_SPL_TEXT_BASE=0x920000
CONFIG_SPL_MAX_SIZE=0x26000        # 152KB: code + data + rodata limit
CONFIG_SPL_STACK=0x940000          # Stack top (grows downward)
CONFIG_SPL_BSS_START_ADDR=0x93C000 # BSS region start
CONFIG_SPL_BSS_MAX_SIZE=0x2000     # 8KB BSS max

# === FIT and Signature ===
CONFIG_SPL_FIT=y
CONFIG_SPL_FIT_SIGNATURE=y
CONFIG_SPL_LOAD_FIT=y
CONFIG_FIT=y
CONFIG_FIT_SIGNATURE=y
CONFIG_FIT_VERBOSE=y
CONFIG_FIT_BEST_MATCH=y

# === Crypto for SPL ===
CONFIG_SPL_RSA=y
CONFIG_SPL_RSA_SOFTWARE_EXP=y
CONFIG_SPL_CRYPTO=y
CONFIG_SPL_HASH=y
CONFIG_SPL_SHA256=y
CONFIG_SPL_SHA384=y
CONFIG_SPL_MD5=n                   # Not needed; not used for FIT

# === UART / Console ===
CONFIG_SPL_SERIAL=y
CONFIG_DEBUG_UART=y
CONFIG_DEBUG_UART_MX6=y
CONFIG_DEBUG_UART_BASE=0x30890000  # UART2 on phyBOARD-Pollux
CONFIG_DEBUG_UART_CLOCK=24000000   # 24MHz OSC reference
CONFIG_BAUDRATE=115200

# === Driver Model ===
CONFIG_SPL_DM=y
CONFIG_SPL_DM_MMC=y
CONFIG_SPL_DM_GPIO=y
CONFIG_SPL_PINCTRL=y
CONFIG_SPL_POWER=y
CONFIG_SPL_POWER_I2C=y
CONFIG_SPL_DM_REGULATOR=y

# === Board Init ===
CONFIG_SPL_BOARD_INIT=y
CONFIG_SPL_WATCHDOG=y

# === MMC / Boot Device ===
CONFIG_SPL_MMC=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_SDMA=y
CONFIG_MMC_SDHCI_IMX=y
CONFIG_SPL_MMC_HS200_ENABLE=y      # Enable eMMC HS200 in SPL

# === i.MX8MP-specific DDR ===
CONFIG_IMX8MP_LPDDR4_TRAIN=y       # Include LPDDR4 training code
CONFIG_SPL_IMX_ROMAPI_LOADADDR=0x48000000  # FIT load address in DRAM

# === Security Hardening (SPL level) ===
CONFIG_SPL_USE_ARCH_MEMSET=y       # Use ARM-optimized memset
CONFIG_SPL_PANIC_ON_MISSING_REQUIRED_SIGS=y  # Panic on signature failure
```

---

## Verifying SPL Configuration Is Security-Active

After building SPL, verify the security configuration is correctly compiled in:

```bash
# 1. Confirm CONFIG_SPL_FIT_SIGNATURE is active
grep CONFIG_SPL_FIT_SIGNATURE spl/.config
# Expected: CONFIG_SPL_FIT_SIGNATURE=y

# 2. Confirm the FIT verification symbol is in the binary
aarch64-linux-gnu-nm spl/u-boot-spl | grep -i fit_image_verify
# Expected: symbols like:
# 0092xxxx T fit_image_verify_required_sigs
# 0092xxxx T fit_config_verify_required_sigs

# 3. Confirm RSA is compiled in
aarch64-linux-gnu-nm spl/u-boot-spl | grep -i rsa
# Expected: rsa_verify, rsa2048_verify, etc.

# 4. Check SPL size is within limit
SPL_SIZE=$(wc -c < spl/u-boot-spl.bin)
MAX_SIZE=155648   # 152KB
if [ $SPL_SIZE -gt $MAX_SIZE ]; then
    echo "WARNING: SPL too large: $SPL_SIZE > $MAX_SIZE"
else
    echo "OK: SPL size $SPL_SIZE bytes"
fi

# 5. Confirm embedded key exists in SPL DTB
# The SPL must have the public key compiled into its device tree
# This is done by mkimage -K at build time
fdtdump spl/u-boot-spl-dtb.bin 2>/dev/null | grep -A5 "signature"
# Expected: /signature/key-fit-signing-key node with algo, rsa,num-bits, etc.
```

---

## Key Embedding in SPL DTB

The public key used to verify the FIT image is embedded in U-Boot's device tree, which is
compiled into SPL. This embedding is done at build time by `mkimage -K`:

```bash
# Step 1: Build U-Boot (produces u-boot.dtb without key)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)

# Step 2: Sign FIT image AND embed public key in u-boot.dtb
mkimage -F fitImage -k keys/ -K u-boot.dtb -r
# -F: modify existing FIT in-place
# -k: key directory containing fit-signing-key.pem and .crt
# -K: destination DTB to embed public key into
# -r: mark signatures as required (verification is enforced)

# Step 3: Rebuild U-Boot with updated u-boot.dtb (key now embedded)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)

# The rebuilt u-boot-spl.bin now contains the public key.
# Verify:
aarch64-linux-gnu-objdump -s spl/u-boot-spl | grep -A4 "sha256"
```

This chicken-and-egg process (build U-Boot, sign FIT, rebuild U-Boot) is why the Yocto
`kernel-fitimage.bbclass` has a specific signing step that triggers a U-Boot DTB update.

---

## Troubleshooting SPL Configuration Issues

### Issue: SPL Boots But Does Not Verify FIT

**Symptom**: Boot succeeds with a modified/unsigned FIT, no signature error is shown.

**Diagnosis**:
```bash
grep CONFIG_SPL_FIT_SIGNATURE spl/.config
# If output is: # CONFIG_SPL_FIT_SIGNATURE is not set
# → SPL was built without signature verification
```

**Root cause**: The defconfig did not have `CONFIG_SPL_FIT_SIGNATURE=y`, or it was overridden
by a menuconfig change that was not committed back to the defconfig.

**Fix**:
```bash
# Ensure defconfig contains:
echo "CONFIG_SPL_FIT_SIGNATURE=y" >> configs/phycore-imx8mp_defconfig
# Rebuild with savedefconfig to normalize:
make phycore-imx8mp_defconfig
make savedefconfig
```

### Issue: SPL Too Large

**Symptom**: Linker error: `region 'sram' overflowed`

**Analysis**:
```bash
# Find largest size contributors
nm --size-sort -r spl/u-boot-spl | head -20
# Common large items:
#   ddr_fw_lpddr4_pmu_train_1d_imem (DDR firmware, if embedded in SPL)
#   rsa_verify functions (~8KB)
#   fit_image_* functions (~6KB)
```

**Fixes**:
- Move DDR firmware to eMMC rather than embedding in SPL
- Set `CONFIG_SPL_FIT_IMAGE_TINY=y` to reduce FIT info printing
- Disable `CONFIG_SPL_BANNER_PRINT=n`
- Enable link-time optimization: `CONFIG_LTO=y`

### Issue: SPL Panics at FIT Verification

**Symptom**:
```
## Loading kernel from FIT Image at 48000000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ... sha256+ Bad hash value for 'sha256'
```

**Diagnosis**: The FIT was signed with a key whose public half is NOT embedded in the SPL.

**Fix**:
1. Identify the key currently embedded in SPL:
   ```bash
   fdtdump spl/u-boot-spl-dtb.bin | grep "key-name"
   ```
2. Ensure the corresponding private key is used to sign the FIT:
   ```bash
   mkimage -F fitImage -k keys/ -K u-boot.dtb -r
   # Where keys/ contains fit-signing-key.pem and fit-signing-key.crt
   # And "fit-signing-key" matches the key name embedded in SPL DTB
   ```

---

*Chapter 07 — SPL Configuration | Embedded Linux Secure Boot Reference*
