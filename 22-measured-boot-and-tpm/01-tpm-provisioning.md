# TPM Provisioning and LUKS Key Sealing

## Overview

This guide covers provisioning a TPM 2.0 (hardware or fTPM), configuring PCR-based measurement, and sealing a LUKS2 disk encryption key to TPM PCR values. This ensures the encrypted data partition can only be unlocked if the exact expected firmware chain booted.

---

## OP-TEE fTPM Setup (i.MX8MP)

### Build OP-TEE with fTPM

```bash
# In Yocto local.conf:
MACHINE_FEATURES:append = " tpm2"
IMAGE_INSTALL:append = " optee-ftpm tpm2-tools tpm2-abrmd"

# OP-TEE build flags (in optee-os bbappend):
EXTRA_OEMAKE:append = " \
    CFG_RPMB_FS=y \
    CFG_RPMB_FS_DEV_ID=0 \
    CFG_CORE_TEEPROF_FS_DIR=y \
"

# fTPM TA build flags:
CFG_TPM_OPTEE=y
```

### Linux Kernel fTPM Driver

```bash
# Kconfig:
CONFIG_TCG_TPM=y
CONFIG_TCG_FTPM_TEE=y   # fTPM via TEE (OP-TEE)
CONFIG_TCG_TIS_CORE=y

# Device tree node (optional — fTPM auto-discovers via TEE):
# firmware {
#     optee { ... };
# };
```

### Verify fTPM is Working

```bash
# Check TPM device:
ls /dev/tpm*
# /dev/tpm0  /dev/tpmrm0

# Read PCR 0:
tpm2_pcrread sha256:0
# sha256:
#   0 : 0x0000000000000000000000000000000000000000000000000000000000000000
# (all zeros on fresh TPM — no measurements yet extended)

# Check TPM manufacturer info:
tpm2_getcap properties-fixed | grep -E "TPM2_PT_VENDOR|TPM2_PT_MANUFACTURER"
# TPMVendorID: 0x4f505445 ("OPTE")
```

---

## TPM Measurement During Boot

### TF-A Measurement (BL2)

TF-A BL2 measures each stage it loads:

```c
/* In TF-A: plat/imx/imx8mp/imx8mp_bl2_setup.c (conceptual) */

#include <drivers/measured_boot/tpm/tpm_measured_boot.h>

void bl2_plat_handle_post_image_load(unsigned int image_id)
{
    measured_boot_init_params_t params = {
        .pcr_index = 0,  /* PCR 0 for boot firmware */
    };

    /* Extend PCR with hash of loaded image */
    bl2_measured_boot_extend(image_id, &params);
}
```

### U-Boot Measurement

```c
/* U-Boot: lib/tpm-v2.c + cmd/tpm-v2.c */

/* Measure U-Boot itself at startup: */
CONFIG_MEASURED_BOOT=y
CONFIG_TPM=y
CONFIG_TPM2_FTPM_OPTEE=y  /* fTPM backend */

/* Measures to PCR 4:
   - U-Boot binary itself
   - Device tree
   - Command line */
```

### Checking PCR Values After Boot

```bash
# Read all PCRs after full boot:
tpm2_pcrread sha256

# sha256:
#   0 : 0x...  (TF-A, BL2 measurements)
#   1 : 0x...  (boot config)
#   4 : 0x...  (U-Boot)
#   5 : 0x...  (U-Boot env)
#   8 : 0x...  (kernel / fitImage)
#   9 : 0x...  (initramfs)

# Save PCR values for golden reference:
tpm2_pcrread sha256 > /etc/tpm/golden-pcrs.txt
```

---

## LUKS2 Key Sealing to TPM

Sealing binds a secret (LUKS key) to a specific TPM state. The key can only be unsealed if the PCRs contain the exact same values as when the key was sealed.

### Step 1: Create LUKS2 Encrypted Data Partition

```bash
# Generate LUKS key (32 bytes random):
dd if=/dev/urandom of=/tmp/luks-key.bin bs=32 count=1

# Format partition with LUKS2:
cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 256 \
    --hash sha256 \
    --pbkdf argon2id \
    --key-file /tmp/luks-key.bin \
    /dev/mmcblk2p5

# Open with key:
cryptsetup luksOpen \
    --key-file /tmp/luks-key.bin \
    /dev/mmcblk2p5 \
    data

# Format and mount:
mkfs.ext4 -L data /dev/mapper/data
mount /dev/mapper/data /data

# Close temporarily:
cryptsetup luksClose data
```

### Step 2: Seal LUKS Key to TPM PCRs

```bash
# Create PCR policy (seal to PCRs 0, 4, 8 — TF-A, U-Boot, kernel)
tpm2_createpolicy \
    --policy-pcr \
    -l sha256:0,4,8 \
    -L /tmp/pcr-policy.bin

# Create primary key in TPM owner hierarchy:
tpm2_createprimary \
    -C o \
    -g sha256 \
    -G rsa \
    -c /tmp/primary.ctx

# Seal the LUKS key under the policy:
tpm2_create \
    -C /tmp/primary.ctx \
    -g sha256 \
    -u /tmp/sealed.pub \
    -r /tmp/sealed.priv \
    -L /tmp/pcr-policy.bin \
    -i /tmp/luks-key.bin

# Load the sealed object:
tpm2_load \
    -C /tmp/primary.ctx \
    -u /tmp/sealed.pub \
    -r /tmp/sealed.priv \
    -c /tmp/sealed.ctx

# Persist the sealed object to NV storage:
tpm2_evictcontrol \
    -C o \
    -c /tmp/sealed.ctx \
    0x81000001

echo "LUKS key sealed to TPM PCRs 0, 4, 8"

# Delete plaintext key:
shred -vuz /tmp/luks-key.bin
```

### Step 3: Unseal at Boot (initramfs/systemd)

```bash
#!/bin/bash
# /usr/lib/initramfs-tools/scripts/local-top/tpm-unlock

# Run from initramfs to unlock data partition

# Step 1: Verify PCRs match (they should if boot chain is unchanged)
tpm2_pcrread sha256:0,4,8 -o /tmp/current-pcrs.bin

# Step 2: Unseal LUKS key from TPM
tpm2_unseal \
    -c 0x81000001 \
    -p pcr:sha256:0,4,8 \
    -o /tmp/unsealed-key.bin

if [ $? -ne 0 ]; then
    echo "ERROR: TPM unseal failed — PCR mismatch or TPM error"
    echo "Boot chain may have been tampered with!"
    # Recovery: fall back to passphrase entry
    cryptsetup luksOpen /dev/mmcblk2p5 data
    exit 1
fi

# Step 3: Open LUKS partition with unsealed key
cryptsetup luksOpen \
    --key-file /tmp/unsealed-key.bin \
    /dev/mmcblk2p5 \
    data

# Step 4: Securely delete the key from RAM
shred -vuz /tmp/unsealed-key.bin

echo "Data partition unlocked via TPM"
```

---

## Remote Attestation

Allows a server to verify what software is running on a device:

```bash
# Device generates attestation quote:
tpm2_createak \
    -C 0x81000001 \
    -c /tmp/ak.ctx \
    -u /tmp/ak.pub \
    -r /tmp/ak.priv

# Create quote over PCRs 0-9:
tpm2_quote \
    -c /tmp/ak.ctx \
    -l sha256:0,1,2,3,4,5,6,7,8,9 \
    -q "$(openssl rand -hex 20)" \  # Nonce from attestation server
    -m /tmp/quote.msg \
    -s /tmp/quote.sig \
    -o /tmp/pcr-values.bin

# Send quote + sig to attestation server
# Server verifies:
#   1. AK public key matches registered device
#   2. Signature is valid over PCR values
#   3. PCR values match expected golden state
#   4. Nonce is fresh (prevents replay)
```

---

## systemd-cryptenroll Integration

systemd 248+ supports TPM2 enrollment directly:

```bash
# Enroll TPM2 key for LUKS2 (systemd-cryptenroll):
systemd-cryptenroll \
    --tpm2-device=auto \
    --tpm2-pcrs=0+4+8 \
    /dev/mmcblk2p5

# /etc/crypttab:
data  /dev/mmcblk2p5  -  tpm2-device=auto,tpm2-pcrs=0+4+8

# systemd will call systemd-cryptsetup at boot, which uses the TPM
# to unseal and unlock the partition automatically.
```

---

## Cross-References

- [../07-spl-tf-a-optee/03-optee-integration.md](../07-spl-tf-a-optee/03-optee-integration.md) — OP-TEE fTPM details
- [../21-verified-boot-and-dmverity/01-dmverity-setup.md](../21-verified-boot-and-dmverity/01-dmverity-setup.md) — dm-verity + TPM combination
- [../27-hardening/01-kernel-hardening.md](../27-hardening/01-kernel-hardening.md) — IMA measured boot
- [../03-root-of-trust/01-hardware-security-features-imx8mp.md](../03-root-of-trust/01-hardware-security-features-imx8mp.md) — CAAM as entropy source
