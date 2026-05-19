# Lab 10: PHYTEC Production Secure Boot

## Learning Objectives

After completing this lab, you can:
1. Set up a complete Yocto build environment for phyCORE-i.MX8MP
2. Generate and manage HABv4 and FIT signing keys
3. Build a signed phytec-securiphy image
4. Provision a phyBOARD-Pollux with signed firmware
5. Validate secure boot is active in CLOSED mode

## Prerequisites

- All previous labs completed
- phyBOARD-Pollux with phyCORE-i.MX8MP SOM
- Linux build workstation (Ubuntu 22.04, 16GB RAM, 200GB disk)
- USB-to-UART adapter
- USB OTG cable
- NXP CST (Code Signing Tool — requires NXP registration)

**Estimated time: 8–12 hours (mostly build time)**

---

## Phase 1: Environment Setup (30 min)

```bash
# Install Yocto dependencies:
sudo apt-get update && sudo apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping python3-git python3-jinja2 \
    libegl1-mesa libsdl1.2-dev xterm python3-subunit mesa-common-dev \
    zstd liblz4-tool file locales libacl1

# Set locale:
sudo locale-gen en_US.UTF-8
export LANG=en_US.UTF-8

# Create working directory:
mkdir -p ~/phytec-secure && cd ~/phytec-secure
```

---

## Phase 2: Clone Layers (20 min)

```bash
# Clone using kas (PHYTEC's build configuration manager):
pip3 install kas

# Create kas configuration:
cat > phytec-secure.yml << 'EOF'
header:
  version: 14

machine: phyboard-pollux-imx8mp-3
distro: ampliphy-headless
target: phytec-headless-image

repos:
  poky:
    url: https://git.yoctoproject.org/poky
    branch: kirkstone
    layers:
      meta: {}
      meta-poky: {}

  meta-openembedded:
    url: https://github.com/openembedded/meta-openembedded
    branch: kirkstone
    layers:
      meta-oe: {}
      meta-python: {}
      meta-networking: {}
      meta-filesystems: {}

  meta-security:
    url: https://git.yoctoproject.org/meta-security
    branch: kirkstone
    layers:
      meta-security: {}

  meta-imx:
    url: https://github.com/nxp-imx/meta-imx
    branch: lf-6.6.y
    layers:
      meta-imx: {}
      meta-sdk: {}

  meta-phytec:
    url: https://github.com/phytec/meta-phytec
    branch: kirkstone
    layers:
      meta-phytec: {}

  meta-ampliphy:
    url: https://github.com/phytec/meta-ampliphy
    branch: kirkstone
    layers:
      meta-ampliphy: {}
EOF

kas checkout phytec-secure.yml
```

---

## Phase 3: Generate Keys (45 min)

```bash
# Create key directory (outside Yocto build tree):
mkdir -p ~/phytec-secure/keys/{hab,fit,swupdate}

# === FIT Signing Key ===
openssl genrsa -out ~/phytec-secure/keys/fit/phytec-fit-key.pem 2048
openssl req -new -x509 \
    -key ~/phytec-secure/keys/fit/phytec-fit-key.pem \
    -out ~/phytec-secure/keys/fit/phytec-fit-key.crt \
    -days 3650 \
    -subj "/CN=phytec-fit-key/O=Lab Corp/C=DE"

echo "FIT key fingerprint:"
openssl x509 -in ~/phytec-secure/keys/fit/phytec-fit-key.crt \
    -fingerprint -sha256 -noout

# === HABv4 Keys (requires NXP CST) ===
# For lab purposes — in production use air-gapped workstation!
export CST=/opt/cst  # Adjust to your CST installation path

cd ~/phytec-secure/keys/hab
${CST}/keys/hab4_pki_tree.sh
# Accept all defaults for lab:
# CA key name: LabCA-2024
# Key length: 2048
# Duration: 3650
# Number of SRKs: 4
# CA flag: n

# Generate SRK table and fuse values:
${CST}/linux64/bin/srktool \
    --hab_ver 4 \
    --certs \
        crts/SRK1_sha256_2048_65537_v3_usr_crt.pem \
        crts/SRK2_sha256_2048_65537_v3_usr_crt.pem \
        crts/SRK3_sha256_2048_65537_v3_usr_crt.pem \
        crts/SRK4_sha256_2048_65537_v3_usr_crt.pem \
    --table SRK_1_2_3_4_table.bin \
    --efuse_entries SRK_1_2_3_4_fuse.bin \
    --format bin

echo "SRK fuse values:"
python3 -c "
import struct
data = open('SRK_1_2_3_4_fuse.bin','rb').read()
for i in range(8):
    word = struct.unpack('<I', data[i*4:(i+1)*4])[0]
    print(f'  Bank 3, Word {i}: 0x{word:08X}')
"

cd ~/phytec-secure

# === SWUpdate Key ===
openssl genrsa -out keys/swupdate/swupdate-signing-key.pem 2048
openssl req -new -x509 \
    -key keys/swupdate/swupdate-signing-key.pem \
    -out keys/swupdate/swupdate-signing-cert.pem \
    -days 3650 \
    -subj "/CN=SWUpdate Lab/O=Lab Corp/C=DE"
```

---

## Phase 4: Configure and Build (6-8 hours build time)

```bash
# Initialize Yocto build environment:
kas shell phytec-secure.yml -- bash -c "echo Build env initialized"

cd build/

# Create local.conf additions:
cat >> conf/local.conf << 'EOF'

# === Lab 10: Secure Boot Configuration ===

# FIT Signing:
UBOOT_SIGN_ENABLE = "1"
UBOOT_SIGN_KEYDIR = "/home/${USER}/phytec-secure/keys/fit"
UBOOT_SIGN_KEYNAME = "phytec-fit-key"
UBOOT_DTB_BINARY = "imx8mp-phyboard-pollux-rdk-4.dtb"
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 2000"

# HABv4 Signing:
HAB_ENABLE = "1"
HAB_SRK_TABLE = "/home/${USER}/phytec-secure/keys/hab/SRK_1_2_3_4_table.bin"
HAB_SRK_INDEX = "0"
HAB_CST_KEY = "/home/${USER}/phytec-secure/keys/hab/CSF1_1_sha256_2048_65537_v3_usr_key.pem"
HAB_CST_CSFK_CERT = "/home/${USER}/phytec-secure/keys/hab/crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem"
HAB_CST_IMG_KEY = "/home/${USER}/phytec-secure/keys/hab/IMG1_1_sha256_2048_65537_v3_usr_key.pem"
HAB_CST_IMG_CERT = "/home/${USER}/phytec-secure/keys/hab/crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem"

# Image features:
EXTRA_IMAGE_FEATURES = "read-only-rootfs"
IMAGE_FEATURES:remove = "debug-tweaks allow-empty-password allow-root-login"

EOF

# Build phytec-headless-image (with signing):
bitbake phytec-headless-image 2>&1 | tee build.log

# After build, check artifacts:
ls tmp/deploy/images/phyboard-pollux-imx8mp-3/
```

---

## Phase 5: Flash and Test (1 hour)

```bash
# Set phyBOARD to USB recovery mode (BOOT_MODE pins = 01)
# Connect USB OTG cable

# Check device is in SDP mode:
lsusb | grep NXP

# Flash via UUU:
cd tmp/deploy/images/phyboard-pollux-imx8mp-3/

uuu -b emmc_all \
    imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk-signed \
    phytec-headless-image-phyboard-pollux-imx8mp-3.wic.gz

# Set BOOT_MODE back to eMMC (BOOT_MODE[1:0] = 10)
# Power cycle

# Connect UART and observe boot:
# Expected:
# HAB Configuration: 0x00 HAB State: 0x00
# No HAB Events Found!   ← OPEN mode, signed correctly
```

---

## Phase 6: Program SRK Fuses and Close Device

**WARNING: This is irreversible in practice. For lab, use a dedicated lab board.**

```
U-Boot> fuse read 3 0 8
# All zeros — fuses clear

# Program SRK fuses (use YOUR values from Phase 3):
U-Boot> fuse prog -y 3 0 0x<WORD0>
U-Boot> fuse prog -y 3 1 0x<WORD1>
# ... continue for words 2-7

# Verify:
U-Boot> fuse read 3 0 8
# Should match your computed values

# Close device:
U-Boot> fuse prog -y 1 3 0x2

# Power cycle — verify CLOSED:
# HAB Configuration: 0x02 HAB State: 0x66
# No HAB Events Found!
```

---

## Validation Checklist

```
[ ] U-Boot shows HAB Configuration: 0x02 (CLOSED)
[ ] No HAB Events Found in hab_status
[ ] FIT image loads with "Verified OK"
[ ] dm-verity active: dmsetup status shows verity device
[ ] Rootfs is read-only: touch /test fails
[ ] OP-TEE responds: tee-supplicant check
[ ] Unsigned firmware fails to boot: verify by trying
```

---

## Cross-References

- [../16-phytec-securiphy/01-securiphy-build.md](../../16-phytec-securiphy/01-securiphy-build.md) — Production build
- [../16-phytec-securiphy/02-securiphy-provisioning.md](../../16-phytec-securiphy/02-securiphy-provisioning.md) — Production provisioning
- [../11-key-management/02-srk-fuse-programming.md](../../11-key-management/02-srk-fuse-programming.md) — Fuse programming reference
