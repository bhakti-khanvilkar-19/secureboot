# Image Signing

## What Gets Signed

A complete secure boot deployment requires signing at multiple levels:

```
Component              | Tool        | Algorithm          | Key Type
───────────────────────────────────────────────────────────────────────────
SPL                    | CST         | RSA-2048 + SHA-256 | SRK→CSF→IMG chain
TF-A BL31              | CST         | RSA-2048 + SHA-256 | SRK→CSF→IMG chain
OP-TEE (BL32)          | CST         | RSA-2048 + SHA-256 | SRK→CSF→IMG chain
U-Boot (BL33)          | CST         | RSA-2048 + SHA-256 | SRK→CSF→IMG chain
Linux Kernel           | mkimage     | RSA-2048 + SHA-256 | FIT signing key
Device Tree Blob       | mkimage     | SHA-256 hash       | FIT signing key (conf)
Initramfs              | mkimage     | SHA-256 hash       | FIT signing key (conf)
Root filesystem        | veritysetup | SHA-256 Merkle     | (hash = auth)
OTA package            | openssl cms | RSA-2048 + SHA-256 | OTA signing key
```

## Signing Architecture: Two Separate Pipelines

### Pipeline 1: HABv4 (CST) Signing
Signs the boot image (`imx-boot` / `flash.bin`) that ROM authenticates.

```
Keys: SRK1–SRK4 → CSF Key → IMG Key
Tool: NXP Code Signing Tool (CST)
Output: flash.bin + CSF appended
Hardware: ROM HABv4 verifies at boot
```

### Pipeline 2: FIT Signing
Signs the FIT image that U-Boot verifies.

```
Keys: FIT signing key (RSA-2048, separate from SRK!)
Tool: mkimage -F
Output: fitImage (with signature nodes)
Hardware: U-Boot verifies using embedded public key
```

**These are SEPARATE key hierarchies.** Mixing them is a security mistake.

## Signing Infrastructure Requirements

```
┌──────────────────────────────────────────────────┐
│         SIGNING INFRASTRUCTURE                   │
│                                                  │
│  ┌────────────────┐     ┌────────────────────┐   │
│  │  AIR-GAPPED    │     │   SIGNING SERVICE  │   │
│  │  KEY GEN       │     │   (HSM-backed)     │   │
│  │  WORKSTATION   │     │                    │   │
│  │                │     │  Receives unsigned │   │
│  │  hab4_pki_tree │     │  artifacts, signs, │   │
│  │  srktool       │     │  returns signed    │   │
│  │  openssl       │     │                    │   │
│  └───────┬────────┘     └────────────────────┘   │
│          │ HSM/USB                               │
│          ▼                                       │
│  ┌────────────────┐                             │
│  │  HSM Storage   │                             │
│  │  (YubiHSM2 /  │                             │
│  │   Thales Luna) │                             │
│  └────────────────┘                             │
└──────────────────────────────────────────────────┘
```

## Build-Time vs Post-Build Signing

### Build-Time Signing (FIT images)
Yocto performs FIT signing during `do_deploy`:
- `kernel-fitimage.bbclass` calls `mkimage -F`
- Requires key directory accessible to build system
- Key security: restrict access to build system

### Post-Build Signing (HABv4)
HABv4 signing occurs **after** Yocto build:
- Build produces unsigned `imx-boot.bin`
- Offline signing station signs with CST
- Signed image replaces unsigned for deployment
- Key security: keys never touch build system

## Cross-References

- [01-signing-workflows.md](01-signing-workflows.md) — Complete signing procedures
- [02-offline-signing-architecture.md](02-offline-signing-architecture.md) — Signing infrastructure
- [11-key-management](../11-key-management/README.md) — Key lifecycle
- [12-habv4-imx8m/04-cst-workflow.md](../12-habv4-imx8m/04-cst-workflow.md) — CST tool usage
