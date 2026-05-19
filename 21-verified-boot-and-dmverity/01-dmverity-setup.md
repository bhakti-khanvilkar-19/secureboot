# dm-verity Setup Guide

## Kernel Configuration

```bash
# Required kernel Kconfig options:
CONFIG_MD=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_VERITY=y
CONFIG_DM_VERITY_VERIFY_ROOTHASH_SIG=y  # Optional: kernel-level signature check
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_SHA256_ARM64=y            # Hardware-accelerated SHA-256

# For dm-verity panic on error (production):
CONFIG_DM_VERITY_HASH_PREFETCH_MIN_SIZE=1  # Pre-fetch hash blocks

# Yocto kernel config fragment:
# meta-your-layer/recipes-kernel/linux/linux-imx/imx8mp-verity.cfg
CONFIG_MD=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_VERITY=y
CONFIG_CRYPTO_SHA256=y
```

---

## Building a dm-verity Protected Rootfs

### Method 1: Yocto (Recommended)

```bash
# In local.conf:
INHERIT += "dm-verity-image"

# Variables:
DM_VERITY_IMAGE = "phytec-securiphy-image"
DM_VERITY_IMAGE_TYPE = "ext4"
DM_VERITY_MAX_RETRIES = "3"  # Retries before panic
```

The `dm-verity-image` bbclass:
1. Builds rootfs as normal ext4
2. Runs `veritysetup format` to generate hash tree
3. Outputs `.verity` (hash device) and `.verity-params` (root hash, salt)

### Method 2: Manual

```bash
# Create ext4 rootfs (must be read-only, no journal)
mkfs.ext4 -L rootfs -O "^has_journal" rootfs.ext4

# Populate rootfs...
# (mount, rsync, unmount)

# Generate dm-verity hash tree
veritysetup format \
    --data-block-size=4096 \
    --hash-block-size=4096 \
    --data-blocks=$(( $(stat --printf='%s' rootfs.ext4) / 4096 )) \
    rootfs.ext4 \
    rootfs.ext4.verity

# Output (save these!):
# VERITY header information for rootfs.ext4.verity
# UUID:            xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# Hash type:       1
# Data blocks:     524288
# Data block size: 4096
# Hash block size: 4096
# Hash algorithm:  sha256
# Salt:            aabbccdd...  ← 32 random bytes
# Root hash:       deadbeef...  ← 32 bytes = 64 hex chars

ROOT_HASH="deadbeef..."  # Save this
SALT="aabbccdd..."       # Save this
```

---

## Disk Layout for dm-verity

### Option A: Hash Tree on Separate Partition

```
mmcblk2p3: 2GB ext4 (data only)
mmcblk2p5: 64MB  (hash tree)

# Format:
veritysetup format mmcblk2p3 mmcblk2p5

# Activate at boot:
veritysetup create vroot /dev/mmcblk2p3 /dev/mmcblk2p5 <root-hash>
mount /dev/mapper/vroot / -o ro
```

### Option B: Hash Tree Appended to Data Device (Common for OTA)

```
# Hash tree immediately after data:
veritysetup format \
    --hash-offset=<data-size-bytes> \
    rootfs.ext4 rootfs.ext4  # Same file for data and hash

# Both use the same device — U-Boot passes device to kernel,
# kernel knows hash starts at data_block_count * 4096
```

---

## Embedding Root Hash in FIT Image

The root hash must be signed — otherwise an attacker can substitute the rootfs and provide a matching (fake) root hash.

```bash
# The root hash goes in the kernel bootargs, which are in the FIT config node,
# which is signed by the FIT key.

# Method 1: Embed in U-Boot default environment (compiled in)
# bootargs=... dm-verity.dev=/dev/mmcblk2p3 dm-verity.hash_dev=/dev/mmcblk2p3 \
#   dm-verity.data_blocks=524288 dm-verity.hash_offset=2147483648 \
#   dm-verity.root_hash=deadbeef... dm-verity.salt=aabbccdd... \
#   root=/dev/mapper/vroot rootwait ro

# Method 2: Hardcode in ITS bootargs:
# fitimage.its:
configurations {
    conf@1 {
        fdt-loadaddr = <0x43000000>;
        config {
            bootargs = "console=ttymxc1,115200 root=/dev/mapper/vroot ro \
                        systemd.verity=yes \
                        verity.data=/dev/mmcblk2p3 \
                        verity.hash=/dev/mmcblk2p3 \
                        verity.roothash=deadbeef... \
                        verity.hashoffset=2147483648";
        };
    };
};

# Method 3: systemd-veritysetup-generator (recommended for systemd images)
# Place root hash in /etc/veritytab or pass via kernel cmdline
# systemd.verity_root_hash=deadbeef...
```

---

## Kernel cmdline for dm-verity

```bash
# Complete production cmdline with dm-verity:
BOOTARGS="
console=ttymxc1,115200n8
root=/dev/mapper/vroot
rootfstype=ext4
rootwait
ro
quiet
dm-mod.create=\"vroot,,,ro,0 $(blockdev --getsz /dev/mmcblk2p3) verity 1 \
    /dev/mmcblk2p3 /dev/mmcblk2p3 4096 4096 $(( $(blockdev --getsz /dev/mmcblk2p3) / 8 )) \
    $(( $(blockdev --getsz /dev/mmcblk2p3) / 8 )) sha256 \
    ${ROOT_HASH} ${SALT}\"
panic=5
"

# Simpler form using systemd:
BOOTARGS="
console=ttymxc1,115200n8 rootwait ro quiet panic=5
systemd.verity=yes
rd.systemd.verity=yes
systemd.verity_root_hash=${ROOT_HASH}
systemd.verity_root_data=/dev/mmcblk2p3
systemd.verity_root_hash_sig=/etc/verity.sig  # Optional: kernel keyring sig
"
```

---

## Verifying dm-verity at Runtime

```bash
# Check dm-verity device is active:
dmsetup status vroot
# vroot: 0 4194304 verity V sha256 /dev/mmcblk2p3 /dev/mmcblk2p3 \
#   4096 4096 524288 524288 deadbeef... aabbccdd...

# Check rootfs is read-only:
mount | grep "on / "
# /dev/mapper/vroot on / type ext4 (ro,relatime)

# Attempt write (must fail):
touch /test_write
# touch: cannot touch '/test_write': Read-only file system

# Verify dm-verity statistics:
dmsetup table vroot
# 0 4194304 verity 1 8:18 8:18 4096 4096 524288 524288 sha256 \
#   deadbeef... aabbccdd... 1 ignore_corruption

# Check kernel messages for verity errors:
dmesg | grep "dm-verity"
# Expected: no errors
```

---

## dm-verity Error Handling

```bash
# Error behavior options:
# --error-behavior=ignore    → Log error, return I/O error to application
# --error-behavior=eio       → Return EIO (application sees I/O error)
# --error-behavior=panic     → Kernel panic immediately (production!)
# --error-behavior=restart   → Trigger emergency restart

# Production: use panic
veritysetup create vroot \
    /dev/mmcblk2p3 /dev/mmcblk2p3 \
    ${ROOT_HASH} \
    --hash-offset=${HASH_OFFSET} \
    --error-behavior=panic

# In dm table format:
# ... verity 1 ... 4096 4096 ... sha256 <hash> <salt> 2 \
#   panic_on_corruption ignore_zero_blocks
```

---

## OTA Update with dm-verity

When updating the rootfs, the hash tree must be regenerated:

```bash
# In SWUpdate post-install handler:
#!/bin/sh
# verity-update.sh

NEW_ROOTFS="/dev/mmcblk2p4"  # B slot

# 1. Rootfs already written by SWUpdate main handler

# 2. Generate new hash tree
veritysetup format \
    --data-block-size=4096 \
    --hash-block-size=4096 \
    "${NEW_ROOTFS}" \
    "${NEW_ROOTFS}"  # Hash appended to same device

# 3. Extract new root hash
NEW_ROOT_HASH=$(veritysetup dump "${NEW_ROOTFS}" | \
    grep "Root hash:" | awk '{print $3}')

# 4. Update U-Boot environment with new root hash
fw_setenv verity_root_hash_b "${NEW_ROOT_HASH}"

# 5. New FIT image (with updated bootargs) was already written
#    The root hash in the FIT bootargs must match what was generated above
#    → This is why root hash must be computed BEFORE signing the FIT image
echo "dm-verity update complete. New root hash: ${NEW_ROOT_HASH}"
```

**Key constraint**: The root hash embedded in the signed FIT image must be computed from the actual rootfs image that will be deployed. This means the signing pipeline must:
1. Build rootfs
2. Run veritysetup to get root hash
3. Build FIT image with root hash in bootargs
4. Sign FIT image

---

## Cross-References

- [../08-u-boot-secure-boot/02-uboot-configuration.md](../08-u-boot-secure-boot/02-uboot-configuration.md) — U-Boot bootargs with verity
- [../09-fit-images/01-its-file-format.md](../09-fit-images/01-its-file-format.md) — Bootargs in ITS
- [../20-secure-updates/01-swupdate-integration.md](../20-secure-updates/01-swupdate-integration.md) — SWUpdate + verity OTA
- [../14-yocto-secure-boot/03-build-artifacts.md](../14-yocto-secure-boot/03-build-artifacts.md) — Yocto verity artifacts
