# Build Artifact Reference: Secure Boot Yocto Build

```
Platform: phyCORE-i.MX8MP (phyboard-pollux-imx8mp-3)
Yocto Release: Scarthgap (5.0.x)
Deploy directory: tmp/deploy/images/phyboard-pollux-imx8mp-3/
```

---

## Overview

After a successful `bitbake phytec-securiphy-image` (or equivalent image target), the deploy directory contains all artifacts needed to flash and verify a secure-boot-enabled system. This document provides a complete reference to each artifact, its purpose, how it was produced, and how to verify its integrity and signing status.

Understanding the artifact set is essential for:
- Verifying that signing succeeded before flashing
- Diagnosing build failures by identifying which artifact is missing or wrong
- Building HSM-integration workflows that pick up specific files for external signing
- Scripting release validation pipelines

---

## Deploy Directory Contents

```
tmp/deploy/images/phyboard-pollux-imx8mp-3/
│
│ ═══ COMBINED BOOT IMAGES (flash to eMMC/SD at 33KB offset) ═══════
├── imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk
│     Combined HABv4 bootable image for SD/eMMC.
│     Contents: SPL + DDR firmware + TF-A BL31 + OP-TEE + U-Boot
│     Note: NOT HAB-signed by Yocto. HAB signing is a post-build step.
│     Size: typically 1.5–3 MB
│
├── imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk_flexspi
│     Same content but assembled at FlexSPI NOR flash offsets.
│     Used for booting from SPI NOR instead of eMMC/SD.
│
│ ═══ SIGNED FIT IMAGE (flash to boot partition as /boot/fitImage) ══
├── fitImage
│     Signed FIT image containing: kernel + DTB(s) [+ initramfs].
│     THIS is the security-critical artifact for kernel verification.
│     Produced by: kernel-fitimage.bbclass do_uboot_assemble_fitimage
│     Signed with: ${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.pem
│
├── fitImage-6.6.36-phyboard-pollux-imx8mp-3.bin
│     Versioned copy of fitImage (same file, different name).
│     Symlink target or hard copy depending on Yocto version.
│
│ ═══ FIT IMAGE SOURCE ═══════════════════════════════════════════════
├── fitImage-its-6.6.36-phyboard-pollux-imx8mp-3.its
│     ITS (Image Tree Source) file used to generate fitImage.
│     Contains: exact image paths, load addresses, hash algorithms,
│               signature node configuration, key name hint.
│     Useful for debugging signing issues; verify this before building.
│
│ ═══ KERNEL BINARY AND DEVICE TREES ════════════════════════════════
├── Image--6.6.36-phyboard-pollux-imx8mp-3.bin
│     Raw arm64 kernel binary (before FIT wrapping).
│     Not used directly in secure boot — embedded in fitImage.
│     Useful for debugging kernel issues outside of FIT.
│
├── imx8mp-phycore-som-pd22.1.0.dtb
│     Primary SOM device tree blob.
│     Embedded in fitImage as fdt-1 node.
│     Also used standalone if booting without FIT (development only).
│
├── imx8mp-phyboard-pollux-rdk.dtb
│     Kit variant device tree blob.
│     Embedded in fitImage as fdt-2 node (conf-2 configuration).
│
│ ═══ U-BOOT ARTIFACTS ═══════════════════════════════════════════════
├── u-boot-phyboard-pollux-imx8mp-3.bin
│     Complete U-Boot binary (SPL + proper), used as build input.
│     Included inside imx-boot combined image.
│
├── u-boot-nodtb-phyboard-pollux-imx8mp-3.bin
│     U-Boot without embedded DTB. Combined with u-boot.dtb by
│     imx-mkimage to produce the final U-Boot image.
│
├── u-boot.dtb
│     U-Boot device tree. After signing step, contains embedded
│     FIT signing public key node (the key U-Boot uses to verify
│     fitImage at runtime).
│     SECURITY CRITICAL: must match the private key used to sign fitImage.
│
├── u-boot-spl.bin
│     SPL (Secondary Program Loader) binary.
│     First stage loaded by ROM after HABv4 authentication.
│     Authenticated by HABv4 (ROM→SPL is the HABv4-secured boundary).
│
│ ═══ TF-A AND OP-TEE ═════════════════════════════════════════════════
├── bl31.bin → bl31-imx8mp.bin
│     TF-A BL31 (EL3 secure monitor). Provides:
│     - PSCI (power management) for Linux
│     - Secure World entry point
│     - SMC routing between Normal World (U-Boot/Linux) and Secure World
│     Embedded in imx-boot combined image. NOT separately HABv4-signed.
│
├── bl31-imx8mp.bin
│     Platform-specific TF-A binary (i.MX8MP variant).
│
├── tee.bin
│     OP-TEE OS binary (BL32 in TF-A terminology).
│     Runs in TrustZone Secure World.
│     Loaded and authenticated by TF-A BL31.
│     Embedded in imx-boot combined image.
│     Size: typically 500 KB – 2 MB depending on OP-TEE configuration.
│
│ ═══ ROOT FILESYSTEM IMAGES ═════════════════════════════════════════
├── phytec-securiphy-image-phyboard-pollux-imx8mp-3.wic.gz
│     Full disk image (gzip-compressed WIC format).
│     Contains MBR + boot partition + rootfs partition.
│     Flash with: bmaptool copy *.wic.gz /dev/sdX
│
├── phytec-securiphy-image-phyboard-pollux-imx8mp-3.wic.bmap
│     Block map file for bmaptool.
│     Enables sparse-write flashing (only writes non-empty blocks).
│     Reduces flash time by 50–80% on typical rootfs images.
│
├── phytec-securiphy-image-phyboard-pollux-imx8mp-3.ext4
│     Raw ext4 rootfs partition image.
│     Input for dm-verity hash tree generation (post-build step).
│
│ ═══ KERNEL MODULE PACKAGE ══════════════════════════════════════════
├── modules--6.6.36-phyboard-pollux-imx8mp-3.tgz
│     Tarball of all kernel modules.
│     If CONFIG_MODULE_SIG_FORCE=y in kernel, modules are signed.
│     Module signing key is separate from FIT signing key.
│
│ ═══ SIGNING ARTIFACTS (if HAB post-signing done) ═══════════════════
│   [These are produced by the external HAB signing workflow, not Yocto]
├── imx-boot-...-signed  (NOT produced by Yocto)
│     HABv4-signed version of imx-boot-*-flash_evk.
│     Produced by: cst --i csf_spl.txt && cst --i csf_uboot.txt
│     Must be re-signed whenever imx-boot changes.
│
└── [Other symlinks and manifest files...]
    ├── fitImage → fitImage-6.6.36-phyboard-pollux-imx8mp-3.bin
    ├── Image → Image--6.6.36-phyboard-pollux-imx8mp-3.bin
    ├── u-boot.dtb → u-boot-phyboard-pollux-imx8mp-3.dtb
    └── phytec-securiphy-image-phyboard-pollux-imx8mp-3.manifest
          Package list with versions (useful for SBOM generation)
```

---

## Artifact Verification Commands

### fitImage: Verify Structure and Signing

```bash
DEPLOY=tmp/deploy/images/phyboard-pollux-imx8mp-3
FIT=${DEPLOY}/fitImage

# 1. Verify FIT image structure
dumpimage -l ${FIT}
# Expected output sections:
# - Image 0 (kernel-1): Type=Kernel, Hash algo=sha256, Hash value=<32 hex bytes>
# - Image 1 (fdt-1): Type=flat_dt, Hash algo=sha256, Hash value=<32 hex bytes>
# - Configuration 0 (conf-1): Sign algo=sha256,rsa2048:fit-signing-key, Required=yes

# 2. Verify signing algorithm is present (fail = unsigned)
dumpimage -l ${FIT} | grep "Sign algo"
# Expected: "Sign algo: sha256,rsa2048:fit-signing-key"
# If missing: UBOOT_SIGN_ENABLE was "0" or signing failed silently

# 3. Verify "Required: yes" is set (fail = signing not enforced)
dumpimage -l ${FIT} | grep "Required"
# Expected: "Required:     yes"
# If "no" or absent: -r flag was not passed to mkimage; U-Boot will not enforce verification

# 4. Verify hash values are non-zero
dumpimage -l ${FIT} | grep "Hash value"
# Hashes should be 64-character hex strings (SHA-256)
# All zeros indicates mkimage failed to hash the image data

# 5. Verify signature value is non-zero
dumpimage -l ${FIT} | grep "Sign value"
# Should be a long hex string (512 chars for RSA-2048)
# All zeros or absent: signing key not found / signing failed

# 6. Extract and verify kernel hash manually
dumpimage -T flat_dt -p 0 -o /tmp/kernel-from-fit ${FIT}
sha256sum /tmp/kernel-from-fit
# Compare with the Hash value shown by dumpimage for Image 0
```

### u-boot.dtb: Verify Embedded Public Key

```bash
DEPLOY=tmp/deploy/images/phyboard-pollux-imx8mp-3

# Dump the U-Boot DTB and look for signature key node
fdtdump ${DEPLOY}/u-boot.dtb 2>/dev/null | grep -A 20 "signature"

# Expected output (key node present):
# signature {
#     fit-signing-key {
#         required = "conf";
#         algo = "sha256,rsa2048";
#         rsa,num-bits = <0x800>;       # 2048 bits
#         rsa,modulus = [aa bb cc ...]; # 256 bytes RSA modulus
#         rsa,exponent = [00 01 00 01]; # 65537
#         rsa,r-squared = [xx yy ...];
#         rsa,n0-inverse = <0x...>;
#     };
# };

# If the signature node is absent: uboot-sign.bbclass did not run
# or UBOOT_SIGN_ENABLE was "0" during U-Boot build

# Verify key name matches UBOOT_SIGN_KEYNAME
fdtdump ${DEPLOY}/u-boot.dtb 2>/dev/null | grep -B 2 -A 5 "fit-signing-key"

# Alternative: use fdtget for specific node queries
fdtget ${DEPLOY}/u-boot.dtb /signature/fit-signing-key algo
# Expected: sha256,rsa2048

fdtget ${DEPLOY}/u-boot.dtb /signature/fit-signing-key required
# Expected: conf
# "conf" means: require verified configuration node (the FIT configuration)
# "image" would require individual image verification
```

### imx-boot: Verify Structure

```bash
DEPLOY=tmp/deploy/images/phyboard-pollux-imx8mp-3
BOOT=${DEPLOY}/imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk

# Check file size (should be 2–4 MB)
wc -c ${BOOT}
ls -lh ${BOOT}

# Locate IVT (HABv4 Image Vector Table) offset
# For i.MX8MP SPL: IVT is at byte 0 of the SPL image within flash.bin
# The ROM reads flash.bin starting at offset 0x8000 (32 KB from media start)
# IVT tag is 0xD1 at offset 0 of the IVT structure

python3 << 'EOF'
data = open('${BOOT}', 'rb').read()
# Search for IVT tag 0xD1
for offset in range(0, min(len(data), 0x100000), 4):
    if data[offset] == 0xD1:
        # Check IVT format: tag=0xD1, length=0x2000 (little-endian at +1), version=0x43 at +3
        if data[offset+3] == 0x43:
            print(f"IVT found at offset 0x{offset:x}")
            entry = int.from_bytes(data[offset+4:offset+8], 'little')
            csf = int.from_bytes(data[offset+24:offset+28], 'little')
            print(f"  Entry point: 0x{entry:08x}")
            print(f"  CSF offset:  0x{csf:08x}")
EOF

# Note: An unsigned imx-boot has IVT with csf=0x00000000
# A HABv4-signed imx-boot has csf pointing to the CSF structure

# Check for HABv4 CSF presence (post-HAB-signing only)
python3 -c "
data = open('${BOOT}', 'rb').read()
csf_count = data.count(bytes([0xD4, 0x00, 0x00, 0x41]))
print(f'CSF header signatures found: {csf_count}')
print('(0 = unsigned, >0 = HABv4 signed)')
"
```

### TF-A and OP-TEE: Size Sanity Checks

```bash
DEPLOY=tmp/deploy/images/phyboard-pollux-imx8mp-3

# TF-A BL31 size
BL31_SIZE=$(wc -c < ${DEPLOY}/bl31.bin)
echo "bl31.bin: ${BL31_SIZE} bytes ($(( BL31_SIZE / 1024 )) KB)"
# Expected range: 100–250 KB
# Too small (<50KB) suggests incomplete build
# Too large (>500KB) suggests wrong binary or debug build

# OP-TEE size
TEE_SIZE=$(wc -c < ${DEPLOY}/tee.bin)
echo "tee.bin: ${TEE_SIZE} bytes ($(( TEE_SIZE / 1024 )) KB)"
# Expected range: 500 KB – 3 MB
# Varies by OP-TEE configuration (TA pre-loading, secure storage, crypto)

# U-Boot SPL size
SPL_SIZE=$(wc -c < ${DEPLOY}/u-boot-spl.bin)
echo "u-boot-spl.bin: ${SPL_SIZE} bytes ($(( SPL_SIZE / 1024 )) KB)"
# Expected: 100–300 KB
# ROM on i.MX8MP loads SPL to OCRAM; OCRAM size constrains SPL max size
# i.MX8MP OCRAM: 256 KB; SPL must fit with DDR training firmware

# DDR firmware (should be present in deploy for imx-boot assembly)
ls -lh ${DEPLOY}/lpddr4_*.bin
# Expected: 4 files, each 20–80 KB
```

### Root Filesystem: Verify Image

```bash
DEPLOY=tmp/deploy/images/phyboard-pollux-imx8mp-3
WIC=${DEPLOY}/phytec-securiphy-image-phyboard-pollux-imx8mp-3.wic.gz

# Verify bmap file exists (required for bmaptool)
ls -la ${WIC%.gz}.bmap

# Check compressed image size
ls -lh ${WIC}

# Decompress and inspect WIC layout (costly; ~30 seconds)
zcat ${WIC} | fdisk -l
# Expected: 2 partitions
# Partition 1: ~8 MB FAT32 (boot: fitImage, imx-boot)
# Partition 2: ~500 MB – 2 GB ext4 (rootfs)

# Verify ext4 filesystem
EXT4=${DEPLOY}/phytec-securiphy-image-phyboard-pollux-imx8mp-3.ext4
e2fsck -n ${EXT4}
# "clean" = healthy filesystem
# Errors suggest corrupted build output

# Check rootfs for debug-tweaks remnants (should be absent in production)
debugfs -R 'ls -l /etc' ${EXT4} 2>/dev/null | grep -E "motd|issue|shadow"
```

---

## Artifact Hash Manifest

Generate a signed manifest of all deployment artifacts for release tracking:

```bash
DEPLOY=tmp/deploy/images/phyboard-pollux-imx8mp-3
MANIFEST=/tmp/release-manifest-$(date +%Y%m%d).sha256

cd ${DEPLOY}

# Compute SHA-256 of all primary artifacts
sha256sum \
    fitImage \
    fitImage-its-*.its \
    imx-boot-*-flash_evk \
    u-boot.dtb \
    u-boot-spl.bin \
    bl31.bin \
    tee.bin \
    phytec-securiphy-image-*.wic.gz \
    phytec-securiphy-image-*.wic.bmap \
    2>/dev/null > ${MANIFEST}

echo "Manifest generated: ${MANIFEST}"
cat ${MANIFEST}

# Optionally sign the manifest with the FIT signing key
openssl dgst -sha256 -sign /secure/keys/fit/fit-signing-key.pem \
    -out ${MANIFEST}.sig ${MANIFEST}

# Verify manifest signature
openssl dgst -sha256 -verify \
    <(openssl x509 -pubkey -noout -in /secure/keys/fit/fit-signing-key.crt) \
    -signature ${MANIFEST}.sig \
    ${MANIFEST}
# Output: Verified OK
```

---

## Build Artifact Cross-Check

This script verifies consistency between the signing key embedded in `u-boot.dtb` and the key used to sign `fitImage`:

```bash
#!/bin/bash
# verify-key-consistency.sh
# Ensures u-boot.dtb and fitImage use the same signing key

DEPLOY="${1:-tmp/deploy/images/phyboard-pollux-imx8mp-3}"
KEYDIR="${2:-../../keys/fit}"
KEYNAME="${3:-fit-signing-key}"

echo "=== FIT Signing Key Consistency Check ==="

# Extract RSA modulus from signing certificate
CERT_MOD=$(openssl x509 -in "${KEYDIR}/${KEYNAME}.crt" -noout \
    -modulus 2>/dev/null | sed 's/Modulus=//')

if [ -z "${CERT_MOD}" ]; then
    echo "ERROR: Cannot read certificate from ${KEYDIR}/${KEYNAME}.crt"
    exit 1
fi

CERT_MOD_LOWER=$(echo "${CERT_MOD}" | tr '[:upper:]' '[:lower:]')

# Extract modulus from u-boot.dtb embedded key node
DTB_MOD=$(fdtget "${DEPLOY}/u-boot.dtb" \
    "/signature/${KEYNAME}" "rsa,modulus" 2>/dev/null | \
    tr ' ' '\n' | \
    awk 'NR>0{printf "%02x", "0x"$1}' 2>/dev/null)

if [ -z "${DTB_MOD}" ]; then
    echo "ERROR: No key node found in u-boot.dtb for key '${KEYNAME}'"
    echo "       U-Boot DTB does not contain embedded FIT public key"
    exit 1
fi

# Compare (first 64 hex chars = first 32 bytes of modulus)
CERT_PREFIX="${CERT_MOD_LOWER:0:64}"
DTB_PREFIX="${DTB_MOD:0:64}"

if [ "${CERT_PREFIX}" = "${DTB_PREFIX}" ]; then
    echo "OK: u-boot.dtb key matches certificate ${KEYNAME}.crt"
else
    echo "MISMATCH: Key in u-boot.dtb does not match ${KEYNAME}.crt"
    echo "  Certificate modulus prefix: ${CERT_PREFIX}"
    echo "  u-boot.dtb modulus prefix:  ${DTB_PREFIX}"
    echo "  This will cause FIT verification failure at runtime!"
    exit 1
fi

# Verify fitImage Sign algo matches expected key name
FIT_KEYNAME=$(dumpimage -l "${DEPLOY}/fitImage" 2>/dev/null | \
    grep "Sign algo" | grep -oP ':\K[a-zA-Z0-9_-]+$' | head -1)

if [ "${FIT_KEYNAME}" = "${KEYNAME}" ]; then
    echo "OK: fitImage signed with key name '${KEYNAME}'"
else
    echo "MISMATCH: fitImage key name '${FIT_KEYNAME}' != expected '${KEYNAME}'"
    exit 1
fi

echo "=== All checks passed ==="
```

---

## What to Flash Where

```
eMMC / SD Card Layout (phyboard-pollux-imx8mp-3):
═════════════════════════════════════════════════════════════
Offset          Size    Content                    Artifact
─────────────────────────────────────────────────────────────
0x000 (0 KB)    32 KB   MBR + partition table      [WIC provides this]
0x8000 (32 KB)  ~3 MB   HABv4 boot image           imx-boot-*-flash_evk
                         (SPL + DDR fw + BL31 +
                          OP-TEE + U-Boot)
─────────────────────────────────────────────────────────────
[ Partition 1: FAT32 boot partition, ~8 MB ]
  /boot/fitImage                                   fitImage
  /boot/imx-boot (optional copy)
─────────────────────────────────────────────────────────────
[ Partition 2: ext4 rootfs partition ]
  Linux root filesystem                            *.wic provides this
═════════════════════════════════════════════════════════════

Flash commands:
  # Full disk image:
  bmaptool copy phytec-securiphy-image-*.wic.gz /dev/mmcblk0

  # Boot image only (after OS is running):
  dd if=imx-boot-*-flash_evk of=/dev/mmcblk0 bs=1024 seek=32 conv=notrunc

  # FIT image only (update kernel):
  mount /dev/mmcblk0p1 /boot
  cp fitImage /boot/
  umount /boot
  # Then update dm-verity hash tree for rootfs if kernel modules changed
```
