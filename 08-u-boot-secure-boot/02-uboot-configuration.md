# U-Boot Configuration for Secure Boot

## Complete Kconfig Reference

```kconfig
# ============================================================
# FIT IMAGE SUPPORT
# ============================================================
CONFIG_FIT=y                          # Enable FIT image support
CONFIG_FIT_SIGNATURE=y                # Enable FIT signature verification (CRITICAL)
CONFIG_FIT_VERBOSE=y                  # Print detailed verification messages (dev)
CONFIG_FIT_BEST_MATCH=y               # Select best matching configuration
CONFIG_FIT_CIPHER=n                   # AES encryption (optional)
CONFIG_FIT_SIGNATURE_MAX_SIZE=0x10000000  # 256MB max FIT size

# ============================================================
# CRYPTOGRAPHIC SUPPORT
# ============================================================
CONFIG_RSA=y                          # RSA algorithm
CONFIG_RSA_SOFTWARE_EXP=y            # Software RSA exponentiation (ARM host)
CONFIG_SHA256=y                       # SHA-256 hash
CONFIG_SHA384=y                       # SHA-384 hash (stronger)
CONFIG_SHA512=y                       # SHA-512 hash
CONFIG_HASH=y                         # Hash framework
CONFIG_ASYMMETRIC_KEY_TYPE=y          # Asymmetric key support
CONFIG_ASYMMETRIC_PUBLIC_KEY_SUBTYPE=y
CONFIG_RSA_PUBLIC_KEY_PARSER=y

# ============================================================
# SECURITY HARDENING
# ============================================================
CONFIG_LEGACY_IMAGE_FORMAT=n          # Disable uImage format (less secure)
CONFIG_BOOTDELAY=-2                   # DISABLE boot countdown (production)
CONFIG_AUTOBOOT_STOP_STR=""           # No stop string
CONFIG_SILENT_CONSOLE=y              # Disable UART console (production)
CONFIG_SYS_DEVICE_NULLDEV=y          # Null device for silent console

# ============================================================
# ENVIRONMENT SECURITY
# ============================================================
# Option A: No persistent environment (most secure)
CONFIG_ENV_IS_NOWHERE=y

# Option B: Environment in eMMC (can be locked)
# CONFIG_ENV_IS_IN_MMC=y
# CONFIG_ENV_OFFSET=0x3F80000
# CONFIG_ENV_SIZE=0x40000

# Disable environment editing commands (production)
CONFIG_CMD_EDITENV=n
CONFIG_CMD_SETEXPR=n
CONFIG_CMD_LOADS=n
CONFIG_CMD_SAVES=n

# ============================================================
# REMOVE DANGEROUS COMMANDS (production)
# ============================================================
CONFIG_CMD_MEMORY=n                   # Remove md, mw, mm, mtest
CONFIG_CMD_I2C=n                      # Remove i2c commands (if not needed)
CONFIG_CMD_USB=n                      # Remove usb commands (if not needed)
CONFIG_CMD_NET=n                      # Remove network commands (if not needed)
CONFIG_CMD_MTDPARTS=n                 # Remove MTD partition commands
CONFIG_CMD_NAND=n                     # Remove NAND commands (if not used)

# ============================================================
# KEEP NECESSARY COMMANDS
# ============================================================
CONFIG_CMD_BOOTI=y                    # Boot arm64 kernel Image
CONFIG_CMD_BOOTM=y                    # Boot from FIT image
CONFIG_CMD_MMC=y                      # MMC access (for loading FIT)
CONFIG_CMD_FAT=y                      # FAT filesystem (for /boot)
CONFIG_CMD_EXT4=y                     # ext4 filesystem
CONFIG_CMD_FS_GENERIC=y               # Generic filesystem commands

# ============================================================
# HAB COMMANDS (i.MX specific)
# ============================================================
CONFIG_CMD_DEKBLOB=n                  # DEK blob (remove if not using encryption)
CONFIG_CMD_HAB=y                      # HAB status command (keep for validation)
# Note: Consider removing CONFIG_CMD_HAB in production after validation
```

## phyCORE-i.MX8MP Defconfig Secure Boot Fragment

Create `configs/phycore-imx8mp-secureboot.config`:

```kconfig
# Overlay this on top of phycore-imx8mp_defconfig

# FIT signing
CONFIG_FIT=y
CONFIG_FIT_SIGNATURE=y
CONFIG_FIT_VERBOSE=y
CONFIG_RSA=y
CONFIG_RSA_SOFTWARE_EXP=y
CONFIG_SHA256=y
CONFIG_SHA384=y

# Security hardening
CONFIG_LEGACY_IMAGE_FORMAT=n
CONFIG_BOOTDELAY=-2
CONFIG_ENV_IS_NOWHERE=y

# Remove dev commands
CONFIG_CMD_EDITENV=n
CONFIG_CMD_SETEXPR=n
```

## U-Boot Environment for Secure Boot

In a secure configuration, the environment is compiled in (`CONFIG_ENV_IS_NOWHERE=y`) and cannot be changed at runtime:

```bash
# Default compiled-in environment:
bootcmd=run secureboot
secureboot=run load_fitimage && run boot_fitimage
load_fitimage=load mmc ${mmcdev}:${mmcpart} ${fit_addr} fitImage
boot_fitimage=bootm ${fit_addr}
mmcdev=2
mmcpart=1
fit_addr=0x40400000

# Kernel arguments (include dm-verity)
bootargs=console=ttymxc1,115200 root=/dev/mapper/vroot rootwait ro quiet \
  dm-mod.create="vroot,,0,ro,0 ${data_blks} verity 1 \
  /dev/mmcblk2p2 /dev/mmcblk2p4 4096 4096 ${data_blks} 1 sha256 \
  ${root_hash} ${verity_salt}" \
  dm-verity.error_behavior=1
```

## Verifying U-Boot Configuration

```bash
# From U-Boot prompt (development only):

# Check FIT signature is required
=> env print fit_check_sig
# Not an env variable - it's compiled in via CONFIG_FIT_SIGNATURE

# Check HAB status
=> hab_status
HAB Configuration: 0xf0 HAB State: 0xf0
No HAB Events Found!

# Check boot delay
=> env print bootdelay
bootdelay=-2
# -2 means NO countdown, no way to interrupt

# Test FIT loading (verbose)
=> load mmc 2:1 0x40400000 fitImage
=> iminfo 0x40400000
=> bootm 0x40400000
```
