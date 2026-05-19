# Secure OTA Updates

## Overview

Over-the-air (OTA) update security is the second-most critical attack surface after initial boot authentication. A compromised OTA mechanism allows an attacker to replace legitimate firmware with malicious firmware — even on an otherwise secure device.

## Security Requirements for OTA

```
1. Authentication:   Only updates signed by authorized key are accepted
2. Integrity:        Update package is not tampered in transit or storage
3. Anti-rollback:    Device cannot be downgraded to vulnerable firmware
4. Atomicity:        Update either completes fully or rolls back (no bricked state)
5. Authorization:    Device validates it is the intended recipient (optional)
6. Audit:            All update operations logged with provenance
```

## OTA Framework Options

| Framework | Language | A/B Support | Signing | Anti-rollback | Used by |
|-----------|----------|-------------|---------|---------------|---------|
| SWUpdate  | C        | Yes (libubootenv) | CMS/RSA, HW | Fuse counter | PHYTEC, many |
| RAUC      | C/GLib   | Yes (bootchooser) | CMS/RSA | Bundle version | Many |
| Mender    | Go       | Yes | JWT/RSA | Artifact version | Mender.io SaaS |
| FOTA-AWS  | C        | Yes | Code signing | Version check | AWS IoT |

## A/B Partition Layout

```
eMMC partitions for A/B update:

Partition   Size    Contents
─────────────────────────────────────────────
boot0       4MB     imx-boot (HABv4 signed)
boot1       4MB     imx-boot (HABv4 signed, backup)
mmcblk2p1   64MB    boot-a (FIT image: kernel+DTB+initramfs)
mmcblk2p2   64MB    boot-b (FIT image: backup slot)
mmcblk2p3   2GB     rootfs-a (dm-verity protected ext4)
mmcblk2p4   2GB     rootfs-b (dm-verity protected ext4, backup slot)
mmcblk2p5   128MB   data (LUKS2 encrypted, persistent across updates)

Active slot determined by:
  U-Boot env: BOOT_ORDER=A B  (or B A after update)
  SWUpdate/RAUC: updates inactive slot, marks active on success
```

## Signing Architecture

```
Update package signing (offline, air-gapped):

  artifacts/
  ├── sw-description        ← Update manifest (SWUpdate) or bundle.raucm (RAUC)
  ├── fitImage              ← Signed FIT (already signed by FIT key)
  ├── imx-boot-signed.bin   ← HABv4 signed boot image
  └── rootfs.ext4.gz        ← Compressed rootfs

  Signing:
  openssl cms -sign -in sw-description -out sw-description.sig ...

  Package:
  ls artifacts/ | cpio -ovL -H newc > update-v2.0.swu

  Transport:
  HTTPS upload to OTA server → signed with server TLS cert
  Device downloads → validates package signature before applying
```

## Cross-References

- [01-swupdate-integration.md](01-swupdate-integration.md) — SWUpdate setup and configuration
- [02-rauc-integration.md](02-rauc-integration.md) — RAUC setup and configuration
- [03-anti-rollback.md](03-anti-rollback.md) — Anti-rollback mechanisms
- [../10-image-signing/01-signing-workflows.md](../10-image-signing/01-signing-workflows.md) — Package signing workflow
- [../11-key-management/README.md](../11-key-management/README.md) — OTA key management
