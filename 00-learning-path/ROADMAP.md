# Implementation Roadmap: From Foundations to Production

## Overview

This roadmap defines a 12-week structured path from zero to production-ready Secure Boot deployment on NXP i.MX8MP with PHYTEC hardware. It is designed for a full-time engineer with the baseline prerequisites met. Part-time engineers should adjust timelines proportionally (approximately 2.5x for 20h/week engagement).

The roadmap is designed around **three competency gates**: after Phase 1, you can explain Secure Boot to a colleague; after Phase 2, you can implement a working HABv4 configuration; after Phase 3, you can deploy it to production.

---

## Phase 1: Foundations (Weeks 1–2)

### Objectives

By the end of Phase 1, you will be able to:
- Describe the full i.MX8MP boot sequence from power-on to userspace
- Explain the threat model that motivates Secure Boot
- Understand the cryptographic primitives used in HABv4
- Identify the trust anchors in an i.MX8MP system and explain why they are trusted
- Explain what the SRK hash is, where it lives, and why it matters

### Chapters Covered

| Chapter | Files | Hours |
|---------|-------|-------|
| 00-learning-path | README, ROADMAP, PREREQUISITES | 2h |
| 01-security-foundations | README, 01-threat-modeling, 02-attack-surfaces, 03-secure-vs-verified | 5h |
| 02-embedded-cryptography | README, 01-hash-functions, 02-asymmetric-crypto, 03-pki-and-certificates | 8h |
| 05-boot-architecture | README, 01-imx8mp-boot-flow | 5h |

### Hands-On Labs

**Lab 1.1: Observe Unprotected Boot**
- Boot a PHYTEC phyBOARD-Pollux from SD card without any Secure Boot configuration
- Capture the full UART boot log
- Annotate the log: identify each software stage (ROM → SPL → TF-A → OP-TEE → U-Boot → kernel)
- Verify stage transitions by recognizing characteristic output strings
- Deliverable: annotated boot log with each stage identified

**Lab 1.2: Cryptographic Operations on Host**
- Generate a 4096-bit RSA key pair using OpenSSL
- Sign a test binary (U-Boot image or any binary)
- Verify the signature
- Extract the public key and examine its structure with `openssl rsa -text`
- Compute SHA-256 of the binary and compare to HABv4 expectations
- Deliverable: completed OpenSSL exercise with documented outputs

**Lab 1.3: Certificate Chain Creation**
- Create a 3-level certificate chain: Root CA → Intermediate CA → Signing Key
- Sign a test CSR at each level
- Verify the chain with `openssl verify`
- Export the chain and examine each certificate with `openssl x509 -text`
- Deliverable: functional 3-level PKI with all intermediate files preserved

**Lab 1.4: Boot Architecture Mapping**
- From the UART log captured in Lab 1.1, create a timeline diagram
- Map each stage to: which software runs, at what address, in which exception level (EL3/EL1/EL0)
- Identify: where DDR initialization happens, where DRAM becomes available, where Normal World begins
- Deliverable: annotated boot timeline with exception levels

### Validation Criteria

Before proceeding to Phase 2, verify:

- [ ] You can explain HABv4 at a 5-minute whiteboard level to a colleague
- [ ] You can explain the difference between SRK hash and the signing key
- [ ] You can describe what happens in boot ROM and why it is the Root of Trust
- [ ] You can generate a key pair and sign a file without referencing documentation
- [ ] You can identify at least 5 specific attack scenarios that Secure Boot addresses
- [ ] You can identify at least 3 attack scenarios that Secure Boot does NOT address
- [ ] You can trace the full i.MX8MP boot flow end-to-end

### Knowledge Checkpoint 1

Answer these questions without looking at documentation. If you cannot, return to the relevant chapter:

1. What is stored in the OCOTP fuses that enables HABv4 to work?
2. What is the difference between HAB open configuration and HAB closed configuration?
3. If the SRK hash in fuses is 0x000...000 (all zeros), will HABv4 reject unsigned images?
4. What exception level does TF-A BL31 run at after handoff from ROM?
5. What does the Boot ROM do if it finds no valid IVT at the expected offset?
6. What is the difference between RSA-PSS and RSA-PKCS1v1.5 padding?
7. Why is SHA-1 not used in HABv4?
8. What is a certificate chain and why does it matter for SRK rotation?

---

## Phase 2: Architecture Understanding (Weeks 3–4)

### Objectives

By the end of Phase 2, you will be able to:
- Trace exactly how HABv4 authenticates the SPL using the SRK table
- Understand the full chain of trust from ROM to Linux kernel
- Configure and build a signed HABv4 image using NXP CST
- Understand what U-Boot FIT image signing accomplishes
- Read and decode a HAB status event log
- Explain TF-A's role in establishing secure monitor services

### Chapters Covered

| Chapter | Files | Hours |
|---------|-------|-------|
| 03-root-of-trust | README, 01-hardware-security-features-imx8mp | 4h |
| 04-chain-of-trust | README, 01-chain-of-trust-diagram | 3h |
| 06-nxp-hab | README, 01-hab-architecture, 02-signing-workflow, 03-csf-configuration | 13h |
| 08-uboot-verified-boot | README, 01-fit-image-signing, 02-public-key-enrollment | 10h |
| 09-trusted-firmware-a | README, 01-build-configuration, 02-secure-monitor | 8h |

### Hands-On Labs

**Lab 2.1: HABv4 Open Mode Testing**
- Configure HABv4 in open mode (ROM authenticates but does not enforce)
- Generate SRK table using NXP CST or SPSDK
- Sign the SPL image with a CSF block
- Boot the signed image and observe HAB status in U-Boot
- Run `hab_status` and document the output (should show 0 events in open mode with valid sig)
- Deliberately corrupt the signature and re-run to observe the HAB event
- Deliverable: captured `hab_status` output for valid sig, invalid sig, and unsigned image

**Lab 2.2: Full Signing Workflow**
- Sign SPL + TF-A/OP-TEE FIT + U-Boot using the CST workflow
- Boot and verify each stage authenticates successfully
- Use `hab_auth_img` in U-Boot to authenticate a test image manually
- Deliverable: working signed boot image with documented CSF files

**Lab 2.3: U-Boot FIT Image Signing**
- Create a FIT image with kernel + DTB + initramfs
- Sign the FIT image with a U-Boot signing key
- Enroll the public key in U-Boot's device tree
- Boot and observe U-Boot's signature verification output
- Deliverable: signed FIT image, modified U-Boot device tree with enrolled key

**Lab 2.4: TF-A Secure Monitor**
- Build TF-A with debug output enabled
- Boot and capture TF-A console output (via UART2 on phyBOARD-Pollux)
- Identify: BL2 handoff, BL31 initialization, BL32 (OP-TEE) loading, BL33 (U-Boot) handoff
- Invoke an PSCI function (e.g., CPU hotplug) from Linux and observe TF-A handling
- Deliverable: annotated TF-A boot log with stage transitions

### Validation Criteria

Before proceeding to Phase 3, verify:

- [ ] You have a working signed boot image that authenticates in HAB open mode
- [ ] You can read and interpret a HAB event code
- [ ] You can explain exactly what the SRK table is and how it is validated
- [ ] You have a working U-Boot FIT image with signature verification
- [ ] You can rebuild the signing workflow from scratch (not from memory—from documentation)
- [ ] You understand the TF-A BL stage sequence and which stage you can modify

### Knowledge Checkpoint 2

1. What happens if you sign with SRK key 1 but the SRK table in the image contains key 2 as index 1?
2. What is the minimum image size alignment required by HABv4's CSF placement requirements?
3. When U-Boot calls `hab_auth_img`, what HABv4 RVT function is invoked, and what does it check?
4. What is the difference between `u-boot-with-spl.bin` and `flash.bin` in the NXP build system?
5. If TF-A BL2 fails to authenticate BL32 (OP-TEE), what is the default behavior?
6. What is the `KEY_IDENTIFIER` field in a HABv4 CSF and why does it matter?
7. In a FIT image, what is the difference between image node hashes and configuration node hashes?

---

## Phase 3: Implementation (Weeks 5–8)

### Objectives

By the end of Phase 3, you will be able to:
- Close HABv4 (burn the SEC_CONFIG fuse) safely on a test device
- Configure dm-verity for the root filesystem
- Configure OP-TEE secure storage
- Set up the full Linux security stack (kernel lockdown, dm-crypt)
- Integrate the signing workflow into a Yocto build
- Run the full validation test suite on a provisioned device

### Chapters Covered

| Chapter | Files | Hours |
|---------|-------|-------|
| 10-optee | README, 01-trusted-applications, 02-secure-storage | 8h |
| 11-linux-kernel-security | README, 01-kernel-lockdown, 02-module-signing | 6h |
| 12-dm-verity | README, 01-verity-configuration, 02-error-handling | 7h |
| 13-dm-crypt | README, 01-luks-setup, 02-key-management | 7h |
| 14-secure-storage | README, 01-optee-storage, 02-rpmb | 6h |
| 18-yocto-integration | README, 01-meta-signing, 02-signing-keys | 12h |
| 19-phytec-specifics | README, 01-phycore-imx8mp, 02-bsp-integration | 6h |
| 21-testing-validation | README, 01-test-suite, 02-hab-event-analysis | 9h |

### Hands-On Labs

**Lab 3.1: HABv4 Closed Mode (CRITICAL)**
- This lab requires a sacrificial board not intended for production
- Verify signing workflow is completely functional in open mode first
- Burn the SRK_HASH fuses using U-Boot `fuse prog` command
- Verify: `fuse read 6 0 4` returns the expected SRK hash value
- Burn SEC_CONFIG[1]: `fuse prog 0 6 0x2` (IRREVERSIBLE)
- Verify: board boots only with correctly signed image
- Verify: unsigned image is rejected (board should hang at HAB check)
- Deliverable: test report documenting each fuse value burned and verification result

> **⚠️ CRITICAL:** This lab permanently modifies hardware. Use only a board explicitly designated for fuse testing. Maintain exact records of which board (by serial number) had which fuses burned.

**Lab 3.2: dm-verity Root Filesystem**
- Build a read-only root filesystem image
- Generate the dm-verity hash tree and root hash
- Configure the kernel command line with `dm-verity` parameters
- Boot and verify dm-verity is active: `dmsetup status`
- Test integrity: introduce a deliberate block corruption and observe kernel panic
- Deliverable: verified dm-verity configuration with test report

**Lab 3.3: OP-TEE Secure Storage**
- Build and install the `optee_test` package
- Run `xtest` test suite and capture results
- Implement a simple Trusted Application that stores a secret
- Verify the secret survives reboot and is inaccessible from Normal World
- Deliverable: `xtest` output, TA source code, test script

**Lab 3.4: Yocto Integration**
- Integrate signing keys into Yocto build (`meta-signing` or equivalent)
- Build a complete signed image using `bitbake`
- Verify the built image boots and authenticates on hardware
- Automate the signing step in the Yocto build pipeline
- Deliverable: working Yocto configuration with automated signing

**Lab 3.5: Validation Test Suite**
- Execute the full test suite from `21-testing-validation/`
- Document any failures and their root causes
- Produce a validation report suitable for security audit
- Deliverable: completed validation report

### Validation Criteria

Before proceeding to Phase 4, verify:

- [ ] A board with burned fuses rejects unsigned images
- [ ] The full signing workflow is automated in Yocto
- [ ] dm-verity is functional and tested (including corruption detection)
- [ ] OP-TEE secure storage is functional and tested
- [ ] The validation test suite passes on a provisioned device

---

## Phase 4: Production Hardening (Weeks 9–12)

### Objectives

By the end of Phase 4, you will be able to:
- Conduct a key ceremony using an HSM
- Design and implement a manufacturing provisioning pipeline
- Evaluate compliance against NIST SP 800-193 and IEC 62443
- Implement an incident response procedure for key compromise
- Build and validate a production-ready Secure Boot deployment

### Chapters Covered

| Chapter | Files | Hours |
|---------|-------|-------|
| 15-key-management | README, 01-key-hierarchy, 02-key-rotation | 8h |
| 16-certificate-management | README, 01-cert-lifecycle, 02-revocation | 6h |
| 17-fuse-programming | README, 01-burn-procedure, 02-verification | 7h |
| 22-debugging | README, 01-hab-failure-codes, 02-uart-analysis | 6h |
| 23-manufacturing | README, 01-provisioning-pipeline, 02-batch-signing | 8h |
| 24-key-ceremony | README, 01-ceremony-procedure, 02-hsm-integration | 5h |
| 25-compliance | README, 01-nist-800-193, 02-iec-62443 | 6h |
| 26-runtime-security | README, 01-kernel-hardening, 02-seccomp | 6h |
| 27-supply-chain | README, 01-sbom, 02-toolchain-security | 6h |
| 28-incident-response | README, 01-key-compromise, 02-firmware-rollback | 5h |

### Hands-On Labs

**Lab 4.1: Key Ceremony Simulation**
- Using a software HSM (SoftHSM2) as a stand-in for hardware HSM
- Simulate a multi-person key ceremony: generate SRK keys with ceremony controls
- Document the full ceremony procedure as if it were a real production ceremony
- Generate key backups and escrow documentation
- Deliverable: completed ceremony record document, generated keys stored in SoftHSM2

**Lab 4.2: Manufacturing Provisioning Pipeline**
- Configure SPSDK to sign and provision a batch of test images
- Simulate a manufacturing station: flash + provision + test in one workflow
- Implement batch verification: every provisioned board must pass authentication test
- Implement audit logging for each provisioned device
- Deliverable: working provisioning script, audit log from provisioning 3 test boards

**Lab 4.3: NIST SP 800-193 Compliance Evaluation**
- Work through the NIST SP 800-193 checklist for your implementation
- Document: which requirements are met, partially met, and not met
- For each gap: identify what would be required to meet the requirement
- Deliverable: compliance evaluation document

**Lab 4.4: Incident Response Drill**
- Scenario: the SRK private key has been compromised (simulate this by "leaking" the test key)
- Execute the incident response procedure:
  1. Identify affected devices (all devices signed with compromised key)
  2. Prepare recovery firmware signed with backup SRK
  3. Deploy recovery firmware via OTA update
  4. Verify recovery is complete
- Deliverable: incident response timeline, recovery procedure document

### Validation Criteria

Production readiness requires all of the following:

- [ ] Key ceremony completed with documented ceremony record
- [ ] Manufacturing pipeline tested with at least 5 devices end-to-end
- [ ] All provisioned devices pass the validation test suite
- [ ] NIST SP 800-193 compliance evaluation completed
- [ ] Incident response procedure documented and drilled
- [ ] No production key material exists outside the HSM
- [ ] Fuse programming procedure reviewed by a second engineer
- [ ] Full validation report reviewed and signed off

---

## Milestone Summary

| Milestone | Week | Gate Criteria |
|-----------|------|---------------|
| M1: Foundations Complete | End of Week 2 | Pass Knowledge Checkpoint 1 |
| M2: First Signed Boot | End of Week 3 | Signed image boots in open mode |
| M3: Architecture Complete | End of Week 4 | Pass Knowledge Checkpoint 2 |
| M4: First Closed Boot | End of Week 6 | Signed image enforced on test device |
| M5: Full Stack Complete | End of Week 8 | dm-verity + OP-TEE + Yocto integration |
| M6: Production Ready | End of Week 12 | All Phase 4 validation criteria met |
