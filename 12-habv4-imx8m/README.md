# HABv4 on i.MX8M Plus: High Assurance Boot Reference

```
Tested Against:
  - NXP CST: 3.3.1
  - U-Boot: 2023.04 (NXP lf-6.1.55-2.2.0)
  - Linux Kernel: 6.1.55 (NXP lf-6.1.55-2.2.0)
  - NXP SPSDK: 2.1.0
  - imx-mkimage: lf-6.1.55-2.2.0
Last Validated: 2024-Q2
Platform: NXP i.MX8M Plus (phyCORE-i.MX8MP)
```

---

## Overview

HABv4 (High Assurance Boot version 4) is the NXP-proprietary boot authentication mechanism embedded in the Boot ROM of i.MX6, i.MX7, i.MX8M, and related processor families. It provides the root-of-trust anchor at reset: before any software executes from external media, HABv4 can cryptographically authenticate the first-stage bootloader against a public key whose hash is stored in one-time-programmable (OTP) fuses.

HABv4 is the boundary between trusted and untrusted execution. Every security property that depends on knowing the identity of executing code — FIT image verification, OP-TEE attestation, dm-verity key sealing — depends on HABv4 establishing that the boot chain started from an authenticated image. If HABv4 is not properly configured and closed, the entire chain of trust is unanchored.

This chapter covers HABv4 from ROM-level operation through production fuse burning, including:
- The authentication protocol in precise detail
- CSF (Command Sequence File) structure and creation
- SRK (Super Root Key) table layout and key revocation
- HAB event log interpretation for failure diagnosis
- Device lifecycle state management
- The CST (Code Signing Tool) workflow for i.MX8MP

---

## HABv4 vs HABv3

HABv3 appeared in i.MX25, i.MX31, i.MX35, and i.MX51. HABv4 was introduced with i.MX50/53 and continues through the current i.MX8M family. The architectural differences are significant.

| Feature | HABv3 | HABv4 |
|---------|-------|-------|
| Signature format | PKCS#1 v1.5 raw | CMS (Cryptographic Message Syntax, RFC 5652) |
| Certificate format | Proprietary | X.509 v3 |
| Key hierarchy | 1 key level | 2-level: SRK → CSF/IMG |
| SRK slots | 1 | 4 (with revocation) |
| Hash algorithm | SHA-1 | SHA-256 (SHA-384/512 in later HABv4 revisions) |
| Command file | Binary CSF | Human-readable CSF text → compiled binary |
| Engine abstraction | Fixed | Pluggable (CAAM, DCP, SW) |
| Event log | Limited | Structured with status/reason/context/engine |
| Lifecycle states | FAB, OPEN, CLOSED | FAB, NXP, OEM OPEN, OEM CLOSED, FIELD RETURN |

The CMS signature format in HABv4 is significant: it enables a proper X.509 certificate chain to be embedded in the CSF, allowing standard PKI tooling (OpenSSL) to manage the signing keys. HABv3's proprietary format required NXP-specific tools throughout.

---

## HABv4 Components

### Boot ROM HAB Library

The HABv4 library is compiled into the Boot ROM at chip fabrication time. It is not field-updatable. On i.MX8MP, the ROM occupies addresses `0x0000_0000` – `0x0001_7FFF` (96 KB). The HAB library is a subset of this ROM.

The HAB library exports a **ROM Vector Table (RVT)** at a fixed address (`0x0000_0098` on i.MX8MP). This table contains function pointers to the HAB API. External code (U-Boot, Linux kernel) can call these functions to perform authentication or read the event log.

```
HAB RVT structure at 0x00000098 (i.MX8MP):
Offset  Size  Name
0x00    4     hdr         Tag=0xDD, Len=0x0024, Ver=0x43 (HABv4.3)
0x04    4     entry       hab_rvt_entry()
0x08    4     exit        hab_rvt_exit()
0x0C    4     check_target  hab_rvt_check_target()
0x10    4     authenticate_image  hab_rvt_authenticate_image()
0x14    4     run_dcd     hab_rvt_run_dcd()
0x18    4     run_csf     hab_rvt_run_csf()
0x1C    4     assert      hab_rvt_assert()
0x20    4     report_event  hab_rvt_report_event()
0x24    4     report_status  hab_rvt_report_status()
0x28    4     authenticate_container  hab_rvt_authenticate_container()
```

The ROM uses these same functions internally during boot. Their availability post-ROM enables U-Boot's `hab_status` command and similar utilities.

### CSF (Command Sequence File)

The CSF is the primary artifact consumed by HABv4 at authentication time. It is a binary structure containing a sequence of commands that instruct HABv4 how to perform authentication:

1. Where to find the SRK table
2. Which SRK to use (by index, 0-3)
3. The CSF signing key certificate
4. The image signing key certificate
5. Cryptographic hash + signature over the image data

The CSF is embedded alongside the image in flash. The Image Vector Table (IVT) contains a pointer to the CSF. See [CSF Structure](02-csf-structure.md) for binary format details.

### SRK (Super Root Key) Table

The SRK table is a 4-entry table of RSA public key certificates (or ECDSA on newer implementations). The SHA-256 hash of the entire SRK table is burned into OTP fuses as the device root-of-trust anchor. During authentication, HABv4 recomputes the SHA-256 hash of the SRK table embedded in the CSF and compares it against the fuse value. If they match, the SRK is considered authentic.

**Why 4 SRKs?** Key revocation. If one of the four SRKs is compromised, it can be revoked by burning the corresponding `SRK_REVOKE` fuse bit. The remaining three SRKs continue to function. This provides resilience against key compromise without bricking all devices in the field.

```
SRK Table structure:
┌─────────────────────────────────────────┐
│  SRK Table Header (8 bytes)             │
│  tag=0xD7, len=total_length, ver=0x42   │
├─────────────────────────────────────────┤
│  SRK Entry 0 (RSA-2048 public key)      │
│  tag=0xE1, modulus[], exponent[]        │
├─────────────────────────────────────────┤
│  SRK Entry 1 (RSA-2048 public key)      │
├─────────────────────────────────────────┤
│  SRK Entry 2 (RSA-2048 public key)      │
├─────────────────────────────────────────┤
│  SRK Entry 3 (RSA-2048 public key)      │
└─────────────────────────────────────────┘

SRK Hash burned in fuses = SHA-256(entire SRK table binary)
```

---

## HABv4 Authentication Flow

The following describes the sequence of operations that occur from power-on reset through first-stage bootloader authentication on i.MX8MP.

### Phase 1: ROM Initialization

At power-on, the ARM core begins executing from the reset vector in Boot ROM. The ROM performs:
1. Clock initialization (PLL setup for minimum frequency)
2. DDR controller pre-initialization
3. Security controller initialization (CAAM/SNVS bring-up)
4. HAB library initialization (internal state machine set to HAB_ST_INITIAL)
5. Boot media detection (boot pins → eMMC, SD, SPI-NOR, etc.)
6. First-stage image load from boot media into OCRAM

### Phase 2: IVT Parsing

After loading the image from boot media, the ROM locates the **Image Vector Table (IVT)**. On i.MX8MP, the IVT is identified by the tag `0xD1` at the IVT header. The IVT structure is:

```c
typedef struct {
    uint8_t  tag;         /* 0xD1 */
    uint16_t length;      /* Big-endian, total IVT size */
    uint8_t  version;     /* HABv4: 0x43 */
    uint32_t entry;       /* Application entry point address */
    uint32_t reserved1;   /* Must be 0 */
    uint32_t dcd;         /* Device Configuration Data pointer (optional) */
    uint32_t boot_data;   /* Boot Data pointer */
    uint32_t self;        /* IVT self-pointer (IVT load address) */
    uint32_t csf;         /* CSF pointer (0 = unsigned) */
    uint32_t reserved2;   /* Must be 0 */
} ivt_t;
```

The `csf` field in the IVT is the critical field. If it is non-zero, HABv4 authentication is attempted. If it is zero:
- In OPEN mode: boot proceeds without authentication
- In CLOSED mode: boot halts (DIS_AUTH fuse behavior may vary — see [Lifecycle](05-hab-lifecycle.md))

### Phase 3: HAB Authentication Invocation

The ROM calls `hab_rvt_authenticate_image()` with the image start address and length. Internally, this:
1. Calls `hab_rvt_entry()` — transitions HAB state machine to HAB_ST_ENTRY, records entry event
2. Calls `hab_rvt_check_target()` — validates the image load address against the allowed memory map
3. Calls `hab_rvt_run_csf()` — processes the CSF command sequence
4. Calls `hab_rvt_exit()` — transitions HAB state machine to HAB_ST_EXIT, records exit event

### Phase 4: CSF Command Execution

`hab_rvt_run_csf()` processes commands sequentially. Each command either succeeds (continue) or fails (record event, behavior depends on lifecycle state). The standard command sequence is:

```
[Install SRK]
    → Load SRK table from CSF
    → Compute SHA-256 of SRK table
    → Compare against SRK_HASH fuses
    → If match: SRK is authenticated, store in HAB state
    → Check SRK_REVOKE fuses for the selected SRK index

[Install CSFK]
    → Load CSF signing key certificate from CSF
    → Certificate is signed by the SRK (just authenticated)
    → Verify certificate signature using authenticated SRK
    → If valid: CSFK is trusted, store in HAB state

[Authenticate CSF]
    → The CSF itself (from the Install CSFK command onward) is signed
    → Verify the signature over the CSF body using CSFK
    → If valid: remaining CSF commands are trusted

[Install Key]
    → Load image signing key (IMG key) certificate from CSF
    → Certificate is signed by CSFK (just authenticated)
    → Verify certificate signature using authenticated CSFK
    → If valid: IMG key is trusted

[Authenticate Data]
    → For each data block specified:
        → Load block address, offset in file, length
        → Compute hash of memory region at [address, address+length)
        → Verify that hash matches the pre-computed hash in the CMS signature
        → Verify CMS signature over hash using IMG key
    → All blocks must authenticate for success
```

### Phase 5: PKI Verification

For each certificate or signature verification step, HABv4 uses the CAAM (Cryptographic Acceleration and Assurance Module) or DCP (Data Co-Processor) if available, or falls back to software. On i.MX8MP, CAAM is available.

The verification path for RSA:
```
Signature = RSA_SIGN(private_key, HASH(data))
Verification: RSA_VERIFY(public_key, signature) == HASH(data)
```

For RSA-2048/SHA-256 (standard configuration):
- CAAM performs the RSA modular exponentiation using PKHA engine
- Result compared to independently-computed SHA-256 hash
- CAAM is initialized and clocked by the Install SRK step's engine specification

### Phase 6: HAB Status Reporting

After `hab_rvt_exit()`, HABv4 has either succeeded or recorded failure events. The behavior depends on lifecycle state:

| State | Authentication Fails | Authentication Passes |
|-------|---------------------|----------------------|
| OEM OPEN | Warning event logged, boot continues | No events, boot continues |
| OEM CLOSED | Fatal: ROM halts (infinite loop or reset) | No events, boot continues |

The return value of `hab_rvt_authenticate_image()`:
- `HAB_SUCCESS (0xF0)`: Authentication passed, or OPEN mode with warnings
- `HAB_FAILURE (0x33)`: Authentication failed (in OPEN mode, this is non-fatal at ROM level)

---

## Open vs Closed Mode

### OEM OPEN Mode (Development)

In OEM OPEN mode, HABv4 performs full authentication but records failures as **non-fatal warning events**. The ROM continues booting even if authentication fails. This mode exists for development: you can sign images, test the signing workflow, and inspect the HAB event log without risking a bricked device from a signing mistake.

**What actually happens on a signing failure in OPEN mode:**
1. Authentication fails at some step (e.g., SRK hash mismatch)
2. HAB records a HAB_WARNING event with the failure reason
3. `hab_rvt_authenticate_image()` returns `HAB_FAILURE (0x33)` or `HAB_WARNING (0x69)` depending on severity
4. The ROM **ignores the return value** in OPEN mode and continues
5. U-Boot boots and `hab_status` shows the recorded events

This means: **a device in OPEN mode will boot an unsigned image**. OPEN mode is not secure. It is a testing mode only.

> **⚠️ WARNING:** OEM OPEN mode provides no security guarantees. Any image can boot. Do not deploy OPEN mode devices in production or security-sensitive environments.

### OEM CLOSED Mode (Production)

In OEM CLOSED mode, `SEC_CONFIG[1]` fuse is burned. Any HAB_FAILURE event causes the ROM to halt. The exact halt behavior:
- On i.MX8MP: The ROM enters an infinite loop at a fixed address in ROM
- JTAG is not automatically disabled (that is a separate fuse: JTAG_SMODE)
- Serial output from ROM is reduced in CLOSED mode (ROM doesn't print errors)

To transition to CLOSED mode, see [Lifecycle Management](05-hab-lifecycle.md).

---

## SEC_CONFIG Fuse

`SEC_CONFIG` is a 2-bit field in the OCOTP fuse array (Bank 1, Word 3 on i.MX8MP). Bit definitions:

```
SEC_CONFIG[0]: NXP Reserved (already programmed by NXP, do not burn)
SEC_CONFIG[1]: OEM_CLOSED bit
    0 = OEM OPEN (HAB authentication performed but non-fatal)
    1 = OEM CLOSED (HAB authentication failure is fatal)
```

The fuse word address in the OCOTP register map (base `0x30350000`):
```
OCOTP_CFG5 = base + 0x470    (Bank 1, Word 7 - security config)
```

> **⚠️ CRITICAL:** Burning `SEC_CONFIG[1]` is irreversible. Once burned:
> - The device will halt on any HAB authentication failure
> - If `SRK_HASH` fuses contain an incorrect value, the device is permanently bricked
> - If the signed images are lost or corrupted, the device cannot boot
> Triple-verify every prerequisite before burning. See [Lifecycle Management](05-hab-lifecycle.md).

---

## HAB API Reference

The HAB ROM Vector Table provides these callable functions from U-Boot or the kernel (call via function pointer, not direct address, as addresses vary by chip revision):

### `hab_rvt_entry()`
```c
hab_status_t hab_rvt_entry(void);
```
Opens a HAB context. Must be called before any other HAB function. Transitions internal state from `HAB_ST_INITIAL` to `HAB_ST_ENTRY`. Records a HAB_CTX_ENTRY event.

### `hab_rvt_exit()`
```c
hab_status_t hab_rvt_exit(void);
```
Closes the HAB context. Must be called after all HAB operations. Transitions state to `HAB_ST_EXIT`. In CLOSED mode, failure to call exit or calling it with pending failures causes halt.

### `hab_rvt_authenticate_image()`
```c
hab_status_t hab_rvt_authenticate_image(
    uint8_t  cid,       /* Caller ID, use HAB_CID_UBOOT (0x01) from U-Boot */
    ptrdiff_t ivt_offset, /* Offset of IVT from start of image buffer */
    void   **start,     /* Pointer to image start address */
    size_t  *bytes,     /* Pointer to image size in bytes */
    void   **loader     /* Reserved, set to NULL */
);
```
The primary authentication function. Locates the IVT at `*start + ivt_offset`, parses the CSF pointer, and executes the full CSF command sequence.

### `hab_rvt_report_event()`
```c
hab_status_t hab_rvt_report_event(
    hab_status_t  status,   /* Filter: HAB_STS_ANY, HAB_FAILURE, HAB_WARNING */
    uint32_t      index,    /* Event index, starting from 0 */
    uint8_t      *event,    /* Output buffer for event data */
    size_t       *bytes     /* Input: buffer size; Output: actual event size */
);
```
Reads event records from the HAB event log. Call repeatedly incrementing `index` until return value is `HAB_FAILURE` (no more events at that index). U-Boot's `hab_status` command implements this loop.

### `hab_rvt_report_status()`
```c
hab_status_t hab_rvt_report_status(
    hab_config_t *config,   /* Output: current HAB configuration */
    hab_state_t  *state     /* Output: current HAB state */
);
```
Returns the current HAB configuration (open/closed) and state (initial/entry/exit). This is the function called by U-Boot's `hab_status` to report the first two lines of output.

---

## HAB Event Log

The HAB event log is a ring buffer in OCRAM. HABv4 writes events as it encounters authentication steps (both successes in verbose mode and failures). Each event record has the structure:

```c
typedef struct {
    uint8_t  tag;       /* Always 0xDB for HAB4 event */
    uint16_t len;       /* Total event record length, big-endian */
    uint8_t  ver;       /* HABv4 version: 0x42 = v4.2, 0x43 = v4.3 */
    uint8_t  sts;       /* HAB status: 0xF0=SUCCESS, 0x33=FAILURE, 0x69=WARNING */
    uint8_t  rsn;       /* HAB reason code */
    uint8_t  ctx;       /* HAB context code */
    uint8_t  eng;       /* Engine code */
    uint8_t  data[];    /* Additional context-specific data */
} hab_event_t;
```

For detailed event decoding, see [HAB Event Decoding](03-hab-event-decoding.md).

**Critical operational note:** The HAB event log in OCRAM persists from ROM through SPL through U-Boot. If U-Boot is reached (in OPEN mode despite failures), the events are still readable. However, **warm reset clears OCRAM on most i.MX8M variants**, so event data may not survive a reset. Capture events before resetting.

> **📝 NOTE:** `hab_status` in U-Boot reads and displays events but does **not** clear the event buffer. The buffer is cleared on next power cycle or reset.

---

## Common HAB Events: Quick Reference

| Status | Reason | Context | Typical Cause |
|--------|--------|---------|---------------|
| WARNING (0x69) | HAB_ENG_FAIL (0x30) | HAB_CTX_AUTHENTICATE (0x1E) | CAAM engine initialization failure |
| FAILURE (0x33) | HAB_INV_SIGNATURE (0x2D) | HAB_CTX_AUTHENTICATE (0x1E) | Wrong signing key, corrupted signature |
| FAILURE (0x33) | HAB_INV_CERTIFICATE (0x25) | HAB_CTX_AUTHENTICATE (0x1E) | Expired certificate, wrong SRK |
| FAILURE (0x33) | HAB_INV_IVT (0x2A) | HAB_CTX_AUTHENTICATE (0x1E) | IVT malformed or at wrong address |
| FAILURE (0x33) | HAB_INV_ADDRESS (0x22) | HAB_CTX_CHECK (0x33) | Image loaded at disallowed address |
| FAILURE (0x33) | HAB_UNS_ALGORITHM (0x32) | HAB_CTX_AUTHENTICATE (0x1E) | Hash or signature algorithm not supported |
| WARNING (0x69) | HAB_ENG_FAIL (0x30) | HAB_CTX_DCD (0x30) | DCD command failed (clock/DDR config) |

Full event code tables and decision trees are in [HAB Event Decoding](03-hab-event-decoding.md).

---

## HABv4 Limitations and Known Issues

### Limitation 1: No Runtime Re-authentication
HABv4 authenticates only at boot time. Once U-Boot is authenticated, HABv4 has no mechanism to re-authenticate a binary that U-Boot subsequently loads from a filesystem. This is why **U-Boot verified boot (FIT image signing)** is required in addition to HABv4. HABv4 authenticates U-Boot; U-Boot authenticates the kernel.

### Limitation 2: No Rollback Protection in HABv4 Itself
HABv4 does not natively enforce version numbers or sequence counters. A signed older (potentially vulnerable) bootloader will pass HABv4 authentication. Anti-rollback must be implemented at a higher layer (U-Boot version counter stored in fuses, OP-TEE anti-rollback service).

### Limitation 3: SRK Revocation Is Coarse
Revoking an SRK revokes it for **all devices** using that SRK slot. You cannot revoke an SRK for a subset of devices. This means all devices sharing that SRK must receive new firmware signed with a different SRK before the compromised one is burned revoked.

### Limitation 4: Physical Attack Surface
HABv4 uses CAAM for cryptographic operations. An attacker with physical access and specialized equipment (voltage glitching, EM fault injection) may be able to corrupt the CAAM operation or ROM execution. HABv4 is not hardened against advanced physical attacks. Devices requiring protection against sophisticated physical attackers require additional hardware security modules.

### Limitation 5: ROM Version Cannot Be Updated
The Boot ROM containing the HABv4 library is read-only silicon. Any vulnerability in HABv4 itself cannot be patched. NXP has released silicon errata for HABv4 in some chips (notably i.MX6 "Shielder" vulnerability). Check the relevant silicon errata document for i.MX8MP.

### Limitation 6: Debug Access
HABv4 CLOSED mode does not automatically disable JTAG. To fully close debug access, the following fuses should also be evaluated:
- `JTAG_SMODE`: Sets JTAG security mode
- `KTE`: Key Transfer Enable (controls secure memory access via JTAG)
- `JTAG_HEO`: HAB Enable Override

These are out of scope for HABv4 itself but are part of device hardening.

---

## Chapter Contents

| File | Content |
|------|---------|
| [README.md](README.md) | This overview — concepts, components, limitations |
| [01-hab-authentication-flow.md](01-hab-authentication-flow.md) | Detailed authentication flow with ROM internals |
| [02-csf-structure.md](02-csf-structure.md) | CSF binary format, commands, example files |
| [03-hab-event-decoding.md](03-hab-event-decoding.md) | Event log reference: all codes, decision trees |
| [04-cst-workflow.md](04-cst-workflow.md) | CST tool workflow, key generation, signing |
| [05-hab-lifecycle.md](05-hab-lifecycle.md) | Device lifecycle states, fuse burning procedure |

---

## References

- NXP Application Note AN4581: "Secure Boot on i.MX50, i.MX53, and i.MX6 Series using HABv4"
  https://www.nxp.com/docs/en/application-note/AN4581.pdf
- NXP Application Note AN12263: "HABv4 RVT Guidelines and Recommendations"
  https://www.nxp.com/docs/en/application-note/AN12263.pdf
- NXP i.MX8M Plus Security Reference Manual, Chapter: High Assurance Boot
  IMX8MPRM Rev. 3, available via NXP.com (registration required)
- NXP Code Signing Tool User Guide (CST 3.3.1)
  https://www.nxp.com/webapp/Download?colCode=IMX_CST_TOOL_NEW
- U-Boot source: `arch/arm/mach-imx/hab.c`
  https://source.denx.de/u-boot/u-boot/-/blob/master/arch/arm/mach-imx/hab.c
