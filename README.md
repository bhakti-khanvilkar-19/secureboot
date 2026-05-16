# Embedded Linux Secure Boot: Enterprise Engineering Reference

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)](https://github.com/example/secureboot)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-i.MX8MP%20%7C%20i.MX9%20%7C%20PHYTEC-orange)](https://www.nxp.com/products/processors-and-microcontrollers/arm-processors/i-mx-applications-processors/i-mx-8-processors/i-mx-8m-plus-arm-cortex-a53-machine-learning-real-time-on-device-ai-motor-control:IMX8MPLUS)
[![Arch](https://img.shields.io/badge/arch-ARM64%20%7C%20ARMv8-lightgrey)](https://developer.arm.com/architectures/learn-the-architecture/a-profile)
[![Yocto](https://img.shields.io/badge/Yocto-kirkstone%20%7C%20scarthgap-yellow)](https://www.yoctoproject.org/)

---

## Executive Summary

This repository is a production-grade, deeply technical engineering reference for implementing Secure Boot on Embedded Linux systems. It targets the NXP i.MX8M Plus (i.MX8MP) and i.MX9 series processors on PHYTEC carrier boards, with additional coverage of Ubuntu Core and generic ARM64 platforms.

The content is intended for engineers who need to understand not just *how* to configure Secure Boot, but *why* each mechanism exists, what it protects against, what it does not protect against, and how to reason about the security properties of a deployed system under real-world threat models. Every section is written at the level of detail required to implement, validate, and maintain a production Secure Boot deployment.

**Who this is for:**

- Security engineers transitioning into embedded Linux systems
- Embedded Linux engineers adding security hardening to existing platforms
- Platform architects designing secure system topologies
- Manufacturing engineers implementing secure provisioning pipelines
- Audit and compliance engineers evaluating Secure Boot deployments
- Firmware engineers integrating HABv4/AHAB, TF-A, OP-TEE, and U-Boot

**What this is not:**

This is not a sales pitch for Secure Boot. It includes honest treatment of what Secure Boot cannot protect against, where it fails, and how attackers have historically circumvented it. Sound security engineering requires adversarial thinking.

---

## Repository Philosophy

**Depth over breadth.** This repository does not attempt to be a wiki that links to other wikis. Every chapter provides genuine technical depth: register values, command outputs, ASCII diagrams, and annotated code. If you need to implement something, you should be able to do it from the content here.

**Threat-model driven.** Every security mechanism is introduced in the context of the threat it mitigates. Mechanisms without understood threat models are cargo cult security. Each chapter identifies what threat actor, with what capability, is defeated by the mechanism described.

**Platform specificity.** Generic treatment of Secure Boot obscures important implementation details. This repository is specific to the NXP i.MX8MP/i.MX9 ecosystem and the PHYTEC phyCORE module family, while clearly identifying which concepts are general and which are platform-specific.

**Production focus.** The manufacturing pipeline, key ceremony, provisioning, and post-deployment key management sections are written for actual production deployments, not laboratory demonstrations.

**Security honesty.** Secure Boot provides specific and limited guarantees. This repository explicitly documents what it does not protect against, including post-boot attacks, side-channel attacks, supply chain attacks on toolchains, and operational security failures.

---

## Directory Map

```
secureboot/
├── 00-learning-path/           Learning tracks, roadmap, prerequisites
├── 01-security-foundations/    Threat modeling, attack surfaces, boot security concepts
├── 02-embedded-cryptography/   Hash functions, asymmetric crypto, PKI, certificates
├── 03-root-of-trust/           Hardware RoT, i.MX8MP security features, fuses, CAAM
├── 04-chain-of-trust/          CoT architecture, verification chain, failure analysis
├── 05-boot-architecture/       i.MX8MP boot flow, ROM→SPL→TF-A→OP-TEE→U-Boot→Linux
├── 06-nxp-hab/                 NXP High Assurance Boot v4: configuration and signing
├── 07-nxp-ahab/                NXP Advanced High Assurance Boot: i.MX8/i.MX9 container format
├── 08-uboot-verified-boot/     U-Boot FIT image signing, public key infrastructure
├── 09-trusted-firmware-a/      TF-A build, BL1/BL2/BL31/BL32/BL33, secure monitor
├── 10-optee/                   OP-TEE OS, Trusted Applications, secure storage
├── 11-linux-kernel-security/   Kernel signing, lockdown mode, secure modules
├── 12-dm-verity/               Device mapper verity, root filesystem integrity
├── 13-dm-crypt/                Full disk encryption, LUKS, key management
├── 14-secure-storage/          OP-TEE secure storage, RPMB, key sealing
├── 15-key-management/          Key hierarchy design, key ceremony, HSM integration
├── 16-certificate-management/  PKI lifecycle, certificate rotation, revocation
├── 17-fuse-programming/        OCOTP fuse map, programming tools, burn procedures
├── 18-yocto-integration/       meta-security, meta-signing, recipe configuration
├── 19-phytec-specifics/        phyCORE-i.MX8MP BSP, PHYTEC-specific configuration
├── 20-ubuntu-core/             Ubuntu Core snaps, secureboot integration, grades
├── 21-testing-validation/      Test methodology, HAB event decoding, CI/CD testing
├── 22-debugging/               UART traces, HAB failure codes, debug strategies
├── 23-manufacturing/           Secure provisioning pipeline, NXP SPSDK, batch signing
├── 24-key-ceremony/            Offline key generation, HSM ceremony procedure
├── 25-compliance/              NIST SP 800-193, IEC 62443, FIPS 140-2 mapping
├── 26-runtime-security/        Kernel hardening, seccomp, AppArmor, audit
├── 27-supply-chain/            SBOM, provenance, toolchain security
├── 28-incident-response/       Key compromise response, firmware rollback
├── 29-reference-builds/        Working reference implementations per platform
└── 30-appendices/              Register maps, command references, glossary
```

---

## Platform Coverage

| Platform | SoC | Boot ROM | HAB/AHAB | TF-A | OP-TEE | dm-verity | Status |
|----------|-----|----------|----------|------|--------|-----------|--------|
| PHYTEC phyCORE-i.MX8MP | NXP i.MX8M Plus | Boot ROM v2 | HABv4 | Yes (BL31) | Yes (BL32) | Yes | Primary |
| PHYTEC phyBOARD-Pollux | NXP i.MX8M Plus | Boot ROM v2 | HABv4 | Yes | Yes | Yes | Primary |
| NXP i.MX8M Mini EVK | NXP i.MX8M Mini | Boot ROM v2 | HABv4 | Yes | Yes | Yes | Supported |
| NXP i.MX8M Nano EVK | NXP i.MX8M Nano | Boot ROM v2 | HABv4 | Yes | Yes | Yes | Supported |
| NXP i.MX93 EVK | NXP i.MX93 | Boot ROM v3 | AHAB | Yes | Yes | Yes | Supported |
| NXP i.MX8QM MEK | NXP i.MX8QM | SECO firmware | AHAB | Yes | Yes | Yes | Supported |
| Generic ARM64 | Any ARMv8 | N/A | N/A | Optional | Optional | Yes | Partial |
| Ubuntu Core 22/24 | ARM64 | N/A | N/A | Optional | No | Via snapd | Supported |

---

## Learning Path Quick-Start

### Beginner Track: Security Engineer New to Embedded
**Time: 6-8 weeks**

Start here if you understand PKI, certificates, and threat modeling but have limited embedded Linux experience.

```
Week 1-2:  01-security-foundations → 05-boot-architecture → 02-embedded-cryptography
Week 3-4:  03-root-of-trust → 04-chain-of-trust → 06-nxp-hab
Week 5-6:  08-uboot-verified-boot → 09-trusted-firmware-a → 12-dm-verity
Week 7-8:  17-fuse-programming → 23-manufacturing → 21-testing-validation
```

See `00-learning-path/ROADMAP.md` for the full structured path with hands-on labs.

### Intermediate Track: Embedded Engineer New to Security
**Time: 4-6 weeks**

Start here if you are comfortable with U-Boot, Yocto, and i.MX8MP but new to security concepts.

```
Week 1:    01-security-foundations → 02-embedded-cryptography (skim)
Week 2-3:  06-nxp-hab → 07-nxp-ahab → 08-uboot-verified-boot
Week 4:    09-trusted-firmware-a → 10-optee → 03-root-of-trust
Week 5-6:  15-key-management → 17-fuse-programming → 23-manufacturing
```

### Advanced Track: Production Implementation
**Time: 2-4 weeks**

Start here if you already understand Secure Boot concepts and need production deployment guidance.

```
Week 1:    06-nxp-hab → 07-nxp-ahab → 15-key-management → 24-key-ceremony
Week 2:    17-fuse-programming → 23-manufacturing → 16-certificate-management
Week 3:    21-testing-validation → 22-debugging → 25-compliance
Week 4:    28-incident-response → 27-supply-chain → 29-reference-builds
```

Full learning path documentation: [`00-learning-path/README.md`](00-learning-path/README.md)

---

## How to Navigate This Repository

**Following a concept:** Each chapter README provides the conceptual foundation. Numbered files within each chapter provide progressive depth. For example, `03-root-of-trust/README.md` introduces the concept; `03-root-of-trust/01-hardware-security-features-imx8mp.md` dives into register-level specifics.

**Finding a specific task:** Use the `30-appendices/` command reference for common operations. The `29-reference-builds/` directory contains working configurations for each platform.

**Understanding a failure:** The `22-debugging/` chapter contains HAB event codes, UART trace analysis, and failure mode trees. Start there when boot authentication fails.

**For production deployment:** Follow `23-manufacturing/` and `24-key-ceremony/` sequentially. These chapters assume all prior content is understood.

---

## Prerequisites

### Hardware
- PHYTEC phyCORE-i.MX8MP SoM + phyBOARD-Pollux carrier (primary)
- USB-to-UART adapter (3.3V, 115200 baud)
- SD card (minimum 8GB, Class 10 or better)
- Optional: eMMC programming adapter
- Optional: JTAG debugger (ARM DSTREAM or Segger J-Link)

### Software
- Linux host (Ubuntu 22.04 LTS or Debian Bookworm recommended)
- Yocto Kirkstone or Scarthgap toolchain
- NXP Code Signing Tool (CST) 3.3.x or later
- NXP SPSDK (Secure Provisioning SDK)
- OpenSSL 3.x
- Python 3.10+ with `cryptography` package
- Docker (for reproducible build environments)

### Knowledge Prerequisites
See [`00-learning-path/PREREQUISITES.md`](00-learning-path/PREREQUISITES.md) for a detailed breakdown with skill assessment questions and links to remediation resources.

**Minimum baseline:**
- Comfortable with Linux shell, git, and package management
- Understands what a bootloader does
- Has built at least one Yocto image
- Understands public/private key cryptography at a conceptual level

---

## Repository Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full document covering design principles, documentation taxonomy, chapter dependency graphs, and naming conventions.

---

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for engineering contribution standards, required sections for new chapters, diagram requirements, security review requirements, and the PR checklist.

Key requirements for contributions:
- All commands must be tested on real hardware or documented as untested
- Security properties must be stated precisely (what is protected, against what attacker)
- No "security theater" content: every mechanism must have a documented threat it addresses
- HAB/AHAB behavior must be verified against NXP Application Notes, not inferred

---

## License

This repository is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Hardware-specific content (register maps, fuse definitions, boot ROM behavior) is derived from NXP Reference Manuals and is subject to NXP's documentation license terms. Reproduction of NXP register maps is for educational reference; consult the official NXP i.MX8M Plus Reference Manual (IMX8MPRM) for authoritative specifications.

---

## A Note on Security Warnings

Throughout this repository, critical security warnings appear in this format:

> **⚠️ WARNING:** Burning fuses is irreversible. A mistake can permanently brick a device or lock you out of the manufacturing flow. Never run fuse-burning commands on production hardware without a validated test run on a sacrificial board.

These warnings identify actions that are irreversible, actions that can expose key material, and common implementation mistakes that undermine the security guarantees of the system. Read them.
