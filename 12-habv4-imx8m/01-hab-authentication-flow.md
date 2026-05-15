# HABv4 Authentication Flow: Deep Dive

```
Tested Against:
  - NXP i.MX8M Plus Boot ROM v2
  - NXP CST: 3.3.1
  - U-Boot: 2023.04 (NXP lf-6.1.55-2.2.0)
Last Validated: 2024-Q2
```

---

## ROM Execution and HAB Initialization

When the i.MX8MP powers on or resets, the ARM Cortex-A53 cores start execution at the reset vector mapped to Boot ROM. The ROM is mapped at physical address `0x0000_0000` (aliased from the internal ROM base). The reset vector at `0x0000_0000` jumps to the ROM entry point.

### ROM Pre-HAB Initialization Sequence

Before HAB can authenticate anything, the ROM must configure sufficient hardware to load an image:

```
ROM reset vector
     │
     ▼
Clock initialization
  ├─ 24 MHz XTAL enabled
  ├─ Minimum PLL configuration for DRAM access
  └─ Security clock (CAAM_CLK, SNVS_CLK) enabled
     │
     ▼
SNVS initialization
  ├─ Read SNVS_HPSR (HP Status Register) for tamper/security state
  ├─ Check LP_VIO_CTL (Voltage Tamper detect status)
  └─ Clear pending tamper events (if recoverable)
     │
     ▼
CAAM initialization
  ├─ Enable CAAM clock
  ├─ Initialize CAAM Job Rings
  ├─ Configure CAAM security level from fuses
  └─ CAAM self-test (AES, SHA-256 KAT)
     │
     ▼
HAB library initialization
  ├─ HAB state machine → HAB_ST_INITIAL
  ├─ Clear event log buffer in OCRAM
  ├─ Read SRK_HASH fuses into HAB internal state
  ├─ Read SEC_CONFIG fuse (open/closed mode)
  └─ Read SRK_REVOKE fuses
     │
     ▼
Boot mode detection
  ├─ Read BOOT_MODE[1:0] pins
  ├─ Read BOOT_CFG fuses for boot media selection
  └─ Initialize boot media driver (eMMC/SD/SPI-NOR/USB)
```

### Boot Mode Pin States

| BOOT_MODE[1:0] | Boot Source |
|----------------|-------------|
| 00 | Boot from fuses (BOOT_CFG) |
| 01 | Serial Downloader (USB OTG) |
| 10 | Internal Boot (boot device from BOOT_CFG) |
| 11 | Reserved |

For production i.MX8MP boards (phyCORE-i.MX8MP), `BOOT_MODE = 10` (internal boot) is normal.

---

## Image Loading from Boot Media

After boot media initialization, the ROM loads the first-stage image. The load process depends on the boot media:

### eMMC Boot (most common production configuration)

```
eMMC Boot Partition 1 (or User Area + offset)
     │
     ▼
ROM reads first 4 KB from offset 0x8000 (32 KB)
  [This is where imx-mkimage places the IVT for eMMC]
     │
     ▼
Validate IVT header: tag=0xD1, ver=0x43
     │
     ├─ Invalid? → Try next boot device (if configured)
     │
     ▼
Read Boot Data structure from IVT→boot_data pointer
  ├─ plugin flag: 0 = standard, 1 = bootloader plugin
  ├─ start: destination load address (OCRAM or DDR)
  └─ size: number of bytes to load
     │
     ▼
DMA transfer: boot media → load address
```

The eMMC offset `0x8000` (32 KB) is defined in the i.MX8MP Boot ROM. For SD card boot, the offset is also `0x8000`. For SPI-NOR boot, the offset is `0x0000`.

### Image Load Addresses

On i.MX8MP, the SPL (U-Boot Secondary Program Loader) is loaded into OCRAM:
- OCRAM base: `0x0090_0000`
- SPL typical load address: `0x0092_0000`
- Maximum OCRAM available for SPL: 256 KB

The IVT `boot_data.start` field specifies the actual load address used. This must match the address used at link time.

---

## Image Vector Table (IVT) Parsing

After loading the image, the ROM validates the IVT. The IVT is always at a fixed offset from the image start:

```
For eMMC/SD: offset 0x0 from the 32KB offset (i.e., IVT IS at 0x8000 in flash)
For SPI-NOR:  offset 0x0 from flash start

IVT is at the BEGINNING of the loaded image.
```

IVT binary layout (20 bytes, all fields big-endian except entry/dcd/boot_data/self/csf which are little-endian load addresses):

```
Offset  Size  Field       Notes
0x00    1     tag         Must be 0xD1
0x01    2     length      Total IVT length, big-endian = 0x0020 (32 bytes)
0x03    1     version     0x43 for HABv4.3
0x04    4     entry       Entry point: address to jump to after auth
0x08    4     reserved1   Must be 0x00000000
0x0C    4     dcd         DCD pointer (or 0 if no DCD)
0x10    4     boot_data   Boot Data structure pointer
0x14    4     self        IVT self-address (IVT's own load address)
0x18    4     csf         CSF pointer (0 if unsigned)
0x1C    4     reserved2   Must be 0x00000000
```

The ROM validates:
1. `tag == 0xD1` — correct IVT magic
2. `version == 0x43` — supported HAB version
3. `self` matches the known IVT load address (prevents relocation attacks)
4. `entry` is within an allowed address range

### Boot Data Structure

The IVT `boot_data` pointer points to:
```c
typedef struct {
    uint32_t start;     /* Absolute start address of image in memory */
    uint32_t size;      /* Total size of image to authenticate */
    uint32_t plugin;    /* Plugin flag: 0=normal, 1=plugin */
    uint32_t pad0;      /* Padding */
} boot_data_t;
```

The `size` field determines how much data the ROM DMA-loads before attempting authentication. It must cover all data referenced in the CSF `Authenticate Data` blocks.

---

## CSF Location and Initial Parsing

The IVT `csf` field points to the start of the CSF in memory (it has been loaded along with the image). The ROM validates the CSF header before executing any commands:

```c
/* CSF header structure */
typedef struct {
    uint8_t  tag;       /* Must be 0xD4 */
    uint16_t length;    /* Total CSF length, big-endian */
    uint8_t  version;   /* 0x43 = HABv4.3 */
} csf_hdr_t;
```

If the CSF header is invalid (wrong tag or version), the ROM records `HAB_INV_CSF` and either halts (CLOSED) or continues (OPEN).

---

## CSF Command Execution Detail

Each CSF command has a 4-byte header:
```
Byte 0: Command tag
Byte 1-2: Command length (big-endian, includes header)
Byte 3: Command parameter byte
```

The ROM executes commands in order. Execution state carries over between commands: authenticated keys from earlier commands are available to later commands.

### Command 1: Header

```
Tag: 0xD4 (this is actually the CSF header itself, not a command)
Version: 0x43
```

Not executed as a command but validates the CSF structure version.

### Command 2: Install SRK

```
Tag: 0xC0
```

Parameters embedded in command:
- `ins_tbl`: Which table to install (always SRK table = 0x03)
- `alg`: Hash algorithm used for SRK hash verification
- `src_index`: Which SRK entry in the table to use (0-3)
- `tgt_index`: Internal HAB key slot to install into

Execution:
```
1. Load SRK table from CSF data area
2. Compute SHA-256(entire SRK table)
3. Read SRK_HASH[7:0] fuses (256 bits = 8 fuse words)
4. Compare computed hash vs fuse value
5. If mismatch: record HAB_INV_CERTIFICATE, abort
6. Read SRK_REVOKE fuse bits
7. If SRK[src_index] is revoked: record HAB_INV_KEY, abort
8. Store SRK[src_index] public key in HAB internal key slot
```

The SRK_HASH fuse layout on i.MX8MP:
```
OCOTP Bank 6:
  Word 0 (0x30350C00): SRK_HASH[31:0]
  Word 1 (0x30350C10): SRK_HASH[63:32]
  Word 2 (0x30350C20): SRK_HASH[95:64]
  Word 3 (0x30350C30): SRK_HASH[127:96]
  Word 4 (0x30350C40): SRK_HASH[159:128]
  Word 5 (0x30350C50): SRK_HASH[191:160]
  Word 6 (0x30350C60): SRK_HASH[223:192]
  Word 7 (0x30350C70): SRK_HASH[255:224]
```

### Command 3: Install CSFK

```
Tag: 0xBF
```

Execution:
```
1. Load CSF key (CSFK) certificate from CSF data area
2. Certificate is X.509 format, signed by the SRK
3. Verify certificate signature:
   - Extract SRK public key (installed in previous step)
   - Compute RSA_VERIFY(SRK_pubkey, cert_signature) == SHA256(cert_tbsCertificate)
4. If invalid signature: record HAB_INV_CERTIFICATE, abort
5. If valid: store CSFK public key in HAB internal key slot 1
```

### Command 4: Authenticate CSF

```
Tag: 0xBF (same tag as Install Key — distinguished by context)
```

This command authenticates the CSF binary itself. The CMS (PKCS#7) signature over the CSF is embedded after the CSF commands. Execution:
```
1. Identify the CSF region to authenticate (from Header to this command's start)
2. Compute SHA-256(CSF bytes)
3. Load CMS SignedData from embedded signature blob
4. Verify CMS signature using CSFK (installed in previous step)
5. If invalid: record HAB_INV_CSF, abort
6. If valid: remaining CSF commands are now authenticated
```

The "Authenticate CSF" step is the self-authentication of the command stream. Without it, an attacker who can modify flash could append malicious commands after a legitimate CSF.

### Command 5: Install Key

```
Tag: 0xBF
```

Installs the image signing key (IMG key):
```
1. Load IMG key certificate from CSF data area
2. Certificate is X.509, signed by CSFK
3. Verify: RSA_VERIFY(CSFK_pubkey, img_cert_signature) == SHA256(img_cert_tbsCert)
4. If invalid: record HAB_INV_CERTIFICATE, abort
5. Store IMG public key in HAB internal key slot 2
```

### Command 6: Authenticate Data

```
Tag: 0xCA
```

This is the final and most important step: authenticating the actual bootloader image:

```
1. For each block in the Authenticate Data command:
   a. block.address = where in memory the data is
   b. block.length = how many bytes to authenticate
   c. Load the CMS SignedData blob associated with this command
   
2. Compute SHA-256 over all specified memory blocks:
   SHA-256(memory[block0.address .. block0.address + block0.length])
   [XOR or concatenate if multiple blocks — see CSF format]
   
3. Verify CMS SignedData:
   - Extract the message digest from the CMS SignedAttributes
   - Compare vs computed SHA-256
   - Verify the RSA signature over signedAttributes using IMG key
   
4. If any block fails: record HAB_INV_SIGNATURE, abort
5. If all blocks pass: image is authenticated
```

**Critical detail:** The addresses in the `Authenticate Data` blocks must exactly match the runtime addresses where the image is loaded. If the image is loaded at `0x0092_0000` but the CSF says `0x0090_0000`, authentication will fail. Address calculation is one of the most common sources of HABv4 signing errors.

---

## HAB Clock and Engine Setup

HABv4 command execution requires the appropriate hardware engine to be available. The engine is specified in the CSF `[Header]` section:

```
[Header]
    ...
    Engine = CAAM
    Engine Configuration = 0
```

CAAM initialization for HABv4 on i.MX8MP:
```
CAAM base: 0x30900000
Required clocks:
  - CAAM_CLK: System clock for CAAM registers
  - CAAM_IPG_CLK: IPG bus clock
  - CAAM_ACLK: AXI DMA clock (for memory access)

Job Ring configuration:
  - JR0: Used by HABv4 exclusively
  - JR1: Available for U-Boot/kernel
  - JR2: Available for OP-TEE (Secure World)
```

The `Engine Configuration = 0` parameter in the CSF Header tells HABv4 to use default CAAM configuration. Non-zero values can configure AES key size or PKHA precision.

---

## PKI Verification Steps

HABv4's PKI verification uses the following X.509 constraints that must be respected in key generation:

### SRK Certificate Requirements
- Self-signed (CA certificate)
- `basicConstraints: CA=TRUE`
- `keyUsage: keyCertSign` (for signing sub-certificates)
- Key size: RSA-2048 minimum, RSA-4096 recommended
- Not checking validity period (HAB ignores cert expiry dates)

### CSFK Certificate Requirements
- Signed by SRK
- `basicConstraints: CA=TRUE` (signs the IMG certificate)
- `keyUsage: keyCertSign`
- Subject must differ from SRK Subject

### IMG Certificate Requirements
- Signed by CSFK
- `basicConstraints: CA=FALSE` (leaf certificate)
- `keyUsage: digitalSignature`
- Subject must differ from CSFK Subject

**Important:** HABv4 does **not** perform full certificate path validation in the RFC 5280 sense. It only verifies the chain SRK→CSFK→IMG using cryptographic signature verification. It does not check:
- Certificate expiry dates (this is intentional — avoid clock dependency)
- Certificate Revocation Lists (CRLs) or OCSP
- Full name constraints or policy constraints

---

## ROM Jump Table: hab_rvt Structure

The HAB ROM Vector Table (RVT) at a fixed ROM address provides the callable interface. The table address varies by chip:

| Chip | HAB RVT Base Address |
|------|---------------------|
| i.MX6UL/ULL | 0x00000098 |
| i.MX7D | 0x00000098 |
| i.MX8MM | 0x00000098 |
| i.MX8MN | 0x00000098 |
| i.MX8MP | 0x00000098 |
| i.MX8MQ | 0x00000098 |

On i.MX8MP specifically, the RVT at `0x98` contains (verify with your specific ROM version using `md.l 0x98 10` in U-Boot):

```
> md.l 0x98 10
00000098: dd002443 xxxxxxxx xxxxxxxx xxxxxxxx  ...$C...........
000000a8: xxxxxxxx xxxxxxxx xxxxxxxx xxxxxxxx  ................
```

The first word `0xdd002443` breaks down as:
- `0xdd` = tag (HAB RVT tag)
- `0x0024` = length (36 bytes = 9 function pointers × 4 bytes)
- `0x43` = version (HABv4.3)

In U-Boot source (`arch/arm/mach-imx/hab.c`):
```c
#define HAB_RVT_BASE  0x00000098

struct hab_rvt {
    struct hab_hdr hdr;
    hab_rnt_f *entry;
    hab_rnt_f *exit;
    hab_chk_tgt_f *check_target;
    hab_auth_img_f *authenticate_image;
    hab_run_dcd_f *run_dcd;
    hab_run_csf_f *run_csf;
    hab_assert_f *assert;
    hab_report_evt_f *report_event;
    hab_report_sts_f *report_status;
};

static inline struct hab_rvt *get_hab_rvt(void)
{
    return (struct hab_rvt *)HAB_RVT_BASE;
}
```

---

## hab_auth_img() Return Values

The return value of `hab_rvt_authenticate_image()` must be interpreted carefully:

```c
typedef uint8_t hab_status_t;

#define HAB_SUCCESS  0xF0  /* All authentication steps passed */
#define HAB_FAILURE  0x33  /* One or more steps failed (fatal in CLOSED mode) */
#define HAB_WARNING  0x69  /* Non-fatal issues (OPEN mode behavior) */
```

In U-Boot, authentication is performed and result checked in `imx_hab_authenticate_image()`:

```c
int imx_hab_authenticate_image(uint32_t ddr_start, uint32_t image_size,
                                uint32_t ivt_offset)
{
    struct hab_rvt *hab_rvt = get_hab_rvt();
    hab_status_t status;

    if (!is_hab_enabled())
        return 0;  /* HABv4 not in use, allow boot */

    status = hab_rvt->entry();
    if (status != HAB_SUCCESS) {
        printf("HAB entry() failed: 0x%x\n", status);
        goto exit;
    }

    status = hab_rvt->authenticate_image(
        HAB_CID_UBOOT,
        ivt_offset,
        (void **)&ddr_start,
        (size_t *)&image_size,
        NULL
    );

exit:
    hab_rvt->exit();

    if (status != HAB_SUCCESS) {
        printf("HAB authentication failed: 0x%x\n", status);
        return -1;
    }
    return 0;
}
```

---

## Full Authentication Flowchart

```
Power-On Reset
      │
      ▼
┌─────────────────────────────┐
│  ROM Pre-HAB Init           │
│  - Clocks, CAAM, SNVS       │
│  - Read HAB config fuses    │
│  - HAB state = INITIAL      │
└────────────┬────────────────┘
             │
             ▼
┌─────────────────────────────┐
│  Load Image from Boot Media │
│  - eMMC/SD: offset 0x8000  │
│  - DMA to OCRAM load addr   │
└────────────┬────────────────┘
             │
             ▼
┌─────────────────────────────┐
│  Parse IVT                  │
│  tag==0xD1 && ver==0x43?    │
└────────────┬────────────────┘
             │ No
             ▼
        [Halt or next boot device]
             │ Yes
             ▼
┌─────────────────────────────┐
│  CSF pointer in IVT?        │
│  (ivt.csf != 0)             │
└────────────┬────────────────┘
        No   │   Yes
        │    ▼
        │  ┌──────────────────────────┐
        │  │  Parse CSF Header        │
        │  │  tag=0xD4, ver=0x43?     │
        │  └────────────┬─────────────┘
        │               │
        │               ▼
        │  ┌──────────────────────────┐
        │  │  INSTALL SRK              │
        │  │  SHA256(SRK_table) ==    │
        │  │  SRK_HASH fuses?         │
        │  └────────────┬─────────────┘
        │         Fail  │   Pass
        │         │     │
        │         │     ▼
        │         │  ┌──────────────────────────┐
        │         │  │  INSTALL CSFK             │
        │         │  │  Verify cert w/ SRK key  │
        │         │  └────────────┬─────────────┘
        │         │         Fail  │   Pass
        │         │         │     │
        │         │         │     ▼
        │         │         │  ┌──────────────────────────┐
        │         │         │  │  AUTHENTICATE CSF         │
        │         │         │  │  Verify CSF signature    │
        │         │         │  │  with CSFK               │
        │         │         │  └────────────┬─────────────┘
        │         │         │         Fail  │   Pass
        │         │         │         │     │
        │         │         │         │     ▼
        │         │         │         │  ┌──────────────────────────┐
        │         │         │         │  │  INSTALL IMG KEY          │
        │         │         │         │  │  Verify cert w/ CSFK     │
        │         │         │         │  └────────────┬─────────────┘
        │         │         │         │         Fail  │   Pass
        │         │         │         │         │     │
        │         │         │         │         │     ▼
        │         │         │         │         │  ┌──────────────────────────┐
        │         │         │         │         │  │  AUTHENTICATE DATA        │
        │         │         │         │         │  │  SHA256(image_blocks) == │
        │         │         │         │         │  │  hash in CMS signature?  │
        │         │         │         │         │  │  RSA_VERIFY(IMG_key)?    │
        │         │         │         │         │  └────────────┬─────────────┘
        │         │         │         │         │         Fail  │   Pass
        │         │         │         │         │         │     │
        │         │         │         │         │         │     ▼
        │         │         │         │         │         │  ┌────────────────┐
        │         │         │         │         │         │  │  AUTH SUCCESS  │
        │         │         │         │         │         │  │  Return        │
        │         │         │         │         │         │  │  HAB_SUCCESS   │
        │         │         │         │         │         │  └───────┬────────┘
        │         │         │         │         │         │          │
        └─────────┼─────────┼─────────┼─────────┼─────────┘          │
                  │         │         │         │                     │
                  └─────────┴─────────┴─────────┘                     │
                                │                                      │
                                ▼                                      │
                     ┌─────────────────────┐                          │
                     │  Record HAB Event   │                          │
                     │  (failure details)  │                          │
                     └────────┬────────────┘                          │
                              │                                        │
                              ▼                                        │
                     ┌─────────────────────┐                          │
                     │  OEM CLOSED mode?   │                          │
                     └────────┬────────────┘                          │
                        No    │   Yes                                  │
                        │     ▼                                        │
                        │   ┌──────────────┐                          │
                        │   │  ROM HALTS   │                          │
                        │   │  (Infinite   │                          │
                        │   │   loop)      │                          │
                        │   └──────────────┘                          │
                        │                                              │
                        ▼ (OEM OPEN: continue despite failures)        │
                        │                                              │
                        └──────────────────────────────────────────────┘
                                                │
                                                ▼
                                        ┌───────────────┐
                                        │  Jump to      │
                                        │  IVT.entry    │
                                        │  (SPL/U-Boot) │
                                        └───────────────┘
```

---

## HAB Status Values Reference

```c
/* From NXP HABv4 API Reference Manual */

/* Status codes */
#define HAB_SUCCESS  (hab_status_t)0xF0  /* Operation completed successfully */
#define HAB_FAILURE  (hab_status_t)0x33  /* Operation failed */
#define HAB_WARNING  (hab_status_t)0x69  /* Operation succeeded with conditions */

/* Configuration values (from hab_rvt_report_status) */
#define HAB_CFG_RETURN  (hab_config_t)0x33  /* Field Return lifecycle */
#define HAB_CFG_OPEN    (hab_config_t)0xF0  /* Non-secure: OPEN lifecycle */
#define HAB_CFG_CLOSED  (hab_config_t)0xCC  /* Secure: CLOSED lifecycle */

/* State values (from hab_rvt_report_status) */
#define HAB_STATE_INITIAL   (hab_state_t)0x33  /* Initializing */
#define HAB_STATE_CHECK     (hab_state_t)0x55  /* Checking targets */
#define HAB_STATE_NONSECURE (hab_state_t)0x66  /* Non-secure boot state */
#define HAB_STATE_TRUSTED   (hab_state_t)0x99  /* Trusted boot state */
#define HAB_STATE_SECURE    (hab_state_t)0xAA  /* Secure boot state */
#define HAB_STATE_FAIL_SOFT (hab_state_t)0xCC  /* Soft failure state */
#define HAB_STATE_FAIL_HARD (hab_state_t)0xFF  /* Hard failure state */
#define HAB_STATE_NONE      (hab_state_t)0xF0  /* No HAB state */
```

### Interpreting `hab_status` Output from U-Boot

```
=> hab_status

HAB Configuration: 0xf0 HAB State: 0xf0
No HAB Events Found!
```

Decoding:
- `Configuration: 0xf0` = `HAB_CFG_OPEN` — device is in OEM OPEN mode
- `State: 0xf0` = `HAB_STATE_NONE` — no HAB operation in progress
- "No HAB Events Found" — no authentication events recorded

```
=> hab_status

HAB Configuration: 0xcc HAB State: 0xf0
No HAB Events Found!
```

Decoding:
- `Configuration: 0xcc` = `HAB_CFG_CLOSED` — device is in OEM CLOSED mode (production)
- No events — authentication passed completely

```
=> hab_status

HAB Configuration: 0xf0 HAB State: 0xf0

--------- HAB Event 1 ---------
event data:
0xdb 0x00 0x14 0x43
0x33 0x0c 0x1e 0x00
...

STS = HAB_FAILURE (0x33)
RSN = HAB_INV_CSF (0x27)
CTX = HAB_CTX_AUTHENTICATE (0x1e)
ENG = HAB_ENG_ANY (0x00)
```

Decoding: Authentication attempted but the CSF was invalid (e.g., corrupt, wrong format).

For the complete event code reference and diagnosis procedures, see [HAB Event Decoding](03-hab-event-decoding.md).
