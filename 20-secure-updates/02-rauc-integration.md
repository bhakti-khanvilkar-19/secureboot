# RAUC Integration

## Overview

RAUC (Robust Auto-Update Controller) is a robust update client for embedded Linux systems. It uses a slot-based A/B update model with CMS-signed update bundles and strong integration with U-Boot via the bootchooser framework.

**Repository:** `https://github.com/rauc/rauc`
**Documentation:** `https://rauc.readthedocs.io`

---

## Yocto Integration

```bash
# meta-rauc layer required:
# git clone https://github.com/rauc/meta-rauc

# In bblayers.conf:
BBLAYERS += "${TOPDIR}/../meta-rauc"

# In local.conf:
IMAGE_INSTALL:append = " rauc"
RAUC_KEYRING_FILE = "${TOPDIR}/../keys/rauc/rauc-ca.pem"
```

---

## System Configuration: system.conf

```ini
# /etc/rauc/system.conf
# Deployed with the image — describes the slot layout

[system]
compatible=phyboard-pollux-imx8mp
bootloader=uboot
bundle-formats=verity

[keyring]
path=/etc/rauc/keyring.pem
check-crl=true

[slot.boot.0]
device=/dev/mmcblk2p1
type=raw
bootname=A

[slot.boot.1]
device=/dev/mmcblk2p2
type=raw
bootname=B

[slot.rootfs.0]
device=/dev/mmcblk2p3
type=ext4
bootname=A
parent=boot.0

[slot.rootfs.1]
device=/dev/mmcblk2p4
type=ext4
bootname=B
parent=boot.1
```

---

## Bundle Creation

### Manifest (bundle.raucm)

```ini
[update]
compatible=phyboard-pollux-imx8mp
version=2.1.0
description=Production Firmware Update 2024-Q1
build=$(date -Iseconds)

[bundle]
format=verity

[image.boot]
filename=imx-boot-signed.bin
sha256=abc123...
size=4194304

[image.rootfs]
filename=rootfs.ext4
sha256=def456...
size=2147483648
```

### Build and Sign Bundle

```bash
#!/bin/bash
# create-rauc-bundle.sh

VERSION="2.1.0"
BUNDLE_DIR="./bundle-${VERSION}"
OUTPUT="./phyboard-pollux-imx8mp-${VERSION}.raucb"
KEY="keys/rauc/rauc-signing-key.pem"
CERT="keys/rauc/rauc-signing-cert.pem"
KEYRING="keys/rauc/rauc-ca.pem"

mkdir -p "$BUNDLE_DIR"

# Copy artifacts
cp artifacts/imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk-signed \
   "${BUNDLE_DIR}/imx-boot-signed.bin"
cp artifacts/phytec-securiphy-image-phyboard-pollux-imx8mp-3.ext4 \
   "${BUNDLE_DIR}/rootfs.ext4"

# Create manifest
cat > "${BUNDLE_DIR}/bundle.raucm" << EOF
[update]
compatible=phyboard-pollux-imx8mp
version=${VERSION}
description=Production Update
build=$(date -Iseconds)

[image.boot]
filename=imx-boot-signed.bin

[image.rootfs]
filename=rootfs.ext4
EOF

# Build and sign bundle
rauc bundle \
    --cert="$CERT" \
    --key="$KEY" \
    --keyring="$KEYRING" \
    "$BUNDLE_DIR" \
    "$OUTPUT"

echo "Bundle created: $OUTPUT"

# Verify
rauc info --keyring="$KEYRING" "$OUTPUT"
```

---

## Key Generation for RAUC

```bash
# Create a CA for RAUC bundle signing
mkdir -p keys/rauc

# Root CA
openssl genrsa -out keys/rauc/rauc-ca-key.pem 4096
openssl req -new -x509 \
    -key keys/rauc/rauc-ca-key.pem \
    -out keys/rauc/rauc-ca.pem \
    -days 7300 \
    -subj "/CN=RAUC Root CA/O=Example Corp/C=DE"

# Signing certificate (signed by CA)
openssl genrsa -out keys/rauc/rauc-signing-key.pem 2048
openssl req -new \
    -key keys/rauc/rauc-signing-key.pem \
    -out keys/rauc/rauc-signing.csr \
    -subj "/CN=RAUC Signing/O=Example Corp/C=DE"
openssl x509 -req \
    -in keys/rauc/rauc-signing.csr \
    -CA keys/rauc/rauc-ca.pem \
    -CAkey keys/rauc/rauc-ca-key.pem \
    -CAcreateserial \
    -out keys/rauc/rauc-signing-cert.pem \
    -days 3650

# Verify chain
openssl verify -CAfile keys/rauc/rauc-ca.pem keys/rauc/rauc-signing-cert.pem
# keys/rauc/rauc-signing-cert.pem: OK
```

---

## U-Boot Bootchooser Integration

RAUC uses U-Boot's bootchooser framework for A/B slot management:

```bash
# U-Boot config requirements:
CONFIG_CMD_BOOTCOUNT=y
CONFIG_BOOTCOUNT_LIMIT=y
CONFIG_BOOTCOUNT_ENV=y
CONFIG_BOOT_RETRY_TIME=-1

# U-Boot environment variables set by RAUC:
# BOOT_ORDER=A B  (or B A)
# BOOT_A_LEFT=3   (retry counter)
# BOOT_B_LEFT=3

# Boot script using bootchooser:
bootcmd=run distro_bootcmd

distro_bootcmd= \
    for BOOT_PART in ${BOOT_ORDER}; do \
        if test "x${BOOT_${BOOT_PART}_LEFT}" = "x0"; then \
            continue; \
        fi; \
        setexpr BOOT_${BOOT_PART}_LEFT ${BOOT_${BOOT_PART}_LEFT} - 1; \
        saveenv; \
        run boot_${BOOT_PART}; \
    done
```

### RAUC Bootchooser Backend

```ini
# /etc/rauc/system.conf addition for bootchooser:

[system]
compatible=phyboard-pollux-imx8mp
bootloader=uboot

[handlers]
post-install=/usr/lib/rauc/post-install.sh

[slot.rootfs.0]
device=/dev/mmcblk2p3
type=ext4
bootname=A
# RAUC sets BOOT_A_LEFT after install
```

---

## RAUC Update Flow

```
Device (running A slot):
  1. RAUC service polls update server (hawkbit/custom)
  2. Download bundle to /tmp or data partition
  3. rauc install /path/to/bundle.raucb
     ├── Verify bundle signature against keyring
     ├── Check compatibility (hardware string must match)
     ├── Write imx-boot-signed.bin to /dev/mmcblk2boot1
     ├── Write rootfs.ext4 to /dev/mmcblk2p4 (B slot)
     ├── Update U-Boot env: BOOT_ORDER=B A, BOOT_B_LEFT=3
     └── Trigger reboot
  4. U-Boot boots slot B (BOOT_B_LEFT decrements on each attempt)
  5. If boot succeeds, service calls: rauc status mark-good
     → BOOT_B_LEFT reset to 3 (confirmed)
  6. If boot fails 3 times, bootchooser falls back to A slot
```

---

## Status and Verification

```bash
# Check RAUC status:
rauc status

# Expected output:
# === System Info ===
# Compatible:  phyboard-pollux-imx8mp
# Variant:
# Booted from: rootfs.0 (A)
#
# === Bootloader ===
# Activated: rootfs.0 (A)
#
# === Slot States ===
# [slot.boot.0] (/dev/mmcblk2p1)
#   bootname: A  state: booted
# [slot.boot.1] (/dev/mmcblk2p2)
#   bootname: B  state: inactive
# [slot.rootfs.0] (/dev/mmcblk2p3)
#   bootname: A  state: booted
# [slot.rootfs.1] (/dev/mmcblk2p4)
#   bootname: B  state: inactive

# Verify bundle without installing:
rauc info --keyring=/etc/rauc/keyring.pem ./bundle.raucb
```

---

## Cross-References

- [01-swupdate-integration.md](01-swupdate-integration.md) — SWUpdate alternative
- [03-anti-rollback.md](03-anti-rollback.md) — Anti-rollback
- [../21-verified-boot-and-dmverity/01-dmverity-setup.md](../21-verified-boot-and-dmverity/01-dmverity-setup.md) — dm-verity slot integration
