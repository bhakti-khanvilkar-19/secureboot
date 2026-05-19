# Chapter 08: U-Boot Secure Boot

```
Tested Against:
  - U-Boot: 2023.04 (NXP lf-6.1.55-2.2.0)
  - mkimage: from u-boot-tools 2023.04
  - Platform: NXP i.MX8M Plus (phyCORE-i.MX8MP)
  - Yocto: kirkstone (NXP lf-6.1.55-2.2.0 BSP)
Last Validated: 2024-Q2
```

---

## Overview

U-Boot is the final bootloader stage before the Linux kernel. Its security role is specific and
critical: it receives a FIT image (Flat Image Tree) from the boot device, authenticates that
image against a public key compiled into U-Boot's own device tree, and only boots the kernel if
authentication succeeds.

This is the authentication boundary that protects the kernel, device tree, and initramfs from
tampering. HABv4 protects U-Boot from tampering (via the ROM → SPL chain). U-Boot protects the
kernel from tampering. The two mechanisms are complementary: breaking either one does not
automatically break the other.

Understanding U-Boot's FIT verification mechanism in detail is required for:
- Debugging kernel boot failures that appear as signature errors
- Correctly embedding the signing public key in U-Boot during the build
- Configuring which images must be signed and which are optional
- Hardening the U-Boot environment against tampering

---

## Table of Contents

1. [U-Boot's Role in Secure Boot](#1-u-boots-role-in-secure-boot)
2. [FIT Image Verification Flow](#2-fit-image-verification-flow)
3. [Configuration Signature: The Core Concept](#3-configuration-signature-the-core-concept)
4. [Key Embedding in U-Boot DTB](#4-key-embedding-in-u-boot-dtb)
5. [The Key Node in U-Boot DTB](#5-the-key-node-in-u-boot-dtb)
6. [U-Boot bootm Flow with FIT](#6-u-boot-bootm-flow-with-fit)
7. [Rollback Protection](#7-rollback-protection)
8. [Secure Environment Configuration](#8-secure-environment-configuration)
9. [Boot Delay and Console Hardening](#9-boot-delay-and-console-hardening)
10. [PHYTEC Defconfig Analysis](#10-phytec-defconfig-analysis)
11. [Verification Failure Scenarios](#11-verification-failure-scenarios)
12. [Cross-References](#12-cross-references)

---

## 1. U-Boot's Role in Secure Boot

### Position in the Trust Chain

```
ROM → SPL → TF-A BL31 → OP-TEE → [U-Boot]  → Kernel
                                      ↑
                           This chapter covers this stage
```

By the time U-Boot executes:
- HABv4 (ROM) has verified SPL authenticity
- SPL has verified the FIT containing TF-A, OP-TEE, and U-Boot
- TF-A has established the secure world and handed off to non-secure EL2
- OP-TEE is running in Secure EL1

U-Boot itself is now trusted — it was loaded and verified by SPL. Its job is to:

1. Locate the kernel FIT image on the boot device
2. Load it into DRAM
3. Verify the FIT signatures using the public key embedded in its compiled-in device tree
4. Pass the authenticated kernel, device tree, and initramfs to the Linux boot infrastructure

### What U-Boot Does NOT Do

U-Boot is not responsible for:
- Its own authentication (SPL does this)
- Verifying the rootfs (dm-verity, configured via kernel command line, does this)
- Runtime policy enforcement (AppArmor, SELinux — Linux does this)

U-Boot's sole security responsibility: **verify the kernel FIT image before handing control to
the kernel**.

---

## 2. FIT Image Verification Flow

When U-Boot executes `bootm ${fit_addr}`, the following sequence occurs. Each step is a distinct
function call in the U-Boot source tree:

### Step 1: Parse FIT Header

```c
/* common/bootm.c → common/image-fit.c */
int bootm_find_images(int flag, int argc, char *const argv[], ...)
{
    /* Locate FIT header in memory */
    if (fit_check_format(fit, IMAGE_SIZE_INVAL) != FIT_FORMAT_OK) {
        /* FIT magic 0xD00DFEED not found, or FIT is malformed */
        puts("Bad FIT image format\n");
        return 1;
    }
    /* fit_check_format() validates:
     * - FDT magic word at offset 0
     * - Total size field consistency
     * - Minimum required nodes exist (/images, /configurations)
     */
}
```

### Step 2: Select Configuration

```c
/* Select which /configurations/conf@N to use */
const char *fit_conf_get_node(const void *fit, const char *def_conf)
{
    /* 1. If def_conf is explicitly specified (e.g., "conf@2"), use it */
    /* 2. Otherwise, read "default" property from /configurations node */
    /* 3. Example: default = "conf@1" → use configurations/conf@1 */
}
```

On the U-Boot console, you can override the default configuration:
```
=> bootm ${fit_addr}#conf@2   # Boot with alternative configuration
```

### Step 3: Verify Required Signatures

```c
/* common/image-fit-sig.c */
int fit_image_verify_required_sigs(const void *fit, int image_noffset,
                                    const char *fit_uname, int sig_required,
                                    const void *sig_blob, int *no_sigsp)
```

This is the critical security function. It:
1. Iterates over all signature nodes in the configuration being booted
2. For each signature node, calls `fit_config_verify_sig()` or `fit_image_sig_verify()`
3. Checks whether the `required` property demands that at least one valid signature exist
4. Returns failure if any required signature is absent or invalid

### Step 4: Per-Image Hash Verification

```c
/* For each image referenced by the configuration: */
int fit_image_verify(const void *fit, int image_noffset, const void *sig_blob)
{
    /* Iterate over hash nodes (hash@1, hash@2, ...) */
    for (hash_noffset = fdt_first_subnode(fit, image_noffset);
         hash_noffset >= 0;
         hash_noffset = fdt_next_subnode(fit, hash_noffset))
    {
        /* Get algorithm: "sha256", "sha384", etc. */
        /* Compute hash of image data */
        /* Compare against stored hash value in FIT */
    }
}
```

### Step 5: Configuration Signature Verification

```c
/* Verify RSA signature over the configuration */
int fit_config_verify(const void *fit, int conf_noffset, const void *sig_blob,
                      int conf_noffset_required)
{
    /* 1. Get sign-images property: e.g., "kernel", "fdt", "ramdisk" */
    /* 2. For each listed image, collect its data pointers */
    /* 3. Concatenate image data (in sign-images order) */
    /* 4. Compute SHA-256 over concatenated data */
    /* 5. Verify RSA signature using public key from sig_blob (U-Boot DTB) */
    /* sig_blob = U-Boot's compiled-in device tree = fdt_blob global */
}
```

### Step 6: Return Verified Images

If all checks pass, `bootm` receives:
- Kernel load address: the `load` field from the kernel@1 image node
- Kernel entry point: the `entry` field (= load for uncompressed AArch64 kernel)
- Device tree address: the `load` field from the fdt@1 image node
- Ramdisk address and size (if present)

---

## 3. Configuration Signature: The Core Concept

The configuration signature is the most important aspect of U-Boot FIT verification, and the
most commonly misunderstood.

### Why Not Just Hash Individual Images?

A naive approach would be to hash each image separately:
- SHA-256 of kernel image → stored in FIT
- SHA-256 of DTB → stored in FIT
- SHA-256 of initramfs → stored in FIT

**Problem**: An attacker can replace the kernel with their own binary and update the hash node.
Without an RSA signature, there is no way to detect this tampering. A hash without a signature
only detects corruption, not intentional modification.

### The Configuration Signature Approach

The configuration signature is an RSA-2048 (or RSA-4096) signature over the concatenated data
of all images listed in `sign-images`. Only the holder of the private key can create a valid
signature. U-Boot verifies this signature using the public key embedded in its device tree.

```
FIT Configuration Node:
  conf@1 {
      kernel = "kernel@1";
      fdt    = "fdt@1";
      ramdisk = "ramdisk@1";
      signature@1 {
          algo = "sha256,rsa2048";
          key-name-hint = "fit-signing-key";
          sign-images = "kernel", "fdt", "ramdisk";
          value = <RSA signature bytes>;    /* Set by mkimage -F ... -r */
      };
  };
```

When U-Boot verifies this:
1. Collects data regions for kernel@1, fdt@1, ramdisk@1 (in that order)
2. Computes SHA-256 over the concatenated regions
3. Verifies the `value` signature using the RSA-2048 public key
4. If the attacker has replaced kernel@1 with different data, the SHA-256 changes,
   the RSA verification fails, and boot is rejected

### Required Enforcement: `required = "conf"`

The `required` property in the U-Boot device tree (embedded as a key attribute) tells U-Boot
whether a signature is optional or mandatory.

In the U-Boot device tree (embedded public key node):
```dts
/signature/key-fit-signing-key {
    required = "conf";   /* ← CRITICAL: require configuration-level signature */
    algo = "sha256,rsa2048";
    ...
};
```

With `required = "conf"`:
- U-Boot MUST find a valid configuration signature for any FIT it boots
- A FIT with no signature node, or with a signature that does not verify, is rejected
- An unsigned FIT image will fail with: `ERROR: Failed to validate required signature`

With `required = "image"`:
- Each individual image must be signed (less common; conf-level is preferred)

Without `required` property:
- U-Boot will verify signatures if present but will boot unsigned images
- **This is NOT secure for production** — it means any unsigned image boots

```bash
# Verify the 'required' property is present in the compiled U-Boot DTB:
fdtdump u-boot.dtb | grep -A8 "signature"
# Expected output:
# key-fit-signing-key {
#     required = "conf";
#     algo = "sha256,rsa2048";
#     rsa,num-bits = <2048>;
#     ...
# }
```

---

## 4. Key Embedding in U-Boot DTB

The public key used for FIT verification must be embedded in U-Boot's compiled-in device tree
before building the final U-Boot binary. This is done with `mkimage -K`:

```bash
# ============================================================
# BUILD WORKFLOW (must be in this order)
# ============================================================

# Step 1: Initial U-Boot build (produces u-boot.dtb without key)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)

# Step 2: Sign the FIT image, simultaneously embedding the public key in u-boot.dtb
# -F: modify existing FIT (fitImage) in-place
# -k: directory containing {key-name}.pem (private) and {key-name}.crt (certificate)
# -K: destination DTB to embed the public key into (u-boot.dtb)
# -r: set 'required = "conf"' in the key node (mandatory for security)
mkimage -F fitImage -k keys/ -K u-boot.dtb -r

# After this command, u-boot.dtb contains:
#   /signature/key-fit-signing-key {
#       required = "conf";
#       algo = "sha256,rsa2048";
#       rsa,num-bits = <2048>;
#       rsa,modulus = <...2048-bit modulus...>;
#       rsa,r-squared = <...Montgomery constant...>;
#       rsa,exponent = <65537>;
#       rsa,n0-inverse = <...Montgomery inverse...>;
#   }

# Step 3: Rebuild U-Boot with the updated u-boot.dtb
# The rebuild compiles the updated DTB into the U-Boot binary
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)

# Now u-boot-nodtb.bin + u-boot.dtb contains the embedded public key.
# SPL built from this U-Boot tree will also pick up the key (for SPL FIT verification).
```

### Key Directory Requirements

The `-k keys/` directory must contain exactly two files per key:
```
keys/
├── fit-signing-key.pem    # RSA-2048 private key in PEM format
│                           # Used by mkimage to create the signature
└── fit-signing-key.crt    # X.509 self-signed certificate (PEM format)
                            # Contains the public key extracted from .pem
                            # Used by mkimage to embed the public key in u-boot.dtb
```

The key name (`fit-signing-key`) is determined by:
1. The `key-name-hint` property in the ITS file's signature node
2. The filename stem in the `keys/` directory

These must match. If they do not, `mkimage` will fail with:
```
FDT_ERR_NOTFOUND: key 'fit-signing-key' not found in key directory
```

---

## 5. The Key Node in U-Boot DTB

After `mkimage -K u-boot.dtb -r`, the DTB contains a `/signature` node with the public key
in RSA Montgomery pre-computed form:

```dts
/ {
    signature {
        key-fit-signing-key {
            required = "conf";
            algo = "sha256,rsa2048";
            padding = "pkcs-1.5";
            rsa,num-bits = <0x00000800>;    /* 2048 */
            rsa,modulus = <
                /* 256 bytes (2048 bits) of RSA modulus */
                0xb3a7c2f1 0x9de84a23 0x7b41c9e2 0xf3821d74
                ... (60 more words) ...
                0x4e9f2b8d 0x1a63c7e5 0x92d4b0f3 0x8e51a6c2
            >;
            rsa,exponent = <0x00000000 0x00010001>;  /* 65537 */
            rsa,r-squared = <
                /* Montgomery R² constant = R² mod N, 256 bytes */
                0x... (64 words) ...
            >;
            rsa,n0-inverse = <0x...>;     /* Montgomery inverse: -(N⁻¹) mod 2³² */
        };
    };
    /* ... rest of U-Boot device tree ... */
};
```

### Montgomery Pre-computation Explanation

RSA modular exponentiation `m^e mod N` is computationally expensive. U-Boot uses Montgomery
multiplication to speed this up without hardware acceleration. The pre-computed values:

- `rsa,modulus (N)`: The RSA public key modulus (2048 bits = 256 bytes)
- `rsa,exponent (e)`: Always 65537 (0x10001) for RSA-2048
- `rsa,r-squared (R²)`: Montgomery constant = `(2^(2048))² mod N`
  Allows conversion into Montgomery form in one multiplication
- `rsa,n0-inverse`: `-(N⁻¹) mod 2³²` — Used in Montgomery reduction

These are pre-computed by `mkimage` from the RSA public key so that U-Boot does not need to
perform the expensive modular inversion at runtime. This is especially important in SPL where
stack space and heap are limited.

### Inspecting the Embedded Key

```bash
# On the host, inspect u-boot.dtb:
fdtdump u-boot.dtb 2>/dev/null | grep -A 30 "^/ {" | grep -A 20 "signature"

# On the target (U-Boot console):
=> fdt addr $fdtaddr
=> fdt print /signature
# signature {
#     key-fit-signing-key {
#         required = "conf";
#         algo = "sha256,rsa2048";
#         rsa,num-bits = <0x800>;
#         ...
#     };
# };

# View full key content:
=> fdt print /signature/key-fit-signing-key rsa,modulus
```

---

## 6. U-Boot bootm Flow with FIT

Complete execution path from `bootm` command to kernel entry:

```
U-Boot console: bootm ${fit_addr}
  │
  ▼
do_bootm() [common/bootm.c]
  │  - Parse fit_addr as image pointer
  │  - Identify image type: FIT
  │
  ▼
bootm_start() [common/bootm.c]
  │  - fit_check_format(): validate FIT magic and structure
  │  - image_get_fit(): locate /images node
  │
  ▼
bootm_find_os() [common/bootm.c]
  │  - fit_conf_get_node(): find default or specified configuration
  │  - "Using 'conf@1' configuration"
  │
  ▼
fit_image_verify_required_sigs() [common/image-fit-sig.c]
  │  - Locate /signature node in U-Boot compiled-in DTB
  │  - For each key with required="conf":
  │      fit_config_verify(): verify RSA signature over all sign-images
  │  - "Verified OK, SIGNATURE sha256,rsa2048:fit-signing-key (1)"
  │  - FAILURE → "ERROR: Failed to validate required signature 'fit-signing-key'"
  │              → return error → boot aborted
  │
  ▼
bootm_load_os() [common/bootm.c]
  │  - fit_image_get_data(): get kernel image data pointer
  │  - image_decompress(): decompress if compressed (gzip, lzma, etc.)
  │  - For AArch64, uncompressed: kernel copied to load address (0x40480000)
  │
  ▼
bootm_find_other() [common/bootm.c]
  │  - Load device tree: fit_image_get_data() for fdt@1
  │  - Copy DTB to fdt_addr (0x44000000)
  │  - Load ramdisk: if present, copy to rd_start address
  │
  ▼
fdt_chosen() + fdt_board_setup() [common/fdt_support.c]
  │  - Inject /chosen/bootargs into DTB (kernel command line)
  │  - Inject memory nodes, clock nodes if required
  │
  ▼
boot_jump_linux() [arch/arm/lib/bootm.c]
  │  - Disable D-cache (kernel starts with caches off)
  │  - Set up kernel entry registers:
  │      x0 = DTB address (0x44000000)
  │      x1 = 0 (reserved)
  │      x2 = 0 (reserved)
  │      x3 = 0 (reserved)
  │  - branch to kernel_entry (0x40480000)
  │
  ▼
Linux Kernel begins execution at 0x40480000
```

---

## 7. Rollback Protection

HABv4 and FIT signature verification prevent running unauthorized code, but they do not prevent
running an older (potentially vulnerable) version of signed code. Rollback protection requires
a monotonic counter stored in a medium that cannot be rolled back.

### Version Checking in FIT

Each FIT image can carry a version number:

```dts
/* In ITS file: */
configurations {
    conf@1 {
        /* ... */
        signature@1 {
            algo = "sha256,rsa2048";
            key-name-hint = "fit-signing-key";
            sign-images = "kernel", "fdt";
        };
    };
};
```

U-Boot can be configured to enforce minimum version numbers stored in fuses, via
`CONFIG_FIT_ROLLBACK_PROTECT`. However, this requires an anti-rollback counter in the
OTP fuse array — a finite resource on i.MX8MP (only 1-4 bits typically available for
application rollback).

### Practical Anti-Rollback for i.MX8MP

The most practical anti-rollback implementation uses OP-TEE's fTPM:

```bash
# TPM NV Index for storing firmware version
# At manufacturing: set to version 1
tpm2_nvdefine 0x1500016 -C platform -s 4 -a "ownerread|ownerwrite|policywrite"
tpm2_nvwrite 0x1500016 -C platform -i <(printf '\x00\x00\x00\x01')

# At each verified boot: check version
current_version=$(tpm2_nvread 0x1500016 | hexdump -e '1/4 "%d"')
image_version=1  # From FIT image version field or signed manifest
if [ "$image_version" -lt "$current_version" ]; then
    echo "ROLLBACK DETECTED: refusing to boot older image"
    reboot
fi

# After successful new version boot: increment counter
tpm2_nvwrite 0x1500016 -C platform -i <(printf '\x00\x00\x00\x02')
```

---

## 8. Secure Environment Configuration

The U-Boot environment (env) is a key-value store that configures boot behavior. In production,
the environment must be locked down to prevent an attacker with brief U-Boot console access from
overriding the secure boot flow.

### Environment Security Options

```kconfig
# Disable environment editing from console
# An attacker cannot modify bootcmd or boot arguments
CONFIG_CMD_EDITENV=n        # Disables 'editenv' command
CONFIG_CMD_ENV_CALLBACK=n   # Disables environment callbacks

# Disable expression evaluation (prevents bootcmd override tricks)
CONFIG_CMD_SETEXPR=n

# Compile boot command into binary rather than storing in flash env
# This makes bootcmd tamper-proof (it's part of the authenticated binary)
CONFIG_USE_BOOTCOMMAND=y
CONFIG_BOOTCOMMAND="run secureboot_cmd"

# No persistent environment (hardest: nothing to tamper with)
CONFIG_ENV_IS_NOWHERE=y
# OR: Environment in MMC (can be write-protected via eMMC WP registers)
CONFIG_ENV_IS_IN_MMC=y

# If ENV_IS_IN_MMC: lock the env partition with eMMC write protect
# Done at manufacturing:
# mmc bootpart enable 1 1 /dev/mmcblk2  (enable boot WP)
```

### Compiled-In Secure Boot Environment

For production, the boot script should be compiled into U-Boot:

```kconfig
CONFIG_EXTRA_ENV_SETTINGS="                                 \
fit_addr=0x40400000\0                                       \
mmcdev=2\0                                                  \
mmcpart=1\0                                                 \
mmcbootpart=1\0                                             \
boot_fit=                                                   \
    mmc dev ${mmcdev} &&                                    \
    mmc partconf ${mmcdev} 0 ${mmcbootpart} 0 &&           \
    mmc read ${fit_addr} 0 0x8000 &&                       \
    bootm ${fit_addr}\0                                    \
secureboot_cmd=run boot_fit\0"
```

---

## 9. Boot Delay and Console Hardening

In production, the interactive U-Boot console is an attack surface. An attacker with physical
access to the serial port can interrupt the boot countdown and gain a U-Boot shell, from which
they can load arbitrary images (bypassing FIT verification if they know how to call the right
commands directly).

### Critical Production Settings

```kconfig
# Disable boot countdown entirely (no way to interrupt boot)
# -2 = no countdown, no prompt, boot immediately
CONFIG_BOOTDELAY=-2

# Remove the ability to stop autoboot with any key press
CONFIG_AUTOBOOT_KEYED=n
# Or if AUTOBOOT_KEYED was used: clear the stop string
CONFIG_AUTOBOOT_STOP_STR=""
CONFIG_AUTOBOOT_STOP_STR2=""

# Disable interactive console entirely
# U-Boot will not respond to any console input
CONFIG_SILENT_CONSOLE=y
CONFIG_DISABLE_CONSOLE=y

# Remove dangerous commands from production build
CONFIG_CMD_IMLS=n           # Don't list images
CONFIG_CMD_FLASH=n          # Disable flash commands
CONFIG_CMD_NVEDIT=n         # Disable environment editing
CONFIG_CMD_MEMORY=n         # Disable md/mw commands (memory read/write)
CONFIG_CMD_I2C=n            # Disable I2C commands (PMIC access)
CONFIG_CMD_USB=n            # Disable USB commands
CONFIG_CMD_NET=n            # Disable network commands (no TFTP)
CONFIG_CMD_SOURCE=n         # Disable script source command
CONFIG_CMD_SETEXPR=n        # Disable expression evaluation
CONFIG_CMD_EDITENV=n        # Disable env editing

# Lock fuses against U-Boot modification
CONFIG_CMD_FUSE=n           # Remove fuse command from production!
```

> **WARNING**: `CONFIG_CMD_FUSE=n` must be set in production. The `fuse prog` command from an
> unauthorized U-Boot console could be used to corrupt or modify device fuses. Once the device
> is closed and deployed, fuse commands must not be accessible.

### JTAG Consideration

Even with console disabled, a JTAG interface can provide full debug access. JTAG hardening is
configured via separate fuses (`JTAG_SMODE`) and is outside U-Boot configuration, but must be
part of the production hardening checklist (Chapter 27).

---

## 10. PHYTEC Defconfig Analysis: Security Options

The `phycore-imx8mp_defconfig` configures U-Boot proper (not SPL) with these security-relevant
settings. The following is the security-focused subset:

```kconfig
# === Target ===
CONFIG_ARCH_IMX8M=y
CONFIG_TARGET_PHYCORE_IMX8MP=y

# === FIT Image Support ===
CONFIG_FIT=y                         # Enable FIT format
CONFIG_FIT_SIGNATURE=y               # Enable signature verification
CONFIG_FIT_VERBOSE=y                 # Print verification details (disable in production)
CONFIG_FIT_BEST_MATCH=y              # Allow best-match config selection
CONFIG_FIT_SIGNATURE_MAX_SIZE=0x10000000  # 256MB maximum FIT size

# === Crypto Libraries ===
CONFIG_RSA=y                         # RSA support
CONFIG_RSA_SOFTWARE_EXP=y           # Software RSA (always needed as fallback)
CONFIG_SHA256=y                      # SHA-256
CONFIG_SHA384=y                      # SHA-384
CONFIG_HASH=y                        # Hash framework

# === Secure Image Handling ===
CONFIG_LEGACY_IMAGE_FORMAT=n         # Disable old uImage format (less secure)
CONFIG_IMAGE_FORMAT_LEGACY=n         # Belt-and-suspenders: confirm legacy off

# === Boot Countdown ===
# DEVELOPMENT: CONFIG_BOOTDELAY=3 (3-second pause, press any key to interrupt)
# PRODUCTION:  CONFIG_BOOTDELAY=-2 (no countdown, no interrupt, immediate boot)
CONFIG_BOOTDELAY=3                   # Adjust to -2 for production

# === Console ===
# DEVELOPMENT: interactive console enabled
# PRODUCTION:  CONFIG_SILENT_CONSOLE=y, CONFIG_DISABLE_CONSOLE=y
CONFIG_SYS_CONSOLE_IS_IN_ENV=y

# === Environment ===
CONFIG_ENV_IS_IN_MMC=y               # Env stored in eMMC
CONFIG_SYS_MMC_ENV_DEV=2            # Device mmcblk2
CONFIG_SYS_MMC_ENV_PART=1           # Boot partition 1
CONFIG_ENV_SIZE=0x4000              # 16KB env size
CONFIG_ENV_OFFSET=0x400000          # Env at 4MB offset in boot partition

# === Bootcommand ===
CONFIG_USE_BOOTCOMMAND=y
CONFIG_BOOTCOMMAND="run mmcboot"

# === HAB Support ===
CONFIG_IMX_HAB=y                    # Include HABv4 API (for hab_status command)
CONFIG_CMD_HAB=y                    # Enable hab_status command in U-Boot console

# === Production Hardening (enable these for final image) ===
# CONFIG_CMD_FUSE=n                 # Remove fuse access
# CONFIG_CMD_EDITENV=n              # Remove env editing
# CONFIG_BOOTDELAY=-2               # No countdown
# CONFIG_SILENT_CONSOLE=y           # No console output
```

---

## 11. Verification Failure Scenarios

### Scenario 1: Missing Signature Node

FIT was created with `mkimage -f fitimage.its fitimage.bin` but never signed with `mkimage -F`.

```
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
ERROR: Failed to validate required signature 'fit-signing-key'
ERROR: bootm: Bad FIT configuration for 'conf@1'
```

**Fix**: Sign the FIT:
```bash
mkimage -F fitImage -k keys/ -r
```

### Scenario 2: Wrong Signing Key

FIT was signed with a key different from the one embedded in U-Boot DTB.

```
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ... sha256+ OK
ERROR: Failed to validate required signature 'fit-signing-key'
# (SHA-256 of data is correct, but RSA verification with the embedded key fails)
```

**Diagnosis**:
```bash
# Check which key is embedded in U-Boot:
fdtdump u-boot.dtb | grep "key-" | head -5

# Check which key was used to sign the FIT:
dumpimage -l fitImage | grep "Sign algo"

# The key-name-hint in the FIT signature node must match a key in U-Boot DTB
```

### Scenario 3: FIT Corrupted in Transit

Image read from eMMC is corrupted (bitflip, partial write, etc.).

```
## Loading kernel from FIT Image at 40400000 ...
Bad FIT kernel image format
```

OR:

```
   Verifying Hash Integrity ... sha256+ Bad hash value for 'sha256' hash
   node in 'kernel@1' image node
```

**Diagnosis**:
- Check eMMC health (smartctl or mmc-utils health data)
- Re-flash the FIT image
- If persistent: eMMC is failing, replace hardware

### Scenario 4: `required` Property Not Set

U-Boot DTB key node lacks `required = "conf"`. U-Boot warns but boots unsigned image.

```
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ... sha256+ OK
WARNING: FIT image not signed — booting anyway
```

**This is a security failure**. Fix by re-embedding the key with `-r`:
```bash
mkimage -F fitImage -k keys/ -K u-boot.dtb -r   # -r is critical
```

---

## 12. Cross-References

- `01-fit-image-verification.md` — C source internals and debug techniques
- `02-uboot-configuration.md` — Complete Kconfig reference for secure boot
- `../09-fit-images/README.md` — FIT image format, ITS syntax, multiple configurations
- `../09-fit-images/02-mkimage-reference.md` — mkimage command reference
- `../10-image-signing/01-signing-workflows.md` — Complete signing workflow script
- `../11-key-management/01-key-generation.md` — Key generation for FIT signing
- `../12-habv4-imx8m/README.md` — HABv4 authentication (SPL/U-Boot level)

---

## Chapter Contents

| File | Content |
|------|---------|
| [README.md](README.md) | This overview — FIT verification, key embedding, hardening |
| [01-fit-image-verification.md](01-fit-image-verification.md) | FIT verification source code internals, debug commands |
| [02-uboot-configuration.md](02-uboot-configuration.md) | Complete Kconfig reference for U-Boot secure boot |

---

*Chapter 08 — U-Boot Secure Boot | Embedded Linux Secure Boot Reference*
