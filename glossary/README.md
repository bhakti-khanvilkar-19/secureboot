# Glossary

## A

**AHAB (Advanced High Assurance Boot)**
NXP's next-generation secure boot mechanism for i.MX9 series. Successor to HABv4. Uses signed containers and EdgeLock Enclave for verification instead of ROM-executed code.

**Anti-rollback**
Security mechanism preventing downgrade to older, potentially vulnerable firmware versions. Implemented via monotonic OCOTP fuse counter or software version checks.

**ARM TrustZone**
Hardware security extension in ARMv8-A that creates two execution environments: Secure World (EL3/EL1-S) and Normal World (EL2/EL1-NS). Provides hardware isolation between trusted (OP-TEE) and untrusted (Linux) software.

**Attestation**
Process by which a device proves its software/configuration state to a remote verifier. Uses TPM PCR quotes signed by an attestation key.

## B

**BL1/BL2/BL31/BL32/BL33**
Trusted Firmware-A boot stage numbering. BL2 = boot loader stage 2 (loads other components). BL31 = EL3 runtime firmware. BL32 = Secure-EL1 payload (OP-TEE). BL33 = Normal world bootloader (U-Boot).

**Boot Container**
See: IVT, CSF. The collection of structures that the ROM parses to locate, authenticate, and execute the first-stage bootloader.

## C

**CAAM (Cryptographic Acceleration and Assurance Module)**
i.MX8MP hardware crypto engine. Provides AES, RSA/ECC, SHA, TRNG. Used by OP-TEE for HUK derivation, key operations, and random number generation.

**Chain of Trust**
Sequence of cryptographic verifications from hardware root (ROM/fuses) through each software stage, ensuring each stage is authenticated before execution. Breaking any link means subsequent stages are untrusted.

**CLOSED mode**
HABv4 device lifecycle state. SEC_CONFIG fuse = 0x2. ROM enforces authentication; any failure halts boot. Cannot be reverted once set.

**CSF (Command Sequence File)**
Binary structure interpreted by HABv4. Contains commands: Install SRK, Install CSFK, Authenticate CSF, Install Key, Authenticate Data. Appended to imx-boot after signing.

**CST (Code Signing Tool)**
NXP proprietary tool for HABv4 CSF generation and signing. Includes `cst` (sign) and `srktool` (SRK table generation) binaries.

## D

**DCD (Device Configuration Data)**
Optional structure in the IVT that the ROM uses to initialize hardware (DDR) before jumping to SPL. Contains register write commands.

**dm-verity**
Linux kernel device mapper target that provides per-block SHA-256 integrity checking for block devices. Uses a Merkle tree (hash tree). Root hash embedded in signed kernel cmdline.

**DTB (Device Tree Blob)**
Compiled binary of a device tree source file (.dts). Describes hardware to Linux kernel and U-Boot. Used in FIT images and for embedding FIT public keys.

## E

**EL0/EL1/EL2/EL3**
ARM64 exception levels. EL0 = user applications. EL1 = kernel (both Normal and Secure worlds). EL2 = hypervisor. EL3 = secure monitor (TF-A BL31).

**eFuse / OCOTP**
One-Time Programmable fuses. i.MX8MP's OCOTP (On-Chip One-Time Programmable controller) provides ~2048 bits of OTP storage. Used for SRK hash, SEC_CONFIG, and other security configuration.

## F

**FIT (Flat Image Tree)**
U-Boot image format based on flattened device tree. Contains multiple images (kernel, DTB, ramdisk) with hashes and RSA signatures. U-Boot verifies the configuration signature before loading.

**fTPM (Firmware TPM)**
Software implementation of TPM 2.0 as an OP-TEE Trusted Application. Uses CAAM for hardware RNG and RPMB for state persistence. No external chip required.

## H

**HABv4 (High Assurance Boot version 4)**
NXP's hardware-enforced secure boot mechanism. ROM reads CSF appended to imx-boot, verifies CSF signature chain using SRK hash stored in OCOTP fuses.

**HSM (Hardware Security Module)**
Dedicated hardware device for cryptographic key operations. Private keys are stored inside HSM and cannot be exported. Examples: YubiHSM2, Thales Luna, AWS CloudHSM.

**HUK (Hardware Unique Key)**
256-bit device-unique secret derived from CAAM fuses (SNVS master key). Used by OP-TEE to derive RPMB key and device-specific secrets. Never leaves the SoC.

## I

**IMA (Integrity Measurement Architecture)**
Linux security subsystem that measures (hashes) files at access time and logs measurements to a TPM PCR. Can enforce file integrity via EVM.

**IMG Key**
HABv4 signing hierarchy: CA → SRK → CSF → **IMG key** → boot images. The IMG key's certificate is installed in the CSF by the "Install Key" command. Used to sign the actual imx-boot binary content.

**ITS (Image Tree Source)**
Source file (.its) from which FIT images are compiled using mkimage. Similar to device tree source syntax.

**IVT (Image Vector Table)**
64-byte data structure at a fixed offset in imx-boot (0x400 for SD/eMMC, 0x0 for eMMC boot0). Contains pointers to entry point, DCD, self (IVT), boot data, CSF. Parsed by ROM.

## K

**Key Ceremony**
Formal, documented process for generating cryptographic keys. Requires multiple authorized witnesses, documented procedures, and audit trail. Required for generating SRK keys.

## L

**LUKS (Linux Unified Key Setup)**
Standard disk encryption format for Linux. LUKS2 supports multiple key slots, Argon2id PBKDF, and TPM-sealed keys.

## M

**Measured Boot**
Boot process where each stage records a measurement (hash) of the next stage into TPM PCRs. Does not prevent boot but provides verifiable audit trail and enables key sealing.

## O

**OCOTP**
See: eFuse

**OP-TEE (Open Portable Trusted Execution Environment)**
Open-source Trusted OS running in ARM TrustZone Secure World at EL1-S. Provides secure storage (RPMB), HUK access, fTPM, and a framework for Trusted Applications (TAs).

**OPEN mode**
HABv4 device state before SEC_CONFIG fuse is burned. Authentication failures are logged as HAB events but do not halt boot. Used for development and testing.

## P

**PCR (Platform Configuration Register)**
TPM register holding a SHA-256 value. Extended (not overwritten) by measured boot stages. PCR values reflect the exact software that booted. Used for key sealing and attestation.

**PKCS#11**
Standard interface for HSM access. Allows software to perform cryptographic operations using keys stored in an HSM without those keys being exported.

## R

**Root Hash**
32-byte SHA-256 value at the root of the dm-verity Merkle tree. Represents a cryptographic commitment to the entire block device contents. Must be in a signed/trusted location.

**RPMB (Replay-Protected Memory Block)**
eMMC partition protected by an authentication key. Prevents replay attacks on stored data. Used by OP-TEE for tamper-resistant secure storage.

## S

**SEC_CONFIG**
OCOTP fuse field (Bank 1, Word 3, bit 1). Setting bit 1 (value 0x2) puts the device in CLOSED mode — HABv4 failures halt boot.

**SNVS (Secure Non-Volatile Storage)**
i.MX8MP hardware module that maintains tamper-detection state, security configuration, and holds the ZMK (Zone Master Key). Always powered (even in standby). Contains tamper detection logic.

**SRK (Super Root Key)**
One of four RSA-2048 keys in the HABv4 hierarchy. SHA-256 of SRK table (SRK1-4 public keys bundled) burned into OCOTP fuses. ROM verifies CSF's SRK against this fuse hash.

**STRIDE**
Threat modeling framework: Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege.

**SWUpdate**
Open-source embedded Linux update framework. Supports A/B updates, CMS-signed packages, hardware handlers, and Hawkbit integration.

## T

**TF-A (Trusted Firmware-A)**
Reference implementation of ARM Trusted Firmware. Provides secure monitor (BL31) that manages TrustZone transitions, power management (PSCI), and loads OP-TEE.

**TrustZone**
See: ARM TrustZone

**TPM (Trusted Platform Module)**
Secure cryptographic processor providing PCR-based measured boot, key generation, key sealing, and remote attestation. Available as discrete chip or firmware TPM (fTPM via OP-TEE).

## U

**U-Boot**
Universal Boot Loader. Third-stage bootloader (after ROM + SPL) that loads and verifies the FIT image (kernel + DTB + ramdisk). Compiled with FIT signing key embedded in DTB.

## V

**Verified Boot**
Boot process where each stage cryptographically verifies the next before executing it. Distinct from Measured Boot: verification halts boot on failure vs. just recording.

## W

**WIC (Wic Image Creator)**
Yocto tool for creating partitioned disk images. Uses .wks (Wic Kickstart) files to define partition layout. Output: .wic, .wic.gz, .wic.bmap files for flashing.
