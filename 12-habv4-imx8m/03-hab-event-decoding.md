# HAB Event Log Decoding Reference

```
Tested Against:
  - NXP i.MX8M Plus Boot ROM HABv4.3
  - U-Boot 2023.04 (NXP lf-6.1.55-2.2.0)
  - NXP Application Notes: AN4581, AN12263
Last Validated: 2024-Q2
```

---

## Overview

The HABv4 event log is the primary diagnostic tool for Secure Boot failures. When authentication fails (or succeeds with warnings), the ROM writes structured event records into an OCRAM buffer. These records persist through SPL execution into U-Boot, where they can be read using the `hab_status` command.

Understanding how to decode HAB events is critical for:
- Diagnosing signing workflow mistakes
- Identifying incorrect CSF addresses
- Validating that OPEN mode authentication succeeds before closing the device
- Debugging manufacturing line failures

---

## HAB Status Codes

These are the top-level result codes returned by HAB API functions and recorded in event `sts` fields:

```
HAB_STATUS codes:
┌──────────┬──────┬─────────────────────────────────────────────────────┐
│ Name     │ Hex  │ Meaning                                             │
├──────────┼──────┼─────────────────────────────────────────────────────┤
│HAB_SUCCESS│0xF0 │ Operation completed without error                   │
│HAB_FAILURE│0x33 │ Operation failed; authentication did not pass       │
│HAB_WARNING│0x69 │ Operation completed with non-fatal conditions       │
└──────────┴──────┴─────────────────────────────────────────────────────┘
```

**HAB_SUCCESS (0xF0):** All authentication steps completed successfully. No issues.

**HAB_FAILURE (0x33):** At least one authentication step failed. In OPEN mode, boot continues but the failure is logged. In CLOSED mode, boot halts immediately.

**HAB_WARNING (0x69):** Authentication completed but with non-fatal conditions. The most common cause is CAAM engine initialization issues on first use. Often seen on fresh devices or after clock configuration changes. In OPEN mode, does not prevent boot. In CLOSED mode, treatment depends on warning type.

---

## HAB Reason Codes (RSN)

The reason code provides specific information about why an event was recorded:

```
HAB_REASON codes:
┌───────────────────────┬──────┬──────────────────────────────────────────────────────────────┐
│ Name                  │ Hex  │ Meaning and Common Causes                                    │
├───────────────────────┼──────┼──────────────────────────────────────────────────────────────┤
│HAB_RSN_ANY            │0x00  │ Catch-all / no specific reason                               │
│HAB_ENG_FAIL           │0x21  │ Cryptographic engine (CAAM/DCP) operation failed             │
│HAB_INV_ADDRESS        │0x22  │ Address not in allowed range; memory protection violation    │
│HAB_INV_ASSERTION      │0x23  │ Internal consistency check failed                            │
│HAB_INV_CALL           │0x24  │ HAB API called in wrong order (e.g., auth before entry)      │
│HAB_INV_CERTIFICATE    │0x25  │ Certificate parse error; signature on cert is invalid        │
│HAB_INV_COMMAND        │0x26  │ CSF command is malformed or has invalid parameters           │
│HAB_INV_CSF            │0x27  │ CSF header invalid; CSF binary is corrupted                  │
│HAB_INV_DCD            │0x28  │ DCD (Device Config Data) command failed                      │
│HAB_INV_INDEX          │0x29  │ Key slot index out of range (>3 for SRK, >2 for HAB slots)   │
│HAB_INV_IVT            │0x2A  │ IVT malformed, wrong tag/version, or self-pointer mismatch   │
│HAB_INV_KEY            │0x2B  │ Key revoked, missing, or type mismatch                       │
│HAB_INV_RETURN         │0x2C  │ Return address check failed (security feature)               │
│HAB_INV_SIGNATURE      │0x2D  │ Cryptographic signature verification failed                  │
│HAB_INV_SIZE           │0x2E  │ Data block size exceeds allowed range                        │
│HAB_MEM_FAIL           │0x2F  │ Memory access failure; DMA error or bus fault                │
│HAB_OVR_COUNT          │0x30  │ Polling loop expired (engine took too long)                  │
│HAB_OVR_STORAGE        │0x31  │ Event log storage exhausted; events dropped                  │
│HAB_UNS_ALGORITHM      │0x32  │ Algorithm not supported by this HAB/engine version           │
│HAB_UNS_COMMAND        │0x33  │ CSF command not recognized by this HAB version               │
│HAB_UNS_ENGINE         │0x34  │ Requested engine not present or not initialized              │
│HAB_UNS_ITEM           │0x35  │ Configuration item not supported                             │
│HAB_UNS_KEY            │0x36  │ Key type or parameters not supported                         │
│HAB_UNS_PROTOCOL       │0x37  │ Protocol not supported                                       │
│HAB_UNS_STATE          │0x38  │ HAB state machine in unsuitable state for operation          │
└───────────────────────┴──────┴──────────────────────────────────────────────────────────────┘
```

---

## HAB Context Codes (CTX)

The context code identifies which HAB internal operation was executing when the event occurred:

```
HAB_CONTEXT codes:
┌──────────────────────┬──────┬──────────────────────────────────────────────────┐
│ Name                 │ Hex  │ Meaning                                          │
├──────────────────────┼──────┼──────────────────────────────────────────────────┤
│HAB_CTX_ANY           │0x00  │ Not context-specific                             │
│HAB_CTX_FAB           │0x11  │ Factory programming context                      │
│HAB_CTX_ENTRY         │0x22  │ Inside hab_rvt_entry()                           │
│HAB_CTX_TARGET        │0x33  │ Inside hab_rvt_check_target()                    │
│HAB_CTX_AUTHENTICATE  │0x0A  │ Inside image/CSF authentication                  │
│HAB_CTX_DCD           │0x30  │ Inside DCD (Device Configuration Data) execution │
│HAB_CTX_CSF           │0xC5  │ During CSF command processing                    │
│HAB_CTX_COMMAND       │0xC6  │ Inside a specific CSF command                    │
│HAB_CTX_AUT_DAT       │0xDB  │ During Authenticate Data command execution        │
│HAB_CTX_ASSERT        │0xA0  │ Inside hab_rvt_assert()                          │
│HAB_CTX_EXIT          │0xEE  │ Inside hab_rvt_exit()                            │
│HAB_CTX_MAX           │0xFF  │ Upper bound marker                               │
└──────────────────────┴──────┴──────────────────────────────────────────────────┘
```

> **📝 NOTE:** The context code value `0x1E` seen in some NXP documentation and U-Boot output examples corresponds to `HAB_CTX_AUTHENTICATE` in older HABv4 versions. In HABv4.3 on i.MX8MP, the value is `0x0A`. Verify against your ROM version.

---

## HAB Engine Codes (ENG)

```
HAB_ENGINE codes:
┌────────────────┬──────┬──────────────────────────────────────────────────┐
│ Name           │ Hex  │ Description                                      │
├────────────────┼──────┼──────────────────────────────────────────────────┤
│HAB_ENG_ANY     │0x00  │ Not engine-specific                              │
│HAB_ENG_SCC     │0x03  │ Security Controller (legacy)                     │
│HAB_ENG_RTIC    │0x05  │ Run-Time Integrity Checker                       │
│HAB_ENG_SAHARA  │0x06  │ SAHARA (legacy crypto, i.MX53)                   │
│HAB_ENG_CSU     │0x0A  │ Central Security Unit                            │
│HAB_ENG_SRTC    │0x0C  │ Secure Real-Time Clock                           │
│HAB_ENG_DCP     │0x1B  │ Data Co-Processor (i.MX6UL AES/SHA engine)       │
│HAB_ENG_CAAM    │0x1D  │ Cryptographic Acceleration and Assurance Module  │
│HAB_ENG_SNVS    │0x1E  │ Secure Non-Volatile Storage                      │
│HAB_ENG_OCOTP   │0x21  │ On-Chip One-Time Programmable fuses              │
│HAB_ENG_DTCP    │0x22  │ DTCP co-processor                                │
│HAB_ENG_ROM     │0x36  │ ROM (for SW-fallback operations)                 │
│HAB_ENG_HDCP    │0x24  │ HDCP co-processor                                │
│HAB_ENG_RTL     │0x77  │ RTL simulation (testing only)                    │
│HAB_ENG_SW      │0xFF  │ Software implementation                          │
└────────────────┴──────┴──────────────────────────────────────────────────┘
```

For i.MX8MP:
- Expected engine: `HAB_ENG_CAAM (0x1D)` for cryptographic operations
- `HAB_ENG_ANY (0x00)` in an event means the failure was not engine-specific

---

## Reading HAB Events from U-Boot

### Command: `hab_status`

```
=> hab_status
```

This command calls `hab_rvt_report_status()` and then loops calling `hab_rvt_report_event()` until all events are retrieved.

### Output: No Events (Clean Authentication)

```
=> hab_status

HAB Configuration: 0xf0 HAB State: 0xf0
No HAB Events Found!
```

This is the target state when testing signed images in OPEN mode. `Configuration: 0xf0` = OEM OPEN. "No HAB Events" confirms the image authenticated successfully.

### Output: OPEN Mode, Authentication Passed (Closed Device)

```
=> hab_status

HAB Configuration: 0xcc HAB State: 0xf0
No HAB Events Found!
```

`Configuration: 0xcc` = OEM CLOSED. "No HAB Events" = authentication passed. This is the expected output on a production closed device that successfully boots.

### Output: Signature Verification Failure

```
=> hab_status

HAB Configuration: 0xf0 HAB State: 0xf0

--------- HAB Event 1 ---------
event data:
0xdb 0x00 0x14 0x43
0x33 0x2d 0x0a 0x1d
0x00 0x00 0x00 0x00
0x00 0x00 0x00 0x00
0x00 0x00 0x00 0x00

STS = HAB_FAILURE (0x33)
RSN = HAB_INV_SIGNATURE (0x2d)
CTX = HAB_CTX_AUTHENTICATE (0x0a)
ENG = HAB_ENG_CAAM (0x1d)
```

Decoding the raw event bytes:
```
Byte  0:    0xdb = HAB4 event tag
Bytes 1-2:  0x0014 = event length = 20 bytes
Byte  3:    0x43 = HABv4.3
Byte  4:    0x33 = STS = HAB_FAILURE
Byte  5:    0x2d = RSN = HAB_INV_SIGNATURE
Byte  6:    0x0a = CTX = HAB_CTX_AUTHENTICATE
Byte  7:    0x1d = ENG = HAB_ENG_CAAM
Bytes 8-19: Additional context data (address of failing data block, etc.)
```

This event means: CAAM rejected the RSA signature over image data. Probable causes: wrong signing key, image modified after signing, wrong data address in CSF.

### Output: SRK Hash Mismatch

```
=> hab_status

HAB Configuration: 0xf0 HAB State: 0xf0

--------- HAB Event 1 ---------
event data:
0xdb 0x00 0x14 0x43
0x33 0x25 0x0a 0x1d
...

STS = HAB_FAILURE (0x33)
RSN = HAB_INV_CERTIFICATE (0x25)
CTX = HAB_CTX_AUTHENTICATE (0x0a)
ENG = HAB_ENG_CAAM (0x1d)
```

`HAB_INV_CERTIFICATE` during authentication context means the SRK table hash does not match the fuse value. This occurs when:
- Different SRK table used for signing vs. what was burned in fuses
- SRK_HASH fuses burned with wrong value
- SRK table file is corrupted

### Output: Engine Initialization Warning (Benign)

```
=> hab_status

HAB Configuration: 0xf0 HAB State: 0xf0

--------- HAB Event 1 ---------
event data:
0xdb 0x00 0x08 0x43
0x69 0x21 0x0a 0x1d

STS = HAB_WARNING (0x69)
RSN = HAB_ENG_FAIL (0x21)
CTX = HAB_CTX_AUTHENTICATE (0x0a)
ENG = HAB_ENG_CAAM (0x1d)
```

`HAB_WARNING + HAB_ENG_FAIL` is often benign on i.MX8MP. It can occur when:
- CAAM RNG was not previously instantiated (first boot after flashing)
- CAAM self-test was interrupted
- Clock rates are at minimum (ROM frequency, not full speed)

**This warning does NOT mean authentication failed.** The image still authenticated successfully. The RNG initialization failure is logged as a warning but does not affect signature verification. However, this warning WILL cause a halt in CLOSED mode on some HABv4 versions — verify with NXP errata before closing devices.

> **⚠️ WARNING:** If you see `HAB_WARNING + HAB_ENG_FAIL` in OPEN mode and plan to close the device, verify whether this warning is treated as fatal in CLOSED mode on your specific silicon revision. Some i.MX8MP revisions require the `[Unlock] Engine = CAAM / Features = RNG` CSF command to suppress this.

### Output: Invalid IVT

```
STS = HAB_FAILURE (0x33)
RSN = HAB_INV_IVT (0x2a)
CTX = HAB_CTX_AUTHENTICATE (0x0a)
ENG = HAB_ENG_ANY (0x00)
```

Causes:
- IVT tag is not 0xD1
- IVT version is not 0x43
- `ivt.self` does not match the address where the IVT was loaded
- IVT `reserved1` or `reserved2` fields are non-zero

### Output: Invalid Address (Memory Range Check)

```
STS = HAB_FAILURE (0x33)
RSN = HAB_INV_ADDRESS (0x22)
CTX = HAB_CTX_TARGET (0x33)
ENG = HAB_ENG_ANY (0x00)
```

HABv4 restricts which memory regions can be authenticated. The allowed regions depend on the chip and are configured in ROM. If the image is loaded to an address outside the allowed range (e.g., DDR before DDR init), this error occurs.

Allowed regions for authentication on i.MX8MP:
```
OCRAM:  0x00900000 - 0x0097FFFF (512 KB)
DRAM:   0x40000000 - 0xBFFFFFFF (when DDR is initialized)
```

SPL is always in OCRAM. U-Boot proper (authenticated from SPL, not HABv4) goes to DDR.

---

## Event Structure Byte Layout (Detailed)

```
HAB Event Record Structure:
┌─────┬──────────────────────────────────────────────────────────────┐
│Byte │ Field                                                        │
├─────┼──────────────────────────────────────────────────────────────┤
│  0  │ tag: 0xDB (HABv4 event tag, always)                         │
│ 1-2 │ len: total event length in bytes, big-endian                │
│  3  │ ver: HABv4 version (0x42 or 0x43)                           │
│  4  │ sts: HAB status code (SUCCESS/FAILURE/WARNING)               │
│  5  │ rsn: reason code                                             │
│  6  │ ctx: context code                                            │
│  7  │ eng: engine code                                             │
│ 8+  │ context-specific data (variable, depends on reason/context) │
└─────┴──────────────────────────────────────────────────────────────┘
```

For authentication failures, bytes 8+ contain the address of the failing data:
```
Bytes 8-11:  address[31:0]  (where the failing data was in memory)
Bytes 12-15: address[63:32] (0 for 32-bit addresses)
```

---

## Common Event Patterns and Root Causes

### Pattern 1: Authentication Passes in OPEN Mode

```
HAB Configuration: 0xf0 HAB State: 0xf0
No HAB Events Found!
```

**Cause:** Correct — image authenticated successfully.
**Action:** Device is ready for CLOSED mode transition.

---

### Pattern 2: HAB_INV_SIGNATURE on Authenticate Data

```
STS=HAB_FAILURE RSN=HAB_INV_SIGNATURE CTX=HAB_CTX_AUTHENTICATE ENG=HAB_ENG_CAAM
```

**Probable causes (in order of likelihood):**

1. **Wrong image binary in Authenticate Data block:**
   The CSF was signed against an older version of flash.bin. Regenerate the CSF after any rebuild of flash.bin.

2. **Incorrect block address in CSF:**
   The `Blocks` address does not match where the ROM actually loads the image. Check `IVT.self` in the binary.

3. **Incorrect block length:**
   The `Blocks` length exceeds or falls short of the data that was signed. The length should cover from file offset 0 to just before the CSF.

4. **Wrong signing key:**
   The IMG key used to sign does not match the IMG certificate embedded in the CSF, OR the CSFK used to sign does not match the CSFK certificate.

5. **Image modified after signing:**
   Any byte in the authenticated region changed (padding, alignment) after the CSF was generated.

**Diagnosis:**
```bash
# Verify the Authenticate Data block address:
hexdump -C -n 32 flash.bin
# Check bytes 20-23 (IVT.self) against CSF Blocks address

# Verify CSF is injected at correct offset:
# Bytes 24-27 of IVT.self should be the CSF RAM address
python3 -c "
import struct
with open('flash.bin', 'rb') as f:
    data = f.read(32)
print('IVT tag:', hex(data[0]))
print('IVT self:', hex(struct.unpack_from('<I', data, 20)[0]))
print('CSF ptr:', hex(struct.unpack_from('<I', data, 24)[0]))
"
```

---

### Pattern 3: HAB_INV_CERTIFICATE on Install SRK

```
STS=HAB_FAILURE RSN=HAB_INV_CERTIFICATE CTX=HAB_CTX_AUTHENTICATE ENG=HAB_ENG_CAAM
```

During the `Install SRK` command, this means the SRK table hash does not match the fuses.

**Probable causes:**
1. SRK_HASH fuses burned with a different SRK table
2. SRK table file (`SRK_1_2_3_4_table.bin`) regenerated after burning fuses
3. SRK table file corrupted

**Diagnosis:**
```bash
# Recompute SRK hash and compare with burned fuses:
sha256sum crts/SRK_1_2_3_4_table.bin

# Read SRK_HASH fuses from U-Boot:
=> fuse read 6 0 8
# Output: Bank 6 Word 0: AA BB CC DD  EE FF 00 11  ...
# Compare hex values with sha256sum output
```

---

### Pattern 4: HAB_INV_KEY with SRK Revocation

```
STS=HAB_FAILURE RSN=HAB_INV_KEY CTX=HAB_CTX_AUTHENTICATE ENG=HAB_ENG_ANY
```

**Cause:** The SRK at `Source index` in the CSF is revoked via `SRK_REVOKE` fuses.

**Diagnosis:**
```bash
# Read SRK_REVOKE fuse (Bank 9, Word 3 on i.MX8MP):
=> fuse read 9 3 1
# Bit 0 = SRK0 revoked, Bit 1 = SRK1 revoked, etc.
# 0x00 = none revoked, 0x01 = SRK0 revoked, 0x02 = SRK1 revoked
```

**Resolution:** Sign new firmware with a non-revoked SRK index.

---

### Pattern 5: Multiple Events — Chain of Failures

```
--------- HAB Event 1 ---------
STS=HAB_WARNING RSN=HAB_ENG_FAIL CTX=HAB_CTX_AUTHENTICATE ENG=HAB_ENG_CAAM

--------- HAB Event 2 ---------
STS=HAB_FAILURE RSN=HAB_INV_SIGNATURE CTX=HAB_CTX_AUTHENTICATE ENG=HAB_ENG_CAAM
```

When multiple events appear, read them in order. Event 1 is often a precondition failure that caused subsequent failures. In this case:
- Event 1: CAAM engine failure (RNG or self-test) — this is the root cause
- Event 2: Signature verification failed (because CAAM was not properly initialized)

Resolving Event 1 (adding the `[Unlock] Engine = CAAM / Features = RNG` command) will likely resolve Event 2 as well.

---

## Decision Tree for HAB Event Diagnosis

```
HAB event present?
├── No events → PASS. Ready to close.
│
└── Events present
    │
    ├── ALL events are HAB_WARNING + HAB_ENG_FAIL + HAB_ENG_CAAM?
    │   ├── YES → CAAM init warning (often benign)
    │   │         Add [Unlock] Engine = CAAM / Features = RNG to CSF
    │   │         Rebuild and test again
    │   │         Verify no events before closing
    │   └── NO → Continue below
    │
    ├── Any HAB_FAILURE event?
    │   │
    │   ├── RSN = HAB_INV_SIGNATURE?
    │   │   ├── Check: Blocks address == IVT.self
    │   │   ├── Check: Blocks length < CSF offset in flash.bin
    │   │   ├── Check: flash.bin not modified after signing
    │   │   └── Check: Correct CSF/IMG keys used
    │   │
    │   ├── RSN = HAB_INV_CERTIFICATE?
    │   │   ├── During Install SRK: SRK hash ≠ fuse value
    │   │   │   → Verify sha256(SRK table) matches fuses
    │   │   └── During Install CSFK/Install Key: cert chain broken
    │   │       → Verify CSFK signed by SRK, IMG signed by CSFK
    │   │
    │   ├── RSN = HAB_INV_IVT?
    │   │   ├── IVT tag not 0xD1
    │   │   ├── IVT version not 0x43
    │   │   └── IVT.self != IVT load address
    │   │
    │   ├── RSN = HAB_INV_ADDRESS?
    │   │   └── Image loaded outside allowed OCRAM/DDR range
    │   │       Check boot_data.start address
    │   │
    │   ├── RSN = HAB_INV_CSF?
    │   │   ├── CSF tag not 0xD4
    │   │   ├── CSF pointer in IVT wrong
    │   │   └── CSF binary corrupted
    │   │
    │   └── RSN = HAB_INV_KEY?
    │       └── SRK index is revoked
    │           Read SRK_REVOKE fuses
    │           Use non-revoked SRK index
    │
    └── Events are HAB_WARNING but not HAB_ENG_FAIL?
        └── Unusual warning — check NXP errata for your silicon rev
```

---

## Capturing HAB Events in U-Boot Script

For automated testing, capture `hab_status` output:

```bash
# From Linux host (picocom/minicom session):
picocom -b 115200 /dev/ttyUSB0 --logfile hab_events.log

# In U-Boot:
=> hab_status
```

Or from a U-Boot boot script:

```
# In U-Boot environment:
setenv hab_check 'hab_status; if test $? = 0; then echo HAB_OK; else echo HAB_FAIL; fi'
run hab_check
```

> **📝 NOTE:** `hab_status` always returns 0 (success) in U-Boot regardless of HAB failures. The exit code does not reflect authentication status — you must parse the text output to detect failures.

---

## HAB Events in Linux (Post-Boot)

After booting Linux, HAB events can be read via the `imx_hab` kernel driver or via SYSFS if the HAB event buffer is mapped:

```bash
# Check if HAB driver is available:
ls /sys/bus/platform/drivers/imx_hab/

# On systems with IMX_HAB driver compiled:
cat /sys/devices/platform/imx_hab/hab_status
```

However, on most production i.MX8MP systems, the HAB event buffer in OCRAM is overwritten during DDR init or kernel memory setup. **Capturing events in U-Boot is the reliable approach.**

---

## References

- NXP Application Note AN4581: "Secure Boot on i.MX50, i.MX53, and i.MX6 Series using HABv4"
  https://www.nxp.com/docs/en/application-note/AN4581.pdf
  (Sections 3-5 cover event log format and status codes)

- NXP Application Note AN12263: "HABv4 RVT Guidelines and Recommendations"
  https://www.nxp.com/docs/en/application-note/AN12263.pdf
  (Table 1: HAB API status codes, Table 2: Context codes)

- U-Boot HAB status implementation:
  `arch/arm/mach-imx/hab.c` — `get_hab_status()` function
  https://source.denx.de/u-boot/u-boot/-/blob/master/arch/arm/mach-imx/hab.c

- NXP i.MX8M Plus Reference Manual (IMX8MPRM)
  Chapter: OCOTP — for SRK_HASH and SRK_REVOKE fuse addresses
  Available from NXP.com (registration required)
