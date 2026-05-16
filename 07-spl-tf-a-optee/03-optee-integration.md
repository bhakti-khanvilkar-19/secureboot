# OP-TEE Integration Guide for i.MX8MP

```
Component: OP-TEE OS + OP-TEE Client
Version:   3.21.0
Platform:  imx-mx8mpevk (NXP i.MX8M Plus EVK / phyCORE-i.MX8MP)
Source:    https://github.com/OP-TEE/optee_os
```

---

## Overview

OP-TEE (Open Portable Trusted Execution Environment) is the secure world OS running in Secure
EL1 on i.MX8MP. It operates concurrently with Linux: while Linux handles normal world tasks,
OP-TEE handles cryptographic operations, secure key storage, and Trusted Application execution.

The two worlds communicate exclusively through the TF-A BL31 secure monitor — no direct path
between Linux and OP-TEE memory exists. This memory separation is enforced by hardware
(TrustZone + TZASC) and cannot be bypassed from software.

---

## Architecture: Two Components, Two Worlds

```
┌─────────────────────────────────────────────────────────────────┐
│  NORMAL WORLD (Non-Secure EL0/EL1)                             │
│                                                                 │
│  ┌─────────────────┐    ┌──────────────────────────────────┐   │
│  │  Application    │    │  tee-supplicant daemon           │   │
│  │  (uses libteec) │    │  - Loads TAs from /lib/optee_armtz│  │
│  │                 │    │  - RPMB access on behalf of OP-TEE│  │
│  └────────┬────────┘    │  - REE filesystem operations     │   │
│           │             └─────────────────┬────────────────┘   │
│           │ libteec.so                    │ /dev/teepriv0       │
│           ▼                               ▼                     │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  Linux kernel: optee driver (drivers/tee/optee/)       │    │
│  │  - /dev/tee0, /dev/teepriv0                            │    │
│  │  - Converts TEEC calls → SMC instructions              │    │
│  └────────────────────────────┬───────────────────────────┘   │
└────────────────────────────────┼────────────────────────────────┘
                                 │ SMC instruction
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  EL3: TF-A BL31 (Secure Monitor)                               │
│  - Routes SMC to opteed dispatcher                             │
│  - Saves/restores world context                                │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECURE WORLD (Secure EL0/EL1)                                 │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  OP-TEE Core (Secure EL1)                               │   │
│  │  - TEE core: TA scheduling, memory, IPC                 │   │
│  │  - Crypto: AES, RSA, ECDSA via CAAM                     │   │
│  │  - RPMB filesystem driver                               │   │
│  │  - Secure storage (encrypted, HMAC-authenticated)       │   │
│  └───────────┬─────────────────────────────────────────────┘   │
│              │ OP-TEE API                                       │
│  ┌───────────┴─────────────────────────────────────────────┐   │
│  │  Trusted Applications (Secure EL0)                      │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐  │   │
│  │  │  fTPM TA │ │ PKCS#11  │ │ SecStore │ │ Custom   │  │   │
│  │  │          │ │    TA    │ │    TA    │ │   TA     │  │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Trusted Applications: Storage and Loading

### TA Binary Location

Trusted Applications are ELF binaries signed with the OP-TEE TA signing key. They reside in the
normal world filesystem and are loaded on demand by `tee-supplicant`:

```
/lib/optee_armtz/
├── ffd2bded-ab7d-4988-95ee-e4962fff7154.ta   # PKCS#11 TA
├── 023f8f1a-292a-432b-8fc4-de8471358067.ta   # Secure Key TA
├── 7672348e-8dcd-11e6-aed5-3b2d2b6939b0.ta   # Trusted UI TA
└── <uuid>.ta                                  # Your custom TA
```

The filename is the TA's UUID in the format: `{8}-{4}-{4}-{4}-{12}`.

### TA Binary Format

A signed TA binary has this structure:

```
TA Binary Layout
───────────────────────────────────────
Offset   Content
──────────────────────────────────────
0x00     TA header (struct shdr)
         - magic: 0x4f545348 ("OTSH")
         - img_type: SHDR_TA (1) or SHDR_BOOTSTRAP_TA (2)
         - img_size: size of TA ELF binary
         - alg: TEE_ALG_RSASSA_PKCS1_V1_5_SHA256
         - hash_size: 32 (SHA-256)
         - sig_size: 256 (RSA-2048)
0x1C     SHA-256 hash (32 bytes)
0x3C     RSA-2048 signature (256 bytes)
0x13C    Encrypted header (struct shdr_encrypted_ta, optional)
         - enc_algo: TEE_ALG_AES_GCM (for encrypted TAs)
         - flags, iv, tag (for AES-GCM decryption)
<var>    TA ELF binary
```

### TA Signing

```bash
# Sign a Trusted Application
# The TA signing key is generated at OP-TEE build time
# Production: this key must be stored in HSM

python3 ${OPTEE_OS_DIR}/scripts/sign_encrypt.py \
    --key ta-signing-key.pem \
    --uuid $(cat ta.uuid) \
    --ta-version 1 \
    --in ta.elf \
    --out $(cat ta.uuid).ta

# Verify the signed TA
python3 ${OPTEE_OS_DIR}/scripts/sign_encrypt.py \
    --key ta-signing-key.pem \
    --verify \
    --in $(cat ta.uuid).ta
```

The TA signing key public component is compiled into `optee_os` via:
```bash
# In OP-TEE build:
CFG_TA_SIGN_KEY=path/to/ta-signing-key.pem
```

If a TA is signed with a different key than the one compiled into `optee_os`, loading the TA
will fail with `TEE_ERROR_SECURITY` in the tee-supplicant log.

---

## OP-TEE Secure Storage Backends

### Backend 1: REE Filesystem (CFG_REE_FS=y)

Files are stored encrypted on the normal world filesystem. OP-TEE uses AES-256-GCM with a key
derived from the HUK (Hardware Unique Key) to encrypt each file. A MAC tree (similar to a
Merkle tree) provides anti-rollback protection.

```
REE FS Storage Layout
──────────────────────
/data/tee/              (configurable via CFG_REE_FS_TA_QUOTA)
├── .teefs_db           # Encrypted storage index
└── <uuid>/
    └── <object_id>     # Encrypted storage object files

Encryption per object:
  key = HKDF(HUK, "REE-FS" || TA_UUID || object_id)
  encrypted = AES-256-GCM(key, iv, plaintext)
  stored = encrypted || iv || tag || mac_tree_node
```

**Security limitations of REE FS**:
- Stored files visible on the filesystem (though encrypted)
- Attacker with filesystem write access can delete objects (OP-TEE detects corruption)
- Not protected against rollback if the filesystem is rolled back (e.g., via OTA downgrade)
- Suitable for development; not recommended for high-security production deployments

### Backend 2: RPMB (Recommended for Production)

```kconfig
CFG_RPMB_FS=y             # Enable RPMB backend
CFG_RPMB_FS_DEV_ID=0     # eMMC device index (/dev/mmcblk0rpmb or mmcblk2rpmb)
CFG_RPMB_TESTKEY=n        # NEVER enable in production (uses fixed test key)
```

RPMB (Replay Protected Memory Block) is a special partition in eMMC controllers with built-in
replay protection. Every write operation includes a write counter that the eMMC hardware
verifies. An attacker who replays an old write command receives an authentication error from
the eMMC hardware.

```
RPMB Write Operation Flow
──────────────────────────
OP-TEE Core (Secure EL1)
  │
  │  1. Prepare RPMB data frame:
  │     data_frame.write_counter = prev_counter + 1
  │     data_frame.data = encrypted_data
  │     data_frame.mac = HMAC-SHA-256(RPMB_auth_key, data_frame)
  │
  ▼ SMC → REE (Normal World)
tee-supplicant
  │  2. Issue MMC_IOC_MULTI_CMD to /dev/mmcblk2rpmb:
  │     CMD23 (SET_BLOCK_COUNT)
  │     CMD25 (WRITE_MULTIPLE_BLOCK) with RPMB data
  │
  ▼ eMMC Hardware
  │  3. eMMC verifies:
  │     MAC = HMAC-SHA-256(stored_auth_key, data_frame)
  │     write_counter == stored_counter + 1
  │     If both checks pass: write committed, counter incremented
  │     If either fails: WRITE_FAILURE response
```

RPMB authentication key derivation (when `CFG_RPMB_KEY_DERIVED_FROM_HUK=y`):

```
HUK (from CAAM OTP)
  │
  └─► HKDF("RPMB", HUK, device_serial_number)
          │
          └─► 256-bit RPMB authentication key
```

The RPMB key is device-unique and derived from hardware secrets. It is provisioned into the
eMMC RPMB partition at first boot if not already present.

### Verifying RPMB Is Operational

```bash
# Ensure tee-supplicant is running (should start at boot)
systemctl status tee-supplicant
# or
ps aux | grep tee-supplicant

# Check RPMB device exists
ls -la /dev/mmcblk*rpmb
# /dev/mmcblk2rpmb → eMMC RPMB on phyBOARD-Pollux

# Run OP-TEE basic storage tests
# (optee-test package must be installed)
xtest -t regression 1000-1099
# Test 1001.0: Storage file create, read, write — PASS
# Test 1002.0: Rollback protection test — PASS
# Test 1003.0: Access rights test — PASS

# If tests fail with TEE_ERROR_STORAGE_NOT_AVAILABLE:
# RPMB key has not been provisioned yet
# First-boot RPMB provisioning is automatic if CFG_RPMB_KEY_DERIVED_FROM_HUK=y
```

---

## fTPM (Firmware TPM) via OP-TEE

The fTPM is a Trusted Application that implements TPM 2.0 functionality in software within
OP-TEE. It provides PCR (Platform Configuration Register) operations, TPM key storage,
and attestation — entirely in software, with state persisted in RPMB.

Source: Microsoft ms-tpm-20-ref ported to OP-TEE:
https://github.com/microsoft/ms-tpm-20-ref (TA-based port)

### fTPM Architecture

```
Linux fTPM Kernel Driver (drivers/char/tpm/tpm_ftpm_tee.c)
  │  - Implements /dev/tpm0 interface
  │  - Converts TPM commands to OP-TEE TEEC calls
  ▼
OP-TEE Core
  │
  ▼
fTPM Trusted Application (UUID: bc50d971-d4c9-42c4-82cb-343fb7f37896)
  │  - Full TPM 2.0 command processing
  │  - PCR extend operations
  │  - Key generation, signing, attestation
  │  - NV (Non-Volatile) storage in RPMB
  ▼
RPMB storage (for TPM NV storage persistence)
```

### fTPM Configuration in OP-TEE Build

```bash
make PLATFORM=imx-mx8mpevk \
     CFG_ARM_GICV3=y \
     CFG_RPMB_FS=y \
     CFG_RPMB_FS_DEV_ID=0 \
     CFG_FTPM_APKGS=y \              # Enable fTPM package
     CFG_FTPM_USE_WOLF=y \           # Use wolfSSL crypto in fTPM
     all
```

### Linux fTPM Configuration

```kconfig
CONFIG_TCG_TPM=y
CONFIG_TCG_TIS_CORE=y
CONFIG_TCG_FTPM_TEE=y              # fTPM over TEE
# After boot: /dev/tpm0 appears
```

### Using fTPM from Linux

```bash
# Check TPM is working
tpm2_getcap properties-fixed | grep TPMVendorSpecific

# Extend a PCR with measurement
tpm2_pcrextend 8:sha256=$(sha256sum /etc/hostname | awk '{print $1}')

# Read PCR values
tpm2_pcrread sha256:0,1,2,3,4,5,6,7,8

# Create an attestation key
tpm2_createprimary -C e -g sha256 -G ecc -c primary.ctx
tpm2_create -C primary.ctx -g sha256 -G ecc -r ak.priv -u ak.pub

# Seal a secret to PCR values (secret is only recoverable if PCRs match)
echo "my secret" | tpm2_create -C primary.ctx -g sha256 -G keyedhash \
    -i - -r sealed.priv -u sealed.pub \
    -L "sha256:0,1,2,3,4,5,6,7,8"
```

PCR meanings (standard):
- PCR 0: BIOS/UEFI firmware (or bootloader for embedded)
- PCR 1: BIOS/UEFI configuration
- PCR 7: Secure boot state
- PCR 8-15: Available for OS/application use

For embedded Linux with measured boot:
- PCR 0: ROM + SPL measurement
- PCR 1: TF-A + OP-TEE measurement
- PCR 2: U-Boot measurement
- PCR 8: Kernel FIT hash (extended by U-Boot before boot)
- PCR 9: Kernel command line
- PCR 10: Rootfs hash (dm-verity root hash)

---

## HUK (Hardware Unique Key) Derivation

The HUK is the foundation of all device-unique cryptographic identity on i.MX8MP. It is derived
by the CAAM from OTP fuses and is never exposed as a readable value to software.

### HUK Derivation Chain

```
i.MX8MP OTP Master Key
  Location: OCOTP_SW_GP2 and related fuses (provisioned at manufacturing)
  Size: 256 bits
  Access: CAAM internal only — reading via software returns zeros
  ↓
CAAM BKEK (Black Key Encryption Key) — CAAM-internal, hardware-backed
  ↓
CAAM Master Key Derivation → HUK
  Derivation: CAAM uses AES-CMAC in NIST SP800-108 counter mode
  Input: CAAM master key || "HUK" label || device identifier
  Output: 256-bit HUK
  ↓
OP-TEE HUK API (tee_hwkey_to_huk())
  → OP-TEE calls CAAM Job Ring operation
  → Receives 256-bit HUK material
  → HUK stays in OP-TEE secure memory (never returned to CAAM buffer)
  ↓
Per-purpose key derivation (HKDF):
  ├── RPMB auth key:    HKDF(HUK, "rpmb")          → 32 bytes
  ├── REE-FS enc key:   HKDF(HUK, "reefs" || uuid)  → 32 bytes
  ├── fTPM seed:        HKDF(HUK, "ftpm")            → 64 bytes
  └── TA storage key:   HKDF(HUK, "ta" || ta_uuid)  → 32 bytes per TA
```

### HUK Security Properties

1. **Device uniqueness**: Two devices with the same software produce different HUKs because the
   OTP Master Key is unique per device (provisioned with random values at manufacturing).

2. **Non-extractability**: The HUK itself is never written to normal world memory. Only values
   derived from HUK (with additional context) are used in practice.

3. **Reproducibility**: The same HUK is derived every boot from the same CAAM fuse state.
   RPMB keys and storage encryption keys remain consistent across reboots.

4. **Fuse dependency**: If the OTP Master Key fuses are not programmed (all zeros), the HUK
   is effectively zero-derived and provides no security. Verify at manufacturing:
   ```bash
   # Check OTP Master Key is not all zeros (indirect check via OP-TEE HUK test)
   xtest -t regression 4001
   # If this test passes, HUK is unique (non-zero)
   ```

---

## Build for i.MX8MP

### Complete OP-TEE Build Command

```bash
cd optee_os

make \
    PLATFORM=imx-mx8mpevk \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_core=aarch64-linux-gnu- \
    CROSS_COMPILE_ta_arm64=aarch64-linux-gnu- \
    \
    CFG_ARM_GICV3=y \
    \
    CFG_RPMB_FS=y \
    CFG_RPMB_FS_DEV_ID=0 \
    CFG_RPMB_KEY_DERIVED_FROM_HUK=y \
    \
    CFG_CORE_HEAP_SIZE=0x110000 \
    CFG_TEE_CORE_LOG_LEVEL=2 \
    \
    CFG_WITH_PAGER=n \
    \
    CFG_HWSUPP_MEM_PERM_PXN=y \
    CFG_HWSUPP_MEM_PERM_WXN=y \
    \
    CFG_TZDRAM_START=0xfe000000 \
    CFG_TZDRAM_SIZE=0x1e00000 \
    \
    CFG_SHMEM_START=0xfdc00000 \
    CFG_SHMEM_SIZE=0x00400000 \
    \
    all
```

### Key Configuration Parameters Explained

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `PLATFORM` | `imx-mx8mpevk` | Platform code selection, includes i.MX8MP GIC/CAAM config |
| `CFG_ARM_GICV3` | `y` | Use GICv3 interrupt controller driver |
| `CFG_RPMB_FS` | `y` | Enable RPMB secure storage backend |
| `CFG_RPMB_FS_DEV_ID` | `0` | eMMC device 0 = /dev/mmcblk0 (or 2 for mmcblk2) |
| `CFG_CORE_HEAP_SIZE` | `0x110000` | OP-TEE heap: 1088 KB; increase for more TAs or large keys |
| `CFG_TEE_CORE_LOG_LEVEL` | `2` | Log level: 0=none, 1=error, 2=info, 3=debug, 4=flow |
| `CFG_WITH_PAGER` | `n` | Disable OP-TEE demand-pager (simpler, required for small TZDRAM) |
| `CFG_TZDRAM_START` | `0xfe000000` | Must match BL32_BASE in TF-A platform_def.h |
| `CFG_TZDRAM_SIZE` | `0x1e00000` | 30 MB for OP-TEE; must fit code + heap + stack + TAs |

### Build Outputs

```
out/arm-plat-imx/core/
├── tee.elf            # ELF with full debug symbols (for GDB/crash analysis)
├── tee-raw.bin        # Raw binary → input for TF-A as BL32
├── tee-pager.bin      # Pager binary (if CFG_WITH_PAGER=y)
├── tee.symtab         # Symbol table (for crash decode)
└── tee.map            # Linker map (for size analysis)

out/arm-plat-imx/export-ta_arm64/
├── include/           # Headers for TA development
├── mk/                # Makefiles for TA build
└── scripts/           # sign_encrypt.py, etc.
```

---

## Yocto Integration

### meta-optee Layer

The `meta-optee` layer (from https://github.com/meta-optee/meta-optee) provides:
- `optee-os` recipe: builds OP-TEE OS
- `optee-client` recipe: builds tee-supplicant and libteec
- `optee-test` recipe: builds xtest test suite
- `optee-examples` recipe: builds example TAs

### optee-os Recipe (Yocto)

```bitbake
# meta-optee/recipes-security/optee/optee-os_3.21.0.bb (simplified)
SUMMARY = "OP-TEE Trusted OS"
LICENSE = "BSD-2-Clause"

SRC_URI = "git://github.com/OP-TEE/optee_os.git;branch=3.21.0"

# Platform-specific override in BSP layer:
# meta-phytec/recipes-security/optee/optee-os_%.bbappend

OPTEEMACHINE = "imx-mx8mpevk"

EXTRA_OEMAKE += " \
    PLATFORM=${OPTEEMACHINE} \
    CFG_ARM_GICV3=y \
    CFG_RPMB_FS=y \
    CFG_RPMB_FS_DEV_ID=0 \
    CFG_CORE_HEAP_SIZE=0x110000 \
    CFG_TEE_CORE_LOG_LEVEL=2 \
    CFG_TZDRAM_START=0xfe000000 \
    CFG_TZDRAM_SIZE=0x1e00000 \
"

do_install() {
    install -d ${D}/lib/firmware
    install -m 0644 ${B}/out/${OPTEEMACHINE}/core/tee-raw.bin ${D}/lib/firmware/
    install -d ${D}/${nonarch_base_libdir}/optee_armtz
}

PACKAGES =+ "${PN}-tadevkit"
FILES:${PN} = "${nonarch_base_libdir}/optee_armtz/"
FILES:${PN}-tadevkit = "${includedir}/optee ${datadir}/optee"
```

### optee-client Recipe (tee-supplicant)

```bitbake
# meta-optee/recipes-security/optee/optee-client_3.21.0.bb (simplified)
SUMMARY = "OP-TEE Client API library and tee-supplicant daemon"

SRC_URI = "git://github.com/OP-TEE/optee_client.git;branch=3.21.0"

inherit cmake

EXTRA_OECMAKE += " \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DRPMB_EMU=0 \
"

# Installed files:
# /usr/sbin/tee-supplicant
# /usr/lib/libteec.so.1
# /usr/lib/libckteec.so.1         (PKCS#11 over OP-TEE)
# /usr/include/tee_client_api.h
```

### MACHINE_FEATURES and IMAGE Integration

```bitbake
# In machine configuration (conf/machine/phyboard-pollux-imx8mp-3.conf):
MACHINE_FEATURES += "optee"

# The "optee" machine feature triggers:
# 1. In meta-optee/conf/layer.conf:
MACHINE_FEATURES_BACKFILL_CONSIDERED += "optee"
# 2. In kernel configuration:
KERNEL_FEATURES += "features/optee/optee.scc"
#   → CONFIG_TEE=y
#   → CONFIG_OPTEE=y
# 3. tee-supplicant is added to IMAGE_INSTALL via:
#   IMAGE_INSTALL:append = " optee-client"

# For production image with OP-TEE:
IMAGE_INSTALL += " \
    optee-client \
    optee-test \
    kernel-module-optee \
"

# Systemd service for tee-supplicant (auto-start):
SYSTEMD_SERVICE:optee-client = "tee-supplicant.service"
```

### Verifying OP-TEE in Yocto Image

```bash
# On the target after boot:

# Check tee-supplicant is running
systemctl is-active tee-supplicant
# Expected: active

# Check TEE device nodes
ls -la /dev/tee*
# /dev/tee0    → application TEE device
# /dev/teepriv0 → supplicant TEE device

# Check kernel TEE driver loaded
lsmod | grep optee
# optee                  49152  0

# Run regression test suite
xtest -t regression 1000   # Storage tests
xtest -t regression 4001   # HUK/derivation test
xtest -t regression 6001   # Certificate operations
# Expected: all PASS
```

---

## Troubleshooting OP-TEE Integration

### Issue: tee-supplicant Fails to Start

```
Failed to start TEE Supplicant daemon: see 'journalctl -xe'
tee-supplicant[1234]: Cannot open /dev/tee0: No such file or directory
```

**Cause**: Kernel TEE driver not loaded, or OP-TEE not initialized by TF-A.
**Diagnosis**:
```bash
# Check kernel config
zcat /proc/config.gz | grep -E "CONFIG_TEE|CONFIG_OPTEE"
# Must have: CONFIG_TEE=y, CONFIG_OPTEE=y

# Check if TEE driver bound:
dmesg | grep -i optee
# Expected: "optee: probing for optee-tz"

# If TF-A did not launch OP-TEE, the driver will fail to probe:
# "optee: SMC call failed"
# → Check TF-A built with SPD=opteed and BL32 present in FIT
```

### Issue: RPMB Tests Fail (TEE_ERROR_STORAGE_NOT_AVAILABLE)

```
xtest: 1001.0 FAILED — TEE_ERROR_STORAGE_NOT_AVAILABLE
```

**Cause**: RPMB device not accessible or RPMB key not provisioned.
**Diagnosis**:
```bash
# Check RPMB device:
ls -la /dev/mmcblk*rpmb
# If missing: eMMC driver issue or no RPMB support in eMMC

# Check tee-supplicant can access RPMB:
journalctl -u tee-supplicant | grep -i rpmb
# "Failed to open RPMB device" → permissions issue
# Solution: ensure tee-supplicant runs as root or has /dev/mmcblk2rpmb access

# RPMB key provisioning (if using derived key):
# Done automatically on first OP-TEE secure storage write
# Run: xtest -t regression 1001 and check for first-run key provisioning in log
```

### Issue: TA Load Fails (TEE_ERROR_SECURITY)

```
tee-supplicant: Cannot load TA <uuid>.ta: TEE_ERROR_SECURITY
```

**Cause**: TA was signed with a different key than the one compiled into optee_os.
**Diagnosis**:
```bash
# Check TA signing key in optee_os build:
grep CFG_TA_SIGN_KEY optee_os/out/*/Makefile

# Re-sign the TA with the correct key:
python3 optee_os/scripts/sign_encrypt.py \
    --key $(correct-key.pem) \
    --uuid <uuid> \
    --ta-version 1 \
    --in ta.elf \
    --out <uuid>.ta
```

---

*Chapter 07 — OP-TEE Integration | Embedded Linux Secure Boot Reference*
