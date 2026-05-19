# SWUpdate Integration

## Overview

SWUpdate is an open-source framework for reliable, authenticated firmware updates on embedded Linux. It supports A/B partition updates, hardware-specific handlers, and CMS-based package signing.

**Repository:** `https://github.com/sbabic/swupdate`

---

## Yocto Integration

```bash
# local.conf additions for SWUpdate:

# Enable SWUpdate
IMAGE_INSTALL:append = " swupdate swupdate-www"

# Signing configuration
SWUPDATE_SIGNING = "RSA"
SWUPDATE_SIGN_KEY = "${TOPDIR}/../keys/swupdate/swupdate-signing-key.pem"
SWUPDATE_SIGN_CERT = "${TOPDIR}/../keys/swupdate/swupdate-signing-cert.pem"
SWUPDATE_VERIFY_CERT = "${TOPDIR}/../keys/swupdate/swupdate-signing-cert.pem"
```

### SWUpdate Configuration in Yocto

```bash
# meta-your-layer/recipes-support/swupdate/swupdate_%.bbappend

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = " \
    file://defconfig \
    file://swupdate.cfg \
"

# SWUpdate Kconfig
# defconfig:
CONFIG_SIGNED_IMAGES=y
CONFIG_SIGALG_CMS=y
CONFIG_SSL_IMPL_OPENSSL=y
CONFIG_CHANNEL_CURL=y
CONFIG_DOWNLOAD=y
CONFIG_SURICATTA=y
CONFIG_SURICATTA_HAWKBIT=y
CONFIG_MTD=n
CONFIG_UBOOT=y
CONFIG_BOOTLOADER_EBG=y
```

---

## sw-description Format (SWUpdate Manifest)

```lua
-- sw-description: SWUpdate manifest (Lua-based syntax)
software = {
    version = "2.1.0";
    description = "phyCORE-i.MX8MP Production Firmware Update";

    hardware-compatibility = ["1.0", "1.1", "2.0"];

    -- Images signed separately with FIT/HABv4
    -- Package itself signed with OTA key (via CMS)

    images: (
        {
            filename = "fitImage";
            type = "raw";
            device = "/dev/mmcblk2p1";  -- boot-a slot
            sha256 = "abc123...";       -- Verified by SWUpdate
            compressed = false;
        },
        {
            filename = "imx-boot-signed.bin";
            type = "raw";
            device = "/dev/mmcblk2boot0";
            sha256 = "def456...";
        }
    );

    partitions: (
        {
            filename = "rootfs.ext4.gz";
            device = "/dev/mmcblk2p3";  -- rootfs-a
            type = "raw";
            compressed = "zlib";
            sha256 = "789abc...";
        }
    );

    scripts: (
        {
            filename = "post-install.sh";
            type = "shellscript";
        }
    );
};
```

---

## Package Signing

### Generate SWUpdate Signing Key (One Time)

```bash
# On air-gapped signing workstation:
mkdir -p keys/swupdate

openssl genrsa -out keys/swupdate/swupdate-signing-key.pem 2048
openssl req -new -x509 \
    -key keys/swupdate/swupdate-signing-key.pem \
    -out keys/swupdate/swupdate-signing-cert.pem \
    -days 3650 \
    -subj "/CN=SWUpdate Signing/O=Example Corp/C=DE"

# Verify
openssl x509 -in keys/swupdate/swupdate-signing-cert.pem -text -noout | \
    grep -E "Subject:|Not After"
```

### Sign and Package

```bash
#!/bin/bash
# create-swu.sh — Create signed SWUpdate package

ARTIFACTS_DIR="./artifacts"
OUTPUT="./update-$(date +%Y%m%d-%H%M%S).swu"
SIGN_KEY="keys/swupdate/swupdate-signing-key.pem"
SIGN_CERT="keys/swupdate/swupdate-signing-cert.pem"
SW_DESC="${ARTIFACTS_DIR}/sw-description"

# Step 1: Compute SHA256 of each artifact
for f in "${ARTIFACTS_DIR}"/*; do
    [ -f "$f" ] || continue
    echo "$(basename $f): $(sha256sum $f | cut -d' ' -f1)"
done

# Step 2: Sign sw-description with CMS
openssl cms -sign \
    -in "$SW_DESC" \
    -out "${ARTIFACTS_DIR}/sw-description.sig" \
    -signer "$SIGN_CERT" \
    -inkey "$SIGN_KEY" \
    -outform DER \
    -nosmimecap \
    -binary

echo "sw-description signed"

# Step 3: Create CPIO package
# CRITICAL: sw-description and sw-description.sig MUST be first two files
(
    cd "$ARTIFACTS_DIR"
    echo "sw-description" > /tmp/file-list
    echo "sw-description.sig" >> /tmp/file-list
    ls | grep -v "^sw-description" >> /tmp/file-list

    cat /tmp/file-list | cpio -ovL -H newc > "${OUTPUT}"
)

echo "Package created: $OUTPUT ($(wc -c < "$OUTPUT") bytes)"

# Step 4: Verify package signature
swupdate -c -i "$OUTPUT"
echo "Package verification: $?"
```

---

## A/B Update with U-Boot libubootenv

### U-Boot Environment for A/B

```bash
# U-Boot default env (in board defconfig or env header):

CONFIG_ENV_SIZE=0x20000
CONFIG_ENV_OFFSET=0x400000
CONFIG_ENV_OFFSET_REDUND=0x420000  # Redundant copy

# Variables used by SWUpdate/libubootenv:
BOOT_ORDER=A B
BOOT_A_LEFT=3
BOOT_B_LEFT=3
BOOT_PART=A

# Boot script:
bootcmd=run boot_${BOOT_PART}
boot_A=setenv bootargs ${bootargs_base} root=/dev/mmcblk2p3 ...; \
       load mmc 2:1 ${fit_addr} fitImage; bootm ${fit_addr}
boot_B=setenv bootargs ${bootargs_base} root=/dev/mmcblk2p4 ...; \
       load mmc 2:2 ${fit_addr} fitImage; bootm ${fit_addr}
```

### libubootenv in SWUpdate

```lua
-- In sw-description, use uboot handler to update bootloader env:
scripts: (
    {
        type = "uboot";
        properties: (
            {
                name = "BOOT_ORDER";
                value = "B A";   -- Switch to B after this update
            }
        );
    }
);
```

---

## Suricatta: Hawkbit Integration

```ini
# /etc/swupdate/swupdate.cfg

globals :
{
    public-key-file = "/etc/swupdate/swupdate-signing-cert.pem";
    no-downgrade = true;
    no-reinstall = false;
};

suricatta :
{
    url = "https://hawkbit.example.com";
    tenant = "DEFAULT";
    id = "@DEVICE_SERIAL@";        # Populated at boot from OCOTP
    polldelay = 45;                # Seconds between polls
    retry = 5;
    retrywait = 30;
    loglevel = 3;
};
```

---

## Verification After Update

```bash
# After SWUpdate completes, verify new partition:

# Check new rootfs hash matches expected
NEW_SLOT_DEV="/dev/mmcblk2p4"  # B slot
ROOT_HASH=$(cat /etc/dm-verity-root-hash)
veritysetup verify "$NEW_SLOT_DEV" "${NEW_SLOT_DEV}-hash" "$ROOT_HASH"

# Trigger reboot into new slot (SWUpdate sets BOOT_ORDER=B A)
reboot

# After reboot, verify active slot:
fw_printenv BOOT_PART
# BOOT_PART=B

# Confirm dm-verity active on new slot:
dmsetup status
```

---

## Cross-References

- [02-rauc-integration.md](02-rauc-integration.md) — RAUC alternative
- [03-anti-rollback.md](03-anti-rollback.md) — Anti-rollback with OCOTP fuses
- [../10-image-signing/01-signing-workflows.md](../10-image-signing/01-signing-workflows.md) — Package signing
- [../21-verified-boot-and-dmverity/01-dmverity-setup.md](../21-verified-boot-and-dmverity/01-dmverity-setup.md) — dm-verity and OTA
