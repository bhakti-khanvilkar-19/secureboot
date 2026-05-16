# Architecture 1: Minimal Secure Boot

```
Architecture: HABv4 + FIT Signing
Platform: NXP i.MX8M Plus (phyCORE-i.MX8MP)
Complexity: Low
Validation Status: Verified on phyBOARD-Pollux (2024-Q3)
```

---

## Overview

The Minimal Secure Boot architecture establishes a hardware-anchored chain of trust from the ROM through the Linux kernel using two mechanisms:

1. **HABv4**: NXP Boot ROM authenticates the first-stage boot image (SPL + U-Boot) using a public key hash burned into OTP fuses. Any tampered or unsigned bootloader is rejected.
2. **FIT Image Signing**: U-Boot authenticates the kernel, device tree, and initramfs using RSA-2048 signatures embedded in a FIT (Flat Image Tree) container. Any tampered kernel is rejected.

This architecture is appropriate for devices where:
- Runtime filesystem integrity is not required (or is handled by application-layer controls)
- The physical attack surface is limited (device is physically secure)
- Cost and complexity of implementation must be minimal
- A foundation is needed to build toward Architecture 2

**Security guarantee:** An attacker cannot boot custom firmware without access to the HABv4 signing keys (SRK → CSF → IMG chain) or the FIT signing key. Code execution begins with authenticated firmware.

---

## Security Properties

| Property | Status | Mechanism |
|----------|--------|-----------|
| Firmware authenticity (ROM → SPL → U-Boot) | ✅ | HABv4: SRK hash in fuses, CSF signature |
| Kernel authenticity (U-Boot → Kernel) | ✅ | FIT signature: RSA-2048/SHA-256 |
| DTB authenticity | ✅ | FIT signature covers DTB |
| Initramfs authenticity | ✅ | FIT signature covers initramfs |
| Chain of trust: ROM to userspace | ✅ | Continuous: HABv4 + FIT |
| Anti-rollback (U-Boot) | Optional | `CONFIG_ANTI_ROLLBACK` + fuse counter |
| Runtime rootfs integrity | ❌ | Requires dm-verity (Architecture 2) |
| Measured boot / TPM | ❌ | Requires Architecture 4 |
| Secure key storage | ❌ | Requires OP-TEE (Architecture 2) |
| OTA with rollback protection | ❌ | Requires SWUpdate (Architecture 3) |
| Data-at-rest encryption | ❌ | Requires LUKS + OP-TEE key sealing |

---

## Security Gaps

Understanding the gaps is as important as understanding the properties.

### Gap 1: No Rootfs Integrity

After the kernel boots and mounts the rootfs, there is no ongoing verification that the filesystem content has not been modified. An attacker with flash access can:
- Modify application binaries on the rootfs
- Add malicious scripts to `/etc/init.d/` or systemd units
- Replace libraries with backdoored versions

**Mitigation if Architecture 2 is not deployed:** Use read-only overlayfs mounts for critical directories, application-layer checksums, and physical tamper detection.

### Gap 2: Rollback Attacks (Without Anti-Rollback Fuse Counter)

If anti-rollback is not enabled, an attacker who can reflash the device can downgrade to an older signed firmware version that contains known vulnerabilities. The old firmware is still signed with valid keys and passes HABv4 authentication.

**Mitigation:** Enable `CONFIG_ANTI_ROLLBACK` in U-Boot and program rollback version into fuses. See Anti-Rollback Configuration section below.

### Gap 3: No Secure Storage

Application credentials, API keys, and device certificates stored on the rootfs are readable by anyone who gains filesystem access. There is no hardware-backed key store.

### Gap 4: U-Boot Environment Manipulation

The U-Boot environment (`/dev/mmcblk2p7` or similar) is not authenticated in this architecture. An attacker with flash access can modify the boot environment to change `bootargs`, `bootcmd`, or other variables to alter boot behavior.

**Partial mitigation:** Set `CONFIG_ENV_IS_NOWHERE=y` and hardcode critical boot variables. See U-Boot Environment Hardening section.

---

## Component List

| Component | Version | Role |
|-----------|---------|------|
| NXP Boot ROM | Silicon (i.MX8MP) | HABv4 authentication engine |
| NXP Code Signing Tool (CST) | 3.3.1 | HABv4 key generation and CSF creation |
| imx-mkimage | lf-6.1.55-2.2.0 | Assembles flash.bin (SPL+TF-A+U-Boot) |
| ARM Trusted Firmware (TF-A) BL31 | v2.9 | EL3 runtime firmware |
| U-Boot | lf-6.1.55-2.2.0 (NXP fork) | Bootloader with FIT verification |
| mkimage (u-boot-tools) | 2023.04 | FIT image creation and signing |
| Linux Kernel | lf-6.1.55-2.2.0 (NXP fork) | Target OS |
| Yocto Project | Kirkstone 4.0.x | Build system |
| meta-phytec | kirkstone | PHYTEC BSP layer |
| meta-imx | lf-6.1.55-2.2.0 | NXP i.MX BSP layer |
| OpenSSL | 3.0.x | Key generation (host tool) |

---

## Key Hierarchy

```
HABv4 KEY HIERARCHY
===================

                    ┌──────────────────────┐
                    │   SRK Root CA         │
                    │   (RSA-2048)          │
                    │   OFFLINE (air-gapped)│
                    │   Stored: HSM / LUKS  │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────┴─────┐  ┌───────┴─────┐  ┌──────┴──────┐
     │   SRK1       │  │   SRK2      │  │  SRK3, SRK4  │
     │ (Active)     │  │ (Backup)    │  │  (Backup)    │
     │ BURNED→FUSE  │  │ FUSE-READY  │  │  FUSE-READY  │
     └────────┬─────┘  └─────────────┘  └─────────────┘
              │ Signs (X.509)
     ┌────────┴─────┐
     │   CSF Key 1  │
     │   (RSA-2048) │
     │   OFFLINE    │
     └────────┬─────┘
              │ Signs (X.509)
     ┌────────┴─────┐
     │   IMG Key 1  │
     │   (RSA-2048) │
     │   Signing    │
     │   Server     │
     └──────────────┘

FIT IMAGE KEY HIERARCHY (SEPARATE)
====================================

     ┌──────────────────────┐
     │  FIT CA Key          │
     │  (RSA-2048)          │
     │  OFFLINE             │
     └──────────┬───────────┘
                │ Signs
     ┌──────────┴───────────┐
     │  FIT Dev Key         │  ← Embedded as certificate in U-Boot DTB
     │  (RSA-2048)          │    at Yocto build time
     │  Build server        │
     └──────────────────────┘
```

**Key storage requirements:**
- SRK keys: Air-gapped HSM (YubiHSM 2 minimum; Thales Luna for production)
- CSF key: Air-gapped signing workstation
- IMG key: Signing server (automated CI/CD)
- FIT CA key: Air-gapped HSM
- FIT dev key: Signing server (CI/CD pipeline secret)

---

## Partition Layout

```
eMMC: mmcblk2 (16 GB)
─────────────────────────────────────────────────
mmcblk2boot0  (4 MB hardware boot partition):
  Offset 0x00000: imx-boot (flash.bin)
    - SPL (Secondary Program Loader)
    - DDR firmware blobs (4× lpddr4_pmu_train*)
    - TF-A BL31
    - U-Boot proper
    - IVT + CSF (HABv4 signature block)
  
  Total signed binary: ~3 MB

mmcblk2p1 (512 MB): FAT32 /boot
  - fitImage (FIT container, ~25 MB)
    - kernel Image (~20 MB)
    - device tree blob (~60 KB)
    - initramfs.cpio.gz (~4 MB)
    - Configuration signature

mmcblk2p2 (remaining): ext4 /
  - Root filesystem (read-write)
  - No integrity protection in Architecture 1

mmcblk2p3 (16 MB): U-Boot environment
  - Boot counters
  - Boot arguments
  - IMPORTANT: Must be hardened (see below)
```

---

## Implementation Guide

### Step 1: Yocto Build Configuration

Create the Yocto build environment using PHYTEC's phyLinux tool:

```bash
# Install phyLinux
curl https://raw.githubusercontent.com/phytec/phyLinux/master/phyLinux \
     -o phyLinux && chmod +x phyLinux

# Initialize Kirkstone BSP
./phyLinux init --machine imx8mp-phyboard-pollux-rdk \
                --distro ampliphy-secure

# This populates sources/ with all required layers
```

**`conf/local.conf` — Minimal Secure Boot configuration:**

```bitbake
# ============================================================
# Architecture 1: Minimal Secure Boot — local.conf
# Platform: phyCORE-i.MX8MP (phyBOARD-Pollux)
# Yocto: Kirkstone (4.0.x)
# ============================================================

MACHINE = "imx8mp-phyboard-pollux-rdk"
DISTRO = "ampliphy-secure"

# Build parallelism — adjust to your host
BB_NUMBER_THREADS = "8"
PARALLEL_MAKE = "-j8"

# Download and cache directories
DL_DIR = "${TOPDIR}/../downloads"
SSTATE_DIR = "${TOPDIR}/../sstate-cache"

# ============================================================
# HABv4 CONFIGURATION
# ============================================================

# Enable HABv4 signing in imx-boot
ENABLE_IMX_HABV4 = "1"

# Path to CST key directory (populated in Step 3)
IMX_HAB_KEYDIR = "${TOPDIR}/../hab-keys"

# SRK to use from the 4-slot table (0-indexed, use slot 0 for primary)
IMX_HAB_SRK_INDEX = "0"

# ============================================================
# FIT IMAGE SIGNING
# ============================================================

# Enable FIT image signing
UBOOT_SIGN_ENABLE = "1"

# Key name (filename without extension in UBOOT_SIGN_KEYDIR)
UBOOT_SIGN_KEYNAME = "dev"

# Key directory (populated in Step 3)
UBOOT_SIGN_KEYDIR = "${TOPDIR}/../fit-keys"

# FIT image hash algorithm
UBOOT_SIGN_IMG_KEYNAME = "dev"

# Required FIT image configuration node
UBOOT_FIT_GENERATE_KEYS = "0"  # We generate keys manually (Step 3)

# ============================================================
# U-BOOT CONFIGURATION
# ============================================================

# U-Boot source — NXP fork with i.MX8MP support
PREFERRED_PROVIDER_u-boot = "u-boot-imx"
PREFERRED_VERSION_u-boot-imx = "2023.04+gitAUTOINC+%"

# U-Boot environment protection
UBOOT_ENV_REDUNDANT = "1"

# ============================================================
# KERNEL CONFIGURATION
# ============================================================

PREFERRED_PROVIDER_virtual/kernel = "linux-imx"
PREFERRED_VERSION_linux-imx = "6.1.%"
LINUX_VERSION = "6.1.55"

# ============================================================
# IMAGE CONFIGURATION
# ============================================================

# Use WIC-based image for direct eMMC flashing
IMAGE_FSTYPES = "wic wic.bmap"

# WIC kickstart file
WKS_FILE = "imx-imx-boot-sd-arch1.wks"

# Image to build
IMAGE_NAME = "phytec-headless-image"

# ============================================================
# EXTRA IMAGE FEATURES
# ============================================================

EXTRA_IMAGE_FEATURES ?= "ssh-server-openssh"

# Remove debug features for production build
# Uncomment for production:
# EXTRA_IMAGE_FEATURES_remove = "debug-tweaks"
# ROOT_HOME = "/home/root"
```

**`conf/bblayers.conf`:**

```bitbake
POKY_BBLAYERS_CONF_VERSION = "2"

BBPATH = "${TOPDIR}"
BBFILES ?= ""

BBLAYERS ?= " \
  ${TOPDIR}/../sources/poky/meta \
  ${TOPDIR}/../sources/poky/meta-poky \
  ${TOPDIR}/../sources/poky/meta-yocto-bsp \
  ${TOPDIR}/../sources/meta-openembedded/meta-oe \
  ${TOPDIR}/../sources/meta-openembedded/meta-networking \
  ${TOPDIR}/../sources/meta-openembedded/meta-python \
  ${TOPDIR}/../sources/meta-openembedded/meta-filesystems \
  ${TOPDIR}/../sources/meta-freescale \
  ${TOPDIR}/../sources/meta-imx/meta-bsp \
  ${TOPDIR}/../sources/meta-imx/meta-sdk \
  ${TOPDIR}/../sources/meta-imx/meta-ml \
  ${TOPDIR}/../sources/meta-phytec \
  ${TOPDIR}/../sources/meta-ampliphy \
  "
```

---

### Step 2: WIC Kickstart File

Create `meta-phytec/wic/imx-imx-boot-sd-arch1.wks`:

```wic
# Minimal Secure Boot WIC kickstart
# Architecture 1: HABv4 + FIT image

# Boot partition (imx-boot goes to eMMC hardware boot partition via post-install)
# mmcblk2boot0 handled by imx-boot installer script

# FAT32 /boot partition for FIT image
part /boot   --source rawcopy --sourceparams="file=${DEPLOY_DIR_IMAGE}/fitImage" \
             --ondisk mmcblk2 --fstype=vfat --label boot --align 4096 --size 512M

# Ext4 root filesystem
part /       --source rootfs --ondisk mmcblk2 --fstype=ext4 \
             --label rootfs --align 4096 --size 8192M

# U-Boot environment partition
part         --ondisk mmcblk2 --size 16M --align 4096 --label uboot-env
```

---

### Step 3: Key Generation

**Prerequisites:** Air-gapped workstation with NXP CST 3.3.1 installed.

```bash
# ============================================================
# HABv4 KEY GENERATION
# Using NXP CST 3.3.1 Bash script
# ============================================================
export CST_DIR=/opt/cst-3.3.1

# Create key directory
mkdir -p /secure-workstation/hab-keys
cd /secure-workstation/hab-keys

# Generate 4 SRK key pairs + CSF + IMG keys
# The CST provides an interactive script for this purpose
${CST_DIR}/keys/hab4_pki_tree.sh

# When prompted:
#   Use Elliptic Curve keys? (y/n): n
#   Enter key length in bits (2048, 3072, 4096): 2048
#   Enter PKI tree duration (years): 10
#   How many Super Root Keys should be generated? 4
#   Do you want the SRK certificates to have the CA flag set? y

# Output files (relative to hab-keys/):
# crts/SRK1_sha256_2048_65537_v3_ca_crt.pem
# crts/SRK2_sha256_2048_65537_v3_ca_crt.pem
# crts/SRK3_sha256_2048_65537_v3_ca_crt.pem
# crts/SRK4_sha256_2048_65537_v3_ca_crt.pem
# keys/SRK1_sha256_2048_65537_v3_ca_key.pem
# keys/SRK2_sha256_2048_65537_v3_ca_key.pem
# keys/SRK3_sha256_2048_65537_v3_ca_key.pem
# keys/SRK4_sha256_2048_65537_v3_ca_key.pem
# crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem
# keys/CSF1_1_sha256_2048_65537_v3_usr_key.pem
# crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem
# keys/IMG1_1_sha256_2048_65537_v3_usr_key.pem

# Generate the SRK table and hash
${CST_DIR}/linux64/bin/srktool \
    -h 4 \
    -t SRK_1_2_3_4_table.bin \
    -e SRK_1_2_3_4_fuse.bin \
    -d sha256 \
    -c crts/SRK1_sha256_2048_65537_v3_ca_crt.pem,\
crts/SRK2_sha256_2048_65537_v3_ca_crt.pem,\
crts/SRK3_sha256_2048_65537_v3_ca_crt.pem,\
crts/SRK4_sha256_2048_65537_v3_ca_crt.pem

# Display the SRK hash (32 bytes = 8 fuse words)
xxd SRK_1_2_3_4_fuse.bin
# 00000000: a3f2 1c4b 7e93 d258 4ab1 209e 3f74 c6d1  ...K~..XJ. .?t..
# 00000010: 8b2e 4f73 12c7 a891 d345 6e01 f234 78a9  ..Os.....En..4x.
# This is what gets burned into SRK_HASH[0..7] fuses (8 × 32-bit words)

# ============================================================
# FIT IMAGE KEY GENERATION
# ============================================================
mkdir -p /secure-workstation/fit-keys
cd /secure-workstation/fit-keys

# Generate FIT signing key pair
openssl genrsa -out dev.pem 2048

# Generate self-signed certificate (embedded in U-Boot DTB)
openssl req -batch -new -x509 -key dev.pem -out dev.crt \
    -days 3650 \
    -subj "/O=MyCompany/CN=FIT Signing Key - Development"

# Verify
openssl x509 -in dev.crt -text -noout | grep -E "Subject:|Not After"
# Subject: O=MyCompany, CN=FIT Signing Key - Development
# Not After : Oct 12 14:23:01 2034 GMT
```

---

### Step 4: CSF File Creation

The CSF (Command Sequence File) instructs HABv4 how to authenticate the imx-boot binary. CST reads this text file and produces a binary CSF that is appended to the signed image.

**Create `/secure-workstation/hab-keys/csf-imx-boot.csf`:**

```csf
[Header]
    Version = 4.3
    Hash Algorithm = sha256
    Engine Configuration = 0
    Certificate Format = X509
    Signature Format = CMS
    Engine = CAAM

[Install SRK]
    # Install the SRK table; use SRK index 0 (first of four)
    File = "SRK_1_2_3_4_table.bin"
    Source index = 0

[Install CSFK]
    # Install the CSF signing key (signed by SRK1)
    File = "crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate CSF]
    # The CSF itself is signed — this binds the following commands to the SRK chain

[Install Key]
    # Install the image signing key (signed by CSF key)
    Verification index = 0
    File = "crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate Data]
    # Authenticate the flash.bin image
    # These offsets and lengths are filled in by the signing script after measuring the binary
    Verification index = 1
    Blocks = 0x401fcdc0 0x00000000 0x000af020 "flash.bin"
    # Address = load address of SPL in OCRAM (0x401fcdc0 for i.MX8MP)
    # Offset   = offset within flash.bin where the authenticated data starts
    # Length   = number of bytes to authenticate
    # File     = the binary file containing the data

[Unlock]
    Engine = CAAM
    Features = RNG
```

**Signing script (`sign-imx-boot.sh`):**

```bash
#!/usr/bin/env bash
# sign-imx-boot.sh — Sign the imx-boot binary for HABv4
# Usage: ./sign-imx-boot.sh <flash.bin> <output-signed.bin>
# Must be run from the hab-keys directory

set -euo pipefail

FLASH_BIN="${1:?Usage: $0 <flash.bin> <output>}"
OUTPUT="${2:?Usage: $0 <flash.bin> <output>}"
CST_BIN="/opt/cst-3.3.1/linux64/bin/cst"
KEYDIR="$(pwd)"

# Copy flash.bin to working directory
cp "${FLASH_BIN}" "${OUTPUT}"

# Extract image parameters needed for CSF
# SPL is at offset 0 in flash.bin, loads to OCRAM at 0x401fcdc0
# The IVT is at offset 0x400 within the SPL image
SPL_LOAD_ADDR=0x401fcdc0

# Get SPL size from the image (first 4 bytes of IVT header give us what we need)
# For i.MX8MP: SPL image + padding is typically at offset 0, size varies
# Use objdump/readelf or measure empirically:
SPL_SIZE=$(stat -c%s "${OUTPUT}")
# Align to 0x1000 boundary
SPL_SIZE_ALIGNED=$(( (SPL_SIZE + 0xFFF) & ~0xFFF ))

echo "flash.bin size: ${SPL_SIZE} bytes (aligned: ${SPL_SIZE_ALIGNED})"
echo "Load address: ${SPL_LOAD_ADDR}"

# Update the CSF with actual binary measurements
# In practice, imx-mkimage generates the offsets and CSF template automatically
# when invoked with HAB signing parameters. The manual process:
sed -i "s|Blocks = .*|Blocks = ${SPL_LOAD_ADDR} 0x00000000 0x$(printf '%08x' ${SPL_SIZE_ALIGNED}) \"${OUTPUT}\"|" \
    csf-imx-boot.csf

# Run CST to generate the signed binary
${CST_BIN} -i csf-imx-boot.csf -o csf_output.bin

# Append CSF to the image at the CSF offset (specified in IVT)
# The IVT's CSF pointer tells HABv4 where to find the CSF
# imx-mkimage writes the CSF pointer during image assembly
# For standalone signing, append at the correct offset:
CSF_OFFSET="${SPL_SIZE_ALIGNED}"
dd if=csf_output.bin of="${OUTPUT}" bs=1 seek="${CSF_OFFSET}" conv=notrunc

echo "Signed image written to: ${OUTPUT}"
echo "CSF appended at offset: 0x$(printf '%x' ${CSF_OFFSET})"
```

> **Note:** In the Yocto build, the `imx-boot` recipe handles CSF generation and signing automatically when `ENABLE_IMX_HABV4 = "1"` and `IMX_HAB_KEYDIR` is set. The manual script above illustrates the mechanics for understanding purposes. See the meta-phytec layer's `imx-boot.bbappend` for the Yocto integration.

---

### Step 5: Yocto Build Execution

```bash
cd build/

# Initialize BitBake environment
source ../sources/poky/oe-init-build-env .

# Ensure keys are accessible (symlink or configure IMX_HAB_KEYDIR)
# local.conf already sets IMX_HAB_KEYDIR = "${TOPDIR}/../hab-keys"
# local.conf already sets UBOOT_SIGN_KEYDIR = "${TOPDIR}/../fit-keys"

# Build the complete image
bitbake phytec-headless-image

# Expected output artifacts in tmp/deploy/images/imx8mp-phyboard-pollux-rdk/:
#   imx-boot-imx8mp-phyboard-pollux-rdk.bin-flash_evk   ← HABv4 signed
#   fitImage                                              ← FIT signed
#   phytec-headless-image-imx8mp-phyboard-pollux-rdk.wic ← Full eMMC image
#   phytec-headless-image-imx8mp-phyboard-pollux-rdk.wic.bmap
```

**Verifying the signed artifacts before flashing:**

```bash
DEPLOY=tmp/deploy/images/imx8mp-phyboard-pollux-rdk

# Verify FIT image signatures
dumpimage -l ${DEPLOY}/fitImage
# Expected output includes:
#  Configuration 0 (conf@1)
#   Required
#   Kernel Image (kernel@1)
#   ... (signed, hash OK)
#   Sign algo: sha256,rsa2048:dev
#   Sign value: <256 bytes>
#   Timestamp: Mon Oct 14 09:23:44 2024
#   Verified OK

# Inspect CSF offset in imx-boot
objdump -d ${DEPLOY}/imx-boot-*.bin | grep -A2 "csf"
# Or check the IVT header directly:
python3 -c "
import struct
data = open('${DEPLOY}/imx-boot-imx8mp-phyboard-pollux-rdk.bin-flash_evk','rb').read()
# IVT at offset 0x400
offset = 0x400
tag, length, version = struct.unpack_from('>BHB', data, offset)
print(f'IVT tag: 0x{tag:02x} (expected 0xD1)')
print(f'IVT version: 0x{version:02x} (expected 0x43 for HABv4.3)')
entry, _, dcd, boot_data, self_ptr, csf, _ = struct.unpack_from('<7I', data, offset+4)
print(f'Entry: 0x{entry:08x}')
print(f'CSF pointer: 0x{csf:08x} (0 = unsigned, nonzero = signed)')
"
```

---

### Step 6: Fuse Programming Sequence

> **⚠️ CRITICAL WARNING:** Fuse programming is IRREVERSIBLE. Follow this sequence exactly. Use a dedicated development board. Never perform on production devices until the workflow is fully validated.

**Prerequisites before burning fuses:**
1. The device boots successfully in OPEN mode with the signed imx-boot binary
2. U-Boot `hab_status` shows no HAB failure events
3. The SRK hash file (`SRK_1_2_3_4_fuse.bin`) is verified against the keys used to sign the binary
4. A backup of all signing keys is stored in the HSM

```bash
# ============================================================
# Step 6.1: Flash the signed image to the development board
# ============================================================

# Using NXP uuu (Universal Update Utility) via USB-C boot download mode
# Set board boot mode pins to USB download mode (see phyBOARD-Pollux HW Manual)

uuu -b emmc_all \
    tmp/deploy/images/imx8mp-phyboard-pollux-rdk/imx-boot-*.bin \
    tmp/deploy/images/imx8mp-phyboard-pollux-rdk/phytec-headless-image-*.wic

# ============================================================
# Step 6.2: Verify HAB status in OPEN mode
# ============================================================
# Connect serial terminal: 115200 8N1

# Power on board (in normal eMMC boot mode)
# U-Boot prompt should appear within 5 seconds

U-Boot=> hab_status

HAB Configuration: 0xf0 HAB State: 0x66
No HAB Events Found!

# ✅ GOOD: No events, OPEN mode (0xf0 = HAB_CFG_OPEN)
# ❌ BAD: If events are listed, DO NOT PROCEED with fuse burning.
#         Fix the signing errors first.

# ============================================================
# Step 6.3: Read SRK hash for verification
# ============================================================

# Convert the SRK_1_2_3_4_fuse.bin to the 8 fuse words
python3 << 'EOF'
import struct
data = open('/secure-workstation/hab-keys/SRK_1_2_3_4_fuse.bin', 'rb').read()
words = struct.unpack('<8I', data)
print("SRK Hash fuse values (program these 8 words into Bank 6, Words 0-7):")
for i, word in enumerate(words):
    print(f"  OCOTP_SRK{i} (Bank 6, Word {i}): 0x{word:08x}")
EOF

# Output example:
# SRK Hash fuse values:
#   OCOTP_SRK0 (Bank 6, Word 0): 0x4b1cf2a3
#   OCOTP_SRK1 (Bank 6, Word 1): 0x58d2937e
#   OCOTP_SRK2 (Bank 6, Word 2): 0x9e20b14a
#   OCOTP_SRK3 (Bank 6, Word 3): 0xd1c6743f
#   OCOTP_SRK4 (Bank 6, Word 4): 0x734f2e8b
#   OCOTP_SRK5 (Bank 6, Word 5): 0x91a8c712
#   OCOTP_SRK6 (Bank 6, Word 6): 0x016e45d3
#   OCOTP_SRK7 (Bank 6, Word 7): 0xa97834f2

# ============================================================
# Step 6.4: Program SRK hash fuses from U-Boot
# ============================================================
# In U-Boot prompt (TRIPLE CHECK these values against your SRK_1_2_3_4_fuse.bin):

U-Boot=> fuse prog 6 0 0x4b1cf2a3
Programming bank 6 word 0x00000000 to 0x4b1cf2a3...

U-Boot=> fuse prog 6 1 0x58d2937e
U-Boot=> fuse prog 6 2 0x9e20b14a
U-Boot=> fuse prog 6 3 0xd1c6743f
U-Boot=> fuse prog 6 4 0x734f2e8b
U-Boot=> fuse prog 6 5 0x91a8c712
U-Boot=> fuse prog 6 6 0x016e45d3
U-Boot=> fuse prog 6 7 0xa97834f2

# ============================================================
# Step 6.5: Verify fuse readback
# ============================================================
U-Boot=> fuse read 6 0 8
Bank 6:
Word 0x00000000: 4b1cf2a3
Word 0x00000001: 58d2937e
Word 0x00000002: 9e20b14a
Word 0x00000003: d1c6743f
Word 0x00000004: 734f2e8b
Word 0x00000005: 91a8c712
Word 0x00000006: 016e45d3
Word 0x00000007: a97834f2

# ✅ Verify each value matches your SRK hash file exactly.
# ❌ If ANY value is wrong, DO NOT burn SEC_CONFIG. The device will be bricked.

# ============================================================
# Step 6.6: Reset and verify HAB still passes
# ============================================================
U-Boot=> reset

# After boot:
U-Boot=> hab_status
HAB Configuration: 0xf0 HAB State: 0x66
No HAB Events Found!

# ✅ Still passing in OPEN mode with SRK hash fuses burned.

# ============================================================
# Step 6.7: Burn SEC_CONFIG (CLOSE the device)
# THIS IS IRREVERSIBLE — FINAL VERIFICATION BEFORE PROCEEDING:
# - hab_status shows no events ✅
# - Fuse readback matches SRK hash file ✅
# - Signed firmware boots correctly ✅
# - You have a backup of all signing keys ✅
# ============================================================

# SEC_CONFIG is in Bank 1, Word 3, bit 1
# Burning bit 1 sets OEM_CLOSED mode

U-Boot=> fuse prog 1 3 0x00000002
Programming bank 1 word 0x00000003 to 0x00000002...

U-Boot=> reset

# After reset, verify closed mode:
U-Boot=> hab_status
HAB Configuration: 0xcc HAB State: 0x66
No HAB Events Found!

# ✅ HAB Configuration 0xcc = HAB_CFG_CLOSED — SUCCESS
# The device will now reject any unsigned or incorrectly signed firmware.
```

---

### Step 7: Validation Procedure

After fuse programming, perform the following validation tests:

#### Test 7.1: Signed Firmware Boots (Expected: PASS)

```
Power on → observe serial output:
U-Boot SPL 2023.04 (...)
Trying to boot from MMC1
NOTICE:  BL31: v2.9(release)...
NOTICE:  BL31: Built : ...

U-Boot 2023.04 (...)
CPU:   Freescale i.MX8MP rev1.1 at 1600 MHz
...
HAB Configuration: 0xcc HAB State: 0x66
No HAB Events Found!
...
Loading FIT Image...
## Loading kernel from FIT Image at ...
   Verifying Hash Integrity ...
   sha256+rsa2048:dev+ OK
Booting using the fdt blob at ...
```

**Key indicators:**
- `HAB Configuration: 0xcc` — device is in CLOSED mode
- `No HAB Events Found!` — imx-boot authentication passed
- `sha256+rsa2048:dev+ OK` — FIT image authentication passed

#### Test 7.2: Unsigned Firmware Rejected (Expected: FAIL)

```bash
# Create an unsigned copy of imx-boot by zeroing the CSF
cp imx-boot-signed.bin imx-boot-unsigned.bin
python3 -c "
data = bytearray(open('imx-boot-unsigned.bin','rb').read())
# Zero the CSF pointer in the IVT (offset 0x400 + 0x18 = CSF field)
import struct
struct.pack_into('<I', data, 0x400 + 0x18, 0)
open('imx-boot-unsigned.bin','wb').write(data)
"

# Flash the unsigned binary and observe:
# (board should enter infinite loop / reset repeatedly — will NOT boot to U-Boot)
# No serial output from U-Boot since ROM halts before SPL execution
```

#### Test 7.3: Tampered FIT Image Rejected (Expected: FAIL)

```bash
# In U-Boot, manually test FIT verification failure:
# (requires a way to serve a modified FIT via TFTP or USB)

U-Boot=> tftp 0x50000000 tampered-fitImage
U-Boot=> bootm 0x50000000

# Expected output:
## Loading kernel from FIT Image at 50000000 ...
   Verifying Hash Integrity ...
   sha256,rsa2048:dev- ERROR: rsa_verify_key: key 'dev' not found in FDT
   ...
ERROR: can't get kernel image!
```

---

### Step 8: U-Boot Environment Hardening

Without environment protection, the signed bootloader can be subverted by modifying the U-Boot environment stored in flash. Apply these configuration changes:

**In `u-boot-imx_%.bbappend` (meta-phytec recipe extension):**

```bitbake
# Append to U-Boot config fragments
SRC_URI_append = " file://secure-boot-env.cfg"
```

**`secure-boot-env.cfg`:**

```config
# Disable runtime modification of critical boot variables
# The bootcmd and bootargs are fixed in the board-specific defconfig
# CONFIG_USE_DEFAULT_ENV_FILE allows a hardcoded environment

# Disable U-Boot scripting language (prevents env variable exploitation)
# CONFIG_BOOTCOMMAND is set in defconfig; disable shell command access:
CONFIG_CMDLINE_PS_SUPPORT=n

# Remove mkenv/saveenv commands from U-Boot
CONFIG_CMD_SAVEENV=n

# If full environment protection is desired (no env partition):
# CONFIG_ENV_IS_NOWHERE=y
# CONFIG_ENV_SIZE=0x2000

# Disable U-Boot network boot (attack vector if not needed)
CONFIG_CMD_NET=n
CONFIG_CMD_DHCP=n
CONFIG_CMD_TFTP=n
```

---

## Expected Boot Output

A correctly configured Architecture 1 device produces the following serial output (115200 8N1):

```
U-Boot SPL 2023.04-lf-6.1.55-2.2.0+g7e4c4f2 (Oct 14 2024 - 09:23:44 +0000)
DDRINFO: start DRAM init
DDRINFO:ddrphy calibration done
DDRINFO: ddrmix config done
Normal Boot
Trying to boot from MMC1


NOTICE:  BL31: v2.9(release):v2.9
NOTICE:  BL31: Built : 09:23:01, Oct 14 2024
NOTICE:  BL31: Booting secure firmware

I/TC: OP-TEE OS version 3.21.0 (gcc version 12.2.0 (GCC))
I/TC: Primary CPU initializing
I/TC: Initialized


U-Boot 2023.04-lf-6.1.55-2.2.0+g7e4c4f2 (Oct 14 2024 - 09:23:44 +0000)

CPU:   Freescale i.MX8MP rev1.1 at 1600 MHz
Model: PHYTEC phyBOARD-Pollux i.MX8MP
DRAM:  2 GiB
Core:  216 devices, 21 uclasses, devicetree: separate
WDT:   Started watchdog@30280000 with servicing 60s timeout
MMC:   FSL_SDHC: 1, FSL_SDHC: 2
Loading Environment from MMC... OK
In:    serial@30890000
Out:   serial@30890000
Err:   serial@30890000
Net:   eth0: ethernet@30be0000

HAB Configuration: 0xcc HAB State: 0x66
No HAB Events Found!

Hit any key to stop autoboot:  0 
switch to partitions #0, OK
mmc1 is current device
Scanning mmc 1:1...
Found /boot/fitImage
## Loading kernel from FIT Image at 40480000 ...
   Using Configuration conf@1
   Trying 'kernel@1' kernel subimage
     Description:  Linux kernel
     Type:         Kernel Image
     Compression:  uncompressed
     Data Start:   0x404800e8
     Data Size:    20971520 Bytes = 20 MiB
     Architecture: AArch64
     OS:           Linux
     Load Address: 0x40480000
     Entry Point:  0x40480000
     Hash algo:    sha256
     Hash value:   a3f21c4b7e93d2584ab1209e3f74c6d18b2e4f73...
   Verifying Hash Integrity ...
   sha256+ OK
   Trying 'fdt@1' fdt subimage
     Description:  Device Tree Blob
     Data Start:   0x415400e8
     Data Size:    65536 Bytes = 64 KiB
     Architecture: AArch64
     Hash algo:    sha256
     Hash value:   9b3e...
   Verifying Hash Integrity ...
   sha256+ OK
   Verifying Signature for Configuration conf@1 ...
   sha256,rsa2048:dev+ OK
## Loading fdt from FIT Image at 40480000 ...
## Booting kernel from Legacy Image at 40480000 ...
   Kernel image @ 0x40480000 [ 0x000000 - 0x1400000 ]
   ## Flattened Device Tree blob at 41540000
   Booting using the fdt blob at 0x41540000
   Loading Device Tree to 000000004ffe0000, end 000000004fffffff ... OK

Starting kernel ...

[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd034]
[    0.000000] Linux version 6.1.55-lf-6.1.55-2.2.0+g...
[    0.000000] Machine model: PHYTEC phyBOARD-Pollux i.MX8MP
...
[    2.341892] systemd[1]: Detected architecture arm64.

Welcome to phyLinux Kirkstone!
```

---

## Anti-Rollback Configuration (Optional)

To prevent downgrade attacks, enable the U-Boot rollback counter:

```config
# In U-Boot defconfig or .cfg fragment:
CONFIG_ANTI_ROLLBACK=y
CONFIG_ROLLBACK_IDX=1          # Current minimum version
CONFIG_ROLLBACK_IDX_FUSE_BANK=1
CONFIG_ROLLBACK_IDX_FUSE_WORD=5  # Use a spare fuse word
```

When a new firmware version is released with a security fix:
1. Increment `CONFIG_ROLLBACK_IDX` in the new build
2. After deploying the new firmware to all devices, burn the new rollback counter into fuses: `fuse prog 1 5 0x00000002` (for version 2)
3. Devices updated to the new firmware will reject the old firmware on next attempt

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|------------|
| Board hangs after power on, no serial output | SEC_CONFIG burned, imx-boot not correctly signed | Recover via USB download mode with correctly signed binary |
| `HAB Events Found!` with `HAB_INV_SIGNATURE` | Wrong SRK/CSF/IMG key used for signing | Rebuild with correct keys; do NOT burn fuses if in OPEN mode |
| FIT verification fails: `key 'dev' not found` | U-Boot built without embedded public key | Rebuild U-Boot with `UBOOT_SIGN_KEYDIR` set |
| HAB config shows `0xf0` after burning `SEC_CONFIG` | Fuse write may not have taken; check `fuse read 1 3` | If readback shows 0x00000002, reset and re-check |
| `Verified OK` but `HAB Configuration: 0xf0` | Device still in OPEN mode — HABv4 not enforcing | Must burn SEC_CONFIG to enforce |

---

## References

- NXP Application Note AN4581: HABv4 on i.MX
- NXP Code Signing Tool User's Guide, CST 3.3.1
- PHYTEC phyBOARD-Pollux BSP Manual (Kirkstone)
  https://phytec.github.io/doc-bsp-yocto-imx/
- U-Boot FIT Signature Documentation
  https://source.denx.de/u-boot/u-boot/-/blob/master/doc/uImage.FIT/signature.txt
- Chapter 12: HABv4 on i.MX8M Plus (this repository)
- Chapter 10: Image Signing (this repository)
