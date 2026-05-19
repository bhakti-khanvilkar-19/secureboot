# U-Boot Hardening

## Overview

U-Boot in production must be locked down to prevent runtime bypass of the verification chain. An attacker with UART access to U-Boot can issue arbitrary commands, load unsigned images, and bypass every security control.

---

## Lock the U-Boot Console

### Option 1: Disable Console Entirely (Highest Security)

```bash
# Kconfig:
CONFIG_CONSOLE_DISABLE_UBOOT_INIT=y  # Disable early console
CONFIG_SILENT_CONSOLE=y               # No output
CONFIG_SYS_DEVICE_NULLDEV=y           # Null device for silent mode

# Set at runtime (in U-Boot env before closing):
U-Boot> setenv silent 1
U-Boot> saveenv
```

### Option 2: Password-Protected Console

```bash
# Kconfig:
CONFIG_CMDLINE_EDITING=y
CONFIG_HUSH_PARSER=y
CONFIG_CMD_CONSOLE=y

# In U-Boot environment (set before closing):
CONFIG_AUTOBOOT_STOP_STR="specialpassword"

# Or use bootmenu with timeout:
CONFIG_BOOTDELAY=-1  # No autoboot delay (boot immediately)
# If set to -2: U-Boot boots immediately, console never interrupts
```

### Option 3: HABv4 Closed Mode (Best)

In CLOSED mode, U-Boot verifies FIT before loading. An attacker at the U-Boot console can run commands but cannot boot their own unsigned kernel — the `bootm` command will reject unsigned FIT images.

---

## Lock U-Boot Environment

In production, the boot environment must not be modifiable:

```bash
# Kconfig options:
CONFIG_ENV_IS_NOWHERE=y        # No environment storage — all defaults
# OR:
CONFIG_ENV_IS_IN_MMC=y
CONFIG_ENV_WRITEABLE_LIST=""   # No variables are writable (empty list)

# Alternatively, lock specific variables:
CONFIG_ENV_WRITEABLE_LIST="ethaddr serial#"  # Only these are writable

# Prevent env save from running:
CONFIG_CMD_SAVEENV=n  # Remove saveenv command
```

### Hardcoded Boot Arguments

Instead of reading bootargs from environment, compile into U-Boot:

```c
/* board/phytec/phyboard_pollux/phyboard_pollux.c */

int board_late_init(void)
{
#ifdef CONFIG_PRODUCTION_SECURE
    /* Override any environment bootargs with hardcoded production values */
    env_set("bootargs",
        "console=ttymxc1,115200n8 "
        "root=/dev/mapper/vroot "
        "rootfstype=ext4 rootwait ro quiet "
        "panic=5 lockdown=confidentiality "
        "systemd.verity=yes "
        "systemd.verity_root_hash=" VERITY_ROOT_HASH " "
        "systemd.verity_root_data=/dev/mmcblk2p3"
    );
#endif
    return 0;
}
```

---

## Remove Development Commands

```bash
# Kconfig: Remove dangerous commands in production:
CONFIG_CMD_LOADS=n        # No S-record download
CONFIG_CMD_LOADB=n        # No Kermit download
CONFIG_CMD_MEMTEST=n      # No memory test (can leak data)
CONFIG_CMD_JTAG=n         # No JTAG backdoor command
CONFIG_CMD_NET=n          # No network (tftp, nfs, ping)
CONFIG_CMD_NFS=n
CONFIG_CMD_PING=n
CONFIG_CMD_MII=n          # No MII/PHY debugging
CONFIG_CMD_CACHE=n        # No cache manipulation

# Keep only what's needed:
CONFIG_CMD_MMC=y          # eMMC access (required for boot)
CONFIG_CMD_EXT4=y         # EXT4 filesystem
CONFIG_CMD_FAT=y          # FAT filesystem (for /boot)
CONFIG_CMD_BOOTZ=n        # Old-style boot (use bootm for FIT)
CONFIG_CMD_BOOTM=y        # FIT image boot
CONFIG_CMD_IMX_HAB=y      # HABv4 status check (keep for diagnostics)
CONFIG_CMD_FUSE=y         # Fuse read (keep for diagnostics, consider removing write)
```

---

## Restrict fuse Command

```bash
# In production: allow fuse read, prevent write
# (If fuses already programmed, no reason to write again)

# Option: Patch fuse_prog to always return error in production builds
# Or: Remove CMD_FUSE entirely if not needed after provisioning
CONFIG_CMD_FUSE=n  # After factory provisioning complete
```

---

## Protect U-Boot from Physical Debug

### Disable JTAG (Fuse)

```bash
# JTAG disable fuse on i.MX8MP:
# Bank 1, Word 3, bit 6 = JTAG_SMODE[1]
# Bank 1, Word 3, bit 7 = JTAG_SMODE[0]

# JTAG_SMODE = 01: JTAG disabled in CLOSED mode
# Program during factory closure:
U-Boot> fuse prog -y 1 3 0x40  # JTAG_SMODE[0] = 1

# After this, JTAG is disabled when device is in CLOSED mode
# (Even with physical JTAG header access, no debug access)
```

---

## U-Boot Verified Boot Configuration Summary

```bash
# Complete production-secure U-Boot Kconfig fragment:

# === FIT and Signing ===
CONFIG_FIT=y
CONFIG_FIT_SIGNATURE=y
CONFIG_FIT_VERBOSE=n          # No verbose FIT output in production
CONFIG_RSA=y
CONFIG_SPL_FIT_SIGNATURE=y
CONFIG_SPL_LOAD_FIT=y

# === HABv4 ===
CONFIG_IMX_HAB=y
CONFIG_CMD_IMX_HAB=y          # Keep for diagnostics

# === Environment lockdown ===
CONFIG_ENV_IS_IN_MMC=y
CONFIG_ENV_WRITEABLE_LIST=""
CONFIG_CMD_SAVEENV=n
CONFIG_BOOTDELAY=-2           # Boot immediately, no interrupt

# === Remove debug commands ===
CONFIG_CMD_NET=n
CONFIG_CMD_LOADS=n
CONFIG_CMD_LOADB=n
CONFIG_CMD_MEMTEST=n
CONFIG_CMD_JTAG=n

# === Console lockdown ===
CONFIG_SILENT_CONSOLE=y
CONFIG_CONSOLE_DISABLE_UBOOT_INIT=y

# === Security ===
CONFIG_USE_BOOTCOMMAND=y
# CONFIG_BOOTCOMMAND hardcoded to boot signed FIT only
```

---

## Anti-Rollback in U-Boot

```c
/* U-Boot anti-rollback check during FIT verification */

/* In board_late_init or before bootm: */
static int check_anti_rollback(void)
{
    u32 fuse_word;
    u32 min_version;
    u32 image_version;

    /* Read minimum version from fuse */
    fuse_read(4, 0, &fuse_word);
    min_version = __builtin_popcount(fuse_word);

    /* Read image version from FIT */
    /* ... parse /images/kernel@1/version property ... */

    if (image_version < min_version) {
        printf("SECURITY: Anti-rollback! Image ver %u < fuse ver %u\n",
               image_version, min_version);
        return -EPERM;
    }
    return 0;
}
```

---

## Verification After Hardening

```bash
# From UART (before console lock): verify settings
U-Boot> env print | grep -E "bootargs|bootcmd|silent"
U-Boot> version
U-Boot> hab_status

# Attempt to interrupt (should fail with BOOTDELAY=-2):
# Power cycle — U-Boot should boot immediately without prompt

# Attempt to load unsigned kernel (should fail):
U-Boot> tftp ${kernel_addr} unsigned-kernel
U-Boot> bootm ${kernel_addr}
# Expected: "FIT: configuration 'conf@1' verification failed"
```

---

## Cross-References

- [../08-u-boot-secure-boot/02-uboot-configuration.md](../08-u-boot-secure-boot/02-uboot-configuration.md) — Full U-Boot configuration
- [01-kernel-hardening.md](01-kernel-hardening.md) — Kernel hardening
- [03-filesystem-hardening.md](03-filesystem-hardening.md) — Filesystem hardening
