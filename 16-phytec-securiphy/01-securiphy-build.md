# securiPHY Build Guide

## Build Environment Setup

```bash
# Clone all required repositories
mkdir phytec-secure && cd phytec-secure

# Poky
git clone git://git.yoctoproject.org/poky -b kirkstone

# meta-openembedded
git clone https://github.com/openembedded/meta-openembedded -b kirkstone

# meta-imx (NXP BSP)
git clone https://github.com/nxp-imx/meta-imx -b lf-6.6.y

# meta-phytec (PHYTEC BSP)
git clone https://github.com/phytec/meta-phytec -b kirkstone

# meta-ampliphy (PHYTEC distro)
git clone https://github.com/phytec/meta-ampliphy -b kirkstone

# meta-security (dm-verity, IMA)
git clone https://git.yoctoproject.org/meta-security -b kirkstone

# Initialize build environment
source poky/oe-init-build-env build-securiphy
```

---

## bblayers.conf

```bash
# build-securiphy/conf/bblayers.conf

BBLAYERS ?= " \
  ${TOPDIR}/../poky/meta \
  ${TOPDIR}/../poky/meta-poky \
  ${TOPDIR}/../meta-openembedded/meta-oe \
  ${TOPDIR}/../meta-openembedded/meta-python \
  ${TOPDIR}/../meta-openembedded/meta-networking \
  ${TOPDIR}/../meta-openembedded/meta-filesystems \
  ${TOPDIR}/../meta-security \
  ${TOPDIR}/../meta-imx/meta-imx \
  ${TOPDIR}/../meta-imx/meta-sdk \
  ${TOPDIR}/../meta-phytec \
  ${TOPDIR}/../meta-ampliphy \
"
```

---

## local.conf (securiPHY Production)

```bash
# build-securiphy/conf/local.conf

MACHINE = "phyboard-pollux-imx8mp-3"
DISTRO = "ampliphy-headless"
PACKAGE_CLASSES = "package_ipk"

# === FIT Image Signing ===
UBOOT_SIGN_ENABLE = "1"
UBOOT_SIGN_KEYDIR = "${TOPDIR}/../keys/fit"
UBOOT_SIGN_KEYNAME = "phytec-fit-key"
UBOOT_DTB_BINARY = "imx8mp-phyboard-pollux-rdk-4.dtb"
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 2000"

# === HABv4 Signing ===
HAB_ENABLE = "1"
HAB_SRK_TABLE = "${TOPDIR}/../keys/hab/SRK_1_2_3_4_table.bin"
HAB_SRK_INDEX = "0"
HAB_CST_KEY = "${TOPDIR}/../keys/hab/CSF1_1_sha256_2048_65537_v3_usr_key.pem"
HAB_CST_CSFK_CERT = "${TOPDIR}/../keys/hab/crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem"
HAB_CST_IMG_KEY = "${TOPDIR}/../keys/hab/IMG1_1_sha256_2048_65537_v3_usr_key.pem"
HAB_CST_IMG_CERT = "${TOPDIR}/../keys/hab/crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem"

# === dm-verity ===
INHERIT += "dm-verity-image"
DM_VERITY_IMAGE = "phytec-securiphy-image"
DM_VERITY_IMAGE_TYPE = "ext4"

# === SWUpdate Signing ===
SWUPDATE_SIGNING = "RSA"
SWUPDATE_SIGN_KEY = "${TOPDIR}/../keys/swupdate/swupdate-signing-key.pem"
SWUPDATE_SIGN_CERT = "${TOPDIR}/../keys/swupdate/swupdate-signing-cert.pem"

# === Image Features ===
EXTRA_IMAGE_FEATURES = "read-only-rootfs"
IMAGE_FEATURES:remove = "debug-tweaks allow-empty-password"

# === Image Types ===
IMAGE_FSTYPES = "ext4 wic.gz wic.bmap"
WKS_FILE = "phytec-securiphy.wks"

# === Build Performance ===
BB_NUMBER_THREADS = "8"
PARALLEL_MAKE = "-j8"

# === Shared state cache (optional) ===
SSTATE_DIR ?= "/var/cache/yocto/sstate"
DL_DIR ?= "/var/cache/yocto/downloads"
```

---

## Key Preparation

Before building, generate and place keys in expected locations:

```bash
# Create key directories
mkdir -p keys/fit keys/hab keys/swupdate

# FIT key (see 11-key-management/01-key-generation.md for full procedure)
openssl genrsa -out keys/fit/phytec-fit-key.pem 2048
openssl req -new -x509 \
    -key keys/fit/phytec-fit-key.pem \
    -out keys/fit/phytec-fit-key.crt \
    -days 3650 \
    -subj "/CN=phytec-fit-key/O=PHYTEC/C=DE"

# HABv4 keys: generate using NXP CST hab4_pki_tree.sh
# (air-gapped workstation required — see 11-key-management/01-key-generation.md)
# Then copy to keys/hab/

# SWUpdate key
openssl genrsa -out keys/swupdate/swupdate-signing-key.pem 2048
openssl req -new -x509 \
    -key keys/swupdate/swupdate-signing-key.pem \
    -out keys/swupdate/swupdate-signing-cert.pem \
    -days 3650 \
    -subj "/CN=SWUpdate Signing/O=PHYTEC/C=DE"

# Verify key tree
find keys/ -type f -name "*.pem" -o -name "*.crt" | sort
```

---

## Build Steps

```bash
cd build-securiphy

# Step 1: Build provisioning image first (fuse-free, for factory)
bitbake phytec-provisioning-image

# Step 2: Build production securiPHY image
bitbake phytec-securiphy-image

# Step 3: Build SWUpdate package for OTA
bitbake phytec-securiphy-image -c swupdate

# Artifacts appear in:
ls tmp/deploy/images/phyboard-pollux-imx8mp-3/
```

---

## Expected Deploy Artifacts

```
tmp/deploy/images/phyboard-pollux-imx8mp-3/
├── imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk          ← Unsigned
├── imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk-signed   ← HABv4 signed
├── fitImage                                                       ← FIT signed
├── imx8mp-phyboard-pollux-rdk-4.dtb                             ← With embedded pub key
├── phytec-securiphy-image-phyboard-pollux-imx8mp-3.ext4         ← Rootfs
├── phytec-securiphy-image-phyboard-pollux-imx8mp-3.verity       ← dm-verity hash tree
├── phytec-securiphy-image-phyboard-pollux-imx8mp-3.wic.gz       ← Full SD card image
├── phytec-securiphy-image-phyboard-pollux-imx8mp-3.wic.bmap
└── phytec-securiphy-image-phyboard-pollux-imx8mp-3.swu          ← SWUpdate package
```

---

## Build Verification

### Verify FIT Image is Signed

```bash
dumpimage -l tmp/deploy/images/phyboard-pollux-imx8mp-3/fitImage | \
    grep -E "Sign algo|Sign value"

# Expected:
# Sign algo:    sha256,rsa2048:phytec-fit-key
# Sign value:   <hash>
```

### Verify U-Boot DTB Has Embedded Key

```bash
fdtdump tmp/deploy/images/phyboard-pollux-imx8mp-3/imx8mp-phyboard-pollux-rdk-4.dtb | \
    grep -A10 "signature"

# Expected:
# signature {
#   key-phytec-fit-key {
#     required = "conf";
#     algo = "sha256,rsa2048";
#     rsa,num-bits = <0x800>;
#     ...
```

### Verify HABv4 CSF Appended

```bash
# Check signed image is larger than unsigned
UNSIGNED=$(stat --printf="%s" *-sd.bin-flash_evk)
SIGNED=$(stat --printf="%s" *-sd.bin-flash_evk-signed)
echo "Unsigned: $UNSIGNED, Signed: $SIGNED, CSF size: $((SIGNED - UNSIGNED))"
# Expected: CSF size ~4096-8192 bytes
```

### Verify dm-verity Hash Tree

```bash
veritysetup verify \
    tmp/deploy/images/phyboard-pollux-imx8mp-3/phytec-securiphy-image-*.ext4 \
    tmp/deploy/images/phyboard-pollux-imx8mp-3/phytec-securiphy-image-*.verity \
    <root-hash>

# Root hash is in phytec-securiphy-image-*.verity-params
cat tmp/deploy/images/phyboard-pollux-imx8mp-3/phytec-securiphy-image-*.verity-params
```

---

## Troubleshooting Common Build Issues

### CST Not Found

```
ERROR: Nothing PROVIDES 'nxp-cst-native'
```

Solution:
```bash
# meta-imx must be in bblayers.conf
# Check that meta-imx/meta-imx is included, not just meta-imx/meta-sdk

# Or install CST manually:
# 1. Download from NXP (requires NXP registration)
# 2. Install to /opt/cst/
# 3. Add to PATH in local.conf:
#    PATH:prepend = "/opt/cst/linux64/bin:"
```

### FIT Signing Fails at do_compile

```
Can't open key file 'keys/fit/phytec-fit-key.pem'
```

Check:
```bash
# Absolute path required — relative paths fail from bitbake work directory
# Ensure UBOOT_SIGN_KEYDIR is absolute

# In local.conf:
UBOOT_SIGN_KEYDIR = "${TOPDIR}/../keys/fit"
# ${TOPDIR} expands to your build directory (e.g., /home/user/phytec-secure/build-securiphy)
```

### dm-verity Image Too Large

```
ERROR: dm-verity: rootfs too large for hash tree
```

```bash
# Trim image:
IMAGE_OVERHEAD_FACTOR = "1.1"   # Reduce from default 1.3
IMAGE_ROOTFS_EXTRA_SPACE = "0"

# Or split data partition from rootfs
```

---

## Cross-References

- [02-securiphy-provisioning.md](02-securiphy-provisioning.md) — Factory provisioning workflow
- [../14-yocto-secure-boot/README.md](../14-yocto-secure-boot/README.md) — Yocto secure boot reference
- [../21-verified-boot-and-dmverity/01-dmverity-setup.md](../21-verified-boot-and-dmverity/01-dmverity-setup.md) — dm-verity details
