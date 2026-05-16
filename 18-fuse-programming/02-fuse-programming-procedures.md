# Fuse Programming Procedures

## WARNING: Fuse programming is IRREVERSIBLE

Once a fuse bit is burned (0 to 1), it CANNOT be reset (1 to 0).
Programming incorrect values PERMANENTLY BRICKS the device.
There is no NXP recovery procedure for incorrect SRK hash + SEC_CONFIG.

## Pre-Programming Safety Checklist

Before programming ANY security fuse:
- [ ] Device is in HAB OPEN mode (SEC_CONFIG = 0x0)
- [ ] Signed firmware boots successfully in OPEN mode
- [ ] `hab_status` shows "No HAB Events Found!" in OPEN mode
- [ ] SRK fuse values VERIFIED against SRK_1_2_3_4_fuse.bin (byte-by-byte)
- [ ] Second engineer has independently verified SRK values
- [ ] Fuse commands reviewed and signed off in change management system
- [ ] Recovery plan documented (USB download mode physically accessible)
- [ ] Dedicated development/test device confirmed (not production unit)
- [ ] VDD_FUSE supply confirmed at 1.8V
- [ ] U-Boot fuse driver version confirmed compatible with i.MX8MP

## Procedure 1: SRK Hash Programming

### Step 1: Compute expected fuse values on signing workstation

```bash
# On air-gapped signing workstation only
# The fuse binary is produced by srktool

# Verify the fuse binary exists and has correct size (32 bytes)
ls -la SRK_1_2_3_4_fuse.bin
# Expected: 32 bytes

# Display all 8 expected fuse words
python3 << 'EOF'
import struct

with open('SRK_1_2_3_4_fuse.bin', 'rb') as f:
    data = f.read()

assert len(data) == 32, f"Expected 32 bytes, got {len(data)}"

print("=" * 60)
print("EXPECTED SRK FUSE VALUES - VERIFY BEFORE PROGRAMMING")
print("=" * 60)
print()
print("U-Boot commands:")
for i in range(8):
    word = struct.unpack('<I', data[i*4:(i+1)*4])[0]
    print(f"fuse prog -y 3 {i} 0x{word:08X}")
print()
print("Expected readback:")
for i in range(8):
    word = struct.unpack('<I', data[i*4:(i+1)*4])[0]
    print(f"Bank 3 Word 0x{i:08X}: {word:08X}")
EOF

# Record these values and have second engineer verify independently
```

### Step 2: Transfer fuse values to target securely

```bash
# Option A: Read from display on air-gapped workstation, type manually
# Option B: Print to paper, carry to programming station
# Option C: Encrypted USB with integrity-protected file

# DO NOT: email fuse values unencrypted
# DO NOT: store fuse values in plaintext on networked systems
```

### Step 3: Program SRK hash fuses from U-Boot

```
# Power on device, interrupt autoboot to reach U-Boot prompt
# Confirm OPEN mode:
=> hab_status
HAB Configuration: 0x00 HAB State: 0x00

# Verify current SRK fuses are all zero (unprogrammed)
=> fuse read 3 0
Bank 3 Word 0x00000000: 00000000
=> fuse read 3 1
Bank 3 Word 0x00000001: 00000000
[... verify all 8 words are 00000000 ...]

# Program 8 SRK hash words (replace <wordN> with actual values)
=> fuse prog -y 3 0 0x<word0>
=> fuse prog -y 3 1 0x<word1>
=> fuse prog -y 3 2 0x<word2>
=> fuse prog -y 3 3 0x<word3>
=> fuse prog -y 3 4 0x<word4>
=> fuse prog -y 3 5 0x<word5>
=> fuse prog -y 3 6 0x<word6>
=> fuse prog -y 3 7 0x<word7>
```

### Step 4: Verify all 8 SRK words after programming

```
# Read back and compare EVERY word against expected values
=> fuse read 3 0
Bank 3 Word 0x00000000: <word0>  ← must match expected

=> fuse read 3 1
Bank 3 Word 0x00000001: <word1>  ← must match expected

=> fuse read 3 2
Bank 3 Word 0x00000002: <word2>  ← must match expected

=> fuse read 3 3
Bank 3 Word 0x00000003: <word3>  ← must match expected

=> fuse read 3 4
Bank 3 Word 0x00000004: <word4>  ← must match expected

=> fuse read 3 5
Bank 3 Word 0x00000005: <word5>  ← must match expected

=> fuse read 3 6
Bank 3 Word 0x00000006: <word6>  ← must match expected

=> fuse read 3 7
Bank 3 Word 0x00000007: <word7>  ← must match expected

# ANY mismatch = STOP. Investigate before proceeding.
```

### Step 5: Test signed image with SRK hash burned (still OPEN mode)

```
# Reboot with SRK hash burned but SEC_CONFIG still OPEN
=> reset

# At new U-Boot prompt, boot signed firmware
=> run bootcmd

# In Linux, check HAB status
dmesg | grep -i hab

# At U-Boot prompt (interrupt boot):
=> hab_status
HAB Configuration: 0x00 HAB State: 0x00
No HAB Events Found!

# 0x00 = OPEN mode, should still show No HAB Events
# If ANY HAB events appear after burning SRK: DO NOT CLOSE
# Investigate signing configuration before proceeding
```

## Procedure 2: Close Device (SEC_CONFIG)

Only proceed after ALL of the following are confirmed:
- SRK fuses verified by two independent engineers
- Signed firmware boots successfully with SRK fuses burned
- `hab_status` shows zero events in OPEN mode
- Sign-off recorded in change management system

```
# Current state check before closing
=> fuse read 1 3
Bank 1 Word 0x00000003: 00000000
# Should show 0x00000000 (OPEN mode)

# Burn SEC_CONFIG bit (bit 1 of Bank 1, Word 3 = value 0x2)
=> fuse prog -y 1 3 0x2
Programming bank 1 word 0x00000003 to 0x00000002...
OK

# Verify SEC_CONFIG burned
=> fuse read 1 3
Bank 1 Word 0x00000003: 00000002

# Reboot to confirm CLOSED mode boots correctly
=> reset
```

After reboot, verify closure:
```
# At U-Boot (CLOSED mode):
=> hab_status
HAB Configuration: 0xf0 HAB State: 0xf0
No HAB Events Found!

# 0xf0 = HAB_SUCCESS
# HAB Configuration: 0xf0 = Closed
# HAB State: 0xf0 = Trusted

# Test that UNSIGNED firmware is rejected:
# Try to boot an unsigned image -- U-Boot should refuse
=> load mmc 0:1 ${loadaddr} unsigned-test-image.bin
=> bootm ${loadaddr}
# Expected: HAB authentication failure, boot halted
```

## Procedure 3: Disable JTAG

JTAG must be disabled after production closure.
JTAG_SMODE controls debug access level.

```
# JTAG_SMODE field: Bank 1, Word 3, bits [23:22]
# Values:
#   00 = no restrictions (JTAG fully enabled)
#   01 = secure JTAG (requires authentication)
#   10 = no debug (JTAG disabled)
#   11 = no debug (same as 10, use this)

# Read current Bank 1 Word 3 value
=> fuse read 1 3
Bank 1 Word 0x00000003: 00000002
# Current: 0x00000002 = SEC_CONFIG=CLOSED, JTAG still accessible

# Calculate new value:
# bits [23:22] = 0b11 = 0x3 shifted left 22 = 0xC00000
# New value = 0x00000002 | 0x00C00000 = 0x00C00002

=> fuse prog -y 1 3 0x00C00002
Programming bank 1 word 0x00000003 to 0x00C00002...
OK

# Verify
=> fuse read 1 3
Bank 1 Word 0x00000003: 00C00002
# Bits [23:22] = 11 = JTAG disabled
```

## Procedure 4: Disable Serial Download Mode (Optional)

In production, disable USB serial download mode to prevent unauthorized firmware loading:

```
# DIR_BT_DIS: Bank 1, Word 3, bit [3]
# Setting bit 3 disables direct boot / serial download mode

# Current value after JTAG disable: 0x00C00002
# Add DIR_BT_DIS: 0x00C00002 | 0x00000008 = 0x00C0000A

=> fuse prog -y 1 3 0x00C0000A

# CAUTION: After this, USB download mode (HID download) is disabled
# Recovery requires JTAG (already disabled) or serial console access
# Only do this if you are certain the device can recover via other means
```

## Procedure 5: Lock SRK Fuses

Prevent accidental re-programming of SRK hash after closure:

```
# Lock register: Bank 0, Word 0, bit [4] = SRK lock
=> fuse read 0 0
Bank 0 Word 0x00000000: 00000000

=> fuse prog -y 0 0 0x10
Programming bank 0 word 0x00000000 to 0x00000010...
OK

# Verify lock
=> fuse read 0 0
Bank 0 Word 0x00000000: 00000010
# Bit 4 set = SRK fuses locked, no further programming possible
```

## Recovery: What to Do If Programming Goes Wrong

### Scenario A: Wrong SRK hash burned, SEC_CONFIG NOT yet burned

Situation: SRK fuses contain wrong hash, but device is still in OPEN mode.

Assessment:
- Device STILL BOOTS (OPEN mode ignores SRK validation)
- The burned SRK hash cannot be changed (fuses are one-time programmable)
- Generating keys that match the burned hash is cryptographically infeasible

Options:
1. Use this device only for testing, never close SEC_CONFIG on it
2. Scraps the board if it must be a production unit
3. Generate a new SRK set and re-derive images, but the already-burned hash is permanent

Prevention: Always verify twice before programming.

### Scenario B: SEC_CONFIG burned with wrong SRK hash

Situation: Device will not boot any firmware. Permanently bricked.

Assessment:
- No recovery is possible
- NXP cannot help -- there is no RMA unlock for incorrect SRK
- Board must be destroyed and disposed of per security policy

Prevention: NEVER close SEC_CONFIG without validated signed boot in OPEN mode.

### Scenario C: Correct SRK, CLOSED mode, but firmware won't boot

Possible causes and diagnostics:

```
# Check HAB events in U-Boot
=> hab_status
# Look for error codes:
# Event data:
#   0xdb 0x00 0x08 0x43 ... ← CSF error details
#   Reason: (decode from IMX HAB API reference)

# Common HAB event codes:
# 0x40 = HAB_ENG_DCP = DCP engine
# 0x33 = HAB_FAILURE = general failure
# 0x22 = HAB_INV_SIGNATURE = signature verification failed
# 0x1D = HAB_INV_RETURN = invalid return address

# Steps to diagnose:
# 1. Compare CSF in image against signing key (run CST verify)
# 2. Check SRK index used during signing vs which SRK is in fuses
# 3. Verify IVT header in image is correct
# 4. Check image load address matches signed address
```

## Automated Fuse Programming Script

For production lines, use automated scripting via U-Boot autoscript:

```bash
#!/bin/bash
# manufacture-close.sh
# Run on programming station, communicates with device via serial

SERIAL_PORT="${1:?Serial port required (e.g. /dev/ttyUSB0)}"
SRK_FUSE_BIN="${2:?SRK fuse binary required}"
BAUD=115200

# Compute expected words
python3 << EOF > /tmp/expected_fuses.txt
import struct
data = open('${SRK_FUSE_BIN}', 'rb').read()
for i in range(8):
    w = struct.unpack('<I', data[i*4:(i+1)*4])[0]
    print(f"{w:08X}")
EOF

mapfile -t WORDS < /tmp/expected_fuses.txt

# Send commands via expect/minicom/picocom
for i in "${!WORDS[@]}"; do
    CMD="fuse prog -y 3 ${i} 0x${WORDS[$i]}"
    echo "Sending: ${CMD}"
    # Implementation: use expect or Python serial to send to U-Boot
done

echo "All fuse commands sent. Manual verification required."
```

## Post-Programming Checklist

After completing all fuse programming steps:
- [ ] SEC_CONFIG = 0x2 (CLOSED) verified via fuse read
- [ ] JTAG_SMODE = 0x3 (disabled) verified via fuse read
- [ ] SRK fuse lock bit programmed (Bank 0, Word 0, bit 4)
- [ ] Device rebooted in CLOSED mode successfully
- [ ] hab_status = "No HAB Events Found!" in CLOSED mode
- [ ] Unsigned image rejected in CLOSED mode (tested)
- [ ] Serial number + fuse programming timestamp recorded in MFG database
- [ ] Operator ID and station ID logged
- [ ] Device label applied with firmware version and programming date
