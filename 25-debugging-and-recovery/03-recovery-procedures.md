# Recovery Procedures

## Recovery Decision Tree

```
Device is not booting
        │
        ▼
Is device in OPEN or CLOSED mode?
        │
   ┌────┴────┐
 OPEN      CLOSED
   │          │
   │          ▼
   │    Does it produce any UART output?
   │          │
   │     ┌────┴────┐
   │   Yes          No
   │     │          │
   │     │          ▼
   │     │    → Check power, BOOT_MODE pins
   │     │    → Try USB SDP (UUU)
   │     ▼
   │    HAB events present?
   │          │
   │     ┌────┴────┐
   │   Yes          No
   │     │          │
   │     │          ▼
   │     │    → Other problem (not HAB)
   │     │    → Check FIT signing, dm-verity
   │     ▼
   │   Fix CSF/signing issue
   │   Re-flash via USB SDP
   │
OPEN mode: USB SDP / UUU is your recovery path
CLOSED mode: Limited options — see below
```

---

## Recovery: Device in OPEN Mode

### USB Serial Download Protocol (SDP) Recovery

When the device fails to boot (any stage), i.MX8MP ROM enters SDP mode automatically if BOOT_MODE = 01 (USB).

```bash
# Set BOOT_MODE pins to USB:
# BOOT_MODE[1:0] = 01 (fused boot source OR manual override via pins)

# Connect USB OTG cable (not debug UART — OTG port)

# Verify SDP mode:
lsusb | grep "NXP"
# Bus 001 Device 003: ID 1fc9:0146 NXP Semiconductors SDP: i.MX8MP

# Flash corrected image via UUU:
uuu -b emmc_all imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk-signed \
    phytec-securiphy-image-phyboard-pollux-imx8mp-3.wic.gz

# Or step by step:
uuu -b spl imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk
# (Boots SPL from RAM via SDP, then you have U-Boot to write eMMC)
```

### JTAG Recovery (OPEN Mode)

```bash
# Connect J-Link or SEGGER to JTAG header on phyBOARD

# OpenOCD commands to write eMMC from JTAG:
openocd \
    -f interface/jlink.cfg \
    -f target/imx8mp.cfg \
    -c "init" \
    -c "halt" \
    -c "flash banks {mmcblk} imxrt 0x0 0 0 0 imx8mp.cpu" \
    -c "program imx-boot.bin 0x0" \
    -c "resume" \
    -c "exit"

# Or use JTAG to load SPL into RAM and execute:
openocd -f interface/jlink.cfg -f target/imx8mp.cfg << 'EOF'
init
halt
load_image spl/u-boot-spl.bin 0x7E1000
resume 0x7E1000
EOF
```

---

## Recovery: Device in CLOSED Mode

**A CLOSED device that won't boot is extremely difficult to recover.** Your options:

### Option 1: SDP with Matching Key

If the device was closed with SRK1 hash, and you have SRK1 private key:

```
CLOSED mode behavior:
  - ROM still enters SDP if BOOT_MODE pins = USB
  - ROM AUTHENTICATES the image loaded via SDP
  - You MUST provide a correctly signed image

So: Load a valid, properly-signed imx-boot via SDP,
    then fix whatever caused the boot failure.
```

```bash
# Sign a known-good imx-boot with your correct keys:
# (This is why you always keep a "recovery" signed image)

# Flash via SDP:
uuu -v imx-boot-recovery-signed.bin
```

### Option 2: SRK Revocation (If Other SRK Slots Available)

If SRK1's key is lost but SRK2-4 are available:

```
HABv4 SRK revocation:
  1. The CSF "Install SRK" command specifies which SRK index (0-3) to use
  2. You can program OCOTP_SRK_REVOKE fuse to revoke specific SRK indices
  3. Then sign with a different SRK index

OCOTP SRK revocation fuse:
  Bank 3, Word 7 (also used for SRK hash — check datasheet for your SoC)
  Bit 0: Revoke SRK0
  Bit 1: Revoke SRK1
  Bit 2: Revoke SRK2
  Bit 3: Revoke SRK3
```

```bash
# U-Boot: Revoke SRK index 0 (your compromised key):
U-Boot> fuse prog -y 3 7 0x1  # Sets bit 0 = revoke SRK0

# Now sign new firmware using SRK index 1:
# In CSF:
# [Install SRK]
#     File = "SRK_1_2_3_4_table.bin"
#     Source index = 1   ← Use SRK2 instead of SRK1
```

### Option 3: NXP Field Service (Last Resort)

For hardware-level JTAG debugging of CLOSED devices:
- Contact NXP FAE (Field Application Engineer)
- Requires NDAs and is not guaranteed
- Only applicable for extremely high-value recovery scenarios

### Option 4: Accept as Destroyed

If no SRK backup slots remain and the signing key is lost:
- The device is permanently bricked
- Mark for secure disposal
- Document in post-mortem for process improvement

---

## Pre-Recovery Checklist

Before attempting any recovery:

```
[ ] Identify device state: OPEN or CLOSED?
    U-Boot> fuse read 1 3  (bit 1 set = CLOSED)

[ ] What was the last known working firmware version?

[ ] Do you have the signing keys for the burned SRK hash?

[ ] Is there a valid signed recovery image available?

[ ] Is BOOT_MODE accessible (pins or switches)?

[ ] Do you have USB OTG access?

[ ] Is JTAG accessible (debug header exposed)?

[ ] What caused the failure?
    (Corruption? Wrong image? Config change? Fuse accident?)
```

---

## Preventing Future Recovery Scenarios

```
1. Always test in OPEN mode before closing
2. Keep signed recovery images for each firmware version
3. Keep at minimum 1 unused SRK slot (3 of 4 active)
4. Keep secure backup of all private keys (air-gapped HSM)
5. Never modify a signed imx-boot.bin after signing
6. Implement A/B update — if B slot fails, fall back to A
7. Set bootcount limit in U-Boot (revert if fails N times)
8. Test UUU recovery procedure as part of factory validation
9. Document recovery procedure and test it annually
```

---

## Emergency Recovery Scripts

```bash
#!/bin/bash
# emergency-recovery.sh
# Run on recovery workstation when device is in SDP mode

DEVICE_USB="1fc9:0146"  # NXP SDP

echo "Checking for device in SDP mode..."
if ! lsusb | grep -q "$DEVICE_USB"; then
    echo "ERROR: Device not found in SDP mode"
    echo "Steps:"
    echo "  1. Set BOOT_MODE pins to USB (01)"
    echo "  2. Power cycle device"
    echo "  3. Connect USB OTG cable"
    exit 1
fi

echo "Device found. Starting recovery..."

# Use uuu to flash recovery image:
uuu -b emmc_all \
    ./recovery/imx-boot-recovery-signed.bin \
    ./recovery/phytec-recovery-image.wic.gz

echo "Recovery flash complete. Power cycle device and check boot."
```

---

## Cross-References

- [01-hab-debugging.md](01-hab-debugging.md) — Diagnose before recovering
- [04-common-failure-modes.md](04-common-failure-modes.md) — Identify failure type
- [../12-habv4-imx8m/05-hab-lifecycle.md](../12-habv4-imx8m/05-hab-lifecycle.md) — Lifecycle states and SRK revocation
- [../19-manufacturing-security/02-secure-manufacturing-tools.md](../19-manufacturing-security/02-secure-manufacturing-tools.md) — UUU usage
