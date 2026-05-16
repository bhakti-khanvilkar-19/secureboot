# Learning Path: Navigating the Secure Boot Reference

## Learning Objectives

After reviewing this learning path, you will be able to:

1. Identify which of the three learning tracks best matches your background
2. Follow a structured chapter sequence with clear prerequisites
3. Estimate the time investment required to reach specific competency levels
4. Understand the dependency relationships between topics
5. Locate authoritative external resources to supplement this repository

---

## Overview

Implementing Secure Boot on embedded Linux systems requires competency across three domains simultaneously: embedded systems architecture, cryptography, and security engineering. Most engineers arrive with deep expertise in one domain and gaps in the others. This learning path provides three entry points calibrated to common background profiles, and a structured progression to production competency.

The three tracks converge at the same destination: the ability to design, implement, validate, and maintain a production Secure Boot deployment on NXP i.MX8MP hardware. They differ only in their starting point and the depth of background coverage provided.

---

## Learning Tracks

### Track A: Security Engineer New to Embedded Linux

**Your background:** You understand PKI, certificate hierarchies, threat modeling, and cryptographic protocols. You have worked with HSMs, TLS/mTLS, or code signing in server or desktop contexts. You are less familiar with bootloaders, device trees, Yocto, fuse programming, and the specific constraints of embedded hardware.

**Your challenge:** Translating abstract security concepts into the concrete reality of a system where there is no operating system when authentication needs to happen, where the "TPM" is a set of one-time-programmable fuses, and where a mistake can permanently destroy a device.

**Recommended sequence:**

```
Week 1: Embedded Systems Context
├── 00-learning-path/PREREQUISITES.md (sections 3, 4, 5)
├── 05-boot-architecture/README.md
└── 05-boot-architecture/01-imx8mp-boot-flow.md

Week 2: Security Concepts Applied to Embedded
├── 01-security-foundations/README.md
├── 01-security-foundations/01-threat-modeling.md
└── 01-security-foundations/03-secure-vs-verified-vs-measured-boot.md

Week 3: Hardware Security
├── 03-root-of-trust/README.md
├── 03-root-of-trust/01-hardware-security-features-imx8mp.md
└── 04-chain-of-trust/README.md

Week 4: NXP-Specific Implementation
├── 06-nxp-hab/README.md
├── 06-nxp-hab/01-hab-architecture.md
└── 06-nxp-hab/02-signing-workflow.md

Week 5-6: Bootloader and OS Security
├── 08-uboot-verified-boot/README.md
├── 09-trusted-firmware-a/README.md
├── 11-linux-kernel-security/README.md
└── 12-dm-verity/README.md

Week 7: Key Management (Your Comfort Zone)
├── 15-key-management/README.md     ← This will feel familiar
├── 16-certificate-management/README.md
└── 24-key-ceremony/README.md

Week 8: Production
├── 17-fuse-programming/README.md
├── 23-manufacturing/README.md
└── 21-testing-validation/README.md
```

**Concepts to focus on:** IVT (Image Vector Table), SRK table vs. certificate chain, HAB events, U-Boot FIT images, fuse programming, eMMC vs SD boot. These have no direct analogs in server security.

### Track B: Embedded Linux Engineer New to Security

**Your background:** You have built Yocto images, customized U-Boot, written device tree overlays, and are familiar with the i.MX8MP boot flow. You understand SPL, TF-A, and OP-TEE at an architectural level. You are less familiar with formal cryptographic concepts, PKI design, threat modeling, and the security properties (and limitations) of the mechanisms you are configuring.

**Your challenge:** Moving from "I know how to configure HABv4" to "I understand what security guarantees HABv4 provides, against which threat actors, and what its limitations are." This matters because incorrect threat models lead to incorrect security architectures.

**Recommended sequence:**

```
Week 1: Security Foundations
├── 01-security-foundations/README.md
├── 01-security-foundations/01-threat-modeling.md
├── 01-security-foundations/02-attack-surfaces.md
└── 01-security-foundations/03-secure-vs-verified-vs-measured-boot.md

Week 2: Cryptographic Foundations
├── 02-embedded-cryptography/README.md
├── 02-embedded-cryptography/01-hash-functions.md
├── 02-embedded-cryptography/02-asymmetric-cryptography.md
└── 02-embedded-cryptography/03-pki-and-certificates.md

Week 3: Implementation (Your Comfort Zone)
├── 06-nxp-hab/README.md         ← Familiar territory, now with security context
├── 06-nxp-hab/02-signing-workflow.md
└── 08-uboot-verified-boot/README.md

Week 4: Deeper Security Stack
├── 10-optee/README.md
├── 12-dm-verity/README.md
└── 14-secure-storage/README.md

Week 5-6: Key Management and Production
├── 15-key-management/README.md
├── 17-fuse-programming/README.md
├── 24-key-ceremony/README.md
└── 23-manufacturing/README.md
```

**Concepts to focus on:** Trust boundaries, what HABv4 does NOT protect, key compromise scenarios, SRK key ceremony requirements, why key ceremony matters. The cryptographic operations you are performing have precise security properties—understand them.

### Track C: Production Implementation (Advanced)

**Your background:** You understand both embedded Linux and security concepts. You may have implemented Secure Boot in a previous project or on a different platform. You need a production-quality implementation for the NXP i.MX8MP with PHYTEC hardware.

**Your challenge:** Production requirements differ significantly from laboratory demonstrations. Key ceremony rigor, manufacturing pipeline scalability, validation completeness, and post-deployment key management are the hard problems.

**Recommended sequence:**

```
Week 1: Platform-Specific Architecture
├── 03-root-of-trust/01-hardware-security-features-imx8mp.md
├── 04-chain-of-trust/01-chain-of-trust-diagram.md
├── 06-nxp-hab/README.md (skim for platform specifics)
└── 19-phytec-specifics/README.md

Week 2: Key Infrastructure
├── 15-key-management/README.md
├── 16-certificate-management/README.md
├── 24-key-ceremony/README.md    ← Critical: do not skip
└── 24-key-ceremony/01-ceremony-procedure.md

Week 3: Implementation and Signing
├── 06-nxp-hab/02-signing-workflow.md
├── 07-nxp-ahab/README.md (if using i.MX93)
├── 17-fuse-programming/01-burn-procedure.md
└── 23-manufacturing/README.md

Week 4: Validation and Compliance
├── 21-testing-validation/README.md
├── 21-testing-validation/02-hab-event-analysis.md
├── 22-debugging/README.md
└── 25-compliance/README.md
```

---

## Visual Learning Progression Map

```
                         START
                           │
            ┌──────────────┼──────────────┐
            │              │              │
            ▼              ▼              ▼
        TRACK A         TRACK B        TRACK C
   (Security Eng)   (Embedded Eng)  (Production)
            │              │              │
            ▼              ▼              │
     Embedded          Security          │
     Basics           Foundations        │
     (Week 1)          (Week 1)          │
            │              │              │
            ▼              ▼              │
     Security          Crypto            │
     Applied           Foundations       │
     (Week 2)          (Week 2)          │
            │              │              │
            └──────┬────────┘             │
                   ▼                      │
          ┌────────────────┐              │
          │  CONVERGENCE   │◄─────────────┘
          │  POINT         │
          │  (HABv4 +      │
          │   Key Mgmt)    │
          └───────┬────────┘
                  │
         ┌────────┼────────┐
         ▼        ▼        ▼
      Boot OS   Full    Fuse +
      Signing  Verity  Mfg Pipeline
         │        │        │
         └────────┼────────┘
                  ▼
          ┌──────────────┐
          │  PRODUCTION  │
          │  VALIDATION  │
          └──────────────┘
                  │
                  ▼
          ┌──────────────┐
          │  PRODUCTION  │
          │  DEPLOYMENT  │
          └──────────────┘
```

---

## Chapter Dependency Matrix

The following table shows which chapters are required (R), recommended (r), or optional (O) for each competency level. "Basic" means understanding the concept; "Impl" means ability to implement; "Prod" means production readiness.

| Chapter | Track A Basic | Track B Basic | Track C Impl | Production |
|---------|---------------|---------------|--------------|------------|
| 00-learning-path | R | R | R | R |
| 01-security-foundations | R | R | r | r |
| 01/01-threat-modeling | R | R | R | R |
| 01/02-attack-surfaces | R | R | R | R |
| 01/03-secure-vs-verified | R | R | R | R |
| 02-embedded-cryptography | R | R | R | R |
| 02/01-hash-functions | R | R | R | R |
| 02/02-asymmetric-crypto | R | R | R | R |
| 02/03-pki-and-certificates | R | R | R | R |
| 03-root-of-trust | R | R | R | R |
| 03/01-hw-security-imx8mp | r | R | R | R |
| 04-chain-of-trust | R | R | R | R |
| 05-boot-architecture | R | r | r | r |
| 05/01-imx8mp-boot-flow | R | O | R | R |
| 06-nxp-hab | R | R | R | R |
| 07-nxp-ahab | O | O | R | R |
| 08-uboot-verified-boot | R | R | R | R |
| 09-trusted-firmware-a | r | R | R | R |
| 10-optee | r | r | R | R |
| 11-linux-kernel-security | r | r | R | R |
| 12-dm-verity | r | r | R | R |
| 13-dm-crypt | O | O | r | R |
| 14-secure-storage | O | O | r | R |
| 15-key-management | R | R | R | R |
| 16-certificate-management | R | r | R | R |
| 17-fuse-programming | R | R | R | R |
| 18-yocto-integration | r | R | R | R |
| 19-phytec-specifics | r | R | R | R |
| 21-testing-validation | R | R | R | R |
| 22-debugging | r | r | R | R |
| 23-manufacturing | r | r | R | R |
| 24-key-ceremony | R | r | R | R |
| 25-compliance | O | O | r | R |

---

## Estimated Time Per Section

These estimates assume active reading with hands-on exercises. Pure reading takes roughly 40% of the time shown.

| Section | Reading | Hands-On Lab | Total |
|---------|---------|--------------|-------|
| 01-security-foundations | 3h | 2h | 5h |
| 02-embedded-cryptography | 4h | 4h | 8h |
| 03-root-of-trust | 3h | 1h | 4h |
| 04-chain-of-trust | 2h | 1h | 3h |
| 05-boot-architecture | 3h | 2h | 5h |
| 06-nxp-hab | 5h | 8h | 13h |
| 07-nxp-ahab | 4h | 6h | 10h |
| 08-uboot-verified-boot | 4h | 6h | 10h |
| 09-trusted-firmware-a | 4h | 4h | 8h |
| 10-optee | 4h | 4h | 8h |
| 11-linux-kernel-security | 3h | 3h | 6h |
| 12-dm-verity | 3h | 4h | 7h |
| 13-dm-crypt | 3h | 4h | 7h |
| 14-secure-storage | 3h | 3h | 6h |
| 15-key-management | 4h | 4h | 8h |
| 16-certificate-management | 3h | 3h | 6h |
| 17-fuse-programming | 3h | 4h | 7h |
| 18-yocto-integration | 4h | 8h | 12h |
| 19-phytec-specifics | 2h | 4h | 6h |
| 21-testing-validation | 3h | 6h | 9h |
| 22-debugging | 2h | 4h | 6h |
| 23-manufacturing | 4h | 4h | 8h |
| 24-key-ceremony | 3h | 2h | 5h |
| **Full curriculum** | **76h** | **91h** | **167h** |

---

## Prerequisites Checklist

Before beginning the main curriculum, verify you can perform the following:

**Linux Systems (required for all tracks):**
- [ ] Navigate the filesystem, use find, grep, pipes, and redirects fluently
- [ ] Understand process management, systemd units, and udev rules
- [ ] Compile a C program from source using gcc and understand ELF binary format
- [ ] Use git at the level of branching, rebasing, and resolving merge conflicts

**Embedded Linux (required for Tracks B and C; Track A can learn as you go):**
- [ ] Have built a custom Yocto image for an ARM target
- [ ] Understand the role of U-Boot, the kernel, and the root filesystem
- [ ] Have used a UART console to observe a Linux boot sequence
- [ ] Understand what a device tree is and can modify a simple device tree overlay

**Cryptography (required for all tracks; Track B can learn from Chapter 02):**
- [ ] Understand symmetric vs. asymmetric encryption conceptually
- [ ] Know what a digital signature is and what it verifies
- [ ] Understand what a certificate authority is and why it is trusted
- [ ] Can use OpenSSL to generate a key pair and sign a file

**Security Engineering (required for Track A; Tracks B/C learn from Chapter 01):**
- [ ] Can construct a basic threat model (assets, threats, mitigations)
- [ ] Understand what a trust boundary is
- [ ] Know the difference between authentication, authorization, and integrity

See `00-learning-path/PREREQUISITES.md` for detailed skill assessment and remediation resources.

---

## Recommended External Resources

### Books

| Title | Author | Relevance |
|-------|--------|-----------|
| *Embedded Linux Systems with the Yocto Project* | Rudolf Streif | Yocto foundations, essential for Track A |
| *Practical Embedded Security* | Timothy Stapko | General embedded security, accessible intro |
| *The Art of Intrusion* | Kevin Mitnick | Adversarial mindset, threat modeling context |
| *Applied Cryptography* | Bruce Schneier | Cryptographic foundations, still relevant |
| *Real-World Cryptography* | David Wong | Modern cryptographic implementations |
| *Cryptography Engineering* | Ferguson, Schneier, Kohno | Cryptographic system design |

### NXP Application Notes (required reading for implementation)

| Document | Title | Covers |
|----------|-------|--------|
| AN4581 | Secure Boot on i.MX using HABv4 | HABv4 fundamentals |
| AN12056 | HABv4 RVT Guidelines and Recommendations | HABv4 robustness |
| AN12108 | i.MX 8M ROM Secure Boot Reference | i.MX8M series specifics |
| IMXBSPPG | i.MX BSP Porting Guide | BSP integration |
| IMX8MPRM | i.MX 8M Plus Reference Manual | Register-level reference |

Download from: https://www.nxp.com/products/processors-and-microcontrollers/arm-processors/i-mx-applications-processors/i-mx-8-processors/i-mx-8m-plus-arm-cortex-a53-machine-learning-real-time-on-device-ai-motor-control:IMX8MPLUS

### ARM Architecture Documentation

| Document | Relevance |
|----------|-----------|
| ARM Architecture Reference Manual (ARMv8) | TrustZone, exception levels |
| ARM Trusted Firmware-A User Guide | TF-A build and integration |
| Trusted Board Boot Requirements (TBBR) | CoT specification |
| PSCI Power State Coordination Interface | Power management in secure context |

Available at: https://developer.arm.com/documentation

### Standards and Specifications

| Standard | Title | Relevance |
|----------|-------|-----------|
| NIST SP 800-193 | Platform Firmware Resiliency Guidelines | Compliance framework |
| NIST SP 800-57 | Key Management Recommendation | Key lifecycle management |
| IEC 62443-4-2 | Security for Industrial IoT | Component security requirements |
| ETSI EN 303 645 | Cyber Security for Consumer IoT | IoT security baseline |
| FIPS 140-2/3 | Cryptographic Module Security | Cryptographic requirements |

---

## Glossary

This glossary defines terms used throughout the repository with their specific meanings in the NXP i.MX8MP Secure Boot context.

| Term | Definition |
|------|------------|
| AHAB | Advanced High Assurance Boot. NXP's container-based authenticated boot architecture used on i.MX8QM, i.MX8X, i.MX93. Supersedes HABv4 on newer SoCs. |
| ASLR | Address Space Layout Randomization. Kernel security feature randomizing memory layout. Not directly related to secure boot but part of runtime security. |
| BEE | Bus Encryption Engine. i.MX6/7 hardware for encrypting external memory. Superseded by BEE/OTFAD in i.MX8. |
| BL1/BL2/BL31/BL32/BL33 | TF-A boot loader stages. BL1=AP Trusted ROM, BL2=Trusted Boot Firmware, BL31=Secure Monitor (EL3), BL32=Secure OS (OP-TEE), BL33=Non-Trusted Firmware (U-Boot). |
| CAAM | Cryptographic Acceleration and Assurance Module. NXP hardware cryptographic engine in i.MX processors, providing AES, RSA, ECC, RNG, and secure key storage. |
| CSF | Code Signing Framework. NXP's command-based signing descriptor format used with CST tool. Describes what to sign, with which key, using which algorithm. |
| CST | Code Signing Tool. NXP's software tool for generating CSF blocks and signed images for HABv4. |
| CoT | Chain of Trust. The unbroken sequence of cryptographic verification from hardware root of trust to application. |
| DCD | Device Configuration Data. Embedded configuration commands in the IVT structure, executed by ROM during boot to configure DDR, clocks, etc. |
| DM-verity | Device Mapper verity. Linux kernel mechanism for block-level integrity verification of read-only filesystems using a Merkle tree of SHA-256 hashes. |
| DTB | Device Tree Blob. Compiled binary form of a device tree, describing hardware to the kernel. |
| EL0/EL1/EL2/EL3 | ARM Exception Levels. EL0=Unprivileged (apps), EL1=Kernel, EL2=Hypervisor, EL3=Secure Monitor. |
| FIT | Flattened Image Tree. U-Boot image format that bundles kernel, DTB, initramfs, and signatures in a single file. |
| HABv4 | High Assurance Boot version 4. NXP's authenticated boot mechanism for i.MX6/7/8M series. Uses RSA-2048/4096 signatures and SHA-256/SHA-384. |
| HAB Event | Error record generated by the HABv4 engine when authentication fails. Stored in SNVS and readable via U-Boot `hab_status` command. |
| HSM | Hardware Security Module. Tamper-resistant hardware device for cryptographic operations and key storage. Used for production key ceremonies. |
| IVT | Image Vector Table. 32-byte data structure at a fixed offset in NXP boot images, pointing to boot data, DCD, and entry point. Parsed by Boot ROM. |
| JTAG | Joint Test Action Group. Debug interface standard (IEEE 1149.1) that provides hardware-level access. Must be disabled or restricted in production devices. |
| LUKS | Linux Unified Key Setup. Standard format for disk encryption on Linux, used with dm-crypt. |
| OCRAM | On-Chip RAM. Fast SRAM internal to the SoC, used as initial execution space by Boot ROM and SPL. |
| OCOTP | One-Time Programmable fuse controller. Hardware block managing OTP fuses in i.MX processors. SRK hash and security configuration are stored here. |
| OP-TEE | Open Portable Trusted Execution Environment. Open-source Trusted OS implementing ARM TrustZone, runs as TF-A BL32. |
| PKI | Public Key Infrastructure. System of certificates, certificate authorities, and key management enabling cryptographic identity. |
| PKCS#11 | Public Key Cryptography Standards #11. API for cryptographic hardware tokens (HSMs, smart cards). |
| RPMB | Replay-Protected Memory Block. Authenticated storage partition in eMMC/UFS with hardware-enforced replay protection. Used by OP-TEE for secure storage. |
| RoT | Root of Trust. The component whose trust is assumed (not derived). Typically Boot ROM + immutable hardware. |
| RSA | Rivest–Shamir–Adleman. Asymmetric cryptographic algorithm. HABv4 requires RSA-2048 minimum; 4096-bit recommended. |
| S-EL0/S-EL1 | Secure Exception Levels. S-EL0=Trusted Applications, S-EL1=OP-TEE kernel. Run in TrustZone Secure World. |
| SNVS | Secure Non-Volatile Storage. i.MX security subsystem providing tamper detection, secure RTC, and persistent secure storage. HAB events are stored here. |
| SPL | Secondary Program Loader. Minimal U-Boot loader that initializes DDR and loads the main bootloader. Subject to HABv4 authentication on i.MX8MP. |
| SPSDK | Secure Provisioning SDK. NXP's Python-based toolset for manufacturing provisioning, replacing/complementing CST. |
| SRK | Super Root Key. RSA or ECC key whose hash is burned into OTP fuses. Signing any bootloader component with the SRK (or a key signed by SRK) establishes the chain of trust. |
| SRK Table | Table of up to 4 SRK public keys embedded in signed images. Allows up to 4 independent SRK keys for redundancy or key rotation. |
| TF-A | Trusted Firmware-A. ARM's reference implementation of Trusted Boot and Secure Monitor. Runs at EL3. Formerly "ARM Trusted Firmware (ATF)". |
| TBBR | Trusted Board Boot Requirements. ARM specification defining the CoT for TF-A. |
| TrustZone | ARM security extension providing hardware separation of Secure World and Normal World. |
| TZASC | TrustZone Address Space Controller. Hardware component controlling access to memory regions based on TrustZone security state. |
| U-Boot | Universal Bootloader. Open-source bootloader used on embedded Linux systems. Runs as TF-A BL33 in the Secure Boot context. |
| eFuse / OTP | Electronic fuse / One-Time Programmable. Hardware bits that can be written once and not erased. Used for SRK hash, security configuration, unique device IDs. |
