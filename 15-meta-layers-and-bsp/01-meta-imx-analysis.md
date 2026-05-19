# meta-imx Layer Analysis

## Layer Overview

`meta-imx` is NXP's official BSP layer for i.MX SoCs. It provides machine definitions, kernel recipes, bootloader recipes, and — critically for secure boot — integration with the NXP Code Signing Tool (CST).

**Repository:** `https://github.com/nxp-imx/meta-imx`
**Compatible release:** Kirkstone / Scarthgap

---

## Directory Structure (Security-Relevant)

```
meta-imx/
├── classes/
│   ├── image_types_fsl.bbclass      ← Generates imx-boot / flash.bin
│   └── fsl-dynamic-packagearch.bbclass
├── conf/
│   ├── machine/
│   │   └── imx8mp-*.conf            ← Machine-specific MACHINE_FEATURES
│   └── distro/
│       └── fsl-imx-*.conf           ← Distro policies (INIT_MANAGER, etc.)
├── recipes-bsp/
│   ├── imx-boot/
│   │   └── imx-boot_%.bbappend      ← imx-mkimage invocation
│   ├── u-boot/
│   │   └── u-boot-imx_%.bbappend    ← U-Boot config fragments
│   └── optee-os/
│       └── optee-os_%.bbappend      ← OP-TEE build flags
├── recipes-kernel/
│   └── linux/
│       └── linux-imx_%.bbappend     ← Kernel defconfig fragments
└── recipes-security/
    └── cst/
        └── nxp-cst_%.bb             ← CST tool recipe
```

---

## image_types_fsl.bbclass — HABv4 Signing Integration

This class orchestrates imx-mkimage and optionally CST signing:

```bash
# Simplified version of what image_types_fsl.bbclass does:

# 1. Collect firmware artifacts
collect_firmware_artifacts() {
    cp ${DEPLOY_DIR_IMAGE}/imx-boot-tools/bl31-imx8mp.bin .
    cp ${DEPLOY_DIR_IMAGE}/imx-boot-tools/tee.bin .
    cp ${DEPLOY_DIR_IMAGE}/imx-boot-tools/u-boot-spl.bin-imx8mp+uboot .
    cp ${DEPLOY_DIR_IMAGE}/imx-boot-tools/u-boot-nodtb.bin .
    cp ${DEPLOY_DIR_IMAGE}/imx-boot-tools/imx8mp-phyboard-pollux-rdk-4.dtb .
    cp ${DEPLOY_DIR_IMAGE}/imx-boot-tools/ddr4_imem_1d.bin .
    # ... more DDR training firmware
}

# 2. Invoke imx-mkimage to bundle into flash.bin
make_flash_bin() {
    make -C ${STAGING_DIR_HOST}/usr/share/imx-mkimage \
        SOC=iMX8MP \
        flash_evk
}

# 3. If HAB signing enabled (HAB_ENABLE = "1"):
sign_with_cst() {
    ${STAGING_DIR_HOST}/usr/bin/cst \
        -o imxboot_csf.bin \
        -i ${CSF_TEMPLATE_DIR}/imxboot_csf.cfg
    cat flash.bin imxboot_csf.bin > flash-signed.bin
}
```

### Enabling HAB Signing in Your Recipe

```bash
# In your bbappend for imx-boot:
# meta-your-layer/recipes-bsp/imx-boot/imx-boot_%.bbappend

HAB_ENABLE = "1"
HAB_CST_KEY = "${TOPDIR}/keys/hab/CSF1_1_sha256_2048_65537_v3_usr_key.pem"
HAB_CST_CSFK_CERT = "${TOPDIR}/keys/hab/crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem"
HAB_CST_IMG_KEY = "${TOPDIR}/keys/hab/IMG1_1_sha256_2048_65537_v3_usr_key.pem"
HAB_CST_IMG_CERT = "${TOPDIR}/keys/hab/crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem"
HAB_SRK_TABLE = "${TOPDIR}/keys/hab/SRK_1_2_3_4_table.bin"
HAB_SRK_INDEX = "0"

# CST is a native tool — build it
DEPENDS += "nxp-cst-native"
```

---

## U-Boot Recipe in meta-imx

### Defconfig Fragments for Secure Boot

`meta-imx` appends config fragments to u-boot-imx:

```bash
# meta-imx/recipes-bsp/u-boot/u-boot-imx_%.bbappend (simplified)
SRC_URI:append:mx8mp-nxp-bsp = " \
    file://imx8mp_evk.config \
    file://secure-boot.config \
"
```

Contents of `secure-boot.config`:
```
CONFIG_FIT=y
CONFIG_FIT_SIGNATURE=y
CONFIG_RSA=y
CONFIG_SPL_FIT_SIGNATURE=y
CONFIG_SPL_LOAD_FIT=y
CONFIG_CMD_BOOTI=y
CONFIG_CMD_IMX_HAB=y
```

### U-Boot Machine Configuration

```bash
# meta-imx/conf/machine/imx8mp-evk.conf (excerpts)

UBOOT_CONFIG ??= "sd"
UBOOT_CONFIG[sd] = "imx8mp_evk_defconfig"
UBOOT_MACHINE = "imx8mp_evk_defconfig"
UBOOT_DTB_NAME = "imx8mp-evk.dtb"

# SPL/U-Boot split for imx-boot bundling
SPL_BINARY = "spl/u-boot-spl.bin"
UBOOT_SUFFIX = "bin"
```

---

## OP-TEE Integration in meta-imx

```bash
# meta-imx/recipes-security/optee-os/optee-os_%.bbappend

OPTEEMACHINE:mx8mp-nxp-bsp = "mx8mpevk"
EXTRA_OEMAKE:append:mx8mp-nxp-bsp = " \
    CFG_RPMB_FS=y \
    CFG_RPMB_FS_DEV_ID=0 \
    CFG_CORE_TEEPROF_FS_DIR=y \
    CFG_TEE_CORE_LOG_LEVEL=2 \
    CFG_WITH_SOFTWARE_PRNG=n \
    CFG_CAAM=y \
"

# For production:
EXTRA_OEMAKE:append:production = " \
    CFG_TEE_CORE_LOG_LEVEL=0 \
    CFG_SEMIHOSTING=n \
"
```

---

## Machine Features Relevant to Security

```bash
# In machine conf, these MACHINE_FEATURES activate security recipes:
MACHINE_FEATURES += " \
    optee \
    optee-ftpm \
    trustzone \
    secure-boot \
"

# 'optee' → pulls in optee-os, optee-client
# 'optee-ftpm' → adds fTPM TA
# 'trustzone' → kernel TrustZone drivers
# 'secure-boot' → activates signing classes
```

---

## Distro Policies (fsl-imx-*.conf)

```bash
# meta-imx/conf/distro/fsl-imx-xwayland.conf (security-relevant excerpts)

DISTRO_FEATURES:append = " \
    pam \
    largefile \
    opengl \
    wayland \
"

# For secure distro, add:
# DISTRO_FEATURES:append = " tpm2 "
# DISTRO_FEATURES:append = " dm-verity "
```

---

## Debugging meta-imx Build Issues

### Check Layer Version Compatibility

```bash
# In your build directory:
bitbake-layers show-layers
bitbake-layers show-overlayed

# Check for recipe conflicts:
bitbake-layers show-recipes | grep u-boot
```

### HABv4 Signing Not Running

```bash
# Verify HAB_ENABLE is set:
bitbake -e imx-boot | grep "^HAB_ENABLE"

# Check CST is available:
bitbake -e imx-boot | grep "^HAB_CST"

# Check signing task:
bitbake imx-boot -c listtasks | grep sign
```

### Wrong U-Boot Config

```bash
# Show all config fragments applied:
bitbake -e u-boot-imx | grep "^SRC_URI"

# Show final defconfig:
bitbake u-boot-imx -c configure && \
    cat tmp/work/imx8mp_evk-poky-linux/u-boot-imx/*/build/.config | \
    grep -E "FIT|HAB|SIGN"
```

---

## Cross-References

- [02-meta-phytec-analysis.md](02-meta-phytec-analysis.md) — PHYTEC layer overrides
- [../14-yocto-secure-boot/01-yocto-layer-configuration.md](../14-yocto-secure-boot/01-yocto-layer-configuration.md) — Full layer configuration
- [../12-habv4-imx8m/04-cst-workflow.md](../12-habv4-imx8m/04-cst-workflow.md) — CST usage details
