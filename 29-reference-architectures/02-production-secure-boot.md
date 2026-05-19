# Production Secure Boot Reference Architecture

## Architecture: HABv4 + FIT + dm-verity + OP-TEE + SWUpdate

This is the recommended production architecture for i.MX8MP deployments.

## Security Layer Stack

```
┌─────────────────────────────────────────────┐
│          APPLICATION LAYER                   │
│  (containerized or native, seccomp filters) │
├─────────────────────────────────────────────┤
│         FILESYSTEM LAYER (Layer 4)          │
│   dm-verity (rootfs) + overlayfs (data)     │
│   Read-only /  + tmpfs /tmp + ext4 /data    │
├─────────────────────────────────────────────┤
│          KERNEL LAYER (Layer 3)              │
│   Linux 6.6 hardened                        │
│   KASLR + NX + SMEP + SMAP                  │
│   IMA/EVM (optional)                        │
├─────────────────────────────────────────────┤
│        BOOTLOADER LAYER (Layer 2)           │
│   FIT image signing (RSA-2048+SHA-256)       │
│   U-Boot with embedded verification key     │
│   FIT covers: kernel + DTB + initramfs      │
├─────────────────────────────────────────────┤
│       SECURE WORLD LAYER (OP-TEE)           │
│   TF-A BL31 at EL3                          │
│   OP-TEE at EL1-S                           │
│   RPMB secure storage                       │
│   fTPM (optional)                           │
├─────────────────────────────────────────────┤
│          ROM LAYER (Layer 1)                │
│   HABv4 authentication                      │
│   SRK hash in OCOTP fuses                   │
│   SEC_CONFIG = CLOSED                        │
└─────────────────────────────────────────────┘
```

## Partition Layout

```
eMMC (8GB):
┌──────────────────────────────────────────────────────┐
│ Boot0 partition (4MB)                                 │
│   imx-boot-signed.bin (SPL+TF-A+OP-TEE+U-Boot)      │
│   HAB authenticated by ROM                           │
├──────────────────────────────────────────────────────┤
│ User area                                             │
│   p1: /boot     128MB FAT32  ← fitImage, signed      │
│   p2: rootfs-A  1.5GB ext4   ← dm-verity protected   │
│   p3: rootfs-B  1.5GB ext4   ← dm-verity protected   │
│   p4: hash-A    16MB  raw    ← verity hash tree       │
│   p5: hash-B    16MB  raw    ← verity hash tree       │
│   p6: /data     512MB ext4   ← persistent user data   │
│   p7: env       1MB   raw    ← U-Boot environment     │
└──────────────────────────────────────────────────────┘
```

## Complete Yocto Configuration

### local.conf

```bitbake
MACHINE = "phyboard-pollux-imx8mp-3"
DISTRO = "phytec-headless-distro"

# FIT signing
UBOOT_SIGN_ENABLE = "1"
UBOOT_SIGN_KEYDIR = "${TOPDIR}/../keys/fit"
UBOOT_SIGN_KEYNAME = "fit-production-key"
FIT_GENERATE_KEYS = "0"
FIT_SIGN_ALG = "rsa2048"
FIT_HASH_ALG = "sha256"
KERNEL_IMAGETYPE = "fitImage"
KERNEL_CLASSES = "kernel-fitimage"

# dm-verity
IMAGE_CLASSES += "dm-verity-img"

# OP-TEE
MACHINE_FEATURES:append = " optee"

# SWUpdate
IMAGE_INSTALL:append = " swupdate"

# Security hardening
IMAGE_FEATURES:remove = "debug-tweaks"
EXTRA_IMAGE_FEATURES = ""
DISTRO_FEATURES:append = " security"

# Kernel hardening
KERNEL_EXTRA_FEATURES:append = " features/security/security.scc"
```

### bblayers.conf additions

```bitbake
BBLAYERS += " \
  ${BSPDIR}/sources/meta-phytec \
  ${BSPDIR}/sources/meta-phytec-bsp \
  ${BSPDIR}/sources/meta-openembedded/meta-oe \
  ${BSPDIR}/sources/meta-openembedded/meta-python \
  ${BSPDIR}/sources/meta-openembedded/meta-networking \
  ${BSPDIR}/sources/meta-security \
  ${BSPDIR}/sources/meta-swupdate \
"
```

## Key Material Organization

```
keys/
├── hab/                          # HABv4 keys (offline, HSM-backed)
│   ├── crts/
│   │   ├── CA1_sha256_2048_65537_v3_ca_crt.pem
│   │   ├── SRK1_sha256_2048_65537_v3_usr_crt.pem
│   │   ├── SRK2_sha256_2048_65537_v3_usr_crt.pem
│   │   ├── SRK3_sha256_2048_65537_v3_usr_crt.pem
│   │   ├── SRK4_sha256_2048_65537_v3_usr_crt.pem
│   │   ├── CSF1_1_sha256_2048_65537_v3_usr_crt.pem
│   │   └── IMG1_1_sha256_2048_65537_v3_usr_crt.pem
│   ├── keys/
│   │   ├── CSF1_1_sha256_2048_65537_v3_usr_key.pem
│   │   └── IMG1_1_sha256_2048_65537_v3_usr_key.pem
│   └── SRK_1_2_3_4_table.bin
├── fit/                          # FIT signing keys (CI/CD accessible)
│   ├── fit-production-key.key    # RSA-2048 private key
│   └── fit-production-key.crt   # Self-signed certificate
└── swupdate/                     # SWUpdate signing keys
    ├── swupdate.key              # RSA-2048 private key
    └── swupdate.crt              # Certificate
```

## Build Pipeline

```
Developer Workstation                CI/CD Server               Signing Server (HSM)
        │                                 │                              │
        │  git push                       │                              │
        ├────────────────────────────────>│                              │
        │                                 │                              │
        │                          Build artifacts                       │
        │                          (unsigned)                            │
        │                                 │                              │
        │                                 │  Sign FIT image              │
        │                                 │─────────────────────────────>│
        │                                 │  fitImage-signed             │
        │                                 │<─────────────────────────────│
        │                                 │                              │
        │                                 │  Sign imx-boot (HAB)         │
        │                                 │─────────────────────────────>│
        │                                 │  imx-boot-signed.bin         │
        │                                 │<─────────────────────────────│
        │                                 │                              │
        │                         Sign SWUpdate pkg                      │
        │                                 │─────────────────────────────>│
        │                                 │  update.swu                  │
        │                                 │<─────────────────────────────│
        │                                 │                              │
        │           Signed artifacts      │                              │
        │<────────────────────────────────│                              │
```

## HABv4 Signing Procedure

```bash
# Step 1: Build unsigned imx-boot
bitbake imx-boot

# Step 2: Determine IVT offset and image size
IMX_BOOT=tmp/deploy/images/phyboard-pollux-imx8mp-3/imx-boot-phyboard-pollux-imx8mp-3.bin-sd

# Step 3: Create CSF for SPL
cat > spl.csf << 'EOF'
[Header]
    Version = 4.3
    Hash Algorithm = sha256
    Engine = CAAM
    Engine Configuration = 0
    Certificate Format = X509
    Signature Format = CMS

[Install SRK]
    File = "keys/hab/SRK_1_2_3_4_table.bin"
    Source index = 0

[Install CSFK]
    File = "keys/hab/crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate CSF]

[Install Key]
    Verification index = 0
    Target index = 2
    File = "keys/hab/crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate Data]
    Verification index = 2
    Blocks = 0x7E1000 0x000 0xDC000 "imx-boot-unsigned.bin"
EOF

# Step 4: Generate CSF binary
cst -o spl.csf.bin -i spl.csf

# Step 5: Append CSF to image
cat ${IMX_BOOT} spl.csf.bin > imx-boot-signed.bin
```

## FIT Image Signing

```bash
# Step 1: Generate RSA-2048 key pair
openssl genrsa -out keys/fit/fit-production-key.key 2048
openssl req -batch -new -x509 -key keys/fit/fit-production-key.key \
    -out keys/fit/fit-production-key.crt \
    -subj "/CN=FIT Production Signing Key"

# Step 2: Build fitImage (Yocto handles this when UBOOT_SIGN_ENABLE=1)
bitbake virtual/kernel

# Step 3: Verify signature
fit_check_sign -f tmp/deploy/images/phyboard-pollux-imx8mp-3/fitImage \
               -k keys/fit/fit-production-key.crt
```

## dm-verity Integration

```bash
# After building the rootfs image:
ROOTFS=tmp/deploy/images/phyboard-pollux-imx8mp-3/your-image-phyboard-pollux-imx8mp-3.ext4
HASH_IMG=rootfs-hash.img

# Create hash image (size = rootfs_size / 128 approximately)
dd if=/dev/zero of=${HASH_IMG} bs=1M count=16

# Format with verity
veritysetup format ${ROOTFS} ${HASH_IMG} > verity.env
source verity.env

# Root hash is embedded in U-Boot environment or signed FIT
echo "dm-verity root hash: ${ROOT_HASH}"
```

## U-Boot Environment for dm-verity

```
# /boot/uEnv.txt (or embedded in fitImage)
verity_dev=mmcblk2p2
verity_hash_dev=mmcblk2p4
verity_roothash=<ROOT_HASH_FROM_BUILD>

# bootargs include:
# root=/dev/dm-0
# dm-mod.create="vroot,,,ro,0 <blocks> verity 1 /dev/mmcblk2p2 /dev/mmcblk2p4 4096 4096 <data_blocks> 1 sha256 <root_hash> <salt>"
```

## OP-TEE Secure Storage

```
OP-TEE provides:
├── RPMB (Replay Protected Memory Block) - eMMC secure storage
│   ├── Device keys (per-device unique)
│   ├── Encrypted application secrets
│   └── Secure rollback counters
├── Trusted Applications (TAs)
│   ├── Secure key storage TA
│   ├── Attestation TA
│   └── Crypto service TA
└── TEE-supplicant (Normal World daemon)
    └── Bridges OP-TEE <-> filesystem for storage
```

## SWUpdate Configuration

```bash
# /etc/swupdate.cfg
globals:
{
    verbose = true;
    loglevel = 5;
    no-downgrade = true;    # Rollback prevention
    no-reinstall = true;    # Prevent re-flashing same version
};

security:
{
    sigalg = "cms";
    postupdate = "/usr/bin/post-update.sh";
};

# /etc/swupdate/verify.pem - SWUpdate public key for CMS verification
```

## sw-description Example

```lua
software =
{
    version = "1.2.3";
    hardware-compatibility = ["1.0", "1.1", "2.0"];

    images: (
        {
            filename = "rootfs-A.ext4.verity";
            type = "raw";
            device = "/dev/mmcblk2p2";
            sha256 = "<SHA256_OF_IMAGE>";
            encrypted = false;
        },
        {
            filename = "rootfs-A-hash.img";
            type = "raw";
            device = "/dev/mmcblk2p4";
            sha256 = "<SHA256_OF_HASH_IMAGE>";
        },
        {
            filename = "fitImage";
            type = "raw";
            device = "/dev/mmcblk2p1";
            path = "/boot/fitImage";
            sha256 = "<SHA256_OF_FITIMAGE>";
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

## Implementation Steps

### Step 1: Generate Keys (Offline, Once)

```bash
# HABv4 keys - use NXP CST hab4_pki_tree.sh
# FIT keys - use generate-fit-keys.sh
# SWUpdate keys - use openssl

# IMPORTANT: Store private keys in HSM or encrypted offline storage
# NEVER commit private keys to version control
```

### Step 2: Configure Yocto Build

```bash
source sources/poky/oe-init-build-env build
# Edit conf/local.conf (see above)
# Edit conf/bblayers.conf (see above)
```

### Step 3: Build Images

```bash
bitbake phytec-headless-image
# Produces:
# - imx-boot-*.bin (unsigned)
# - fitImage (signed by Yocto)
# - *.ext4 + *.ext4.verity (with verity metadata)
```

### Step 4: Sign imx-boot with HABv4

```bash
scripts/signing/create-csf.sh \
    --image tmp/deploy/images/phyboard-pollux-imx8mp-3/imx-boot-*.bin \
    --keydir keys/hab \
    --output imx-boot-signed.bin
```

### Step 5: Validate in OPEN Mode

```bash
# Flash to device (still in OPEN mode)
uuu -b emmc_all imx-boot-signed.bin phytec-headless-image.wic

# Boot and check HAB status
# U-Boot: hab_status
# Linux: dmesg | grep -i hab
```

### Step 6: Provision Devices

```bash
# Program SRK fuses
scripts/provisioning/program-srk-fuses.sh \
    --device /dev/ttyUSB0 \
    --srk-fuse-file keys/hab/SRK_1_2_3_4_fuse.bin

# Close device (IRREVERSIBLE)
# scripts/provisioning/close-device.sh
```

### Step 7: Close Devices

```bash
# Program SEC_CONFIG fuse to CLOSED (0x2)
# This PERMANENTLY locks the device to your SRK
# VALIDATE EVERYTHING BEFORE THIS STEP
```

## Security Properties

| Property | Mechanism | Verification Method |
|----------|-----------|---------------------|
| Firmware authenticity | HABv4 RSA-2048 | `hab_status` in U-Boot |
| Bootloader authenticity | HABv4 RSA-2048 | `hab_status` in U-Boot |
| Kernel authenticity | FIT RSA-2048 | U-Boot boot verbose output |
| DTB authenticity | FIT RSA-2048 | U-Boot boot verbose output |
| Rootfs integrity | dm-verity SHA-256 | `dmesg \| grep verity` |
| Secure key storage | OP-TEE + RPMB | `tee-supplicant` status |
| OTA authenticity | SWUpdate CMS/RSA | `swupdate -v` |
| Rollback prevention | SWUpdate version check | `swupdate -l` |
| Debug port lockout | JTAG fuse | Physical inspection |
| Console lockout | U-Boot password | Boot log |

## Threat Coverage

| Threat | Mitigation | Coverage |
|--------|-----------|---------|
| Malicious firmware flashing | HABv4 + fuse closure | ROM-level enforcement |
| Modified kernel/DTB | FIT signing | U-Boot enforces |
| Rootfs tampering | dm-verity | Kernel blocks corrupted reads |
| Malicious OTA | SWUpdate CMS | Signature verified before flash |
| Rollback to vulnerable version | SWUpdate no-downgrade | Policy + rollback counters |
| Key extraction via JTAG | JTAG fuse + TrustZone | Hardware isolation |
| Cold boot attack | Encrypted RPMB | OP-TEE RPMB binding |
| Physical rootfs modification | dm-verity | Hash tree verification |

## Boot Time Analysis

| Stage | Component | Typical Time |
|-------|-----------|-------------|
| ROM | HAB authentication | ~50ms |
| SPL | DDR init + TF-A load | ~300ms |
| TF-A | BL31 init | ~50ms |
| OP-TEE | Secure world init | ~200ms |
| U-Boot | FIT verification + load | ~500ms |
| Kernel | Boot + dm-verity init | ~2-4s |
| Userspace | First process | ~1-2s |
| **Total** | | **~4-7 seconds** |

## Compliance Checklist

- [ ] All keys generated offline in air-gapped environment
- [ ] SRK private keys stored in HSM (FIPS 140-2 Level 3+)
- [ ] SRK fuse backup stored in secure physical location
- [ ] HAB CLOSED fuse set on all production units
- [ ] JTAG disable fuse set on all production units
- [ ] FIT signing keys rotatable without reflashing SRK
- [ ] dm-verity enabled on rootfs partition
- [ ] SWUpdate configured with CMS signature verification
- [ ] OP-TEE RPMB provisioned per device
- [ ] Console disabled or password-protected in production
- [ ] Security policy documented and approved
- [ ] Incident response procedure defined for key compromise
