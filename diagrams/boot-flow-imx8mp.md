# i.MX8MP Boot Flow Diagram

## Boot Sequence

```mermaid
sequenceDiagram
    participant ROM as ROM (BL0)
    participant DDR as DDR Init
    participant SPL as SPL (BL1)
    participant TFA as TF-A BL31
    participant OPTEE as OP-TEE BL32
    participant UBOOT as U-Boot BL33
    participant LINUX as Linux Kernel

    Note over ROM: Power-on reset
    ROM->>ROM: Read BOOT_MODE pins
    ROM->>ROM: Read BOOT_CFG fuses
    ROM->>ROM: Initialize boot media (eMMC/SD)
    ROM->>ROM: Load IVT from offset 0x400 (SD) or 0x0 (eMMC boot0)
    ROM->>ROM: Parse IVT → locate SPL entry, DCD, CSF

    Note over ROM: HABv4 authentication
    ROM->>ROM: Install SRK (verify vs OCOTP fuses)
    ROM->>ROM: Install CSF key (verify cert chain)
    ROM->>ROM: Authenticate CSF
    ROM->>ROM: Authenticate Data (verify imx-boot binary)

    alt CLOSED mode + auth success
        ROM->>DDR: Load and execute DCD (DDR training)
    else CLOSED mode + auth fail
        ROM->>ROM: HAB_FAIL → halt
    else OPEN mode (any auth result)
        ROM->>DDR: Continue (log events)
    end

    DDR->>SPL: DDR operational → jump to SPL entry
    Note over SPL: ~10ms

    SPL->>SPL: Initialize clocks, UART
    SPL->>SPL: Load TF-A BL31 from eMMC
    SPL->>SPL: Load OP-TEE BL32 from eMMC
    SPL->>SPL: Load U-Boot BL33 from eMMC

    SPL->>TFA: Hand off to TF-A BL31
    Note over TFA: EL3 (Secure Monitor)

    TFA->>OPTEE: Initialize OP-TEE at EL1-S
    OPTEE->>OPTEE: Initialize CAAM driver
    OPTEE->>OPTEE: Initialize RPMB key
    OPTEE->>OPTEE: Start fTPM TA
    OPTEE->>TFA: OP-TEE ready

    TFA->>UBOOT: Jump to U-Boot at EL2/EL1-NS
    Note over UBOOT: ~200ms from SPL start

    UBOOT->>UBOOT: Initialize peripherals
    UBOOT->>UBOOT: Load fitImage from eMMC partition
    UBOOT->>UBOOT: Verify FIT configuration signature (RSA-2048)
    UBOOT->>UBOOT: Verify component hashes (SHA-256)

    alt FIT signature valid
        UBOOT->>LINUX: bootm → jump to kernel entry
    else FIT signature invalid
        UBOOT->>UBOOT: "ERROR: Bad signature!" → halt
    end

    Note over LINUX: EL1-NS

    LINUX->>LINUX: Decompress and initialize
    LINUX->>LINUX: Mount initramfs
    LINUX->>LINUX: Unseal LUKS key from TPM (if configured)
    LINUX->>LINUX: Activate dm-verity: veritysetup open
    LINUX->>LINUX: Mount /dev/mapper/vroot as /
    LINUX->>LINUX: Switch root to dm-verity rootfs
    LINUX->>LINUX: Start systemd
```

## Timing Reference

| Stage | Typical Duration | Notes |
|-------|-----------------|-------|
| ROM + DDR init | 500ms–2s | DDR training is slow |
| SPL | 50–200ms | Loading TF-A + OP-TEE + U-Boot |
| TF-A/OP-TEE init | 100–300ms | CAAM init, RPMB key |
| U-Boot | 200ms–2s | Depends on env, FIT load |
| Linux boot | 3–15s | Depends on rootfs size, init |
| **Total** | **4–20s** | Optimize if needed |

## Memory Map at Boot

```
0x00000000 ┌─────────────────────────────┐
           │  ROM (read-only)             │  ~96KB
0x00017FFF └─────────────────────────────┘
           ...
0x7E1000   ┌─────────────────────────────┐
           │  SPL (loaded by ROM)         │  ~256KB max
0x821000   └─────────────────────────────┘
           ...
0x40000000 ┌─────────────────────────────┐
           │  DDR (start)                 │
           │  TF-A BL31: 0x40000000      │  ~512KB
           │  OP-TEE:    0x56000000      │  ~2MB
           │  U-Boot:    0x40400000      │  ~1.5MB
           │  U-Boot DTB: 0x43000000     │  ~64KB
           │  FIT image:  0x50000000     │  ~25MB
           │  Kernel:     0x40480000     │  ~20MB
           │  DTB:        0x43000000     │  ~64KB
           │  Ramdisk:    0x44000000     │  ~5MB
0xC0000000 └─────────────────────────────┘
           DDR end (1GB configuration)
```
