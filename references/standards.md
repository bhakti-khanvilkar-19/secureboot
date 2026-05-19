# Standards and Specifications

## ARM Architecture Standards

| Standard | Description | Relevance |
|----------|-------------|-----------|
| ARM TrustZone | Security extension for ARMv8-A | TF-A, OP-TEE isolation model |
| PSCI (ARM DEN0022) | Power State Coordination Interface | TF-A power management |
| SMCCC (ARM DEN0028) | SMC Calling Convention | TF-A/OP-TEE interface |
| ARM PSA | Platform Security Architecture | Security requirements framework |
| ARM CCA | Confidential Compute Architecture | Future attestation model |

## Trusted Computing Group (TCG)

| Standard | Description | Relevance |
|----------|-------------|-----------|
| TCG TPM 2.0 Spec | TPM architecture and commands | TPM provisioning, key sealing |
| TCG PC Client Platform TPM Profile | Hardware TPM requirements | Discrete TPM integration |
| TCG EFI Protocol Spec | EFI TPM interface | TPM access from bootloader |
| TCG Measured Boot | Boot measurement specification | PCR usage, event log format |
| TCG Remote Attestation | Attestation protocol | Device identity verification |

## IETF Standards

| RFC | Description | Relevance |
|-----|-------------|-----------|
| RFC 5280 | X.509 Certificate Profile | Certificate format used in CSF |
| RFC 5652 | Cryptographic Message Syntax (CMS) | SWUpdate/RAUC package signing |
| RFC 8949 | CBOR | COSE message format (newer attestation) |
| RFC 9334 | RATS Architecture | Remote Attestation Procedures |

## NIST Standards

| Document | Description | Relevance |
|----------|-------------|-----------|
| NIST SP 800-57 | Key Management Recommendations | Key generation and lifecycle |
| NIST SP 800-131A | Transitioning Cryptographic Algorithms | Algorithm selection |
| NIST SP 800-147 | BIOS Protection Guidelines | Firmware update security |
| NIST SP 800-155 | BIOS Integrity Measurement Guidelines | Measured boot |
| NIST SP 800-193 | Platform Firmware Resiliency Guidelines | Production resilience |
| NIST FIPS 140-3 | Security Requirements for Crypto Modules | HSM requirements |
| NIST FIPS 186-5 | Digital Signature Standard | RSA, ECDSA parameters |

## IEC/ISO Standards

| Standard | Description | Relevance |
|----------|-------------|-----------|
| IEC 62443-4-2 | Security for IACS: Component Requirements | Embedded device requirements |
| IEC 62443-4-1 | Security for IACS: Product Development | Secure development lifecycle |
| ISO 27001 | Information Security Management | Key management processes |
| ISO 21434 | Road Vehicle Cybersecurity | Automotive embedded security |
| EN 303 645 | ETSI Cyber Security for IoT | Consumer IoT security baseline |

## Open Source References

| Project | Description | URL |
|---------|-------------|-----|
| Trusted Firmware-A | ARM Trusted Firmware | trustedfirmware.org/projects/tf-a |
| OP-TEE | Open Portable Trusted Execution Environment | optee.readthedocs.io |
| U-Boot | Universal Bootloader | u-boot.readthedocs.io |
| Linux dm-verity | Kernel documentation | kernel.org/doc/html/latest/admin-guide/device-mapper/verity.html |
| SWUpdate | Software Update for Embedded Systems | sbabic.github.io/swupdate |
| RAUC | Robust Auto-Update Controller | rauc.readthedocs.io |

## Algorithm Selection Reference

| Use Case | Recommended | Minimum | Avoid |
|----------|------------|---------|-------|
| RSA key size | 3072 | 2048 | 1024 |
| Hash function | SHA-256 | SHA-256 | MD5, SHA-1 |
| Symmetric encryption | AES-256-GCM | AES-128-CBC | DES, 3DES |
| ECC curve | P-384 | P-256 | secp192r1 |
| PBKDF iterations | 600,000 | 100,000 | < 10,000 |
| Key derivation | HKDF | PBKDF2 | Simple hash |
