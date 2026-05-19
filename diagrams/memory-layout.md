# Memory Layout Diagram

## eMMC Partition Layout

```
eMMC (8GB example):
┌──────────────────────────────────────────────────────────────┐
│ Boot0 partition (4MB)                                        │
│  Offset 0x000: imx-boot.bin-flash_evk-signed                │
│  (SPL + DDR FW + TF-A BL31 + OP-TEE BL32 + U-Boot BL33)    │
│  + CSF appended (HABv4 signature)                            │
├──────────────────────────────────────────────────────────────┤
│ Boot1 partition (4MB)                                        │
│  Offset 0x000: imx-boot.bin-flash_evk-signed (backup)       │
│  (Same as Boot0, or previous firmware version)               │
├──────────────────────────────────────────────────────────────┤
│ User Area:                                                   │
│                                                              │
│  mmcblk2p1 (64MB)  ─── boot-a partition                     │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ fitImage (signed FIT: kernel + DTB + initramfs)        │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  mmcblk2p2 (64MB)  ─── boot-b partition (A/B update)        │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ fitImage (OTA update target)                           │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  mmcblk2p3 (2GB)   ─── rootfs-a partition                   │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ ext4 (read-only, no journal)                           │  │
│  │ + dm-verity hash tree (appended)                       │  │
│  │ Mounted as: /dev/mapper/vroot → /                      │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  mmcblk2p4 (2GB)   ─── rootfs-b partition (A/B update)      │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ ext4 (OTA update target)                               │  │
│  │ + dm-verity hash tree (appended)                       │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  mmcblk2p5 (256MB) ─── data partition                       │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ LUKS2 encrypted ext4                                   │  │
│  │ Key: TPM-sealed (PCR-bound)                            │  │
│  │ Mounted as: /dev/mapper/data → /data                   │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  mmcblk2p6 (128MB) ─── U-Boot environment                   │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ U-Boot env (BOOT_ORDER, BOOT_A_LEFT, etc.)             │  │
│  │ Redundant copy                                         │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  mmcblk2p7 (RPMB)  ─── Replay Protected Memory Block        │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ OP-TEE secure storage (authenticated by RPMB key)      │  │
│  │ RPMB key derived from HUK                              │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

## RAM Layout During Boot

```
DDR (1GB example, base 0x40000000):
┌────────────────────────────────────────────────────────────┐
│ 0x40000000: TF-A BL31 (EL3 Secure Monitor)    ~512KB      │
│ 0x40200000: OP-TEE BL32 (Trusted OS)           ~32MB      │
│             (+ OP-TEE heap, secure storage)               │
│ 0x56000000: OP-TEE end                                    │
├────────────────────────────────────────────────────────────┤
│ 0x40400000: U-Boot text + data                  ~1.5MB    │
│ 0x43000000: U-Boot/Board DTB (with embedded key) ~128KB  │
│             (← FIT public key embedded here)              │
├────────────────────────────────────────────────────────────┤
│ 0x50000000: FIT image (loaded by U-Boot)         ~25MB   │
│             (fitImage: kernel + DTB + ramdisk)            │
├────────────────────────────────────────────────────────────┤
│ 0x40480000: Linux kernel (extracted from FIT)    ~20MB   │
│             (decompressed and executed here)              │
│ 0x43000000: Board DTB (from FIT)                  ~64KB  │
│ 0x44000000: Initramfs (from FIT)                   ~5MB  │
│ 0x50000000: Kernel heap and data                         │
│             (grows toward higher addresses)               │
├────────────────────────────────────────────────────────────┤
│ 0x7E1000:   SPL load address (during ROM phase)           │
│             (ROM loads SPL here from eMMC boot0)          │
└────────────────────────────────────────────────────────────┘
```

## WKS File (Wic Kickstart) for Partition Layout

```bash
# meta-phytec/wic/phytec-securiphy.wks

# Bootloader (imx-boot) on boot0 — handled by imx-boot recipe
# User partition layout:

part --source rawcopy --sourceparams="file=fitImage" \
     --ondisk mmcblk2 --part-name boot-a --fixed-size 64M --fstype=none

part --source rawcopy --sourceparams="file=fitImage" \
     --ondisk mmcblk2 --part-name boot-b --fixed-size 64M --fstype=none

part / --source rootfs --ondisk mmcblk2 --part-name rootfs-a \
     --fstype=ext4 --label rootfs-a --fixed-size 2G

part --ondisk mmcblk2 --part-name rootfs-b --fixed-size 2G --fstype=none

part /data --ondisk mmcblk2 --part-name data --fixed-size 256M \
     --fstype=ext4 --label data

part --ondisk mmcblk2 --part-name env --fixed-size 128M --fstype=none
```
