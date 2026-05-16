# SRK Hash Verification

## Why Verification is Critical

Burning wrong SRK hash + SEC_CONFIG = permanent brick with no recovery.

The SRK hash is a 256-bit SHA-256 digest of the SRK table (concatenated
public key components). A single wrong bit in any of the 8 fuse words
means the device will reject ALL signed firmware after closure.

The verification procedure MUST be performed by TWO independent engineers
who each derive the expected values from the original key files independently.

## Background: How the SRK Hash is Computed

```
Keys:          SRK1.pem  SRK2.pem  SRK3.pem  SRK4.pem
                  |          |          |          |
                  v          v          v          v
SRK Table:   [ SRK1_pub | SRK2_pub | SRK3_pub | SRK4_pub ]  (concatenated)
                                   |
                            SHA-256 hash
                                   |
                         SRK_1_2_3_4_fuse.bin
                         (32 bytes = 8 x 4-byte words)
                                   |
                         Programmed into OTP fuses
                         Bank 3, Words 0-7
```

## Step 1: Generate Expected Values on Signing Workstation

Perform on the air-gapped signing workstation where SRK private keys reside.

```bash
# Confirm srktool version and environment
srktool --version
# CST version should match what was used to create keys

# Regenerate fuse binary from SRK certificates
srktool --hab_ver 4 \
    --certs SRK1_sha256_2048_65537_v3_usr_crt.pem \
            SRK2_sha256_2048_65537_v3_usr_crt.pem \
            SRK3_sha256_2048_65537_v3_usr_crt.pem \
            SRK4_sha256_2048_65537_v3_usr_crt.pem \
    --table SRK_1_2_3_4_table.bin \
    --efuse_entries SRK_1_2_3_4_fuse.bin \
    --format bin

# Verify file size
wc -c SRK_1_2_3_4_fuse.bin
# Must be exactly 32 bytes

# Display hex representation
xxd SRK_1_2_3_4_fuse.bin
# Example output:
# 00000000: aabb ccdd eeff 0011 2233 4455 6677 8899  ................
# 00000010: aabb ccdd eeff 0011 2233 4455 6677 8899  ................

# Generate expected fuse commands
python3 << 'EOF'
import struct, hashlib

with open('SRK_1_2_3_4_fuse.bin', 'rb') as f:
    data = f.read()

assert len(data) == 32, f"Expected 32 bytes, got {len(data)}"

print("=" * 70)
print("EXPECTED SRK FUSE VALUES")
print("Signing Workstation Output - For Two-Person Verification")
print("=" * 70)
print()
print("SHA-256 of fuse binary (integrity check):")
print(f"  {hashlib.sha256(data).hexdigest()}")
print()
print("U-Boot programming commands:")
for i in range(8):
    word = struct.unpack('<I', data[i*4:(i+1)*4])[0]
    print(f"  fuse prog -y 3 {i} 0x{word:08X}")
print()
print("U-Boot readback expected values:")
for i in range(8):
    word = struct.unpack('<I', data[i*4:(i+1)*4])[0]
    print(f"  Bank 3 Word 0x{i:08X}: {word:08X}")
print()
print("Linux nvmem expected hex dump:")
import binascii
print(f"  {binascii.hexlify(data).decode()}")
EOF
```

## Step 2: Independent Verification by Second Engineer

Engineer 2 must independently derive expected values WITHOUT looking at
Engineer 1's output until after their own derivation is complete.

```bash
# Engineer 2: independently run the same commands
# Use the SAME SRK certificate files (verify certificate fingerprints first)

# Verify certificate fingerprints match known-good values
for cert in SRK1_sha256_2048_65537_v3_usr_crt.pem \
            SRK2_sha256_2048_65537_v3_usr_crt.pem \
            SRK3_sha256_2048_65537_v3_usr_crt.pem \
            SRK4_sha256_2048_65537_v3_usr_crt.pem; do
    echo -n "$cert fingerprint: "
    openssl x509 -in "$cert" -noout -fingerprint -sha256
done

# Run srktool independently and produce separate fuse binary
srktool --hab_ver 4 \
    --certs SRK1_sha256_2048_65537_v3_usr_crt.pem \
            SRK2_sha256_2048_65537_v3_usr_crt.pem \
            SRK3_sha256_2048_65537_v3_usr_crt.pem \
            SRK4_sha256_2048_65537_v3_usr_crt.pem \
    --table SRK_1_2_3_4_table_eng2.bin \
    --efuse_entries SRK_1_2_3_4_fuse_eng2.bin \
    --format bin

# Compare outputs from both engineers
diff <(xxd SRK_1_2_3_4_fuse.bin) <(xxd SRK_1_2_3_4_fuse_eng2.bin)
# Expected: no output (files identical)

sha256sum SRK_1_2_3_4_fuse.bin SRK_1_2_3_4_fuse_eng2.bin
# Both hashes must match
```

## Step 3: Verify After Programming on Target Device

On target device at U-Boot console, read back all 8 programmed words:

```
# Method 1: Manual readback (one word at a time)
=> fuse read 3 0
=> fuse read 3 1
=> fuse read 3 2
=> fuse read 3 3
=> fuse read 3 4
=> fuse read 3 5
=> fuse read 3 6
=> fuse read 3 7
```

Compare each readback value against the expected values from Step 1.

```
# Method 2: In-memory verification using U-Boot md command
# Load SRK fuse binary to RAM for comparison
=> tftp ${loadaddr} SRK_1_2_3_4_fuse.bin
# Or from storage:
=> load mmc 0:1 ${loadaddr} SRK_1_2_3_4_fuse.bin

# Display loaded data
=> md.l ${loadaddr} 8
# Compare visually against fuse read output
```

## Step 4: Linux-Side Verification

After booting Linux, verify via nvmem interface:

```bash
#!/bin/bash
# verify_srk_nvmem.sh
# Run on target device after programming, compares nvmem against expected file

EXPECTED_FILE="SRK_1_2_3_4_fuse.bin"
NVMEM_DEV="/sys/bus/nvmem/devices/imx-ocotp0/nvmem"

if [ ! -f "$EXPECTED_FILE" ]; then
    echo "ERROR: Expected fuse file not found: $EXPECTED_FILE"
    exit 1
fi

if [ ! -r "$NVMEM_DEV" ]; then
    echo "ERROR: Cannot read nvmem device (need root?)"
    exit 1
fi

# Bank 3, Words 0-7 start at byte offset (3*8+0)*4 = 96
OFFSET=96

# Read 32 bytes from nvmem at fuse offset
ACTUAL=$(dd if="$NVMEM_DEV" bs=1 skip=$OFFSET count=32 2>/dev/null | xxd -p | tr -d '\n')
EXPECTED=$(xxd -p "$EXPECTED_FILE" | tr -d '\n')

echo "Expected: $EXPECTED"
echo "Actual:   $ACTUAL"

if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo ""
    echo "PASS: SRK fuse values match expected values"
    exit 0
else
    echo ""
    echo "FAIL: SRK fuse values DO NOT match expected values"
    echo "DO NOT BURN SEC_CONFIG"
    exit 1
fi
```

## Step 5: Cross-Verification Script

Full cross-verification with detailed word-by-word comparison:

```python
#!/usr/bin/env python3
# verify_srk_fuses.py
#
# Usage:
#   On target device: read fuse values and paste into 'actual_values' list
#   Run: python3 verify_srk_fuses.py

import struct
import hashlib
import sys

# Path to expected fuse binary (transfer from signing workstation)
EXPECTED_FILE = "SRK_1_2_3_4_fuse.bin"

# Actual values read from 'fuse read 3 N' commands on target
# REPLACE THESE with actual readback values from device
actual_values = [
    0x00000000,  # Word 0 - paste actual value here
    0x00000000,  # Word 1
    0x00000000,  # Word 2
    0x00000000,  # Word 3
    0x00000000,  # Word 4
    0x00000000,  # Word 5
    0x00000000,  # Word 6
    0x00000000,  # Word 7
]

# Load expected values from fuse binary
try:
    with open(EXPECTED_FILE, 'rb') as f:
        data = f.read()
except FileNotFoundError:
    print(f"ERROR: Cannot find {EXPECTED_FILE}")
    sys.exit(2)

if len(data) != 32:
    print(f"ERROR: {EXPECTED_FILE} should be 32 bytes, got {len(data)}")
    sys.exit(2)

expected_values = [
    struct.unpack('<I', data[i*4:(i+1)*4])[0]
    for i in range(8)
]

print("=" * 70)
print("SRK FUSE VERIFICATION REPORT")
print("=" * 70)
print(f"Expected file:  {EXPECTED_FILE}")
print(f"Expected SHA256: {hashlib.sha256(data).hexdigest()}")
print()
print(f"{'Word':<6} {'Expected':>12} {'Actual':>12} {'Status':>10}")
print("-" * 44)

all_ok = True
for i, (exp, act) in enumerate(zip(expected_values, actual_values)):
    status = "PASS" if exp == act else "FAIL"
    if exp != act:
        all_ok = False
    print(f"{i:<6} 0x{exp:08X}   0x{act:08X}   {status:>10}")

print()
if all_ok:
    print("RESULT: ALL SRK FUSE VALUES MATCH")
    print("SAFE TO PROCEED with SEC_CONFIG programming")
    print()
    print("Required sign-off:")
    print("  Engineer 1: _________________________ Date: _________")
    print("  Engineer 2: _________________________ Date: _________")
    sys.exit(0)
else:
    print("RESULT: MISMATCH DETECTED - DO NOT BURN SEC_CONFIG")
    print()
    print("Actions required:")
    print("  1. Investigate which fuse words are incorrect")
    print("  2. Determine if it is a programming error or wrong source file")
    print("  3. This device may need to be retired if wrong values are permanent")
    sys.exit(1)
```

## Step 6: Document and Sign Off

Complete and file the following before proceeding to SEC_CONFIG:

```
SRK FUSE PROGRAMMING SIGN-OFF SHEET
=====================================
Device serial number: _______________________
Programming date/time: ______________________
Station ID: ________________________________
U-Boot version: ____________________________
SRK fuse binary SHA-256: ___________________

SRK Certificate fingerprints:
  SRK1: __________________________________
  SRK2: __________________________________
  SRK3: __________________________________
  SRK4: __________________________________

Fuse readback verification:
  Word 0: 0x________ expected  0x________ actual  [ ] MATCH
  Word 1: 0x________ expected  0x________ actual  [ ] MATCH
  Word 2: 0x________ expected  0x________ actual  [ ] MATCH
  Word 3: 0x________ expected  0x________ actual  [ ] MATCH
  Word 4: 0x________ expected  0x________ actual  [ ] MATCH
  Word 5: 0x________ expected  0x________ actual  [ ] MATCH
  Word 6: 0x________ expected  0x________ actual  [ ] MATCH
  Word 7: 0x________ expected  0x________ actual  [ ] MATCH

Signed boot test (OPEN mode with SRK burned):
  hab_status result: [ ] No HAB Events Found

Engineer 1 signature: ______________________ Date: _________
Engineer 2 signature: ______________________ Date: _________
```

## Common Mistakes and How to Avoid Them

### Mistake 1: Byte order confusion

The SRK fuse binary is stored in little-endian byte order. The fuse
register is a 32-bit little-endian word. No byte-swapping is needed
when using the srktool-generated binary with standard U-Boot fuse commands.

```bash
# CORRECT: use as-is from srktool
python3 -c "
import struct
data = open('SRK_1_2_3_4_fuse.bin','rb').read()
word0 = struct.unpack('<I', data[0:4])[0]  # little-endian
print(f'fuse prog -y 3 0 0x{word0:08X}')  # This is correct
"

# WRONG: byte-swapping the word
python3 -c "
import struct
data = open('SRK_1_2_3_4_fuse.bin','rb').read()
word0 = struct.unpack('>I', data[0:4])[0]  # big-endian WRONG
print(f'fuse prog -y 3 0 0x{word0:08X}')  # This would program wrong value
"
```

### Mistake 2: Using wrong SRK certificate order

The order of certificates passed to srktool MUST match the order
used during image signing. SRK index 0 in the signing CSF must
correspond to SRK1 certificate used in srktool.

```bash
# Document and lock the ordering in your signing scripts
# The default: SRK1=index0, SRK2=index1, SRK3=index2, SRK4=index3
```

### Mistake 3: Verifying against stale fuse binary

Always regenerate the fuse binary from the actual certificates.
Do not reuse a fuse binary file from a previous key generation run.

```bash
# Good practice: generate fresh fuse binary and verify its SHA-256
# matches the authoritative copy in your secure key store
```

### Mistake 4: Skipping the two-engineer verification

Single-person verification is insufficient for production devices.
Both engineers must independently derive expected values from source certificates.
