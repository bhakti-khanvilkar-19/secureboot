# HABv4 Debugging

## Reading HAB Status in U-Boot

```
U-Boot> hab_status
```

### Success Output (OPEN mode)

```
HAB Configuration: 0x00 HAB State: 0x00
No HAB Events Found!
```

### Success Output (CLOSED mode)

```
HAB Configuration: 0x02 HAB State: 0x66
No HAB Events Found!
```

### Failure Output

```
HAB Configuration: 0x00 HAB State: 0x00

----- HAB Event 1 -----
event data:
        0xdb 0x00 0x24 0x43 0x33 0x22 0x0a 0x00
        0xca 0x00 0x00 0x00 0x00 0x00 0x00 0x00
        0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
        0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
        0x00 0x00 0x00 0x00

STS = HAB_FAILURE (0x33)
RSN = HAB_INV_SIGNATURE (0x18)
CTX = HAB_CTX_COMMAND (0x0A)
ENG = HAB_ENG_ANY (0x00)
```

---

## HAB Event Byte Structure

```
Byte  0:    Header (0xdb = HAB event header)
Byte  1:    Length high byte
Byte  2:    Length low byte (0x24 = 36 bytes total)
Byte  3:    Version (0x43 = HABv4)
Byte  4:    Status  (0x33 = HAB_FAILURE)
Byte  5:    Reason  (0x18 = HAB_INV_SIGNATURE)
Byte  6:    Context (0x0A = HAB_CTX_COMMAND)
Byte  7:    Engine  (0x00 = HAB_ENG_ANY)
Bytes 8-35: Additional data (context-specific)
```

---

## Status Codes

| Value | Name | Meaning |
|-------|------|---------|
| 0xF0 | HAB_SUCCESS | Operation succeeded |
| 0x33 | HAB_FAILURE | Operation failed |
| 0x69 | HAB_WARNING | Non-fatal issue (OPEN mode) |

---

## Reason Codes (Most Common)

| Value | Name | Cause | Fix |
|-------|------|-------|-----|
| 0x00 | HAB_RSN_ANY | Generic/unspecified | Check full event data |
| 0x05 | HAB_INV_ADDRESS | Invalid load address | Check SPL_LOAD_ADDR in CSF |
| 0x18 | HAB_INV_SIGNATURE | Signature verification failed | Re-sign with correct keys |
| 0x1D | HAB_INV_INDEX | Invalid SRK index | Check SRK table index |
| 0x1E | HAB_INV_ASSERTION | Internal assertion | Check image integrity |
| 0x2B | HAB_INV_CERTIFICATE | Certificate chain invalid | Verify CSF cert chain |
| 0x3B | HAB_INV_CLAIM | Algorithm mismatch | Match algorithms in CSF |
| 0x3E | HAB_INV_COMMAND | Invalid CSF command | Check CSF syntax |
| 0x3F | HAB_INV_CSF | CSF structure invalid | Regenerate CSF |
| 0xC2 | HAB_INV_KEY | Key not loaded | Install SRK before CSF |
| 0xCA | HAB_INV_DATA | Data verification failed | Wrong image covered by CSF |
| 0x2B | HAB_MEM_FAIL | Memory error | Address/size issue in CSF |

---

## Context Codes

| Value | Name | When it Occurs |
|-------|------|----------------|
| 0x00 | HAB_CTX_ANY | Generic |
| 0x0A | HAB_CTX_COMMAND | During CSF command processing |
| 0x10 | HAB_CTX_AUT_DAT | During Authenticate Data |
| 0x20 | HAB_CTX_ASSERT | During assertion/check |
| 0x22 | HAB_CTX_DCD | During DCD processing |
| 0x24 | HAB_CTX_ENTRY | During HAB_ENTRY |
| 0x25 | HAB_CTX_EXIT | During HAB_EXIT |
| 0x41 | HAB_CTX_FAB | During certificate fabrication |

---

## Systematic Debugging Workflow

### Step 1: Reproduce in OPEN Mode

If the device is CLOSED and failing, it will halt. Work in OPEN mode during development:

```
# Verify device is OPEN (fuse not burned):
U-Boot> fuse read 1 3
# Bit 1 of word 3 must be 0 for OPEN mode
```

### Step 2: Get Full HAB Event Data

```
U-Boot> hab_status
```

Capture all output — especially the "event data" hex bytes.

### Step 3: Decode Event

```python
#!/usr/bin/env python3
# decode-hab-event.py

STATUS = {
    0xF0: "HAB_SUCCESS",
    0x33: "HAB_FAILURE",
    0x69: "HAB_WARNING"
}

REASON = {
    0x00: "HAB_RSN_ANY",
    0x05: "HAB_INV_ADDRESS",
    0x18: "HAB_INV_SIGNATURE",
    0x1D: "HAB_INV_INDEX",
    0x1E: "HAB_INV_ASSERTION",
    0x2B: "HAB_INV_CERTIFICATE",
    0x3B: "HAB_INV_CLAIM",
    0x3E: "HAB_INV_COMMAND",
    0x3F: "HAB_INV_CSF",
    0xC2: "HAB_INV_KEY",
    0xCA: "HAB_INV_DATA",
    0x2B: "HAB_MEM_FAIL",
}

CONTEXT = {
    0x00: "HAB_CTX_ANY",
    0x0A: "HAB_CTX_COMMAND",
    0x10: "HAB_CTX_AUT_DAT",
    0x20: "HAB_CTX_ASSERT",
    0x22: "HAB_CTX_DCD",
    0x24: "HAB_CTX_ENTRY",
    0x25: "HAB_CTX_EXIT",
    0x41: "HAB_CTX_FAB",
}

ENGINE = {
    0x00: "HAB_ENG_ANY",
    0x01: "HAB_ENG_SCC",
    0x02: "HAB_ENG_RTIC",
    0x03: "HAB_ENG_SAHARA",
    0x06: "HAB_ENG_CSU",
    0x0A: "HAB_ENG_SRTC",
    0x1D: "HAB_ENG_DCP",
    0x1E: "HAB_ENG_CAAM",
    0x1F: "HAB_ENG_SNVS",
    0x21: "HAB_ENG_OCOTP",
    0x22: "HAB_ENG_DTCP",
    0x36: "HAB_ENG_ROM",
    0xFF: "HAB_ENG_SW",
}

# Paste event bytes here:
raw = "0xdb 0x00 0x24 0x43 0x33 0x18 0x0a 0x00 0xca 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00"
data = [int(b, 16) for b in raw.split()]

print(f"Header:  0x{data[0]:02X}")
print(f"Length:  {(data[1] << 8) | data[2]}")
print(f"Version: 0x{data[3]:02X}")
print(f"Status:  {STATUS.get(data[4], 'UNKNOWN')} (0x{data[4]:02X})")
print(f"Reason:  {REASON.get(data[5], 'UNKNOWN')} (0x{data[5]:02X})")
print(f"Context: {CONTEXT.get(data[6], 'UNKNOWN')} (0x{data[6]:02X})")
print(f"Engine:  {ENGINE.get(data[7], 'UNKNOWN')} (0x{data[7]:02X})")
if len(data) > 8:
    extra = " ".join(f"0x{b:02X}" for b in data[8:])
    print(f"Data:    {extra}")
```

### Step 4: Match Reason to Fix

**HAB_INV_SIGNATURE (0x18) + HAB_CTX_AUT_DAT (0x10)**

The most common failure. Image data does not match signature in CSF.

Causes:
1. Image was modified after signing
2. CSF block descriptor uses wrong address/offset/size
3. Wrong IMG key used for signing

Fix:
```bash
# Re-verify CSF coverage:
# Check Authenticate Data block in CSF:
# Blocks = <load_addr> <image_offset> <size> "<image_file>"

# The load_addr must match SPL_LOAD_ADDR
# The image_offset is usually 0x000
# The size must match actual image size (after padding)

# Recompute expected size:
FLASH_SIZE=$(wc -c < imx-boot.bin)
PADDED_SIZE=$(( (FLASH_SIZE + 0xFFF) & ~0xFFF ))
echo "Padded size: 0x$(printf '%x' $PADDED_SIZE)"
# This value goes in the CSF Authenticate Data block
```

**HAB_INV_CERTIFICATE (0x2B)**

Certificate chain broken.

Causes:
1. CSF certificate not signed by SRK in the SRK table
2. Using wrong CSF cert (from different key generation run)

Fix:
```bash
# Verify CSF cert is signed by SRK1 (or whichever SRK index you used):
openssl verify \
    -CAfile ${CST}/crts/SRK1_sha256_2048_65537_v3_usr_crt.pem \
    ${CST}/crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem
```

**HAB_INV_KEY (0xC2)**

SRK not installed — "Install SRK" command in CSF failed.

Causes:
1. SRK table file path wrong
2. SRK index in CSF doesn't match fuse-burned SRK hash

Fix:
```bash
# Verify SRK table hash matches burned fuses:
python3 << 'EOF'
import hashlib, struct

table = open('SRK_1_2_3_4_table.bin', 'rb').read()
sha = hashlib.sha256(table).digest()

print("SRK table SHA-256 fuse values:")
for i in range(8):
    word = struct.unpack('<I', sha[i*4:(i+1)*4])[0]
    print(f"  Bank 3, Word {i}: 0x{word:08X}")
EOF

# Compare against:
# U-Boot> fuse read 3 0 8
```

---

## Common Scenarios and Solutions

### Scenario: Signed on Different Hardware

**Problem**: Signed on build machine, fails on target.
**Cause**: Build machine has different libraries that generate different IVT layouts.
**Fix**: Always use the actual target's imx-boot.bin output — never re-link after signing.

### Scenario: Padding Changed

**Problem**: Image was padded to wrong alignment.
**Fix**:
```bash
# CSF block size must match exactly:
ACTUAL_SIZE=$(wc -c < imx-boot.bin)
# Pad to next 4KB boundary:
PADDED=$(( (ACTUAL_SIZE + 4095) & ~4095 ))

# If you used dd to pad, verify:
dd if=imx-boot-padded.bin bs=1 count=1 skip=$PADDED | od -An -tx1
# Should show 0x00 (padding byte)
```

---

## Cross-References

- [../12-habv4-imx8m/03-hab-event-decoding.md](../12-habv4-imx8m/03-hab-event-decoding.md) — Complete event code tables
- [../12-habv4-imx8m/04-cst-workflow.md](../12-habv4-imx8m/04-cst-workflow.md) — CST workflow
- [04-common-failure-modes.md](04-common-failure-modes.md) — All failure modes
