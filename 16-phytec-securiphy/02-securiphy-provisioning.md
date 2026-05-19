# securiPHY Factory Provisioning

## Overview

Factory provisioning transforms a blank phyCORE-i.MX8MP module into a production-secured device. This is a two-phase process: first, run the provisioning image to program fuses and verify the device; second, write the production securiPHY image.

**This process is irreversible after fuse closure. Test thoroughly before deploying at scale.**

---

## Provisioning Station Requirements

```
Hardware:
  - USB-to-UART adapter (115200 8N1)
  - USB-A to USB-micro cable (for UUU)
  - phyBOARD-Pollux carrier board with phyCORE-i.MX8MP SOM
  - Provisioning workstation (Linux, networked to factory MES)

Software:
  - uuu (Universal Update Utility) v1.4+
  - PHYTEC provisioning image (phytec-provisioning-image-*.wic)
  - PHYTEC securiPHY image (phytec-securiphy-image-*.wic)
  - SRK fuse values file (SRK_1_2_3_4_fuse.bin)

Network:
  - Factory MES (Manufacturing Execution System) integration API
  - Provisioning log server (for audit trail)
```

---

## Phase 1: Boot Provisioning Image via UUU

```bash
# Put phyBOARD into USB recovery mode:
# 1. Set BOOT_MODE pins: 01 (USB Serial Download)
# 2. Power on while holding RECOVERY button (if present)
# 3. Connect USB cable to USB OTG port

# Verify device is in SDP mode
lsusb | grep "NXP"
# Bus 001 Device 003: ID 1fc9:0146 NXP Semiconductors SDP: i.MX8MP

# Flash provisioning image via UUU
uuu -b emmc phytec-provisioning-image-phyboard-pollux-imx8mp-3.wic.gz
```

### UUU Script (Auto Mode)

```bash
# phytec-provision.uuu
# Usage: uuu -v phytec-provision.uuu

uuu_version 1.4.182

# Boot from RAM using SDP
SDP: boot -f imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk

# Flash provisioning rootfs to eMMC boot0
SDPU: write -f phytec-provisioning-image-phyboard-pollux-imx8mp-3.wic -pane

# Reboot into provisioning image
SDPU: done
```

---

## Phase 2: Provisioning Script Execution

After the provisioning image boots, the `provisioning-init.sh` service runs automatically:

```bash
#!/bin/bash
# /usr/share/phytec/provisioning-init.sh
# Runs as systemd service on provisioning image first boot

set -euo pipefail

LOG="/var/log/provisioning.log"
SRK_FUSE_BIN="/usr/share/phytec/SRK_1_2_3_4_fuse.bin"
PRODUCTION_IMAGE="/run/media/mmcblk1p1/phytec-securiphy-image.wic.gz"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }

# ─────────────────────────────────────────────
# Step 1: Read device serial number
# ─────────────────────────────────────────────
read_device_serial() {
    # Read from OCOTP (unique ID fuses)
    SERIAL_HIGH=$(cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem | \
        dd bs=1 skip=$((0x410)) count=4 2>/dev/null | od -An -tx4 | tr -d ' ')
    SERIAL_LOW=$(cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem | \
        dd bs=1 skip=$((0x420)) count=4 2>/dev/null | od -An -tx4 | tr -d ' ')
    DEVICE_SERIAL="${SERIAL_HIGH}${SERIAL_LOW}"
    log "Device serial: $DEVICE_SERIAL"
}

# ─────────────────────────────────────────────
# Step 2: Check HAB status (fuses not yet burned)
# ─────────────────────────────────────────────
check_hab_status() {
    # Read SEC_CONFIG fuse (Bank 1, Word 3, bit 1)
    # If already closed, abort — device was already provisioned
    SEC_CONFIG=$(cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem | \
        dd bs=1 skip=$((0x410 + 0x60 + 12)) count=4 2>/dev/null | \
        od -An -tu4 | tr -d ' ')

    if [ "$((SEC_CONFIG & 2))" -ne 0 ]; then
        log "ERROR: Device SEC_CONFIG already set. Already provisioned?"
        exit 1
    fi

    log "HAB status: OPEN (ready for provisioning)"
}

# ─────────────────────────────────────────────
# Step 3: Verify SRK fuse values (not yet burned)
# ─────────────────────────────────────────────
check_srk_fuses_clear() {
    OFFSET=96  # Bank 3, Word 0 in OCOTP nvmem
    FUSE_DATA=$(dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem \
        bs=1 skip=$OFFSET count=32 2>/dev/null | od -An -tx1 | tr -d ' \n')

    if [ "$FUSE_DATA" != "$(printf '0%.0s' {1..64})" ]; then
        log "ERROR: SRK fuses already programmed: $FUSE_DATA"
        log "Manual inspection required"
        exit 1
    fi
    log "SRK fuses: clear (ready to program)"
}

# ─────────────────────────────────────────────
# Step 4: Report to MES — get authorization
# ─────────────────────────────────────────────
request_provisioning_authorization() {
    MES_URL="${MES_SERVER:-http://factory-mes.local}"
    RESPONSE=$(curl -sf -X POST "$MES_URL/api/v1/authorize-provisioning" \
        -H "Content-Type: application/json" \
        -d "{\"serial\": \"$DEVICE_SERIAL\", \"batch\": \"$BATCH_ID\"}")

    if [ "$(echo "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["authorized"])')" != "True" ]; then
        log "ERROR: MES authorization denied for $DEVICE_SERIAL"
        exit 1
    fi

    AUTH_TOKEN=$(echo "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
    log "MES authorization granted. Token: ${AUTH_TOKEN:0:8}..."
}

# ─────────────────────────────────────────────
# Step 5: Program SRK fuses via U-Boot API
# ─────────────────────────────────────────────
program_srk_fuses() {
    log "Programming SRK fuse hash..."

    python3 << 'PYEOF'
import struct, subprocess, sys

data = open('/usr/share/phytec/SRK_1_2_3_4_fuse.bin', 'rb').read()
assert len(data) == 32, f"SRK fuse file bad size: {len(data)}"

# Write via nvmem (requires kernel nvmem write support or use fuse tool)
with open('/sys/bus/nvmem/devices/imx-ocotp0/nvmem', 'r+b') as f:
    offset = 3 * 8 * 4  # Bank 3, Word 0
    f.seek(offset)
    f.write(data)

print("SRK fuses programmed successfully")
PYEOF

    log "SRK fuse programming complete"
}

# ─────────────────────────────────────────────
# Step 6: Verify fuses were programmed correctly
# ─────────────────────────────────────────────
verify_srk_fuses() {
    OFFSET=96
    ACTUAL=$(dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem \
        bs=1 skip=$OFFSET count=32 2>/dev/null | sha256sum | cut -d' ' -f1)
    EXPECTED=$(sha256sum "$SRK_FUSE_BIN" | cut -d' ' -f1)

    if [ "$ACTUAL" != "$EXPECTED" ]; then
        log "ERROR: SRK fuse verification FAILED"
        log "  Expected: $EXPECTED"
        log "  Actual:   $ACTUAL"
        exit 1
    fi

    log "SRK fuse verification: PASS"
}

# ─────────────────────────────────────────────
# Step 7: Write production image
# ─────────────────────────────────────────────
write_production_image() {
    log "Writing production image to eMMC..."

    # Decompress and write to eMMC
    zcat "$PRODUCTION_IMAGE" | dd of=/dev/mmcblk2 bs=4M status=progress

    sync
    log "Production image written"
}

# ─────────────────────────────────────────────
# Step 8: Close device (program SEC_CONFIG)
# ─────────────────────────────────────────────
close_device() {
    log "CLOSING DEVICE — THIS IS IRREVERSIBLE"

    # Use U-Boot's fuse driver via devmem or nvmem
    # SEC_CONFIG = Bank 1, Word 3, bit 1 = value 0x2
    python3 << 'PYEOF'
import struct

with open('/sys/bus/nvmem/devices/imx-ocotp0/nvmem', 'r+b') as f:
    # Bank 1, Word 3 = offset (1*8 + 3)*4 = 44
    f.seek(44)
    current = struct.unpack('<I', f.read(4))[0]
    f.seek(44)
    f.write(struct.pack('<I', current | 0x2))

print("SEC_CONFIG fuse set — device CLOSED")
PYEOF

    log "Device closed successfully"
}

# ─────────────────────────────────────────────
# Step 9: Report completion to MES
# ─────────────────────────────────────────────
report_completion() {
    MES_URL="${MES_SERVER:-http://factory-mes.local}"
    curl -sf -X POST "$MES_URL/api/v1/provisioning-complete" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"serial\": \"$DEVICE_SERIAL\",
            \"status\": \"success\",
            \"timestamp\": \"$(date -Iseconds)\",
            \"srk_sha\": \"$(sha256sum $SRK_FUSE_BIN | cut -d' ' -f1)\"
        }"

    log "MES provisioning-complete reported for $DEVICE_SERIAL"
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
main() {
    log "=== PHYTEC securiPHY Provisioning Starting ==="

    read_device_serial
    check_hab_status
    check_srk_fuses_clear
    request_provisioning_authorization
    program_srk_fuses
    verify_srk_fuses
    write_production_image
    close_device
    report_completion

    log "=== Provisioning COMPLETE. Rebooting in 5s ==="
    sleep 5
    reboot
}

main "$@"
```

---

## Phase 3: First Boot Verification

After reboot into production image:

```
U-Boot output (expected):
  HAB Configuration: 0x02 HAB State: 0x66
  No HAB Events Found!

  Starting kernel ...

Linux boot:
  [    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd034]
  ...

Verify dm-verity active:
  $ dmsetup status
  vroot: 0 <sectors> verity <version> <dev> <hash_dev> <data_block_size> <hash_block_size> <num_data_blocks> <hash_start_block> sha256 <root_hash> <salt>

  $ grep verity /proc/mounts
  /dev/mapper/vroot / ext4 ro,relatime 0 0
```

---

## Post-Provisioning Quality Gate

```bash
#!/bin/bash
# quality-gate.sh — Run after provisioning, before device ships

DEVICE="$1"  # e.g., /dev/ttyUSB0

check() {
    local desc="$1"
    local cmd="$2"
    local expected="$3"

    result=$(ssh root@"$DEVICE_IP" "$cmd" 2>&1)
    if echo "$result" | grep -q "$expected"; then
        echo "  PASS: $desc"
    else
        echo "  FAIL: $desc"
        echo "        Expected: $expected"
        echo "        Got: $result"
        FAILURES=$((${FAILURES:-0} + 1))
    fi
}

FAILURES=0

echo "=== securiPHY Quality Gate ==="
check "HAB CLOSED mode"    "hab_status"              "HAB Configuration: 0x02"
check "No HAB events"      "hab_status"              "No HAB Events Found"
check "FIT verified"       "booti --dry-run"          "Verified OK"
check "dm-verity active"   "dmsetup status vroot"    "verity"
check "Rootfs read-only"   "touch /test_rw 2>&1"     "Read-only file system"
check "OP-TEE running"     "tee-supplicant --version" "."

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "QUALITY GATE FAILED: $FAILURES check(s) failed"
    exit 1
else
    echo "QUALITY GATE PASSED: Device ready to ship"
fi
```

---

## Cross-References

- [01-securiphy-build.md](01-securiphy-build.md) — Building securiPHY images
- [../11-key-management/02-srk-fuse-programming.md](../11-key-management/02-srk-fuse-programming.md) — SRK fuse programming details
- [../18-fuse-programming/02-fuse-programming-procedures.md](../18-fuse-programming/02-fuse-programming-procedures.md) — Fuse programming reference
- [../19-manufacturing-security/01-manufacturing-pipeline.md](../19-manufacturing-security/01-manufacturing-pipeline.md) — Factory pipeline architecture
- [../28-production-checklists/01-pre-provisioning-checklist.md](../28-production-checklists/01-pre-provisioning-checklist.md) — Pre-provisioning checklist
