# Yocto Secure Boot Integration: Reference Guide

```
Tested Against:
  - Yocto Project: Scarthgap (5.0.x)
  - OpenEmbedded-Core: 5.0.x
  - meta-imx: lf-6.6.36-2.1.0
  - meta-phytec: BSP-Yocto-NXP-i.MX8MP-PD24.1.y
  - meta-security: scarthgap branch
  - Platform: phyCORE-i.MX8MP (phyboard-pollux-imx8mp-3)
Last Validated: 2024-Q4
```

---

## Overview

Integrating secure boot into a Yocto build involves configuring multiple cooperating layers, classes, and variables such that the build system automatically generates signed artifacts ready for deployment to a closed device. Done correctly, the Yocto build becomes the authoritative source of signed images: every `bitbake` invocation produces a `fitImage` whose signature is cryptographically bound to a specific key stored offline.

This chapter covers the complete Yocto secure boot integration: layer stack organization, critical BitBake variables and their semantic effects, the class hierarchy that produces FIT images, the build artifact reference, and production configuration practices.

---

## Layer Stack for Secure Boot

The layer stack defines which recipes are available and how conflicts between layers are resolved. Priority determines which `.bbappend` files win when multiple layers append to the same recipe.

### Complete Layer Stack (Priority Order, Highest First)

```
BSP LAYER STACK
═══════════════════════════════════════════════════════════
Layer                              Priority  Role
───────────────────────────────────────────────────────────
meta-phytec-bsp                       10    PHYTEC hardware BSP
meta-phytec                            9    PHYTEC software recipes
meta-imx/meta-sdk                      8    NXP SDK (demos, tools)
meta-imx/meta-bsp                      8    NXP hardware BSP
meta-security/meta-tpm                 7    TPM2 recipes
meta-security                          7    Security framework recipes
meta-openembedded/meta-networking      6    Network tools
meta-openembedded/meta-python          6    Python recipes
meta-openembedded/meta-filesystems     6    Filesystem utilities
meta-openembedded/meta-oe             6    OpenEmbedded extensions
openembedded-core/meta-poky            5    Poky distro configuration
openembedded-core/meta                 5    OE-Core base layer
═══════════════════════════════════════════════════════════
```

Layer priority resolves recipe conflicts. When two layers define the same recipe or `.bbappend`, the higher-priority layer wins. `meta-phytec-bsp` at priority 10 ensures PHYTEC's U-Boot and kernel configurations take precedence over generic NXP configurations in `meta-imx`.

### Layer Compatibility

Each layer must declare compatibility with the Yocto release codename via `LAYERSERIES_COMPAT`. For Scarthgap (5.0.x):

```bitbake
# In each layer's conf/layer.conf:
LAYERSERIES_COMPAT_meta-phytec = "scarthgap"
LAYERSERIES_COMPAT_meta-imx-bsp = "scarthgap"
LAYERSERIES_COMPAT_meta-security = "scarthgap"
```

BitBake will error if a layer is not declared compatible with the active Yocto release. This prevents accidentally using a Kirkstone-era layer with a Scarthgap build.

---

## Security-Relevant Yocto Classes

Yocto classes (`.bbclass` files) implement reusable build logic. Several classes are critical to the secure boot integration.

### kernel-fitimage.bbclass

Located in `openembedded-core/meta/classes/kernel-fitimage.bbclass`.

This class is inherited by the kernel recipe (via `KERNEL_CLASSES`) and adds tasks to:
1. Assemble a FIT image from kernel + DTBs + optional initramfs
2. Generate an ITS (Image Tree Source) file describing the FIT layout
3. Optionally generate signing keys (`FIT_GENERATE_KEYS = "1"`)
4. Sign the FIT image using `mkimage -F -k`
5. Embed the signing public key into U-Boot's DTB

When `UBOOT_SIGN_ENABLE = "1"` is set, `do_deploy` copies the signed `fitImage` (not the raw kernel `Image`) to `DEPLOY_DIR_IMAGE`.

### uboot-sign.bbclass

Located in `openembedded-core/meta/classes/uboot-sign.bbclass`.

Inherited by the U-Boot recipe. Handles:
- Embedding FIT verification public key into U-Boot's DTB (`u-boot.dtb`)
- The public key node in U-Boot's DTB tells U-Boot at runtime: "use this key to verify FIT configurations"
- Triggers re-build of U-Boot when FIT signing key changes

The key embedding step is what creates the chain of trust from U-Boot to the FIT image: U-Boot contains the embedded public key; the FIT image is signed with the corresponding private key. U-Boot's own authenticity is guaranteed by HABv4/AHAB (upstream in the chain).

### ima.bbclass

Provides IMA (Integrity Measurement Architecture) kernel policy and key provisioning support. When enabled, the kernel measures each file at access time and records/validates hashes against an IMA policy. Requires `CONFIG_IMA=y` in the kernel.

### kernel-module-split.bbclass

When kernel modules are built separately from the monolithic kernel, this class handles per-module signing with a module signing key. Required when `CONFIG_MODULE_SIG_FORCE=y` is set in the kernel — unsigned modules will be rejected by the kernel at load time.

### systemd-security.bbclass

Applies systemd hardening options: `ProtectSystem=strict`, `PrivateTmp=yes`, `NoNewPrivileges=yes`, and similar unit-file hardening flags. Not directly part of boot-chain signing but contributes to runtime security posture.

---

## Key BitBake Variables and Their Effects

### Kernel Image Type Variables

```bitbake
# KERNEL_IMAGETYPE: controls what kernel artifact is produced
KERNEL_IMAGETYPE = "fitImage"
# Without this, the kernel recipe produces "Image" (raw arm64 kernel)
# With "fitImage", it invokes kernel-fitimage.bbclass tasks

# KERNEL_CLASSES: additional classes to inherit in kernel recipe
KERNEL_CLASSES = "kernel-fitimage"
# Required alongside KERNEL_IMAGETYPE = "fitImage"
# Alternative longer form:
KERNEL_CLASSES:append = " kernel-fitimage"
```

### FIT Signing Variables

These variables control whether and how the FIT image is signed:

```bitbake
# Enable/disable signing (default: "0" = disabled)
UBOOT_SIGN_ENABLE = "1"

# Directory containing signing keys
# Must contain: ${UBOOT_SIGN_KEYNAME}.key (private) 
#               ${UBOOT_SIGN_KEYNAME}.crt (certificate/public key)
UBOOT_SIGN_KEYDIR = "${TOPDIR}/../keys/fit"

# Base name of key files (without extension)
UBOOT_SIGN_KEYNAME = "fit-signing-key"

# Whether to auto-generate keys during build (default: "0")
# "1": generates keys into UBOOT_SIGN_KEYDIR during do_compile
# "0": requires keys to exist at UBOOT_SIGN_KEYDIR before build
FIT_GENERATE_KEYS = "0"
# Production builds MUST use "0" — auto-generated keys are not
# stored securely and would be regenerated on each clean build,
# invalidating all previously deployed images

# Signature algorithm
FIT_SIGN_ALG = "rsa2048"
# Options: "rsa2048", "rsa4096", "ecdsa256"
# Must be supported by both mkimage (on build host) and U-Boot (CONFIG_RSA, etc.)

# Hash algorithm
FIT_HASH_ALG = "sha256"
# Options: "sha1" (discouraged), "sha256", "sha384", "sha512"

# Key size in bits (informational, affects pkcs11 HSM lookup)
FIT_SIGN_NUMBITS = "2048"

# dtc options for mkimage (must accommodate large FIT images)
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 2000"
# -p 2000: reserve 2000 bytes padding in DTB for signature nodes
# Without sufficient padding, mkimage cannot add signature nodes in-place
```

### U-Boot Variables

```bitbake
# U-Boot defconfig (selects configuration)
UBOOT_MACHINE = "phycore-imx8mp_defconfig"

# DTB file embedded in U-Boot image (contains FIT public key after signing)
UBOOT_DTB_BINARY = "u-boot.dtb"

# U-Boot provider selection
PREFERRED_PROVIDER_virtual/bootloader = "u-boot-imx"

# U-Boot version pinning
PREFERRED_VERSION_u-boot-imx = "2024.01%"
```

### MACHINE_FEATURES and DISTRO_FEATURES

`MACHINE_FEATURES` declares hardware capabilities present on this board. Recipes check these to enable/disable software support:

```bitbake
MACHINE_FEATURES += "optee"    # OP-TEE Secure World OS
MACHINE_FEATURES += "tpm2"     # TPM2 hardware present
MACHINE_FEATURES += "bluetooth wifi"  # Connectivity (unrelated to secure boot)
```

`DISTRO_FEATURES` declares software features the distribution enables:

```bitbake
DISTRO_FEATURES:append = " security"
# Enables security framework: mandatory access control,
# security audit hooks, etc.

DISTRO_FEATURES:append = " ima"
# Enables IMA subsystem in kernel and userspace tooling

DISTRO_FEATURES:append = " smack"
# SMACK LSM (alternative to SELinux, simpler policy model)
# SMACK and SELinux cannot coexist; choose one

# Remove PAM if systemd handles authentication:
DISTRO_FEATURES:remove = "pam"
```

### Image Feature Control

```bitbake
# Remove debug features from production images
IMAGE_FEATURES:remove = "debug-tweaks"
# debug-tweaks enables: root login without password, /etc/resolv.conf
# symlink, allow-empty-password SSH, etc. Remove for production.

EXTRA_IMAGE_FEATURES = ""
# Ensure no debug features are added

# Explicit production image features
IMAGE_FEATURES = "read-only-rootfs"
# read-only-rootfs: mounts rootfs read-only; required for dm-verity
# (dm-verity cannot protect a writable filesystem)
```

### Package Exclusions

```bitbake
# Remove development/debug tools from production image
PACKAGE_EXCLUDE = "gcc g++ gdb binutils strace ltrace"

# Remove package managers (prevents in-field package installation)
PACKAGE_EXCLUDE:append = " opkg dpkg rpm"

# Alternatively, use IMAGE_INSTALL:remove in the image recipe:
# IMAGE_INSTALL:remove = "packagegroup-core-buildessential"
```

---

## Build Flow: From Source to Signed Artifacts

Understanding the task dependency graph is essential for debugging signing failures.

### Task Flow for fitImage Production

```
Kernel recipe (linux-imx):
  do_patch
    └── do_configure (runs make menuconfig / applies .cfg fragments)
          └── do_compile (make -j8)
                └── do_install (copies Image, DTBs to ${D})
                      └── do_assemble_fitimage  ← added by kernel-fitimage.bbclass
                          │  Creates ${WORKDIR}/fitImage.its (ITS source)
                          │  Invokes: mkimage -f fitImage.its fitImage-unsigned
                          │
                          └── do_uboot_assemble_fitimage  ← depends on U-Boot
                              │  Signs FIT: mkimage -F -k ${UBOOT_SIGN_KEYDIR}
                              │             -K u-boot.dtb fitImage-unsigned fitImage
                              │  (Signs in place; modifies fitImage-unsigned → fitImage)
                              │
                              └── do_deploy
                                  │  Copies: fitImage → ${DEPLOY_DIR_IMAGE}/
                                  │  Copies: fitImage.its → ${DEPLOY_DIR_IMAGE}/
                                  │  Copies: Image, *.dtb → ${DEPLOY_DIR_IMAGE}/
                                  └── (done)

U-Boot recipe (u-boot-imx):
  do_compile (builds u-boot-spl.bin, u-boot-nodtb.bin, u-boot.dtb)
    └── do_install
          └── [uboot-sign.bbclass] do_uboot_sign
              │  Embeds FIT public key into u-boot.dtb
              │  mkimage -F -k ${UBOOT_SIGN_KEYDIR} -K u-boot.dtb ...
              └── do_deploy
                  Copies: u-boot*.bin, u-boot.dtb → ${DEPLOY_DIR_IMAGE}/

Combined boot image recipe (imx-boot):
  do_compile[depends] += u-boot-imx:do_deploy trusted-firmware-a:do_deploy optee-os:do_deploy
    └── [imx-mkimage] combines all components → flash.bin
          └── do_deploy → imx-boot-*.bin
```

### Why u-boot.dtb Must Be Built Before fitImage Is Signed

The `do_uboot_assemble_fitimage` task (the signing step) writes the FIT signing public key node into `u-boot.dtb`. This means U-Boot must be compiled first (to produce `u-boot.dtb`), then the key is embedded, then the signed `fitImage` is produced. The task dependency chain enforces this order:

```
fitImage signing task (do_uboot_assemble_fitimage)
    depends on: u-boot-imx:do_deploy
```

If you change the FIT signing key, both U-Boot (to embed the new public key) and the FIT image (to sign with the new private key) must be rebuilt. The `UBOOT_SIGN_KEYNAME` variable change will trigger this automatically via BitBake's hash-based dependency tracking.

---

## OP-TEE Integration via MACHINE_FEATURES

When `MACHINE_FEATURES` includes `"optee"`, the following changes take effect:

```bitbake
# optee-os recipe is built when MACHINE_FEATURES contains "optee"
# Provides: tee.bin (OP-TEE OS binary, acts as BL32 in TF-A terminology)

# optee-client recipe provides userspace:
# - tee-supplicant daemon
# - libteec.so (TEE client library)
# - libutee.so (TA framework library)
# These are automatically included when optee is in MACHINE_FEATURES

# TF-A (trusted-firmware-a-imx) loads OP-TEE as BL32:
# In TF-A build: SPD=opteed BL32=tee.bin
# TF-A passes control to OP-TEE before booting U-Boot
```

The OP-TEE binary (`tee.bin`) is incorporated into the imx-boot combined image by imx-mkimage alongside TF-A BL31 and U-Boot. It is authenticated by HABv4/AHAB as part of the boot image, not separately.

---

## Production Security Configuration Summary

For a production phyCORE-i.MX8MP build, the following settings must be applied to `local.conf` or a distro configuration file:

```bitbake
# === Signed kernel image ===
KERNEL_IMAGETYPE = "fitImage"
KERNEL_CLASSES = "kernel-fitimage"
UBOOT_SIGN_ENABLE = "1"
UBOOT_SIGN_KEYDIR = "${TOPDIR}/../keys/fit"
UBOOT_SIGN_KEYNAME = "fit-signing-key"
FIT_GENERATE_KEYS = "0"
FIT_SIGN_ALG = "rsa2048"
FIT_HASH_ALG = "sha256"
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 2000"

# === No debug features ===
IMAGE_FEATURES:remove = "debug-tweaks"
EXTRA_IMAGE_FEATURES = ""
IMAGE_FEATURES = "read-only-rootfs"

# === No development packages ===
PACKAGE_EXCLUDE = "gcc g++ gdb binutils strace"

# === OP-TEE enabled ===
MACHINE_FEATURES:append = " optee"

# === Root filesystem will be dm-verity protected ===
# (dm-verity setup is handled post-build or by a dedicated image class)
IMAGE_FSTYPES = "wic.gz wic.bmap ext4"
# ext4 is needed as input for dm-verity hash tree generation
```

---

## Further Reading

- `01-yocto-layer-configuration.md`: Complete `bblayers.conf` and `local.conf` reference
- `02-kernel-fitimage-class.md`: `kernel-fitimage.bbclass` internals and generated ITS analysis
- `03-build-artifacts.md`: Complete deploy directory reference with verification commands
- Chapter 16 (`16-phytec-securiphy/`): PHYTEC's securiphy distribution that implements these patterns
- `openembedded-core/meta/classes/kernel-fitimage.bbclass`: Source code for the FIT assembly class
- `openembedded-core/meta/classes/uboot-sign.bbclass`: Source code for U-Boot key embedding class
- Yocto Project Reference Manual: https://docs.yoctoproject.org/ref-manual/
