# Secure Manufacturing Tools

## NXP uuu (Universal Update Utility)

### Overview
uuu (Universal Update Utility) is the NXP tool for programming i.MX
devices over USB when in USB Download Mode (ROM serial download mode).

Version: 1.5.21+ recommended for i.MX8MP support
License: BSD-3-Clause

### Installation

```bash
# From NXP GitHub releases (preferred, pinned to specific version)
UUU_VERSION="1.5.21"
UUU_URL="https://github.com/nxp-imx/mfgtools/releases/download/uuu_${UUU_VERSION}/uuu"

wget "${UUU_URL}" -O /usr/local/bin/uuu
chmod +x /usr/local/bin/uuu

# Verify binary (compare against published SHA-256 on NXP releases page)
sha256sum /usr/local/bin/uuu

# Install udev rules (allow non-root access to NXP USB devices)
cat > /etc/udev/rules.d/70-nxp-imx.rules << 'EOF'
# NXP i.MX serial download mode
SUBSYSTEM=="usb", ATTRS{idVendor}=="1fc9", ATTRS{idProduct}=="0146", \
    GROUP="plugdev", MODE="0664"
# i.MX8MP ROM serial downloader
SUBSYSTEM=="usb", ATTRS{idVendor}=="1fc9", ATTRS{idProduct}=="012b", \
    GROUP="plugdev", MODE="0664"
EOF
udevadm control --reload-rules
```

### USB Download Mode on i.MX8MP

To enter serial download mode:
- BOOT_MODE[1:0] pins = 01 (USB OTG port)
- Or: press and hold download button, apply power

```bash
# Detect device in download mode
lsusb | grep -i "1fc9"
# 0403:6001 NXP Semiconductors SE Blank i.MX8MP

# Quick device detection loop
while ! lsusb | grep -q "1fc9:0146"; do
    echo "Waiting for device in download mode..."
    sleep 1
done
echo "Device detected"
```

### Basic uuu Commands

```bash
# Flash eMMC boot partition only (bootloader)
uuu -b emmc imx-boot-signed.bin

# Flash eMMC boot + user data (full system image)
uuu -b emmc_all imx-boot-signed.bin phytec-securiphy-image.wic

# Flash SD card (alternative boot media for testing)
uuu -b sd imx-boot-signed.bin phytec-securiphy-image.wic

# Run custom script
uuu manufacturing.auto

# Verbose mode (debug flashing issues)
uuu -v -b emmc imx-boot-signed.bin

# List all detected NXP devices
uuu -lsusb
```

### uuu Script Format (.auto)

uuu scripts define multi-step programming sequences:

```
# manufacturing.auto
# Complete provisioning sequence for phyBOARD-Pollux i.MX8MP

uuu_version 1.5

# Phase 1: Boot SPL from USB (gets device into SDPV state)
SDP: boot -f imx-boot-signed.bin

# Phase 2: Flash bootloader to eMMC boot0 partition
SDPV: delay 2000
SDPV: write -f imx-boot-signed.bin -offset 0x57c00 -skip 0x57c00

# Phase 3: Boot full bootloader from SDPV
# (device now runs U-Boot, can use FB/fastboot protocol)
FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv mmcdev 2
FB: ucmd mmc dev 2

# Phase 4: Flash eMMC partitions
FB: download -f phytec-securiphy-image.wic
FB: flash -raw2sparse all

# Phase 5: Set boot environment
FB: ucmd setenv bootdelay 3
FB: ucmd saveenv

# Done
FB: done
```

### Advanced: Per-Device Parametric Scripting

```bash
#!/bin/bash
# generate-uuu-script.sh
# Create per-device uuu script with embedded serial number

SERIAL="${1:?Serial required}"
FIRMWARE_VERSION="2.0.1"

cat > "flash-${SERIAL}.auto" << EOF
uuu_version 1.5

SDP: boot -f imx-boot-signed-v${FIRMWARE_VERSION}.bin

SDPV: delay 2000
SDPV: write -f imx-boot-signed-v${FIRMWARE_VERSION}.bin -offset 0x57c00 -skip 0x57c00

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv mmcdev 2
FB: ucmd mmc dev 2
FB: download -f phytec-securiphy-image-v${FIRMWARE_VERSION}.wic
FB: flash -raw2sparse all

# Set device-specific serial number in U-Boot env
FB: ucmd setenv serial_number ${SERIAL}
FB: ucmd saveenv

FB: done
EOF

echo "Generated: flash-${SERIAL}.auto"
uuu "flash-${SERIAL}.auto"
```

## imx-mkimage

### Overview
imx-mkimage creates the combined boot image for i.MX8 series SoCs.
It assembles: SPL, U-Boot, TF-A, OP-TEE, LPDDR firmware into one binary.

```bash
git clone https://github.com/nxp-imx/imx-mkimage.git
cd imx-mkimage
```

### Component Assembly for i.MX8MP

```bash
# Set Yocto deploy directory
DEPLOY="${BUILDDIR}/tmp/deploy/images/phyboard-pollux-imx8mp-3"

# Copy all required components
cp ${DEPLOY}/u-boot-spl.bin                    iMX8MP/
cp ${DEPLOY}/u-boot-nodtb.bin                  iMX8MP/
cp ${DEPLOY}/u-boot.dtb                        iMX8MP/
cp ${DEPLOY}/bl31.bin                          iMX8MP/   # TF-A BL31
cp ${DEPLOY}/tee.bin                           iMX8MP/   # OP-TEE
cp ${DEPLOY}/lpddr4_pmu_train_1d_imem.bin     iMX8MP/   # DDR firmware
cp ${DEPLOY}/lpddr4_pmu_train_1d_dmem.bin     iMX8MP/
cp ${DEPLOY}/lpddr4_pmu_train_2d_imem.bin     iMX8MP/
cp ${DEPLOY}/lpddr4_pmu_train_2d_dmem.bin     iMX8MP/

# Build for SD card boot
make SOC=iMX8MP flash_evk
# Output: iMX8MP/flash.bin (for SD boot)

# Build for eMMC boot
make SOC=iMX8MP flash_evk_emmc
# Output: iMX8MP/flash.bin (for eMMC boot)

# After HAB signing:
make SOC=iMX8MP flash_evk_emmc
# Must re-run after CST signing modifies components
```

### AHAB Image Assembly (i.MX9 series)

```bash
# For i.MX93 (uses AHAB instead of HABv4):
make SOC=iMX9 flash_singleboot
# Output includes AHAB container header
```

## veritysetup (dm-verity)

### Installation

```bash
# Usually included with cryptsetup
sudo apt-get install cryptsetup-bin

veritysetup --version
# cryptsetup 2.4.3
```

### Creating a Verified Root Filesystem

```bash
#!/bin/bash
# create-verity-rootfs.sh
# Apply dm-verity to a root filesystem image

ROOTFS_IMG="${1:?Rootfs image required}"
HASH_IMG="${ROOTFS_IMG%.ext4}.hash"
VERITY_PARAMS_FILE="${ROOTFS_IMG%.ext4}.verity-params"

# Ensure rootfs is not mounted and is final (no more changes)
echo "Creating verity hash tree..."
veritysetup format \
    --data-block-size=4096 \
    --hash-block-size=4096 \
    --hash=sha256 \
    "${ROOTFS_IMG}" \
    "${HASH_IMG}" \
    | tee "$VERITY_PARAMS_FILE"

# Parse output
ROOT_HASH=$(grep "Root hash:" "$VERITY_PARAMS_FILE" | awk '{print $3}')
SALT=$(grep "Salt:" "$VERITY_PARAMS_FILE" | awk '{print $2}')
DATA_BLOCKS=$(grep "Data blocks:" "$VERITY_PARAMS_FILE" | awk '{print $3}')

echo ""
echo "Verity configuration:"
echo "  Root hash:   $ROOT_HASH"
echo "  Salt:        $SALT"
echo "  Data blocks: $DATA_BLOCKS"
echo ""
echo "U-Boot bootargs fragment:"
echo "  dm-mod.create=\"vroot,,0,ro,0 ${DATA_BLOCKS} verity 1 \\"
echo "    /dev/mmcblk2p2 /dev/mmcblk2p4 4096 4096 ${DATA_BLOCKS} 1 \\"
echo "    sha256 ${ROOT_HASH} ${SALT}\""
```

### Testing dm-verity

```bash
# Test: open and mount verity device
ROOT_HASH="<hash from veritysetup format output>"
sudo veritysetup open \
    /dev/mmcblk2p2 vroot \
    /dev/mmcblk2p4 \
    "$ROOT_HASH"

sudo mount /dev/mapper/vroot /mnt/verity-test -o ro

# Verify contents accessible
ls /mnt/verity-test/usr/bin/ | head -5

# Verify status (V = verified, no corruption)
sudo dmsetup status vroot
# 0 131072 verity V (0/0)

# Cleanup
sudo umount /mnt/verity-test
sudo veritysetup close vroot
```

### Corruption Test

```bash
# Simulate data corruption and verify detection:
sudo veritysetup open \
    /dev/mmcblk2p2 vroot \
    /dev/mmcblk2p4 \
    "$ROOT_HASH"

# Deliberately corrupt one block
sudo dd if=/dev/urandom of=/dev/mmcblk2p2 bs=4096 count=1 seek=100 conv=notrunc

# Attempt to read the corrupted block
sudo dd if=/dev/mapper/vroot bs=4096 count=1 skip=100 of=/dev/null
# Expected: dd: error reading '/dev/mapper/vroot': Input/output error

# Check kernel log
sudo dmesg | tail -5
# [  xx.xxxxxx] device-mapper: verity: 8:18: data block 100 is corrupted
```

## CST (Code Signing Tool)

### Overview
NXP Code Signing Tool (CST) generates HABv4 Command Sequence Files (CSFs)
and signs boot images for i.MX8M series devices.

### Installation

```bash
# Download from NXP website (requires NXP account)
# https://www.nxp.com/webapp/sps/download/license.jsp?colCode=IMX_CST_TOOL

tar xzf cst_3.4.0.tgz
cd cst_3.4.0
ls release/linux64/bin/
# cst  srktool  x509Certificate

# Add to PATH
export PATH="$PATH:$(pwd)/release/linux64/bin"
cst --version
```

### Key Generation with srktool

```bash
#!/bin/bash
# generate-srk-keys.sh
# Generate SRK key hierarchy for HABv4

KEY_DIR="${HOME}/hab-keys"
mkdir -p "$KEY_DIR"
cd "$KEY_DIR"

# Generate 4 SRK key pairs (RSA 2048, SHA-256)
for i in 1 2 3 4; do
    echo "Generating SRK${i}..."
    openssl genrsa -out "SRK${i}_sha256_2048_65537_v3_usr_key.pem" 2048

    # Generate self-signed certificate
    openssl req -new -x509 \
        -key "SRK${i}_sha256_2048_65537_v3_usr_key.pem" \
        -out "SRK${i}_sha256_2048_65537_v3_usr_crt.pem" \
        -days 7300 \
        -subj "/CN=SRK${i}/O=MyCompany/C=US"
done

# Generate SRK table and fuse binary
srktool --hab_ver 4 \
    --certs SRK1_sha256_2048_65537_v3_usr_crt.pem \
            SRK2_sha256_2048_65537_v3_usr_crt.pem \
            SRK3_sha256_2048_65537_v3_usr_crt.pem \
            SRK4_sha256_2048_65537_v3_usr_crt.pem \
    --table SRK_1_2_3_4_table.bin \
    --efuse_entries SRK_1_2_3_4_fuse.bin \
    --format bin

echo "Keys generated in: $KEY_DIR"
echo "SRK fuse binary: $KEY_DIR/SRK_1_2_3_4_fuse.bin"
echo "Backup these files to offline secure storage immediately!"
```

### Signing a Boot Image

```bash
#!/bin/bash
# sign-bootloader.sh
# Sign imx-boot binary with HABv4 CST

INPUT_IMAGE="flash.bin"
OUTPUT_IMAGE="flash-signed.bin"
CSF_TEMPLATE="hab4-csf-template.csf"
CSF_SIGNED="hab4.csf"

KEY_DIR="${HOME}/hab-keys"

# Get IVT offset for i.MX8MP SPL
IVT_OFFSET=0x57c00

# Parse image entry point from IVT header
python3 << EOF
import struct
with open('${INPUT_IMAGE}', 'rb') as f:
    f.seek(${IVT_OFFSET})
    ivt = f.read(32)
header, entry, _, dcd, boot_data, self_ptr = struct.unpack('<6I', ivt[:24])
print(f"IVT header: 0x{header:08X}")
print(f"Entry point: 0x{entry:08X}")
print(f"Self (load addr): 0x{self_ptr:08X}")
EOF

# Create CSF file
cst --o "${CSF_SIGNED}" --i "${CSF_TEMPLATE}"

# The signed CSF is then embedded back into the image
# (exact procedure depends on CST version and image format)
```

## tpm2-tools

### Installation

```bash
sudo apt-get install tpm2-tools tpm2-abrmd

# Verify TPM is accessible
tpm2_getcap properties-fixed | grep -A2 "TPM2_PT_FIRMWARE"
# TPM2_PT_FIRMWARE_VERSION_1:
#   raw: 0x20191023
```

### Basic TPM Operations

```bash
# Read all PCR values (SHA-256 bank)
tpm2_pcrread sha256

# Read specific PCRs
tpm2_pcrread sha256:0,4,7,8,9

# Extend PCR manually (for testing)
echo -n "test measurement" | sha256sum | xxd -r -p > /tmp/test.hash
tpm2_pcrextend 15:sha256=$(cat /tmp/test.hash | xxd -p)

# Create primary key under owner hierarchy
tpm2_createprimary -C o -c primary.ctx -G rsa

# Get TPM random data
tpm2_getrandom 32 | xxd
```

## openocd (JTAG Verification Tool)

Used in security testing to CONFIRM that JTAG is disabled after closure.
A successful JTAG connection in CLOSED mode is a security failure.

```bash
sudo apt-get install openocd

# Attempt JTAG connection (expect failure on closed device)
openocd -f interface/jlink.cfg \
        -f target/imx8mp.cfg \
        -c "init; targets; shutdown" 2>&1 | head -20

# Expected output on CLOSED device with disabled JTAG:
# Error: JTAG scan chain interrogation failed: all zeroes
# Error: Check JTAG interface, target power etc.

# If connection SUCCEEDS: JTAG is still enabled (security failure)
# If connection FAILS:    JTAG is disabled (expected for production)
```

## Factory Test Automation Framework

```python
#!/usr/bin/env python3
# factory-test-framework.py
# Reusable framework for manufacturing test automation

import serial
import time
import logging
import requests
from typing import Optional, Callable
from dataclasses import dataclass, field

logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

@dataclass
class TestResult:
    name: str
    passed: bool
    detail: str = ""
    duration_ms: float = 0.0

@dataclass
class DeviceSession:
    serial_number: str
    uart_port: str
    baud_rate: int = 115200
    results: list[TestResult] = field(default_factory=list)
    _conn: Optional[serial.Serial] = field(default=None, init=False)
    
    def connect(self):
        self._conn = serial.Serial(self.uart_port, self.baud_rate, timeout=5)
        log.info(f"Connected to {self.uart_port}")
    
    def disconnect(self):
        if self._conn:
            self._conn.close()
            self._conn = None
    
    def send_command(self, cmd: str, timeout: float = 10.0) -> str:
        """Send command and return response"""
        self._conn.write(f"{cmd}\n".encode())
        self._conn.flush()
        
        response = ""
        deadline = time.time() + timeout
        while time.time() < deadline:
            chunk = self._conn.read(256)
            if chunk:
                response += chunk.decode(errors='replace')
                # Simple heuristic: response complete when prompt appears
                if "=>" in response or "# " in response:
                    break
        return response
    
    def run_test(self, name: str, test_fn: Callable[[], bool],
                 detail_fn: Callable[[], str] = None) -> TestResult:
        """Execute a single test and record result"""
        start = time.time()
        try:
            passed = test_fn()
            detail = detail_fn() if detail_fn else ""
        except Exception as e:
            passed = False
            detail = str(e)
        
        duration = (time.time() - start) * 1000
        result = TestResult(name, passed, detail, duration)
        self.results.append(result)
        
        status_str = "PASS" if passed else "FAIL"
        log.info(f"  [{status_str}] {name} ({duration:.0f}ms)")
        if not passed and detail:
            log.warning(f"    Detail: {detail}")
        
        return result
    
    def summary(self) -> dict:
        passed = sum(1 for r in self.results if r.passed)
        total = len(self.results)
        return {
            "serial": self.serial_number,
            "passed": passed,
            "total": total,
            "success": passed == total,
            "results": [{"name": r.name, "passed": r.passed, "detail": r.detail}
                       for r in self.results]
        }
```
