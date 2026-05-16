# HABv4 Device Lifecycle Management

```
Tested Against:
  - NXP i.MX8M Plus (i.MX8MP)
  - NXP SPSDK: 2.1.0
  - U-Boot: 2023.04 (NXP lf-6.1.55-2.2.0)
Last Validated: 2024-Q2
```

---

## Overview

HABv4 devices progress through a series of lifecycle states that are determined by burned OTP fuses. Each state transition is **one-way and irreversible**: fuses can only be burned from 0 to 1, never back. This means lifecycle progression is permanent. A mistake in lifecycle management can produce either a bricked device or a device that is permanently less secure than intended.

Understanding lifecycle states is not optional for production deployment. The state of a device at the time of delivery to a customer determines the security guarantees it provides.

---

## NXP i.MX8MP Lifecycle States

```
Lifecycle progression (one-way):

  FAB ──────────────────────► NXP ──────────────────────► OEM OPEN
  (silicon mfg)               (NXP internal)               (default OEM state)
                                                              │
                                                              │  Burn SEC_CONFIG[1]
                                                              │  (IRREVERSIBLE)
                                                              ▼
                                                           OEM CLOSED ◄──────────────┐
                                                           (production)               │
                                                              │                       │
                                                              │  Burn FIELD_RETURN     │
                                                              │  (if available)        │
                                                              ▼                       │
                                                           FIELD RETURN               │
                                                           (limited debug)            │
                                                              │                       │
                                                              │  No path back to       │
                                                              └── CLOSED directly ────┘
```

---

## Lifecycle State Descriptions

### FAB State

The device immediately after silicon fabrication. Only NXP has access to devices in this state. All security fuses are unprogrammed (logic 0). HABv4 library is present in ROM but disabled. No authentication is performed.

Not relevant for OEM operations.

### NXP State

NXP programs device-specific fuses during testing and provisioning (e.g., Chip Unique ID, NXP reserved fuses). OEMs receive devices in this state. The NXP-burned fuses are permanent.

From an OEM perspective, devices are effectively in NXP state when received. `hab_status` typically shows:
```
HAB Configuration: 0xf0 HAB State: 0xf0
No HAB Events Found!
```

### OEM OPEN State (Default Development State)

This is the initial state for OEM development. Key characteristics:
- `SEC_CONFIG[1]` fuse = 0 (not burned)
- HABv4 performs full authentication when a CSF is present
- Authentication failures are **non-fatal**: boot continues, events are logged
- Unsigned images boot without restriction
- Used for development, integration testing, and pre-production validation

The HAB configuration byte is `0xF0`:
```
HAB_CFG_OPEN = 0xF0
```

**Security property in OPEN state:** None. Any image can boot. OPEN mode is for development only.

### OEM CLOSED State (Production State)

After burning `SEC_CONFIG[1]`. Key characteristics:
- `SEC_CONFIG[1]` fuse = 1 (burned)
- HABv4 authentication is **mandatory** and **fatal on failure**
- Any authentication failure causes ROM to halt (infinite loop)
- Only images signed with the correct SRK can boot
- JTAG access is not automatically disabled (must be separately controlled)

The HAB configuration byte is `0xCC`:
```
HAB_CFG_CLOSED = 0xCC
```

**Security property in CLOSED state:** Only code signed by the holder of the SRK private key can execute on this device.

> **⚠️ CRITICAL:** Transitioning to CLOSED is irreversible. Once `SEC_CONFIG[1]` is burned, it cannot be unburned. If:
> - The `SRK_HASH` fuses contain wrong values
> - The signing keys are lost
> - The signed boot images are lost
> 
> The device is permanently bricked and cannot be recovered.

### FIELD RETURN State

An optional special state that can be reached from CLOSED by burning the `FIELD_RETURN` fuse (if available on your device/revision). This state enables limited debug access for authorized return-to-factory scenarios.

> **⚠️ WARNING:** FIELD_RETURN is not a path back to full OPEN mode. It provides limited, controlled debug access. The specific capabilities depend on the silicon revision. Consult NXP for your device's FIELD_RETURN capabilities before relying on this.

---

## Fuse Map for Lifecycle Control

On i.MX8MP, the relevant fuses are in the OCOTP peripheral (base: `0x30350000`):

### SEC_CONFIG Fuse

```
Register: OCOTP_BOOT_CFG1 (shadow register)
Fuse address: Bank 1, Word 3
Physical register: 0x30350460

Bit  Name          Description
25   SEC_CONFIG[1] OEM_CLOSED bit
                   0 = OEM OPEN (default, unfused)
                   1 = OEM CLOSED (production)
24   SEC_CONFIG[0] NXP Reserved — already set, do not touch
```

Fuse programming command:
```bash
# U-Boot fuse write command:
# fuse prog [-y] <bank> <word> <value>

# To set SEC_CONFIG[1] (bit 25 of bank 1, word 3):
# Value = 0x02000000 (bit 25 of the 32-bit word)
=> fuse prog -y 1 3 0x02000000
```

> **⚠️ CRITICAL:** The bit position of SEC_CONFIG[1] must be verified against the official i.MX8M Plus Reference Manual for your specific silicon revision. The value `0x02000000` is for bit 25 of the 32-bit word at Bank 1, Word 3. Confirm before burning.

### SRK_HASH Fuses

```
Bank 6, Words 0-7:
OCOTP offset  Register Name    SRK_HASH bits
0x30350C00    OCOTP_SRK0       SRK_HASH[31:0]
0x30350C10    OCOTP_SRK1       SRK_HASH[63:32]
0x30350C20    OCOTP_SRK2       SRK_HASH[95:64]
0x30350C30    OCOTP_SRK3       SRK_HASH[127:96]
0x30350C40    OCOTP_SRK4       SRK_HASH[159:128]
0x30350C50    OCOTP_SRK5       SRK_HASH[191:160]
0x30350C60    OCOTP_SRK6       SRK_HASH[223:192]
0x30350C70    OCOTP_SRK7       SRK_HASH[255:224]
```

Programming SRK_HASH from U-Boot (example values — use your actual hash):
```bash
=> fuse prog -y 6 0 0xA1B2C3D4
=> fuse prog -y 6 1 0xE5F60718
=> fuse prog -y 6 2 0x293A4B5C
=> fuse prog -y 6 3 0x6D7E8F90
=> fuse prog -y 6 4 0x1A2B3C4D
=> fuse prog -y 6 5 0x5E6F7081
=> fuse prog -y 6 6 0x92A3B4C5
=> fuse prog -y 6 7 0xD6E7F809
```

> **⚠️ CRITICAL:** Fuse words are burned with **byte-swapped** values in some NXP tools vs. others. The byte order written by `fuse prog` may differ from `srktool --hash` output depending on endianness conventions. Verify by:
> 1. Programming a sacrificial board
> 2. Reading back the fuses with `fuse read 6 0 8`
> 3. Verifying the signed image boots (no HAB events)
> **before** programming production boards.

### SRK_REVOKE Fuses

```
Bank 9, Word 3 (verify with your silicon revision reference manual):
Bit 0: SRK_REVOKE[0] = 1 → SRK slot 0 is revoked
Bit 1: SRK_REVOKE[1] = 1 → SRK slot 1 is revoked
Bit 2: SRK_REVOKE[2] = 1 → SRK slot 2 is revoked
Bit 3: SRK_REVOKE[3] = 1 → SRK slot 3 is revoked
```

To revoke SRK 0 (after deploying firmware signed with SRK 1):
```bash
=> fuse prog -y 9 3 0x00000001
# Bit 0 = SRK0 revoked
```

> **⚠️ WARNING:** Only revoke an SRK after:
> 1. All affected devices have received new firmware signed with a different SRK
> 2. The new firmware has been validated to boot successfully
> 3. You have confirmed rollback to the old firmware is not needed
> 
> Revoking an SRK before updating firmware makes the device unbootable.

### DIR_BT_DIS Fuse

```
DIR_BT_DIS: Disable Direct Boot
When set: Prevents booting unsigned images (even in OEM OPEN mode)
This is an additional security feature that can be enabled independently of CLOSED mode.
```

Setting DIR_BT_DIS in OPEN mode forces HABv4 authentication to be required, but the failure mode is still non-fatal (events logged). Setting both DIR_BT_DIS and SEC_CONFIG[1] (CLOSED) provides full protection.

### JTAG Security Fuses

While not part of HABv4 proper, these should be addressed before considering a device fully secured:

```
JTAG_SMODE[1:0]:
  00 = JTAG enabled (debug access unrestricted)
  01 = Secure JTAG (requires authentication challenge)
  10 = JTAG disabled (no debug access)
  11 = No JTAG override (controlled by lifecycle)

KTE (Key Transfer Enable):
  0 = Normal (HABv4 key material not accessible via JTAG)
  1 = Key Transfer Enabled (reduced security, do not set in production)
```

---

## OEM OPEN to OEM CLOSED Transition Procedure

This is the most critical operation in device lifecycle management. Follow these steps exactly.

### Step 1: Generate and Validate Keys (Offline)

```bash
# On air-gapped machine:
cd cst-3.3.1/release/
bash hab4_pki_tree.sh
# Follow prompts (see 04-cst-workflow.md)

# Generate SRK table and hash:
./linux64/bin/srktool \
    --hab_ver 4 \
    --certs crts/SRK1_sha256_4096_65537_v3_ca_crt.pem,...
    --hash crts/SRK_1_2_3_4_fuse.bin \
    --table crts/SRK_1_2_3_4_table.bin

# Record the fuse values:
hexdump -e '/4 "0x%08X\n"' crts/SRK_1_2_3_4_fuse.bin > srk_fuse_values.txt
cat srk_fuse_values.txt
# Store this file securely — you'll need these values at fuse burning time
```

### Step 2: Sign the Production Image

```bash
# Build flash.bin:
make -C imx-mkimage SOC=iMX8MP flash_evk
CSF_OFFSET=<from imx-mkimage output>

# Create and compile CSF:
./linux64/bin/cst --i csf_flash.csf --o csf_flash.bin

# Inject CSF:
dd if=csf_flash.bin of=flash.bin bs=1 seek=${CSF_OFFSET} conv=notrunc
```

### Step 3: Test in OPEN Mode (MANDATORY)

```bash
# Flash to test hardware:
dd if=flash.bin of=/dev/sdX bs=1024 seek=32 conv=notrunc

# Boot the board. In U-Boot:
=> hab_status

# REQUIRED: No HAB Events Found
# Any events = DO NOT PROCEED. Fix and repeat.
```

### Step 4: Verify SRK Hash Match

Before burning fuses, confirm the hash you're about to burn matches your signing keys:

```bash
# From the CSF signing workflow, recompute and display the hash:
sha256sum crts/SRK_1_2_3_4_table.bin
# The output should match srk_fuse_values.txt when converted from hex

# In U-Boot on the test board, read current SRK_HASH fuses (should be all zeros):
=> fuse read 6 0 8
# Expected: all 00000000 (unfused)
```

### Step 5: Burn SRK_HASH Fuses (IRREVERSIBLE)

```bash
# Using values from srk_fuse_values.txt:
# BANK 6, WORD 0-7
=> fuse prog -y 6 0 <word0_from_fuse_file>
=> fuse prog -y 6 1 <word1_from_fuse_file>
=> fuse prog -y 6 2 <word2_from_fuse_file>
=> fuse prog -y 6 3 <word3_from_fuse_file>
=> fuse prog -y 6 4 <word4_from_fuse_file>
=> fuse prog -y 6 5 <word5_from_fuse_file>
=> fuse prog -y 6 6 <word6_from_fuse_file>
=> fuse prog -y 6 7 <word7_from_fuse_file>
```

### Step 6: Verify SRK Hash Burned Correctly

```bash
# Read back and compare:
=> fuse read 6 0 8
# Values must exactly match srk_fuse_values.txt

# Power cycle and run hab_status again:
=> hab_status
# Must still show: No HAB Events Found!
# If events appear after SRK_HASH is burned but before CLOSING,
# STOP IMMEDIATELY — the fuse values are wrong or the signing was incorrect.
# DO NOT BURN SEC_CONFIG. The device is still recoverable at this point.
```

### Step 7: Burn SEC_CONFIG[1] to CLOSE the Device (IRREVERSIBLE)

Only proceed when all of the following are confirmed:
- [ ] `hab_status` shows no events with the signed image
- [ ] SRK_HASH fuses read back correctly
- [ ] You have verified the above on at least 3 boards
- [ ] You have a backup copy of the signing keys stored securely offline
- [ ] You have a backup copy of the signed flash.bin stored securely

```bash
# POINT OF NO RETURN:
=> fuse prog -y 1 3 0x02000000

# Power cycle:
=> reset
```

### Step 8: Verify CLOSED Mode

```bash
# In U-Boot after power cycle:
=> hab_status

# Expected output for successful CLOSED device:
# HAB Configuration: 0xcc HAB State: 0xf0
# No HAB Events Found!

# If you see 0xf0 instead of 0xcc, the SEC_CONFIG fuse did not burn.
# Check the fuse word address and bit mask.

# Test: verify unsigned image is rejected
# (flash an unsigned image to SD card, try to boot)
# Expected: Board halts silently at ROM level (no U-Boot output)
# This confirms the CLOSED mode is functioning correctly
```

---

## FIELD_RETURN Fuse

For devices where NXP supports FIELD_RETURN, this fuse enables a limited diagnostic mode. The specific register and usage varies by device and must be confirmed with NXP.

Usage scenario: Customer returns a non-booting device to manufacturer. Manufacturer burns FIELD_RETURN to get limited diagnostic access, diagnoses the issue, and returns or replaces the device. This cannot restore OPEN mode or disable HABv4.

---

## Verification Checklist Before Closing

Use this checklist as a gate before burning SEC_CONFIG. Check each item and record results:

```
PRE-CLOSE VALIDATION CHECKLIST
Date: _______________
Board serial: _______________
Flash.bin SHA256: _______________
SRK_1_2_3_4_fuse.bin SHA256: _______________

[ ] 1. hab_status shows HAB_CFG_OPEN (0xf0) before SRK hash
[ ] 2. hab_status shows NO EVENTS with signed flash.bin
[ ] 3. hab_status shows HAB_FAILURE events with corrupted image (tamper test)
[ ] 4. SRK_HASH fuses burned: Bank 6, Words 0-7 match fuse.bin
[ ] 5. hab_status shows NO EVENTS after SRK_HASH fused (with signed image)
[ ] 6. hab_status shows HAB_FAILURE events with mismatched SRK signed image
[ ] 7. Signing keys backed up to secure offline storage (HSM or encrypted media)
[ ] 8. Signed flash.bin backed up to secure storage
[ ] 9. srk_fuse_values.txt backed up to secure storage
[ ] 10. At least 3 boards validated through steps 1-9

APPROVAL FOR CLOSING:
Signed by: _______________
Date: _______________
```

---

## What If Something Goes Wrong

### After SRK_HASH burned, before SEC_CONFIG burned

The device is still in OEM OPEN mode. Authentication may fail if the hash is wrong (you'll see HAB events), but the device still boots. Options:
- If wrong hash: SRK_HASH fuses cannot be changed (all 0s are set, but individual bits cannot be cleared). The device is now partially bricked — it cannot authenticate with the correct keys.
- Recovery: This device cannot be used for production. Use it only for further testing with knowledge that HABv4 is permanently non-functional.

### After SEC_CONFIG burned, device does not boot

The device will not produce any console output after the ROM runs. The ROM halts silently.
- There is no software recovery path.
- Hardware recovery (JTAG) may be possible if JTAG fuses were not burned, but the ROM halt happens before JTAG can be attached in most cases.
- Contact NXP for hardware-level debug options.

**Prevention is the only recovery strategy.** This is why the validation checklist exists.
