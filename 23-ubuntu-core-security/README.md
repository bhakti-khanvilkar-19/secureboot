# 23 — Ubuntu Core Security for Embedded Linux

## Overview

Ubuntu Core is Canonical's minimal, fully transactional Linux distribution built around the snap package system. Unlike traditional embedded Linux distributions built with Yocto/Buildroot or a custom Debian derivative, Ubuntu Core treats every component of the system — including the kernel, base OS, and applications — as a versioned, signed snap package. This architectural choice has profound implications for secure boot, update security, and factory provisioning.

This chapter examines Ubuntu Core from the perspective of an engineer who already understands HABv4, FIT image signing, and Yocto-based secure boot. The question is not "is Ubuntu Core secure?" but rather "what security properties does Ubuntu Core provide, how does it provide them, what are its gaps, and when is it the right choice for an embedded i.MX8MP project?"

---

## Ubuntu Core Architecture

### Layered Snap Architecture

Ubuntu Core decomposes the system into four categories of snap:

```
┌─────────────────────────────────────────────────────────────┐
│                      App Snaps                              │
│         (your application, installed via snap store         │
│          or side-loaded with assertions)                    │
├─────────────────────────────────────────────────────────────┤
│                     Base Snap                               │
│    core20 / core22 / core24                                 │
│    (minimal Ubuntu userland: libc, busybox utilities,       │
│     daemons; replaces traditional rootfs)                   │
├─────────────────────────────────────────────────────────────┤
│                    Kernel Snap                              │
│    (Linux kernel + initramfs + DTB for your hardware)       │
├─────────────────────────────────────────────────────────────┤
│                    Gadget Snap                              │
│    (bootloader, partition layout, hardware-specific         │
│     boot assets: u-boot.env, imx-boot, DTBs)               │
└─────────────────────────────────────────────────────────────┘
```

Each layer is an immutable, read-only SquashFS image with cryptographic signature. Snaps are content-addressed — the same hash means the same content, regardless of when or where it was downloaded.

### Snap Store and Signing Infrastructure

The global Snap Store (snapcraft.io) is Canonical's centralized distribution and signing infrastructure. Every snap published to the store is:

1. Reviewed (automated + manual for store-published snaps)
2. Signed by the store's key: `canonical-signing-key`
3. Accompanied by a snap assertion (snap-revision) binding hash to version number to developer account

For embedded devices, you operate either against the global store, a Proxy Store, or a completely custom/offline signing infrastructure. The signing model is identical in all three cases — only who holds the signing key changes.

---

## Ubuntu Core Secure Boot Model

### Boot Chain on i.MX8MP (ARM64)

The Ubuntu Core secure boot chain on a non-x86 platform like i.MX8MP is significantly more complex than on PC, because UEFI Secure Boot (the native mechanism Ubuntu Core was designed around) is not available in the same form.

```
NXP ROM
  │ HABv4 authenticates imx-boot (SPL+TF-A container)
  ▼
imx-boot (SPL + TF-A BL31 + OP-TEE)
  │ Compiled into gadget snap or standalone
  │ TF-A runs in EL3, sets up secure world
  ▼
U-Boot (in gadget snap or kernel snap)
  │ U-Boot is compiled with UEFI capsule support
  │ or with FIT image signing (non-UEFI path)
  ▼
Ubuntu Core boot path (two variants):

  Path A: UEFI Secure Boot (preferred by Canonical)
    U-Boot acts as UEFI firmware
    shim.efi is first UEFI boot target
    shim → grub.efi (signed by shim's embedded cert)
    grub → linux kernel (verified against grub's keyring)

  Path B: FIT image path (more common for i.MX8MP)
    U-Boot loads FIT image containing kernel + DTB
    FIT verified against key embedded at U-Boot build time
    This path requires custom gadget/kernel snaps
```

### UEFI Path Details

When U-Boot is compiled with `CONFIG_EFI_LOADER=y` and `CONFIG_EFI_SECURE_BOOT=y`, it implements a subset of the UEFI Secure Boot specification:

- **PK (Platform Key):** Controls who can modify Secure Boot databases. Generated during device provisioning, often stored in U-Boot's environment or EFI variable partition.
- **KEK (Key Exchange Key):** Can update DB/DBX.
- **DB (Allowed):** Certificates of allowed boot binaries.
- **DBX (Forbidden):** Hashes and certificates of revoked binaries.

For Ubuntu Core, the chain is:
1. `shim.efi` is signed by Microsoft's UEFI CA (for PC) or by Canonical's ARM Secure Boot key
2. `shim` contains Canonical's key embedded in its `vendor_cert.h`
3. `grub.efi` is signed by the key in shim
4. The kernel is loaded and verified by GRUB against its keyring

On i.MX8MP, you replace the Microsoft-signed shim with your own shim or skip shim entirely if you control the entire chain.

### snap Assertions as the Second Layer of Boot Security

Separate from binary verification during boot, Ubuntu Core uses **assertions** — cryptographically signed JSON-like documents — to establish:

- Which snaps are permitted on which device
- What version of a snap is canonical
- What the device's identity is
- Who authorized the installation

Assertions are verified by `snapd` (the snap daemon) at runtime. Even if a snap binary could somehow be loaded, snapd would reject it without a valid assertion chain.

---

## Snap Assertions System

### Assertion Format

Assertions are signed, structured text documents. Example snap-revision assertion:

```
type: snap-revision
authority-id: canonical
snap-sha3-384: QlqR0uAWEAWF5Nwnzj5kqmmwFslYPu1IL16MKtLKnkTzetculyVpMm1amltSCBDz
snap-id: buPKUD3TKqCOgLEjjHx5kSiCpIs5cMuQ
snap-revision: 99
snap-size: 12345678
timestamp: 2024-01-15T10:00:00Z
sign-key-sha3-384: BWDEoaqyr25nF5SNCvL1W1J2HxJ0c5Ws9BjFRlV4nMEikfBW3bDcAA

AcLBXAQAAQoABgUCZacpAAAKCRA...
(base64-encoded signature)
```

Key fields:
- `authority-id`: Who signed this assertion (account ID of the authority)
- `snap-sha3-384`: SHA3-384 hash of the snap SquashFS
- `snap-id`: Unique, immutable identifier assigned by the store at publication time
- `sign-key-sha3-384`: Which key signed this assertion (links to account-key assertion)

### Assertion Types

| Type | Purpose | Signed by |
|------|---------|-----------|
| `account` | Declares a developer/brand account | Canonical |
| `account-key` | Registers a public key as belonging to an account | Canonical |
| `snap-declaration` | Declares a snap exists, its ID, name, and permissions | Canonical or brand |
| `snap-revision` | Binds a snap hash to a revision number | Store / brand |
| `model` | Declares device model: allowed snaps, kernel, gadget | Brand account |
| `serial` | Per-device identity: serial number bound to model | Serial Vault / brand |

### Model Assertion

The model assertion is the foundation of Ubuntu Core device identity. It defines what is a valid Ubuntu Core device of a given type:

```yaml
type: model
authority-id: your-brand-account-id
brand-id: your-brand-account-id
model: phyboard-pollux-imx8mp
architecture: arm64
base: core22
grade: signed          # or: dangerous (development), secured (with FDE)

snaps:
  - name: pi-kernel     # replace with your custom kernel snap
    id: jeIkYVdcBHkgL3zaaDeNatNmP3BnOg2t
    type: kernel
    default-channel: 22/stable

  - name: phyboard-pollux-gadget
    id: your-gadget-snap-id
    type: gadget
    default-channel: 22/stable

  - name: core22
    id: amcUKQILKXHHTlmSa7NMdnXSx02dNeeT
    type: base
    default-channel: latest/stable

  - name: your-app
    id: your-app-snap-id
    type: app
    default-channel: latest/stable

timestamp: 2024-01-15T10:00:00.000Z
sign-key-sha3-384: <sha3-384 of brand key>

AcLBXAQAAQoABgUCZacpAAA...
(base64 signature by brand account key)
```

Key fields:
- `grade`: `dangerous` allows unsigned snaps (development), `signed` requires assertions, `secured` enables FDE
- `brand-id`: Your company's Snap Store account ID
- Every snap listed must have a valid snap-declaration + snap-revision assertion

### Serial Assertion and the Serial Vault

The serial assertion binds a device to its serial number:

```yaml
type: serial
authority-id: your-brand-account-id
brand-id: your-brand-account-id
model: phyboard-pollux-imx8mp
serial: SN-2024-001234
device-key: AcbDTQRWhcGAARAA...   (device's RSA public key)
device-key-sha3-384: abc123...
timestamp: 2024-01-15T10:05:00Z
body-length: 0
sign-key-sha3-384: <brand key sha3-384>

AcLBXAQAAQoABgUCZacpAAA...
```

The **Serial Vault** is Canonical's service (or your self-hosted equivalent) that:
1. Receives the device's RSA public key (generated fresh on first boot)
2. Issues a signed serial assertion back to the device
3. Records the mapping: brand+model+serial → device key → timestamp

This enables per-device identity without pre-provisioning individual keys at the factory.

---

## Full Disk Encryption in Ubuntu Core

### Architecture

Ubuntu Core FDE (grade: `secured`) uses a TPM 2.0 (or equivalent secure element) to seal the LUKS key against the boot state:

```
Boot measurement sequence:
  ROM → SPL → TF-A → U-Boot
        Each stage extends PCRs in TPM

TPM PCR sealing:
  LUKS key sealed against PCR[4] (bootloader) + PCR[7] (Secure Boot state) + PCR[11] (snap boot state)

On each boot:
  TPM unseals key only if current PCR values match sealed values
  LUKS key used to open LUKS container holding ubuntu-data partition
  If PCR values differ (firmware update, attack) → decryption fails → recovery mode
```

### Partition Layout for FDE

```
/dev/mmcblk2:
  mmcblk2boot0        imx-boot (HABv4 authenticated)
  mmcblk2p1  ubuntu-seed   FAT32  ~1GB    (snaps, assertions, recovery system - unencrypted)
  mmcblk2p2  ubuntu-boot   ext4   ~750MB  (bootloader, grub — unencrypted)
  mmcblk2p3  ubuntu-save   ext4   ~32MB   (encrypted, holds TPM state, factory reset data)
  mmcblk2p4  ubuntu-data   ext4   ~rest   (encrypted, all user/app data)
```

### TPM-Based Key Sealing

For i.MX8MP without a discrete TPM 2.0 chip, options include:
- **NXP CAAM secure key**: Can substitute for TPM key sealing using CAAM's black key mechanism
- **OP-TEE as TPM emulation**: `libtpms` + `swtpm` running as a TA provides TPM2 interface via `optee-tpm-ta`
- **External SLB9670 TPM chip**: SPI-connected TPM2 module; commonly used on industrial boards

The Ubuntu Core `secboot` package handles the sealed key operations. It calls into the TPM via the Linux tpm2 device driver (`/dev/tpm0`).

### Recovery Key Mechanism

When TPM unsealing fails, Ubuntu Core prompts for a recovery key:

```
┌──────────────────────────────────────────────────────────┐
│  Full disk decryption failed.                            │
│                                                          │
│  Enter the recovery key:                                 │
│  xxxxxx-xxxxxx-xxxxxx-xxxxxx-xxxxxx-xxxxxx-xxxxxx-xxxxxx │
│                                                          │
│  Or connect to a network and use:                        │
│    snap recover                                          │
└──────────────────────────────────────────────────────────┘
```

The recovery key is a 128-bit random value generated at provisioning time and printed/stored for safekeeping. It is stored in the LUKS header as a keyslot separate from the TPM-sealed key.

---

## Core20 / Core22 / Core24 Differences

| Feature | core20 | core22 | core24 |
|---------|--------|--------|--------|
| Ubuntu base | 20.04 (focal) | 22.04 (jammy) | 24.04 (noble) |
| Snap-based FDE | Limited | Full (`grade: secured`) | Full |
| UEFI Secure Boot | Partial | Full | Full |
| ARM64 support | Yes | Yes | Yes |
| Kernel snap | 5.4 / 5.15 | 5.15 / 6.5 | 6.8 |
| snapd version | 2.54+ | 2.58+ | 2.63+ |
| Landlock LSM | No | Optional | Default |
| AppArmor policy | v3 | v4 | v4 |
| Classic confinement | Allowed | Allowed | Discouraged |

For new projects, **core22** is the recommended base. core24 is stable but has less community-tested hardware support as of 2024. core20 is reaching end-of-standard support.

---

## Ubuntu Core vs Custom Yocto: Decision Guide

### When to Use Ubuntu Core

- Your device needs app-store-style OTA updates from multiple parties
- Your team has stronger expertise in Ubuntu/Debian than Buildroot/Yocto
- You need snap-level sandboxing (AppArmor, seccomp) without custom policy
- You're targeting a x86-64 device or a well-supported ARM SBC
- You need the Ubuntu Core commercial support from Canonical
- Your security model benefits from assertions and the snap trust model
- Update frequency is high and you need transactional (rollback) updates

### When to Use Yocto/Buildroot

- You need direct, auditable control over every binary in the rootfs
- Your team has deep Yocto expertise and existing layers
- Image size is critical (Ubuntu Core base is ~300MB compressed vs. a 20MB Yocto minimal image)
- You need custom boot chain integration (unusual HABv4 setup, custom SPL patches)
- Your OTA mechanism is RAUC or SWUpdate (well-integrated with Yocto)
- Your platform is not officially supported by Ubuntu Core (many industrial i.MX8MP boards)
- Regulatory compliance requires a fully audited, custom BOM
- Build reproducibility is a hard requirement (Yocto has better tooling for this)

### Mixed Approach

Some teams use Ubuntu Core for the base OS and OS-level services, while using Yocto to build the kernel snap and gadget snap. This captures Ubuntu Core's update model while preserving direct kernel and bootloader control.

---

## Ubuntu Core on i.MX8MP: Practical Limitations

### Non-x86 Specific Challenges

1. **No UEFI firmware**: The i.MX8MP ROM is not UEFI. U-Boot acts as UEFI firmware via `CONFIG_EFI_LOADER`, but this is a partial implementation. Some UEFI Secure Boot features (MOKLIST, SBAT revocations) behave differently.

2. **No shim for non-x86**: Microsoft's UEFI CA only signs x86_64 shim binaries. For ARM64 devices, you must compile your own shim and embed your own certificate, or skip shim entirely and trust your U-Boot's EFI DB directly.

3. **HABv4 is below Ubuntu Core's awareness**: Ubuntu Core secures the snap layer and assumes the firmware below it is trustworthy. The HABv4 layer (ROM → imx-boot authentication) is completely separate from Ubuntu Core's security model. You must configure HABv4 yourself, outside Ubuntu Core.

4. **Serial Vault requires network**: If your device has no network during provisioning, you need a self-hosted serial vault accessible on the factory floor network.

5. **Official board support**: As of 2024, Canonical officially supports:
   - Raspberry Pi (all models), Raspberry Pi Compute Module
   - DragonBoard 410c, 845c
   - Intel NUC, generic UEFI x86_64
   The i.MX8MP is **not** officially supported. You need a custom gadget snap and kernel snap.

### Custom Gadget Snap for i.MX8MP

A gadget snap for i.MX8MP must provide:

```yaml
# gadget.yaml
name: phyboard-pollux-imx8mp-gadget
version: "1.0"
summary: Gadget snap for PHYTEC phyBOARD-Pollux i.MX8MP

volumes:
  imx8mp:
    schema: gpt
    bootloader: u-boot
    structure:
      - name: imx-boot
        type: bare
        size: 4M
        offset: 33K      # 33*512 = 0x8400 (required by i.MX8MP ROM)
        content:
          - image: imx-boot-phyboard-pollux-imx8mp.bin

      - name: ubuntu-seed
        role: system-seed
        filesystem: vfat
        type: EF,C12A7328-F81F-11D2-BA4B-00A0C93EC93B
        size: 1200M
        content:
          - source: grub.conf
            target: EFI/ubuntu/grub.cfg

      - name: ubuntu-boot
        role: system-boot
        filesystem: ext4
        type: 83,0FC63DAF-8483-4772-8E79-3D69D8477DE4
        size: 750M

      - name: ubuntu-save
        role: system-save
        filesystem: ext4
        type: 83,0FC63DAF-8483-4772-8E79-3D69D8477DE4
        size: 32M

      - name: ubuntu-data
        role: system-data
        filesystem: ext4
        type: 83,0FC63DAF-8483-4772-8E79-3D69D8477DE4
        size: 0          # fill remaining space

assets:
  grub:
    update: false
    content:
      - grub.efi
```

Key i.MX8MP constraints:
- `imx-boot` must start at offset 33 * 512 bytes = 0x4200 (for eMMC). The ROM hardcodes this.
- The `imx-boot` binary includes SPL + TF-A + OP-TEE + U-Boot, all HABv4-signed.
- U-Boot must be compiled with EFI loader support for Ubuntu Core's grub.efi to work.

### Custom Kernel Snap for i.MX8MP

The kernel snap packages:
- Linux kernel bzImage/Image.gz
- DTB files for your board
- Initramfs (Ubuntu Core's `ubuntu-core-initramfs`)
- Kernel modules

```bash
# snapcraft.yaml for kernel snap
name: phyboard-pollux-imx8mp-kernel
version: "6.6.0-phytec-1"
summary: Linux kernel for PHYTEC phyBOARD-Pollux i.MX8MP
type: kernel

parts:
  kernel:
    plugin: kernel
    source: https://github.com/phytec/linux-phytec-imx
    source-branch: v6.6.3_2.0.0-phy
    kernel-image-target:
      arm64: Image.gz
    kernel-with-firmware: false
    kernel-build-efi-image: false    # we use FIT, not EFI
    kernel-device-trees:
      - freescale/imx8mp-phyboard-pollux-rdk.dtb
    kconfigfile: configs/phyboard-pollux-secure-defconfig
    build-packages:
      - gcc-aarch64-linux-gnu
      - libssl-dev
      - bc
      - flex
      - bison
```

---

## Secure Updates via snap refresh

### Transactional Update Properties

Every snap update is transactional:
1. New snap revision downloaded in the background
2. Signature verified against assertion chain
3. SquashFS mounted at new path (`/snap/myapp/99/`)
4. Old snap kept for rollback (`/snap/myapp/98/`)
5. Symlink atomically updated: `/snap/myapp/current → 99`
6. If snap fails to start after update: automatic rollback to previous revision

This is the same transactional property that RAUC/SWUpdate A/B partition schemes provide, but at the snap granularity rather than full partition granularity.

### Anti-Rollback in Ubuntu Core

Ubuntu Core does not have a hardware anti-rollback counter mechanism equivalent to i.MX8MP's fuse-based version counter. Instead:
- The `snap-revision` assertion has a monotonically increasing `revision` field
- `snapd` refuses to install a revision lower than the currently installed one (by default)
- An attacker who can forge assertions could bypass this, but that requires compromising the brand key

For hardware-enforced anti-rollback on i.MX8MP, you still need the HABv4 layer and U-Boot's `CONFIG_VERSION_VARIABLE` or fuse-based version check.

---

## OCI/Docker vs Snap Security Model

| Property | Docker/OCI | Snaps |
|----------|-----------|-------|
| Signature | Optional (cosign, Notary v2) | Required (assertions) |
| Update atomicity | No (layer-based) | Yes (full revision swap) |
| Rollback | Manual | Automatic |
| Sandboxing | Linux namespaces + seccomp | AppArmor + seccomp + namespaces |
| Offline operation | With private registry | With IoT App Store proxy |
| Runtime policy | Container runtime (runc) | snapd |
| Root requirement | No (rootless podman) | snapd daemon (root) |
| Audit trail | Registry tags (mutable) | Assertions (immutable log) |
| Revocation | Delete from registry | `snapd` checks revocation list |

For embedded secure boot, snaps have stronger **pre-boot integrity** guarantees because the kernel snap and gadget snap are part of the Ubuntu Core verified boot chain. Docker images are not verified at the bootloader level.

---

## Further Reading

- [01-snap-signing.md](./01-snap-signing.md) — Snap signing workflow, key management, custom signing server
- Ubuntu Core documentation: https://ubuntu.com/core/docs
- Snapcraft gadget snap specification: https://snapcraft.io/docs/gadget-snaps
- Ubuntu Core on ARM: https://ubuntu.com/download/iot/arm
