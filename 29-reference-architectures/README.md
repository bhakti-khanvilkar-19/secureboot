# Reference Architectures for Embedded Linux Secure Boot

```
Tested Against:
  - NXP CST: 3.3.1
  - U-Boot: 2023.04 (NXP lf-6.1.55-2.2.0)
  - Linux Kernel: 6.1.55 (NXP lf-6.1.55-2.2.0)
  - Yocto Project: Kirkstone (4.0.x)
  - Platform: NXP i.MX8M Plus (phyCORE-i.MX8MP, phyBOARD-Pollux)
Last Validated: 2024-Q3
```

---

## Overview

This chapter provides complete, deployable reference architectures for embedded Linux secure boot deployments on the NXP i.MX8M Plus platform. Each architecture represents a validated security posture with explicitly documented properties, gaps, complexity, and performance tradeoffs.

These are not conceptual templates. Each architecture includes a concrete Yocto configuration, key hierarchy, signing workflow, and validation procedure sufficient to reproduce the deployment. The architectures are ordered from minimal to comprehensive; a production deployment should choose the architecture that matches its threat model and operational constraints.

**Architecture selection guidance:**

| Use Case | Recommended Architecture |
|----------|--------------------------|
| Prototype / proof of concept | Architecture 1: Minimal |
| Industrial IoT, no OTA | Architecture 2: Full Secure Boot |
| Industrial IoT with OTA | Architecture 3: Full Secure Boot + OTA |
| High assurance, audit-grade | Architecture 4: Measured Boot |
| Ubuntu-based snap ecosystem | Architecture 5: Ubuntu Core |

---

## Architecture Comparison Matrix

| Property | Arch 1 | Arch 2 | Arch 3 | Arch 4 | Arch 5 |
|----------|--------|--------|--------|--------|--------|
| Firmware authenticity (ROM→SPL) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Firmware authenticity (SPL→Kernel) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Runtime rootfs integrity | ❌ | ✅ | ✅ | ✅ | ✅ |
| OTA with rollback protection | ❌ | ❌ | ✅ | ✅ | ✅ |
| Secure key storage (OP-TEE) | ❌ | ✅ | ✅ | ✅ | ❌ |
| Measured boot (TPM attestation) | ❌ | ❌ | ❌ | ✅ | ✅* |
| Anti-rollback (fuse counter) | Optional | ✅ | ✅ | ✅ | ✅ |
| Remote attestation | ❌ | ❌ | ❌ | ✅ | Partial |
| Snap confinement | ❌ | ❌ | ❌ | ❌ | ✅ |

*Ubuntu Core uses TPM-backed full disk encryption (FDE) rather than pure measured boot attestation.

---

## Architecture 1: Minimal Secure Boot

**File:** [01-minimal-secure-boot.md](01-minimal-secure-boot.md)

**Description:** HABv4 + FIT image signing. Establishes hardware root of trust at boot and authenticates the Linux kernel before execution. No runtime integrity enforcement.

**Components:**
- HABv4 (i.MX8MP Boot ROM)
- NXP Code Signing Tool (CST) 3.3.1
- Signed SPL + U-Boot (HAB CSF)
- FIT image: kernel + DTB + initramfs (RSA-2048/SHA-256)
- U-Boot verified boot (FIT signature verification)

**Security Properties:**
- Firmware authenticity: ROM verifies SPL+U-Boot via HABv4
- Kernel authenticity: U-Boot verifies FIT image via RSA-2048
- Chain of trust: ROM → SPL → U-Boot → Kernel

**Security Gaps:**
- No rootfs integrity at runtime (attacker with flash access can modify rootfs)
- No protection against rollback to vulnerable older firmware
- No secure storage for application secrets
- No attestation capability

**Implementation Complexity:** Low (2–3 days for an experienced engineer)

**Performance Impact:**
- Boot time overhead: +1.2 seconds (HABv4 CAAM authentication)
- No runtime overhead after kernel boots
- Flash space: +32 KB for CSF + SRK table per signed binary

---

## Architecture 2: Full Secure Boot

**File:** [02-production-secure-boot.md](02-production-secure-boot.md)

**Description:** HABv4 + FIT signing + dm-verity + OP-TEE. The recommended production configuration for deployments without OTA requirements or with manual update procedures. Provides comprehensive protection from ROM through filesystem layer.

**Components:**
- Architecture 1 components, plus:
- OP-TEE OS 3.21.0 (Secure World)
- TF-A BL31 2.9 (EL3 firmware)
- dm-verity (Linux kernel feature)
- Custom initramfs with dm-verity setup scripts
- LUKS encrypted data partition (optional, OP-TEE key sealing)

**Security Properties:**
- Everything in Architecture 1, plus:
- Rootfs integrity: kernel verifies filesystem hash tree at mount time
- Secure key storage: OP-TEE RPMB-backed key store
- Secure world services: cryptographic operations in TEE
- Data partition encryption: LUKS with OP-TEE sealed key

**Security Gaps:**
- No OTA update mechanism (manual update requires physical access or custom script)
- No TPM-based attestation
- No remote proof of device state

**Implementation Complexity:** Medium (1–2 weeks)

**Performance Impact:**
- Boot time overhead: +2.1 seconds vs. unprotected (HABv4 + FIT + dm-verity mount)
- Runtime overhead: dm-verity adds ~5–8% I/O overhead on sequential reads
- Flash: +64 MB for dm-verity hash tree on a 2 GB rootfs

---

## Architecture 3: Full Secure Boot + OTA

**File:** [02-production-secure-boot.md](02-production-secure-boot.md) (SWUpdate integration section)

**Description:** Architecture 2 + SWUpdate with dual-copy A/B rootfs and cryptographically signed update images. The standard production architecture for field-deployed devices.

**Components:**
- Architecture 2 components, plus:
- SWUpdate 2023.11
- libgcrypt / OpenSSL for SWUpdate signature verification
- Dual rootfs partitions (rootfs-a, rootfs-b, hash-a, hash-b)
- SWUpdate web server or Hawkbit integration (optional)
- U-Boot A/B boot counter management

**Security Properties:**
- Everything in Architecture 2, plus:
- OTA update authenticity: SWUpdate verifies update image CMS signature
- Rollback protection: A/B partitioning with fallback; update counter in U-Boot env
- Atomic updates: either old or new system, never partial

**Security Gaps:**
- No TPM-based attestation
- Rollback counter is stored in U-Boot env (flash) — software-enforced, not hardware-enforced

**Implementation Complexity:** Medium-High (2–3 weeks)

**Performance Impact:**
- Double storage required for dual rootfs
- No additional boot time vs. Architecture 2
- OTA download + verification: depends on image size and network

---

## Architecture 4: Full Secure Boot + Measured Boot

**File:** [02-production-secure-boot.md](02-production-secure-boot.md) (fTPM section)

**Description:** Architecture 3 + fTPM (OP-TEE firmware TPM) for measured boot and remote attestation. For high-assurance deployments requiring verifiable proof of device configuration.

**Components:**
- Architecture 3 components, plus:
- OP-TEE fTPM TA (Trusted Application)
- TPM2 software stack (tpm2-tools, tpm2-tss)
- U-Boot TPM2 driver
- Linux kernel TPM2 driver
- IMA/EVM (optional, for filesystem measurement)

**Security Properties:**
- Everything in Architecture 3, plus:
- Measured boot: each boot stage is hashed into TPM PCRs
- Remote attestation: TPM PCR quote signed by Endorsement Key
- TPM-sealed secrets: keys unsealed only when PCRs match expected values
- Tamper evidence: any modification to boot chain changes PCR values

**Security Gaps:**
- fTPM (software TPM in OP-TEE) is weaker than discrete hardware TPM
- OP-TEE must itself be in the trusted chain (it is, via TF-A + HABv4)

**Implementation Complexity:** High (3–4 weeks)

**Performance Impact:**
- Boot time overhead: +0.3 seconds for TPM extend operations
- Attestation response time: ~50–200 ms (fTPM quote generation)

---

## Architecture 5: Ubuntu Core on i.MX8MP

**File:** (see Chapter 23: Ubuntu Core Security)

**Description:** Ubuntu Core 22 on i.MX8MP with snappy confinement, automatic OTA via Snapstore, and full disk encryption backed by TPM (fTPM via OP-TEE).

**Components:**
- Ubuntu Core 22 (ARM64)
- snapd with security confinement
- Canonical gadget snap (custom for i.MX8MP)
- Canonical kernel snap
- OP-TEE fTPM for full disk encryption key sealing
- systemd-boot (bootloader)

**Security Properties:**
- Snap confinement: applications run in seccomp/AppArmor sandboxes
- Full disk encryption: dm-crypt with TPM-sealed keys
- Automatic security updates via Snapstore
- Delta updates via snap protocol

**Security Gaps:**
- Canonical's signing infrastructure required (dependency on Canonical)
- Less flexibility in boot chain customization
- Limited support for custom OP-TEE TAs in snap model

**Implementation Complexity:** Medium (1–2 weeks with Ubuntu Core experience)

**Performance Impact:**
- snapd daemon startup: +2–4 seconds
- Application startup: minimal if snaps are pre-seeded

---

## Bill of Components

### Software Components (All Architectures)

| Component | Source | Version | License |
|-----------|--------|---------|---------|
| NXP Code Signing Tool (CST) | NXP (registration required) | 3.3.1 | NXP Proprietary |
| imx-mkimage | github.com/nxp-imx/imx-mkimage | lf-6.1.55 | GPL-2.0 |
| U-Boot | github.com/nxp-imx/uboot-imx | lf-6.1.55 | GPL-2.0 |
| TF-A | git.trustedfirmware.org/TF-A | v2.9 | BSD-3-Clause |
| OP-TEE OS | github.com/OP-TEE/optee_os | 3.21.0 | BSD-2-Clause |
| Linux Kernel | github.com/nxp-imx/linux-imx | lf-6.1.55 | GPL-2.0 |
| OpenSSL | openssl.org | 3.0.x | Apache-2.0 |
| SWUpdate | github.com/sbabic/swupdate | 2023.11 | GPL-2.0 |
| Yocto Project | yoctoproject.org | Kirkstone 4.0.x | Various |
| meta-phytec | github.com/phytec/meta-phytec | kirkstone | MIT |
| meta-imx | github.com/nxp-imx/meta-imx | lf-6.1.55 | MIT |
| meta-security | git.yoctoproject.org/meta-security | kirkstone | MIT |

### Hardware Components

| Component | Description | Required For |
|-----------|-------------|--------------|
| phyBOARD-Pollux | i.MX8MP SBC | All architectures |
| USB-to-UART adapter | Debug console | Development |
| 8 GB+ SD card | Boot media (development) | Development |
| 16 GB+ eMMC | Production boot media | Production |
| YubiHSM 2 | Offline key storage | Key management |
| Thales Luna HSM | Production key storage | Manufacturing |

---

## Chapter Contents

| File | Content |
|------|---------|
| [README.md](README.md) | This overview — architecture comparison and selection guide |
| [01-minimal-secure-boot.md](01-minimal-secure-boot.md) | Architecture 1: HABv4 + FIT signing only |
| [02-production-secure-boot.md](02-production-secure-boot.md) | Architecture 2–4: Full secure boot with OP-TEE, OTA, fTPM |
| [03-secure-manufacturing-reference.md](03-secure-manufacturing-reference.md) | Manufacturing and provisioning architecture |

---

## References

- NXP i.MX8M Plus Security Reference Manual, IMX8MPRM Rev. 3
- PHYTEC phyCORE-i.MX8M Plus BSP Manual (phyLinux Kirkstone)
  https://phytec.github.io/doc-bsp-yocto-imx/
- Yocto Project Security Guide
  https://docs.yoctoproject.org/dev-manual/securing-images.html
- OP-TEE Documentation
  https://optee.readthedocs.io/
- SWUpdate Documentation
  https://sbabic.github.io/swupdate/
