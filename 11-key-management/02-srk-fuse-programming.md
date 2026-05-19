# SRK Hash Fuse Programming

## Overview

Programming the SRK hash fuses is the **irreversible** step that binds your device to a specific key hierarchy. Once written, these fuses cannot be changed. The device will only boot software signed with the matching SRK keys.

```
OCOTP Bank 3, Words 0–7 (32 bytes total)
= SHA-256 hash of SRK_1_2_3_4_table.bin
= SHA-256(SRK1_pub || SRK2_pub || SRK3_pub || SRK4_pub)
```

**This operation is one-way. Verify three times before programming.**

---

## Fuse Map: SRK Hash Location

```
OCOTP Bank 3:
  Word 0: SRK_HASH[31:0]    (0x580)  ← LSB first
  Word 1: SRK_HASH[63:32]   (0x590)
  Word 2: SRK_HASH[95:64]   (0x5A0)
  Word 3: SRK_HASH[127:96]  (0x5B0)
  Word 4: SRK_HASH[159:128] (0x5C0)
  Word 5: SRK_HASH[191:160] (0x5D0)
  Word 6: SRK_HASH[223:192] (0x5E0)
  Word 7: SRK_HASH[255:224] (0x5F0)  ← MSB last

SRK hash is stored in little-endian word order but each
word value is stored as-is (no byte swap within word).
```

---

## Step 1: Generate Fuse Values

From the signing workstation after key generation:

```bash
# Confirm SRK table exists and is correct size
ls -la SRK_1_2_3_4_table.bin SRK_1_2_3_4_fuse.bin
# SRK_1_2_3_4_table.bin  — should be ~1KB (4× RSA-2048 public keys)
# SRK_1_2_3_4_fuse.bin   — must be exactly 32 bytes

# Verify fuse file size
stat --printf="%s\n" SRK_1_2_3_4_fuse.bin
# Must output: 32

# Compute SHA-256 of SRK table to cross-verify
sha256sum SRK_1_2_3_4_table.bin

# Display fuse programming commands
python3 << 'EOF'
import struct

data = open('SRK_1_2_3_4_fuse.bin', 'rb').read()
assert len(data) == 32, f"ERROR: Expected 32 bytes, got {len(data)}"

print("=" * 60)
print("SRK HASH FUSE VALUES FOR i.MX8MP")
print("OCOTP Bank 3, Words 0-7")
print("=" * 60)
print()
print("U-Boot fuse programming commands:")
print()
for i in range(8):
    word = struct.unpack('<I', data[i*4:(i+1)*4])[0]
    print(f"  fuse prog -y 3 {i} 0x{word:08X}")
print()
print("Linux nvmem write commands (byte offsets from /sys/bus/nvmem/...):")
for i in range(8):
    word = struct.unpack('<I', data[i*4:(i+1)*4])[0]
    print(f"  # Word {i}: 0x{word:08X}")
print()
print("SHA-256 hash (hex) for documentation:")
import hashlib
table_data = open('SRK_1_2_3_4_table.bin', 'rb').read()
sha = hashlib.sha256(table_data).hexdigest()
print(f"  {sha}")
print()
print("RECORD THESE VALUES. VERIFY WITH SECOND ENGINEER.")
print("FUSES ARE ONE-TIME PROGRAMMABLE.")
EOF
```

---

## Step 2: Pre-Programming Verification Checklist

```
MANDATORY — both engineers must sign off before proceeding:

[ ] 1. Fuse binary is exactly 32 bytes
[ ] 2. SRK table SHA-256 verified by Engineer 1
[ ] 3. SRK table SHA-256 verified by Engineer 2 (independently)
[ ] 4. Fuse values recorded in key ceremony log
[ ] 5. Device is running in HAB OPEN mode (sec_config = 0x00)
[ ] 6. Signed imx-boot has been validated in OPEN mode (hab_status OK)
[ ] 7. U-Boot prompt accessible on device
[ ] 8. Backup keys stored offline (at least 1 unused SRK slot available)
[ ] 9. This is NOT a production device being used for development

Engineer 1: _________________________ Date: _____________
Engineer 2: _________________________ Date: _____________
```

---

## Step 3: Read Current Fuse Values (Before Programming)

Connect to device via UART console (U-Boot prompt):

```
U-Boot> fuse read 3 0 8
Reading bank 3:

Word 0x00000000: 00000000 00000000 00000000 00000000
                 00000000 00000000 00000000 00000000
```

All zeros confirms fuses not yet programmed.

---

## Step 4: Program SRK Fuses

**Example values — substitute your actual values from Step 1:**

```
U-Boot> fuse prog -y 3 0 0xDEADBEEF
Programming bank 3 word 0x00000000 to 0xdeadbeef...OK

U-Boot> fuse prog -y 3 1 0xCAFEBABE
Programming bank 3 word 0x00000001 to 0xcafebbabe...OK

U-Boot> fuse prog -y 3 2 0x12345678
...

# Continue for words 3–7 with your actual hash values
```

**If any `fuse prog` command returns an error**, stop immediately. Do not try to continue programming.

---

## Step 5: Verify Programmed Values

```
U-Boot> fuse read 3 0 8
Reading bank 3:

Word 0x00000000: DEADBEEF CAFEBABE 12345678 ...
                 ...      ...      ...      ...
```

Cross-reference every word with your recorded values from Step 1. If any word differs:
- The fuse burned incorrectly or a bit was already set
- Document the discrepancy
- Contact NXP support before proceeding to device closure

---

## Step 6: Reload HAB Shadow Registers (Without Reboot)

```
U-Boot> fuse override 3 0 0xDEADBEEF
```

Or simply power-cycle — HAB reads fuses on every power-on reset.

---

## Step 7: Test HAB Authentication (Still in OPEN Mode)

```
U-Boot> hab_auth_img <load_addr> <ivt_offset>
```

Or boot normally and check:

```
U-Boot> hab_status
HAB Configuration: 0x00 HAB State: 0x00
No HAB Events Found!
```

`HAB Configuration: 0x00` = OPEN mode (not yet closed)
`No HAB Events Found!` = SRK hash matches, signature verified

**If you see HAB events at this point**, the SRK hash does not match your signing keys. **Do not close the device.** Investigate immediately.

---

## Step 8: Close the Device (SEC_CONFIG Fuse)

Only after confirming `No HAB Events Found!` in Step 7:

```
U-Boot> fuse prog -y 1 3 0x2
Programming bank 1 word 0x00000003 to 0x00000002...OK
```

After closing, power-cycle and verify:

```
U-Boot> hab_status
HAB Configuration: 0x02 HAB State: 0x66
No HAB Events Found!
```

`HAB Configuration: 0x02` = CLOSED mode
`HAB State: 0x66` = TRUSTED (not 0x33 FAIL)

The device will now **halt boot** if any authentication fails.

---

## Verification Scripts

### Linux-Side Verification (Post-Deployment)

```bash
#!/bin/bash
# verify-srk-fuses.sh — Run on target device after provisioning

SRK_FUSE_PATH="/sys/bus/nvmem/devices/imx-ocotp0/nvmem"

# Bank 3 starts at offset 0x60 (Bank * 0x20 * 4 = 3 * 0x80 = 0x180... check datasheet)
# For i.MX8MP: Bank 3 Word 0 = shadow register 0x580 → nvmem offset = (3*8 + 0)*4 = 96 = 0x60
OFFSET=$((3 * 8 * 4))  # = 96 = 0x60

echo "Reading SRK hash from OCOTP nvmem..."
read_fuses() {
    dd if="$SRK_FUSE_PATH" bs=1 skip=$OFFSET count=32 2>/dev/null | \
        od -An -tx4 -w4 | tr -d ' \n'
}

FUSE_HEX=$(read_fuses)
echo "Raw fuse words (hex): $FUSE_HEX"

# Compare against known-good value (embed at provisioning time)
EXPECTED_SHA="$(sha256sum /etc/srk-table.bin | cut -d' ' -f1)"
echo "Expected SRK table hash: $EXPECTED_SHA"
```

### Cross-Check SRK Hash

```bash
# On signing station: regenerate fuse values from SRK table
python3 << 'EOF'
import hashlib, struct

table = open('SRK_1_2_3_4_table.bin', 'rb').read()
sha = hashlib.sha256(table).digest()

print("Expected fuse values (LSB word first):")
for i in range(8):
    word = struct.unpack('<I', sha[i*4:(i+1)*4])[0]
    print(f"  Bank 3, Word {i}: 0x{word:08X}")
EOF
```

---

## Failure Recovery

### Scenario: Wrong SRK Hash Burned

This is a **catastrophic failure**. Once the wrong SRK hash is in fuses:
- If device is still OPEN: you can still boot, but the device cannot be properly authenticated by the SRK keys
- If device is CLOSED: the device will never boot again (unless you have a key matching the burned hash)

**Recovery options:**
1. **Use SRK revocation (if remaining open slots)**: HABv4 supports 4 SRK slots; if you burned SRK1's hash incorrectly but other slots are available, re-sign with a different SRK key that matches
2. **NXP field service**: In some cases NXP can assist with JTAG-level recovery for early lifecycle devices
3. **Hardware write**: Not feasible — OCOTP is truly OTP
4. **Accept as destroyed**: Mark device as unusable, destroy securely

**Prevention is the only real answer.** Never rush fuse programming.

### Scenario: Fuse Program Command Fails

```
ERROR: fuse prog: Programming error at bank 3 word 0
```

Possible causes:
- Voltage on VDD_FUSE (1.8V) not stable
- Fuse already programmed (a 1 cannot become 0)
- Hardware fault

Actions:
1. Check VDD_FUSE voltage on board
2. Read current fuse value — if already correct, no action needed
3. If partially wrong bits, evaluate SRK key recovery path

---

## Key Ceremony Record Template

```
KEY CEREMONY LOG
================
Date:                    _______________
Location:                _______________
HSM Serial:              _______________
Device Serial:           _______________

Personnel:
  Engineer 1:            _______________  [signature] _______________
  Engineer 2:            _______________  [signature] _______________
  Security Officer:      _______________  [signature] _______________

SRK Table SHA-256:       _______________________________________________

Fuse Values Programmed:
  Bank 3, Word 0:        0x_______________
  Bank 3, Word 1:        0x_______________
  Bank 3, Word 2:        0x_______________
  Bank 3, Word 3:        0x_______________
  Bank 3, Word 4:        0x_______________
  Bank 3, Word 5:        0x_______________
  Bank 3, Word 6:        0x_______________
  Bank 3, Word 7:        0x_______________

HAB Status After Programming:   _______________
Device Closure Fuse Set:         Yes / No

Notes:
_________________________________________________________________
```

---

## Cross-References

- [01-key-generation.md](01-key-generation.md) — Generate SRK keys and fuse.bin
- [../12-habv4-imx8m/05-hab-lifecycle.md](../12-habv4-imx8m/05-hab-lifecycle.md) — SEC_CONFIG fuse and lifecycle states
- [../18-fuse-programming/02-fuse-programming-procedures.md](../18-fuse-programming/02-fuse-programming-procedures.md) — General fuse programming
- [../28-production-checklists/01-pre-provisioning-checklist.md](../28-production-checklists/01-pre-provisioning-checklist.md) — Full provisioning checklist
