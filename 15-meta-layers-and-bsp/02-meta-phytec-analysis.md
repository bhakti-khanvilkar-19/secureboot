# meta-phytec Layer Analysis

## Overview

`meta-phytec` is PHYTEC's BSP layer providing machine definitions, board support packages, and the securiPHY framework for production secure boot deployments on PHYTEC hardware (phyCORE-i.MX8MP, etc.).

**Repository:** `https://github.com/phytec/meta-phytec`
**Yocto Release:** Kirkstone / Scarthgap

---

## Layer Structure (Security-Relevant)

```
meta-phytec/
├── classes/
│   ├── phytec-securiphy.bbclass     ← securiPHY signing pipeline
│   └── phytec-provisioning.bbclass  ← provisioning image class
├── conf/
│   └── machine/
│       └── phyboard-pollux-imx8mp-*.conf  ← Board machine definitions
├── recipes-bsp/
│   ├── u-boot/
│   │   ├── u-boot-imx_%.bbappend        ← PHYTEC defconfig + keydir
│   │   └── files/
│   │       ├── phyboard-pollux.cfg       ← U-Boot Kconfig fragment
│   │       └── phyboard-pollux-secure.cfg ← Secure boot Kconfig
│   └── imx-boot/
│       └── imx-boot_%.bbappend          ← PHYTEC flash.bin targets
├── recipes-kernel/
│   └── linux/
│       └── linux-phytec-imx_%.bbappend  ← Kernel config + FIT ITS
└── recipes-images/
    ├── phytec-securiphy-image.bb        ← Production secure image
    └── phytec-provisioning-image.bb     ← Factory provisioning image
```

---

## Machine Definition: phyboard-pollux-imx8mp-3

```bash
# meta-phytec/conf/machine/phyboard-pollux-imx8mp-3.conf

require conf/machine/imx8mp-phytec-common.conf

MACHINE = "phyboard-pollux-imx8mp-3"
MACHINE_FEATURES += "optee vpu gpu wifi bluetooth"

# U-Boot configuration
UBOOT_MACHINE = "phyboard-pollux-imx8mp_defconfig"
UBOOT_DTB_NAME = "imx8mp-phyboard-pollux-rdk-4.dtb"
SPL_BINARY = "spl/u-boot-spl.bin"

# Flash targets
IMXBOOT_TARGETS = "flash_evk flash_evk_flexspi"

# FIT image signing key (embedded in U-Boot DTB)
UBOOT_SIGN_ENABLE = "1"
UBOOT_SIGN_KEYDIR ?= "${TOPDIR}/keys/fit"
UBOOT_SIGN_KEYNAME ?= "phytec-fit-key"
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 2000"
```

---

## U-Boot Kconfig Fragment (Secure)

```bash
# meta-phytec/recipes-bsp/u-boot/files/phyboard-pollux-secure.cfg

CONFIG_FIT=y
CONFIG_FIT_SIGNATURE=y
CONFIG_FIT_VERBOSE=y
CONFIG_SPL_LOAD_FIT=y
CONFIG_SPL_FIT_SIGNATURE=y
CONFIG_RSA=y
CONFIG_RSA_SOFTWARE_EXP=y
CONFIG_CMD_IMX_HAB=y
CONFIG_IMX_HAB=y
CONFIG_SECURE_BOOT=y
CONFIG_SPL_CRYPTO=y
CONFIG_SPL_RSA=y
CONFIG_ENV_IS_IN_MMC=y
CONFIG_SYS_REDUNDAND_ENVIRONMENT=y
# Lock environment in CLOSED mode
CONFIG_ENV_WRITEABLE_LIST=""
```

---

## FIT ITS Template (PHYTEC)

```bash
# meta-phytec/recipes-kernel/linux/files/fitimage-phyboard-pollux.its.in

/dts-v1/;

/ {
    description = "phyCORE-i.MX8MP Production Secure Boot Image";
    #address-cells = <1>;

    images {
        kernel@1 {
            description = "Linux kernel";
            data = /incbin/("@@KERNEL_BINARY@@");
            type = kernel;
            arch = arm64;
            os = linux;
            compression = none;
            load = <0x40480000>;
            entry = <0x40480000>;
            hash@1 {
                algo = sha256;
            };
            signature@1 {
                algo = sha256,rsa2048;
                key-name-hint = "@@UBOOT_SIGN_KEYNAME@@";
            };
        };

        fdt@1 {
            description = "imx8mp-phyboard-pollux-rdk-4.dtb";
            data = /incbin/("@@DTB_BINARY@@");
            type = flat_dt;
            arch = arm64;
            compression = none;
            hash@1 {
                algo = sha256;
            };
        };

        ramdisk@1 {
            description = "initramfs";
            data = /incbin/("@@INITRAMFS_BINARY@@");
            type = ramdisk;
            arch = arm64;
            os = linux;
            compression = none;
            hash@1 {
                algo = sha256;
            };
        };
    };

    configurations {
        default = "conf@1";
        conf@1 {
            description = "phyCORE-i.MX8MP Secure Boot";
            kernel = "kernel@1";
            fdt = "fdt@1";
            ramdisk = "ramdisk@1";
            signature@1 {
                algo = sha256,rsa2048;
                key-name-hint = "@@UBOOT_SIGN_KEYNAME@@";
                sign-images = "kernel", "fdt", "ramdisk";
            };
        };
    };
};
```

---

## phytec-securiphy Image Recipe

```bash
# meta-phytec/recipes-images/phytec-securiphy-image.bb

require recipes-images/images/phytec-headless-image.bb

SUMMARY = "PHYTEC securiPHY hardened production image"

IMAGE_FEATURES:remove = "debug-tweaks allow-empty-password"
IMAGE_FEATURES:append = " read-only-rootfs"

IMAGE_INSTALL:append = " \
    swupdate \
    swupdate-client \
    optee-client \
    tpm2-tools \
    ima-evm-utils \
    cryptsetup \
"

# dm-verity rootfs
INHERIT += "dm-verity-image"

# FIT signing
UBOOT_SIGN_ENABLE = "1"

# Image format: ext4 + verity
IMAGE_FSTYPES = "ext4 wic.gz wic.bmap"

# Set dm-verity options
DM_VERITY_IMAGE = "${IMAGE_NAME}"
DM_VERITY_IMAGE_TYPE = "ext4"
```

---

## phytec-provisioning Image

```bash
# meta-phytec/recipes-images/phytec-provisioning-image.bb

SUMMARY = "PHYTEC factory provisioning image"

# Minimal image that:
# 1. Reads target device serial
# 2. Programs SRK fuses (if not yet programmed)
# 3. Writes production firmware
# 4. Closes device (SEC_CONFIG)
# 5. Reports pass/fail to factory MES

IMAGE_INSTALL = " \
    packagegroup-core-boot \
    openssh \
    bash \
    python3 \
    python3-cryptography \
    u-boot-tools \
    dtc \
    provisioning-scripts \
"

IMAGE_FEATURES = "ssh-server-openssh"
```

---

## securiPHY Signing Pipeline Integration

```bash
# meta-phytec/classes/phytec-securiphy.bbclass

# Variables consumed:
# PHYTEC_HAB_KEY_DIR  — path to HABv4 key directory
# PHYTEC_FIT_KEY_DIR  — path to FIT signing key directory
# PHYTEC_SIGN_SERVER  — optional: remote signing server URL

python do_securiphy_sign() {
    import subprocess, os

    hab_key_dir = d.getVar('PHYTEC_HAB_KEY_DIR')
    if not hab_key_dir:
        bb.fatal("PHYTEC_HAB_KEY_DIR must be set for securiPHY builds")

    # Invoke CST for HABv4 signing
    flash_bin = os.path.join(d.getVar('DEPLOY_DIR_IMAGE'),
                              'imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk')

    cst_path = d.getVar('STAGING_DIR_NATIVE') + '/usr/bin/cst'
    csf_template = d.getVar('WORKDIR') + '/imxboot_csf.cfg'

    # Generate CSF
    result = subprocess.run(
        [cst_path, '-o', 'imxboot_csf.bin', '-i', csf_template],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        bb.fatal(f"CST signing failed: {result.stderr}")

    bb.note("HABv4 signing complete")
}

addtask securiphy_sign after do_deploy before do_build
```

---

## Layer Configuration for PHYTEC Secure Boot

```bash
# build/conf/bblayers.conf
BBLAYERS ?= " \
  ${TOPDIR}/../poky/meta \
  ${TOPDIR}/../poky/meta-poky \
  ${TOPDIR}/../meta-openembedded/meta-oe \
  ${TOPDIR}/../meta-openembedded/meta-python \
  ${TOPDIR}/../meta-openembedded/meta-networking \
  ${TOPDIR}/../meta-openembedded/meta-filesystems \
  ${TOPDIR}/../meta-security \
  ${TOPDIR}/../meta-imx/meta-imx \
  ${TOPDIR}/../meta-imx/meta-sdk \
  ${TOPDIR}/../meta-phytec \
  ${TOPDIR}/../meta-ampliphy \
  ${TOPDIR}/../meta-your-custom-layer \
"

# build/conf/local.conf (security additions)
MACHINE = "phyboard-pollux-imx8mp-3"
DISTRO = "ampliphy-xwayland"  # or ampliphy-headless for minimal

# FIT signing
UBOOT_SIGN_ENABLE = "1"
UBOOT_SIGN_KEYDIR = "${TOPDIR}/keys/fit"
UBOOT_SIGN_KEYNAME = "phytec-fit-key"
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 2000"

# HABv4 signing
HAB_ENABLE = "1"
PHYTEC_HAB_KEY_DIR = "${TOPDIR}/keys/hab"
```

---

## Common PHYTEC BSP Issues

### FIT Key Not Found

```
ERROR: u-boot-imx-1.0-r0 do_compile: Command 'mkimage -F fitImage -k /path/to/keys -r' returned non-zero exit status 1
```

Fix:
```bash
# Verify key directory has both .pem and .crt files
ls ${UBOOT_SIGN_KEYDIR}/
# phytec-fit-key.pem
# phytec-fit-key.crt

# Key name must match UBOOT_SIGN_KEYNAME exactly
```

### DTB Padding Insufficient

```
ERROR: signatures node not found in DTB
```

Fix in local.conf:
```bash
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 4096"
```

---

## Cross-References

- [01-meta-imx-analysis.md](01-meta-imx-analysis.md) — NXP BSP layer
- [../16-phytec-securiphy/README.md](../16-phytec-securiphy/README.md) — securiPHY complete guide
- [../14-yocto-secure-boot/README.md](../14-yocto-secure-boot/README.md) — Yocto configuration
