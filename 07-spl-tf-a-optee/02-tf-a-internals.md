# TF-A Internals for i.MX8MP

```
Component: Trusted Firmware-A (TF-A / ATF)
Version:   lf-v2.8 (NXP fork, tag: lf-v2.8)
Platform:  imx8mp
Source:    https://github.com/nxp-imx/imx-atf
```

---

## Overview

TF-A on i.MX8MP is the permanent EL3 supervisor. It runs for the entire lifetime of the system,
handling every transition between secure and non-secure world, servicing PSCI calls from the
operating system, and routing SMC calls to registered handlers. Understanding TF-A internals is
required for:

- Diagnosing boot failures between SPL handoff and U-Boot output
- Configuring TrustZone memory regions correctly
- Enabling Trusted Board Boot (authenticated BL32/BL33 loading)
- Understanding OP-TEE dispatcher and SMC routing
- Implementing platform-specific SiP (Silicon Provider) SMC services

---

## Source Tree: `plat/imx/imx8mp/`

```
trusted-firmware-a/
├── plat/imx/
│   ├── common/                     # Shared across all i.MX8M variants
│   │   ├── imx8m/
│   │   │   ├── imx8m_bl31_setup.c  # BL31 generic setup (GIC, MMU)
│   │   │   ├── imx8m_caam.c        # CAAM initialization for secure world
│   │   │   └── imx8m_measured_boot.c # TPM measured boot hooks (optional)
│   │   ├── imx_gpc.c               # General Power Controller (GPC) driver
│   │   ├── imx_psci.c              # PSCI implementation (CPU_ON/OFF, SYSTEM_RESET)
│   │   ├── imx_sip_handler.c       # SiP SMC service handlers
│   │   ├── imx_sip_svc.c           # SiP service registration
│   │   ├── imx_uart_console.c      # TF-A UART console driver
│   │   └── imx_interrupt_mgmt.c    # IRQ/FIQ routing table
│   │
│   └── imx8mp/                     # i.MX8MP-specific platform code
│       ├── imx8mp_bl31_setup.c     # Main BL31 platform setup
│       ├── imx8mp_bl2_el3_setup.c  # BL2-as-EL3 variant (for FIP loading)
│       ├── platform.mk             # Makefile: flags, source lists
│       ├── imx8mp_def.h            # Platform constants (addresses, sizes)
│       └── include/
│           └── platform_def.h      # Memory map, stack sizes, assertions
│
├── drivers/
│   ├── auth/                       # Authentication framework
│   │   ├── auth_mod.c              # Core CoT (Chain of Trust) logic
│   │   ├── crypto/
│   │   │   └── auth_crypto.c       # Crypto abstraction (mbedtls backend)
│   │   ├── mbedtls/
│   │   │   ├── mbedtls_x509_parser.c  # X.509 certificate parsing
│   │   │   ├── mbedtls_crypto.c    # RSA/ECDSA verification via mbedtls
│   │   │   └── mbedtls_common.c    # mbedtls heap setup
│   │   └── tbbr/
│   │       └── tbbr_cot_bl2.c      # TBBR Chain of Trust image descriptors
│   ├── arm/
│   │   └── gic/
│   │       └── v3/                 # GICv3 driver for i.MX8MP
│   └── imx/
│       ├── clk/                    # Clock driver
│       └── uart/                   # IMX UART driver
│
├── lib/
│   ├── el3_runtime/                # EL3 CPU context save/restore
│   │   ├── aarch64/
│   │   │   ├── context.S           # Assembly save/restore routines
│   │   │   └── context_mgmt.c      # Context management API
│   │   └── cpu_data.c              # Per-CPU data structures
│   ├── psci/                       # PSCI state machine
│   │   ├── psci_main.c             # PSCI dispatch
│   │   ├── psci_on.c               # CPU_ON implementation
│   │   ├── psci_off.c              # CPU_OFF implementation
│   │   └── psci_system_off.c       # SYSTEM_RESET/OFF
│   └── optee/
│       └── optee_utils.c           # OP-TEE header parsing utilities
│
└── services/
    └── spd/
        └── opteed/                 # OP-TEE Secure Payload Dispatcher
            ├── opteed_main.c       # OP-TEE dispatcher: SMC routing
            ├── opteed_pm.c         # OP-TEE power management integration
            └── opteed_helpers.S    # Assembly entry/exit helpers
```

---

## Key Source Files

### `plat/imx/imx8mp/imx8mp_bl31_setup.c`

This is the main platform entry point for TF-A BL31 on i.MX8MP. It is called during BL31
initialization and performs i.MX8MP-specific hardware setup:

```c
/* Primary platform setup — called by bl31_platform_setup() */
void bl31_platform_setup(void)
{
    /* 1. Initialize GIC-400 (interrupt controller) */
    plat_imx8mp_gic_init();
    /* Routes:
     * - Secure interrupts (CAAM, SNVS, etc.) to EL3/Secure EL1
     * - Non-secure interrupts to non-secure EL1/EL2
     * FIQ in NS world is trapped to EL3 (for OP-TEE interrupt routing)
     */

    /* 2. Configure TZASC (TrustZone Address Space Controller) */
    /* Protects secure DRAM regions from non-secure world access */
    imx8mp_init_tzasc();
    /* After this, attempts to access 0xFE000000 from Linux → bus error */

    /* 3. Initialize CAAM for secure world use */
    imx8m_caam_init();
    /* Configures CAAM job rings:
     * Job Ring 0 → secure world (OP-TEE / TF-A)
     * Job Ring 1/2/3 → non-secure world (Linux kernel CAAM driver)
     */

    /* 4. Configure GPC (General Power Controller) for CPU power states */
    imx_gpc_init();
}

/* Platform early setup — called before MMU is initialized */
void bl31_early_platform_setup2(u_register_t arg0, u_register_t arg1,
                                 u_register_t arg2, u_register_t arg3)
{
    /* Console initialization for TF-A debug output */
    console_imx_uart_register(IMX_BOOT_UART_BASE,   /* 0x30890000 */
                               IMX_BOOT_UART_CLK_IN_HZ, /* 24000000 */
                               IMX_CONSOLE_BAUDRATE, /* 115200 */
                               &console);

    /* Store SPL-passed arguments (BL31, BL32, BL33 image info) */
    bl31_params_parse_helper(arg0, &bl32_image_ep_info, &bl33_image_ep_info);
}

/* Returns entry point for BL32 (OP-TEE) or BL33 (U-Boot) */
entry_point_info_t *bl31_plat_get_next_image_ep_info(uint32_t type)
{
    if (type == SECURE)
        return &bl32_image_ep_info;  /* OP-TEE entry */
    else
        return &bl33_image_ep_info;  /* U-Boot entry */
}
```

### `plat/imx/imx8mp/imx8mp_bl2_el3_setup.c`

Used when TF-A is built in `BL2_AT_EL3` mode (loading images from storage):

```c
/* Called when TF-A acts as its own BL2, loading BL31/BL32/BL33 from FIP */
void bl2_el3_plat_arch_setup(void)
{
    /* Initialize storage backend for FIP loading */
    plat_imx_io_setup();  /* Configure eMMC/SD access */
}

/* Platform-specific memory regions for BL2 to load into */
void bl2_plat_get_bl31_params(struct bl2_to_bl31_params_mem *mem)
{
    mem->bl31_image_info.image_base = BL31_BASE;     /* 0x00970000 */
    mem->bl32_ep_info.pc            = BL32_BASE;     /* OP-TEE entry */
    mem->bl33_ep_info.pc            = BL33_BASE;     /* U-Boot entry */
}
```

---

## Trusted Board Boot (TBB)

### What TBB Provides

Trusted Board Boot (TBB) is TF-A's own authentication framework, separate from HABv4. When
enabled (`TRUSTED_BOARD_BOOT=1`), TF-A performs cryptographic authentication of every image
it loads — including BL32 (OP-TEE) and BL33 (U-Boot) — before executing them.

Without TBB:
- TF-A loads and executes BL32/BL33 without any authentication
- Security relies entirely on HABv4 (ROM) + SPL FIT verification

With TBB:
- TF-A uses its own certificate chain to authenticate BL32 and BL33
- Provides a second layer of authentication on top of HABv4/SPL FIT verification
- Required for deployments using the ARM TBBR (Trusted Board Boot Requirements) specification

### Chain of Trust (CoT) for TBBR

```
ROTPK (Root of Trust Public Key)
  → Hash stored in TF-A build configuration or in device fuses
  → On i.MX8MP: hash can be stored in OCOTP via ROTPK_HASH fuse

ROTPK authenticates → Trusted Key Certificate
  Contains: Trusted World Key, Non-Trusted World Key

Trusted World Key authenticates → SoC FW Key Certificate
  SoC FW Key → BL31 certificate → BL31 binary hash

Trusted World Key authenticates → Trusted OS FW Key Certificate
  Trusted OS FW Key → BL32 certificate → BL32 (OP-TEE) binary hash

Non-Trusted World Key authenticates → Non-Trusted FW Content Certificate
  Non-Trusted FW Key → BL33 certificate → BL33 (U-Boot) binary hash
```

### Authentication Framework Source Files

```
drivers/auth/auth_mod.c
─────────────────────────
The core authentication logic. Key functions:

auth_mod_init()
  - Registers the image parser modules (X.509, hash)
  - Registers the crypto library (mbedtls)

auth_mod_verify_img(img_id, img_handle, img_size)
  - Called for each image to be authenticated
  - Looks up the image descriptor in the CoT array
  - For each auth method (hash, signature):
      Get the data to authenticate
      Get the authentication parameter (expected hash/public key)
      Verify using the registered crypto module
  - Returns AUTH_SUCCESS or AUTH_FAIL

The CoT array (tbbr_cot_bl2.c):
  Defines auth_img_desc_t for each image:
    - Image ID (BL31_IMAGE_ID, BL32_IMAGE_ID, etc.)
    - Auth methods (hash check, signature check)
    - Parent image (which image vouches for this one)
```

```c
/* Example: BL32 (OP-TEE) image descriptor in CoT */
static const auth_img_desc_t trusted_os_fw_content_cert = {
    .img_id = TRUSTED_OS_FW_CONTENT_CERT_ID,
    .img_type = IMG_CERT,
    .parent = &trusted_os_fw_key_cert,
    .img_auth_methods = (const auth_method_desc_t[AUTH_METHOD_NUM]) {
        [0] = {
            .type = AUTH_METHOD_SIG,
            .param.sig = {
                .pk    = &trusted_os_fw_signing_key,  /* from key cert */
                .sig   = &sig,                        /* from this cert */
                .data  = &raw_data,                   /* cert body */
                .alg   = &sig_alg,                    /* SHA256withRSA */
            }
        },
        [1] = {
            .type = AUTH_METHOD_NV_CTR,
            .param.nv_ctr = {
                .cert_nv_ctr = &trusted_nv_ctr,      /* rollback counter */
                .plat_nv_ctr = &trusted_nv_ctr,
            }
        }
    },
    .authenticated_data = (const auth_param_desc_t[COT_MAX_VERIFIED_PARAMS]) {
        [0] = {
            .type_desc = &trusted_os_fw_hash,          /* BL32 hash */
            .data.ptr  = (void *)TRUSTED_OS_FW_HASH_OID,
        }
    },
};
```

### Building TF-A with TBB

```bash
# Standard NXP BSP build (no TBB — SPL FIT verification is used instead)
make PLAT=imx8mp \
     CROSS_COMPILE=aarch64-linux-gnu- \
     TRUSTED_BOARD_BOOT=0 \
     GENERATE_COT=0 \
     BL33=../u-boot/u-boot-nodtb.bin \
     BL32=../optee_os/out/arm-plat-imx/core/tee-raw.bin \
     SPD=opteed \
     LOG_LEVEL=20 \
     all fip

# Full TBBR build (both SPL FIT verification AND TF-A TBB active)
make PLAT=imx8mp \
     CROSS_COMPILE=aarch64-linux-gnu- \
     TRUSTED_BOARD_BOOT=1 \
     GENERATE_COT=1 \
     MBEDTLS_DIR=../mbedtls \
     KEY_SIZE=2048 \
     HASH_ALG=sha256 \
     ROT_KEY=../keys/rotpk.pem \
     BL33=../u-boot/u-boot-nodtb.bin \
     BL32=../optee_os/out/arm-plat-imx/core/tee-raw.bin \
     SPD=opteed \
     all fip certificates
```

With `GENERATE_COT=1`, TF-A's `cert_create` tool generates:
- `trusted_key.crt`
- `soc_fw_key.crt`, `soc_fw_content.crt` (for BL31)
- `tos_fw_key.crt`, `tos_fw_content.crt` (for BL32)
- `nt_fw_content.crt` (for BL33)

These certificates are packaged into the FIP alongside the binaries.

---

## Memory Layout with TF-A

The following addresses are from `plat/imx/imx8mp/include/platform_def.h`:

```c
/* TF-A Memory Map for i.MX8MP
 * These must not overlap with each other or with Linux kernel
 */

/*
 * BL31: Resident EL3 code — loaded once, runs forever
 * This DRAM region is protected by TZASC from non-secure access
 */
#define BL31_BASE       UL(0x00960000)
#define BL31_LIMIT      UL(0x00980000)   /* 128KB for BL31 */
/* Physical: Secure OCRAM S on some configurations, or DRAM */

/*
 * BL32: OP-TEE OS
 * CFG_TZDRAM_START in OP-TEE build must match this
 * Size depends on OP-TEE configuration (pager, heap, etc.)
 */
#define BL32_BASE       UL(0xFE000000)
#define BL32_LIMIT      UL(0xFF000000)   /* 16MB for OP-TEE */

/*
 * BL33: U-Boot
 * Non-secure DRAM — accessible from U-Boot and Linux
 */
#define BL33_BASE       UL(0x40200000)
/* No hard limit — U-Boot determines its own size */

/*
 * EL3 Runtime Stack
 * Per-CPU stacks for TF-A EL3 exception handlers
 */
#define PLATFORM_STACK_SIZE  UL(0x1000)  /* 4KB per CPU */
/* 4 CPUs × 4KB = 16KB total EL3 stack space */
```

### TZASC Configuration

The TrustZone Address Space Controller (TZASC) partitions DRAM into secure and non-secure
regions. TF-A configures TZASC in `bl31_platform_setup()`:

```
DRAM Region Configuration (post-TZASC setup)
──────────────────────────────────────────────
0x40000000–0xFDFFFFFF   Non-secure DRAM
  → Accessible from both NS EL1 (Linux) and S EL1 (OP-TEE)
  → U-Boot, kernel, rootfs all live here

0xFE000000–0xFEFFFFFF   Secure DRAM (TZASC-protected)
  → OP-TEE text, data, heap, stack
  → Inaccessible from Linux: read/write → synchronous abort

0xFF000000–0xFFFFFFFF   Secure DRAM (TZASC-protected)
  → OP-TEE secure storage cache
  → OP-TEE page tables (if pager enabled)
```

Non-secure access to the protected range results in:

```
[   12.345678] Unhandled fault: synchronous external abort at 0xfe000000
[   12.345690] Internal error: : 96000010 [#1] SMP
```

This abort is correct behavior — it confirms TZASC is protecting OP-TEE memory.

---

## Debug vs Release Build Differences

| Property | Debug (`DEBUG=1`) | Release (`DEBUG=0`) |
|----------|------------------|---------------------|
| LOG_LEVEL default | 40 (INFO) | 20 (NOTICE) |
| Assertions | Enabled (panic on assert fail) | Disabled |
| Stack protector | Enabled | Disabled |
| Binary size | ~50% larger | Minimal |
| Console UART | Enabled | Configurable |
| NOTICE messages | Yes | Yes |
| INFO/VERBOSE messages | Yes (LOG_LEVEL≥40) | No |
| Optimization | -O1 | -O2 |

### Log Levels

```c
/* include/common/debug.h */
#define LOG_LEVEL_NONE     0
#define LOG_LEVEL_ERROR    10
#define LOG_LEVEL_NOTICE   20
#define LOG_LEVEL_WARNING  30
#define LOG_LEVEL_INFO     40
#define LOG_LEVEL_VERBOSE  50
```

### Interpreting TF-A Console Output

```
NOTICE:  BL31: v2.8(release):lf-v2.8-0-g1234abcd (Oct 01 2024 - 12:00:00 +0000)
NOTICE:  BL31: Built : 12:00:00, Oct  1 2024
INFO:    ARM GICv3 driver initialized in EL3
INFO:    Maximum SPI INTID supported: 991
INFO:    BL31: Initializing runtime services
INFO:    BL31: cortex_a55: CPU workaround for erratum 1530923 was applied
NOTICE:  BL31: Preparing for EL3 exit to normal world
VERBOSE: Entry point address = 0x40200000   ← U-Boot entry
VERBOSE: SPSR = 0x3c9                       ← EL2, AArch64, all ints masked
```

Key lines to watch:
- `NOTICE: BL31:` lines → TF-A identifying itself
- `ERROR:` → something failed (OP-TEE init, GIC setup, etc.)
- Missing output after SPL `Jumping to U-Boot via ARM Trusted Firmware` → TF-A crashed at EL3 init
- `Preparing for EL3 exit to normal world` → TF-A is about to launch U-Boot

If TF-A output is entirely absent after the SPL jump line, verify:
1. `IMX_BOOT_UART_BASE` in platform_def.h matches UART2 at `0x30890000`
2. `LOG_LEVEL` is ≥ 20 (NOTICE) in the build
3. TF-A BL31 binary was correctly extracted from the FIT to `BL31_BASE`

---

## OP-TEE Dispatcher (SPD=opteed)

When `SPD=opteed` is set in the TF-A build, the `services/spd/opteed/` dispatcher is compiled
in. This dispatcher:

1. **BL31 Initialization**: Calls `opteed_init()` during service initialization
   - Passes control to OP-TEE entry point
   - Waits for OP-TEE to signal initialization complete (via SMC return)

2. **SMC Routing**: All SMCs with OEN (Owning Entity Number) 0x32 (Trusted OS Call) are routed
   to `opteed_smc_handler()`

3. **Context Switching**: Saves/restores full CPU state (all registers, system registers,
   floating point) on each world switch

```c
/* opteed_main.c: SMC handler for OP-TEE calls */
static uintptr_t opteed_smc_handler(uint32_t smc_fid,
                                     u_register_t x1, u_register_t x2,
                                     u_register_t x3, u_register_t x4,
                                     void *cookie, void *handle,
                                     u_register_t flags)
{
    /* Check caller is from non-secure world */
    if (is_caller_non_secure(flags)) {
        /* Linux → OP-TEE: save NS context, restore S context, call OP-TEE */
        opteed_synchronous_sp_entry(optee_ctx);
        /* OP-TEE processes the call, returns via another SMC */
    } else {
        /* OP-TEE → Linux: save S context, restore NS context, return to Linux */
        opteed_synchronous_sp_exit(optee_ctx, x1);
    }
}
```

---

## Common TF-A Failure Scenarios

### Failure: TF-A Crashes Before First NOTICE Line

No output after SPL `Jumping to U-Boot via ARM Trusted Firmware`.

**Possible causes**:
1. TF-A was loaded to wrong address (FIT load address ≠ `BL31_BASE`)
2. TF-A was built for wrong UART base address
3. TZASC configuration conflicts with the loaded TF-A region
4. Linker issue: TF-A trying to access non-existent memory at startup

**Diagnosis**:
```bash
# Check TF-A binary entry point
aarch64-linux-gnu-readelf -h build/imx8mp/release/bl31.elf | grep "Entry point"
# Must match BL31_BASE (0x00960000)

# Check load address in FIT
dumpimage -l fitImage | grep -A5 "bl31\|BL31\|tee-fw"
# Load Address field must match BL31_BASE
```

### Failure: OP-TEE Does Not Initialize

```
NOTICE:  BL31: Initializing runtime services
ERROR:   Error initializing runtime service opteed_fast
```

**Cause**: BL32 (OP-TEE) is missing from the FIT, loaded to wrong address, or incompatible.

**Diagnosis**:
```bash
# Verify OP-TEE is in the FIT
dumpimage -l fitImage | grep -i "tee\|optee\|bl32"

# Check OP-TEE entry address matches TF-A expectation
# In optee_os build: CFG_TZDRAM_START must match BL32_BASE in TF-A
grep CFG_TZDRAM_START optee_os/.config
# Compare with platform_def.h BL32_BASE
```

### Failure: U-Boot Does Not Start (TF-A Hangs After OP-TEE)

```
NOTICE:  BL31: Preparing for EL3 exit to normal world
[ hangs ]
```

**Cause**: U-Boot binary at BL33_BASE is incorrect or BL33 entry address is wrong.

**Diagnosis**:
```bash
# Check U-Boot load address in FIT
dumpimage -l fitImage | grep -A5 "u-boot\|bl33"
# Load Address and Entry Point must both be 0x40200000

# Verify U-Boot was compiled for correct text base
grep CONFIG_TEXT_BASE u-boot/.config
# Must be 0x40200000
```

---

*Chapter 07 — TF-A Internals | Embedded Linux Secure Boot Reference*
