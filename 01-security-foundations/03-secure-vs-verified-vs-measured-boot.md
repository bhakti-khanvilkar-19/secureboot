# Secure Boot vs Verified Boot vs Measured Boot

## Version Matrix

| Topic/Standard | Version/Reference | Status |
|----------------|-------------------|--------|
| NXP HABv4 | i.MX8MP RM Rev 3, 11/2021 | Current |
| Android Verified Boot (AVB) | 2.0 | Current |
| TPM 2.0 (Measured Boot) | TCG TPM Library Spec 2.0 Rev 1.59 | Current |
| dm-verity | Linux kernel 5.15+ | Current |
| UEFI Secure Boot | UEFI Spec 2.10 | Current |

---

## Overview

Three distinct concepts are routinely conflated in embedded systems literature, vendor documentation, and implementation teams: Secure Boot, Verified Boot, and Measured Boot. Each term describes a different architectural approach to boot security. Each enforces different properties, uses different mechanisms, and protects against different threat scenarios.

Getting this distinction wrong leads to real implementation failures. Engineers who believe "we have Secure Boot" when they have only Measured Boot believe they have runtime enforcement when they have only an audit trail. Engineers who conflate Verified Boot with Measured Boot may fail to deploy TPM-based disk encryption keys because they believe boot verification already covers the use case.

This chapter defines each precisely, explains the threat it mitigates, shows the implementation on i.MX8MP where applicable, and provides a comparison that guides architectural decisions for embedded Linux systems.

---

## Secure Boot

### Definition

Secure Boot is a mechanism that cryptographically verifies the authenticity and integrity of firmware or software **before allowing it to execute**. Verification failure **halts execution**. The defining characteristic is the enforcement: on a correctly configured system, unverified code never runs.

### Key Properties

- Cryptographic signature verification precedes every execution handoff
- Chain of trust: each stage verifies the next before jumping to it
- Failure mode in production (CLOSED mode): system halts, execution does not proceed
- No fallback to unsigned code in production configuration
- Protects against: unsigned firmware loading, tampered firmware loading

### What Secure Boot Is NOT

Secure Boot does not verify that the code is *correct*, *bug-free*, or *legitimate in intent*. It verifies that it was signed by the holder of the expected private key. A buggy but signed bootloader passes Secure Boot. A signed but malicious kernel (if the signing key is compromised) passes Secure Boot. The mechanism authenticates provenance, not quality or intent.

### NXP HABv4 Implementation

NXP i.MX8MP uses HABv4 (High Assurance Boot version 4) as its Secure Boot implementation. HABv4 is a ROM-resident authentication library. Its operation:

1. The Boot ROM executes at power-on from the on-die ROM address
2. ROM reads the Image Vector Table (IVT) from the boot device at offset 0x400 (SD/MMC)
3. The IVT contains a pointer to the Command Sequence File (CSF)
4. The CSF describes the signing structure: which SRK certificate to use, what image regions to authenticate
5. ROM compares the SHA-256 hash of the SRK table (from CSF) against the **SRK_HASH burned in OTP fuses**
6. If the SRK table hash matches the fuse values, HABv4 verifies the image signature using the SRK-signed certificate chain
7. In **OPEN mode** (`SEC_CONFIG[1]=0`): HABv4 logs verification results but permits execution regardless of outcome
8. In **CLOSED mode** (`SEC_CONFIG[1]=1`): HABv4 halts if signature verification fails

The behavior difference between OPEN and CLOSED mode is not cosmetic. **OPEN mode is not a production security configuration.** It is a development and validation mode. Secure Boot enforcement requires CLOSED mode.

```
HABv4 Secure Boot Flow:

Power On Reset
     │
     ▼
Boot ROM Executes
     │
     ├── Read boot device (eMMC BOOT0 partition)
     ├── Parse IVT at offset 0x8400 (eMMC boot partition)
     │   ├── entry: SPL entry address
     │   ├── self: IVT address itself
     │   ├── dcd: Device Configuration Data pointer
     │   ├── boot_data: boot data structure pointer
     │   └── csf: Command Sequence File pointer ◄── HABv4 reads this
     │
     ├── Parse CSF
     │   ├── Install SRK table (4 SRK certificates)
     │   ├── Install IMG public key certificate (signed by SRK)
     │   ├── Verify SRK table hash == OCOTP fuse SRK_HASH ◄── KEY CHECK
     │   └── Authenticate image regions (hash + RSA verify)
     │
     ├── SEC_CONFIG[1] == 1 (CLOSED)?
     │   ├── YES: Verification failure → HALT (WDT reset or spin)
     │   └── NO:  Verification failure → log HAB event, continue
     │
     └── Verification passed → jump to SPL entry point
```

### HABv4 SRK Hash Verification Detail

The SRK hash in OTP fuses is a SHA-256 hash of the concatenation of four SRK public key moduli:

```
SRK_HASH = SHA-256(SRK1_modulus || SRK2_modulus || SRK3_modulus || SRK4_modulus)
```

This 256-bit hash is stored across 8 fuse words (OCOTP_SRK0 through OCOTP_SRK7). Four SRK slots allow key revocation: if one SRK private key is compromised, its slot can be burned (fused) as revoked, and subsequent images are signed with a different SRK slot.

```bash
# Inspect the SRK hash that will be burned (from NXP CST tool output)
$ cat SRK_1_2_3_4_fuse.bin | xxd | head -4
00000000: a3b7 2c9e 1f4d 6a88 7e5c 3012 8b94 ef1a  ..,..Mj.^.0.....
00000010: 5d72 c8a9 0e3b 1f6d 4a9e 8c72 1d5b 9f3e  ]r...;.mJ..r.[.>

# Read current fuse values on running device
$ cat /sys/bus/platform/drivers/imx-ocotp/*/nvmem | xxd -s 0x580 -l 32
```

### What HABv4 Secure Boot Protects

| Threat | Protected? | Mechanism |
|--------|-----------|-----------|
| Replace SPL with unsigned binary | YES (closed) | SRK_HASH mismatch |
| Replace SPL with signed-but-tampered binary | YES | Image hash mismatch in CSF |
| Replace SPL with attacker-signed binary (no matching fuse) | YES | SRK_HASH mismatch |
| Replace SPL with attacker-signed binary (matching fuse, stolen key) | NO | Key material compromise |
| Post-boot kernel exploit | NO | HABv4 scope ends at handoff |
| Side-channel extraction of SRK key | NO | Physical security domain |

---

## Verified Boot

### Definition

Verified Boot is a term most precisely defined by Google for ChromeOS and Android, though it has broader use. The core concept is the same as Secure Boot — cryptographic verification before execution — but the term emphasizes hash-based integrity verification of **all system components**, including the root filesystem, using Merkle tree (hash tree) structures.

The defining extension beyond basic Secure Boot is **dm-verity**: the Linux kernel module that verifies the integrity of block devices on every read using a Merkle tree whose root hash is known-good.

### Key Differences from Secure Boot

| Property | Secure Boot (HABv4) | Verified Boot (AVB/dm-verity) |
|----------|---------------------|-------------------------------|
| Scope | Bootloader chain | Bootloader + entire rootfs |
| Data structure | Certificate chain + CSF | Merkle tree (dm-verity) |
| Verification timing | At boot, before execution | At boot + on every block read |
| Rootfs covered | No (kernel only in FIT) | Yes (dm-verity on entire partition) |
| Filesystem must be | Writable or read-only | Read-only (dm-verity requires RO) |
| Recovery mode | Halt or boot | ChromeOS: recovery mode |

### Android Verified Boot (AVB) Architecture

Android Verified Boot 2.0 uses a `vbmeta` partition containing:
- Verification descriptor for each signed partition (hash or Merkle tree root hash)
- Hash algorithms and sizes
- Rollback index for anti-rollback protection
- Signature over the entire vbmeta structure

```
AVB Chain:

Bootloader (verified by HABv4)
     │
     ▼
vbmeta partition
  ├── boot partition descriptor (hash)
  ├── system partition descriptor (dm-verity root hash)
  ├── vendor partition descriptor (dm-verity root hash)
  └── AVBv2 signature (RSA/ECDSA, key in bootloader)
     │
     ▼
Android kernel + dm-verity for /system, /vendor
```

### U-Boot "Verified Boot" = FIT Image Signing

In U-Boot documentation and community usage, "verified boot" often refers specifically to the FIT (Flattened Image Tree) image signature verification feature. This is U-Boot's implementation of bootloader-to-kernel chain of trust:

- Public key embedded in U-Boot binary (in U-Boot DTB, `signature` node)
- FIT image signed with corresponding private key using `mkimage`
- U-Boot verifies FIT signature using the embedded public key
- On verification failure: `bootm` refuses to boot the kernel

This is equivalent in security properties to Secure Boot at the kernel handoff stage. The U-Boot FIT documentation calls it "verified boot" as a distinct feature name. In this repository, we treat FIT signing as the "Layer 2" Verified Boot that extends the HABv4 chain of trust from the bootloader to the kernel.

### dm-verity: Block-Level Rootfs Verification

dm-verity implements a Merkle tree over the root filesystem block device. The root of the Merkle tree (the "root hash") is embedded in the kernel command line or in the FIT image configuration, signed as part of the FIT signature.

```
dm-verity Merkle Tree Structure:

Level 0 (Leaves):
  [H(Block0)] [H(Block1)] [H(Block2)] ... [H(BlockN)]
                                  │
Level 1:                          │
  [H(H(B0)||H(B1))] [H(H(B2)||H(B3))] ... │
                           │               │
Level N:                   │               │
                    [ROOT HASH] ◄── embedded in signed FIT / kernel cmdline

Every block read goes through this tree. A tampered block produces
a hash mismatch anywhere in the tree, which dm-verity detects and
responds to (typically with I/O error or kernel panic).
```

```bash
# Create a dm-verity root filesystem
# 1. Build read-only ext4 rootfs (no modifications needed)
mkfs.ext4 -O ^has_journal /dev/sda3  # /dev/sda3 = rootfs partition

# 2. Calculate Merkle tree and root hash
veritysetup format /dev/sda3 /dev/sda4  # /dev/sda4 = verity hash partition
# Output:
# VERITY header information for /dev/sda3
# UUID:                   e1b1e1b1-e1b1-e1b1-e1b1-e1b1e1b1e1b1
# Hash type:              1
# Data blocks:            262144
# Data block size:        4096
# Hash block size:        4096
# Hash algorithm:         sha256
# Salt:                   aabbccdd...
# Root hash:              7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069

# 3. Embed root hash in kernel cmdline or FIT image
# kernel cmdline approach:
root=/dev/mapper/vroot ro \
  dm-verity.dev=/dev/mmcblk0p3 \
  dm-verity.hashtree=/dev/mmcblk0p4 \
  dm-verity.roothash=7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069

# 4. Kernel activates dm-verity during mount:
veritysetup open /dev/mmcblk0p3 vroot /dev/mmcblk0p4 \
  7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069
mount /dev/mapper/vroot /mnt/root -o ro
```

---

## Measured Boot

### Definition

Measured Boot **records** the cryptographic hash of each boot component into a Trusted Platform Module (TPM) Platform Configuration Register (PCR) as each component is loaded, but **does not enforce** anything. The system boots regardless of what the measurements show. There is no signature verification, no halting on mismatch.

The value of Measured Boot comes not from preventing boot, but from:
1. **TPM key sealing**: the TPM will only release sealed keys (e.g., disk encryption keys) if the PCR values match the expected state
2. **Remote attestation**: a remote verifier can request a TPM-signed quote of PCR values to prove which software ran

### Why Measured Boot Does Not Prevent Attacks

The common misconception: "if the measurements don't match, the system doesn't boot." This is wrong for Measured Boot alone. Measured Boot only *measures*. It is Secure Boot that *enforces*.

The correct understanding: an attacker who replaces the bootloader with malicious code will cause different PCR measurements to be recorded. The TPM will refuse to unseal a disk encryption key that was sealed to different PCR values. The attacker's malicious bootloader runs, but **cannot access the encrypted disk** because the TPM withholds the key.

This is not the same as preventing the malicious code from executing. It does prevent the malicious code from accessing secrets sealed to the expected PCR state.

### TPM Platform Configuration Registers

PCRs are special TPM registers with a particular property: they cannot be directly set to an arbitrary value. They can only be **extended**:

```
PCR_new = SHA-256(PCR_current || new_measurement)
```

Starting from a fixed initial value (all zeros, or a fixed platform-specific value), each measurement extends the PCR by hashing the current value concatenated with the new measurement. This creates a one-way chain: you cannot reverse-engineer the previous state, and you cannot manipulate one measurement without changing all subsequent PCRs.

The standard PCR allocation for UEFI/firmware Measured Boot (PC platform) is:

| PCR | Contents |
|-----|----------|
| 0 | UEFI Firmware executable code |
| 1 | UEFI Firmware data and configuration |
| 2 | UEFI driver and application code |
| 3 | UEFI driver and application configuration |
| 4 | UEFI Boot Manager code / OS loader |
| 5 | UEFI Boot Manager data / OS loader configuration |
| 6 | Host platform manufacturer specific |
| 7 | Secure Boot policy |
| 8-15 | OS use (kernel, initrd measurements) |
| 16 | Debug use |
| 23 | Application support |

For embedded Linux without UEFI, the PCR allocation is defined by the implementation. A typical U-Boot + Linux implementation:

| PCR | Contents | Who measures |
|-----|----------|--------------|
| 0 | U-Boot binary hash | U-Boot EFI stub or TPM init |
| 1 | U-Boot configuration (env) | U-Boot |
| 7 | Secure Boot policy | U-Boot (if HABv4 status logged) |
| 8 | Linux kernel cmdline | U-Boot bootm |
| 9 | Linux kernel Image binary | U-Boot bootm |
| 10 | Linux initramfs | U-Boot bootm |
| 11-15 | Reserved for IMA | Linux IMA subsystem |

### Measurement Sequence Example

```
t=0ms  Power on
t=50ms ROM starts → measures nothing (ROM has no TPM access at this stage)
       [This is a gap in Measured Boot on i.MX8MP without TPM firmware integration]

t=200ms U-Boot starts → TPM driver initialized (SPI TPM or I2C TPM)
        U-Boot measures itself:
          tpm2_extend 0 <SHA256 of U-Boot binary>
        U-Boot measures configuration:
          tpm2_extend 1 <SHA256 of U-Boot env>
        U-Boot measures boot target:
          tpm2_extend 8 <SHA256 of kernel cmdline>
          tpm2_extend 9 <SHA256 of kernel Image>
          tpm2_extend 10 <SHA256 of initramfs>

t=800ms Linux starts → IMA (Integrity Measurement Architecture) enabled
        IMA measures each file at access:
          PCR[10] extended with each measured file hash
          /etc/shadow, /bin/sshd, /lib/libcrypto.so ...
```

### TPM Key Sealing and Unsealing

The primary use of Measured Boot for embedded security is sealing the LUKS disk encryption key to expected PCR values:

```bash
# At provisioning time (on a trusted system with expected PCR values):
# 1. Generate disk encryption key
openssl rand 32 > luks-key.bin

# 2. Seal key to TPM with expected PCR values
tpm2_createprimary -C o -g sha256 -G ecc -c primary.ctx
tpm2_create -C primary.ctx -g sha256 \
  -i luks-key.bin \
  -u sealed-key.pub \
  -r sealed-key.priv \
  -L "pcr:sha256:0,1,7,8,9,10"  # seal to these PCRs
# Sealed object: only unsealed if PCRs 0,1,7,8,9,10 match sealing values

# At boot time:
# 1. U-Boot measured the components → PCRs extended
# 2. Linux boots with TPM driver loaded
# 3. Initramfs unseals the key:
tpm2_load -C primary.ctx -u sealed-key.pub -r sealed-key.priv -c sealed.ctx
tpm2_unseal -c sealed.ctx -o luks-key-unsealed.bin
# If PCRs don't match expected values → unseal FAILS → LUKS volume stays locked

# 4. Open LUKS volume with unsealed key:
cryptsetup luksOpen /dev/mmcblk0p4 cryptroot --key-file luks-key-unsealed.bin
```

### IMA: Linux Integrity Measurement Architecture

IMA extends Measured Boot into the running system by measuring every file as it is executed or opened. IMA is a Linux kernel subsystem:

```
# Enable IMA in kernel config
CONFIG_IMA=y
CONFIG_IMA_MEASURE_PCR_IDX=10  # Extend PCR[10]
CONFIG_IMA_APPRAISE=y          # Enable enforcement (= Secure Boot property)
CONFIG_IMA_APPRAISE_BOOTPARAM=y

# IMA policy (in initramfs or /etc/ima-policy):
# Measure all executables before execution
measure func=BPRM_CHECK
# Measure all files opened with write access
measure func=FILE_CHECK mask=^MAY_READ
# Measure kernel modules
measure func=MODULE_CHECK

# Kernel cmdline for IMA:
ima_policy=tcb  # "Trusted Computing Base" policy

# View IMA measurement log:
cat /sys/kernel/security/ima/ascii_runtime_measurements
# Output format: PCR-idx SHA256-hash filename
10 sha256:7f83b1... /etc/shadow
10 sha256:a3c72f... /usr/bin/sshd
```

### Remote Attestation with TPM

Remote attestation allows a remote server to verify that a device booted the expected software before granting access to resources (network access, certificates, secrets):

```
Embedded Device                    Remote Attestation Server
      │                                        │
      │ 1. TPM creates Attestation Key (AK)    │
      │ 2. Get TPM nonce from server ─────────►│
      │◄──────────────────────── server nonce ─│
      │ 3. TPM quote: sign PCRs with AK        │
      │    over nonce                           │
      │ 4. Send quote to server ───────────────►│
      │                                        │ 5. Verify AK signature
      │                                        │ 6. Verify PCR values
      │                                        │    match expected reference
      │                                        │ 7. If match: grant access
      │◄─────────────────── access token ──────│
```

---

## Authenticated Boot (NXP Terminology)

NXP documentation uses "Authenticated Boot" as a synonym for what this document calls Secure Boot. The term appears in i.MX8MP Reference Manual sections on HABv4. The meaning is identical: cryptographic authentication of the boot image before execution, with enforcement via the SEC_CONFIG fuse.

NXP's i.MX93 and later processors use AHAB (Advanced High Assurance Boot) with similar semantics but different implementation (ELE — EdgeLock Enclave — replaces the HABv4 ROM engine).

---

## Comparison Table

| Feature | Secure Boot (HABv4) | Verified Boot (FIT+dm-verity) | Measured Boot (TPM+IMA) |
|---------|---------------------|-------------------------------|--------------------------|
| Primary mechanism | RSA sig verify, certificate chain | RSA/ECDSA sig + Merkle tree | SHA-256 hash into PCR |
| Enforcement | YES — halts on failure (closed mode) | YES — halts on failure | NO — records only |
| Boot halted on failure | YES (CLOSED mode) | YES | NO |
| TPM required | NO | NO | YES |
| Covers SPL/TF-A/U-Boot | YES (HABv4 covers all in flash.bin) | NO (FIT starts at kernel) | YES (U-Boot can measure) |
| Covers kernel + DTB | Indirect (FIT layer 2) | YES (FIT image signing) | YES |
| Covers initramfs | Indirect (FIT layer 2) | YES (FIT signature) | YES |
| Covers rootfs blocks | NO | YES (dm-verity per-block) | Via IMA per-file |
| Rootfs must be read-only | NO | YES (dm-verity requires RO) | NO |
| Disk encryption support | NO (separate) | NO (separate) | YES (PCR sealing) |
| Remote attestation | NO | NO | YES |
| Revocation mechanism | SRK slot revocation | Key rotation | PCR policy update |
| NXP i.MX8MP support | HABv4 (ROM-resident) | FIT in U-Boot | fTPM via OP-TEE |
| Key storage | OCOTP fuses (SRK hash) | U-Boot DTB (embedded pubkey) | TPM NV storage |
| Failure recovery | JTAG or alternate boot device | U-Boot rescue mode | No failure; PCR mismatch |

---

## Combining All Three Approaches

Production embedded Linux systems should combine all three layers. Each addresses threats the others do not:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    COMPLETE BOOT SECURITY STACK                         │
│                                                                         │
│  Layer 0: Hardware Root of Trust                                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  OCOTP Fuses (SRK_HASH, SEC_CONFIG)                              │  │
│  │  i.MX8MP Boot ROM (HABv4 engine)                                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                           │                                             │
│  Layer 1: Secure Boot (HABv4)     ← Prevents unsigned bootloader exec  │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  ROM verifies: SPL + TF-A + OP-TEE + U-Boot (all in flash.bin)  │  │
│  │  Algorithm: RSA-2048 + SHA-256, SRK certificate chain            │  │
│  │  Enforcement: SEC_CONFIG fuse = CLOSED                           │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                           │                                             │
│  Layer 2: Verified Boot (FIT + dm-verity) ← Extends trust to rootfs   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  U-Boot verifies FIT image:                                      │  │
│  │    ├── Linux kernel (SHA-256 + RSA-2048 signature)               │  │
│  │    ├── Device tree blob (SHA-256 in FIT)                         │  │
│  │    └── Initramfs (SHA-256 in FIT)                                │  │
│  │  Kernel enforces dm-verity on rootfs:                            │  │
│  │    └── Merkle tree root hash from signed FIT cmdline             │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                           │                                             │
│  Layer 3: Measured Boot (TPM PCRs + IMA) ← Detects runtime changes    │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  U-Boot measures kernel/initramfs → PCR[8,9,10]                  │  │
│  │  TPM seals LUKS key to expected PCR values                       │  │
│  │  IMA measures runtime files → PCR[10]                            │  │
│  │  Remote attestation: server verifies PCR quote                   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                           │                                             │
│  Runtime: Linux with dm-crypt (encrypted rootfs)                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  TPM unseals LUKS key if PCRs match (Measured Boot dependency)   │  │
│  │  dm-verity protects read-only rootfs (Verified Boot dependency)  │  │
│  │  Writable data partition: dm-crypt encrypted                     │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why Each Layer Is Necessary

**Secure Boot alone (without Verified Boot):** The kernel is authenticated, but the root filesystem can be modified at runtime or between boots. A kernel that runs correctly but mounts a tampered rootfs provides no security for the application.

**Verified Boot alone (without Secure Boot):** If the bootloader is unsigned, an attacker replaces the bootloader with one that presents a fake "verification passed" result to the kernel. The entire verification chain is compromised.

**Measured Boot alone:** No code is prevented from running. An attacker can replace all boot components, which causes TPM PCR values to change. The LUKS disk key is not released (attacker cannot read encrypted data), but the malicious code still runs and the device is compromised.

**All three combined:** An attacker must simultaneously (a) possess the SRK private key to sign malicious firmware, (b) possess the PCR-sealing policy or break TPM sealing to access encrypted data, and (c) produce dm-verity-valid rootfs without the signing key. This combination is not achievable by typical threat actors.

---

## Platform Support Matrix

| Platform | Secure Boot | Verified Boot (FIT) | Verified Boot (dm-verity) | Measured Boot |
|---------|-------------|---------------------|---------------------------|---------------|
| i.MX8MP | HABv4 (ROM) | U-Boot FIT signing | dm-verity (kernel driver) | fTPM via OP-TEE TrustZone |
| i.MX93 | AHAB (ELE) | U-Boot FIT signing | dm-verity | fTPM via ELE |
| i.MX6ULL | HABv4 | U-Boot FIT signing | dm-verity (limited RAM) | Software TPM only |
| i.MX8QM | HABv4 | U-Boot FIT signing | dm-verity | fTPM via SECO |
| Raspberry Pi 4 | HAT OTP-based | Partial (Pi-specific) | dm-verity | External TPM2.0 |
| Ubuntu Core 22 | UEFI Secure Boot | Snap assertions | squashfs + dm-verity | TPM2 (UEFI) |
| PHYTEC phyCORE-i.MX8MP | HABv4 | FIT (with meta-phytec) | dm-verity (production) | OP-TEE fTPM |

### i.MX8MP fTPM Note

i.MX8MP does not have a discrete TPM chip. Instead, OP-TEE (Open Portable Trusted Execution Environment) running in ARM TrustZone implements a firmware TPM (fTPM) conforming to TPM 2.0 specification. The fTPM presents a standard TPM2.0 interface to Linux via the `tpm_ftpm_tee` kernel driver, allowing standard TPM userspace tools (`tpm2-tools`) to work without modification.

The fTPM's state (PCR values, NV storage, sealed objects) is stored in OP-TEE secure storage, which is backed by CAAM hardware key encryption and RPMB (Replay Protected Memory Block) on the eMMC for tamper resistance.

---

## Security Warning

> **WARNING:** In HABv4 OPEN mode, Secure Boot does not enforce. The system logs HAB events but boots unsigned images. This is **not** a secure production configuration. Enforcement requires burning the `SEC_CONFIG[1]` fuse to set CLOSED mode.
>
> **WARNING:** Burning `SEC_CONFIG[1]` to CLOSED mode with an incorrect or mismatched SRK_HASH in fuses will permanently brick the device. The Boot ROM will reject all images, including recovery images, and the device cannot be recovered via software. Always validate signing in OPEN mode with `hab_status` showing no HAB failures before transitioning to CLOSED mode.
>
> **WARNING:** dm-verity requires the root filesystem to be read-only. A dm-verity-protected filesystem cannot be updated in place. Any rootfs update requires providing a new signed Merkle tree root hash through the boot configuration. Plan the update workflow before enabling dm-verity in production.

---

## Common Misconceptions

**"Secure Boot prevents all boot-time attacks."**
False. Secure Boot prevents unauthorized code from running at boot time on a correctly configured (CLOSED mode) system. It does not prevent attacks against signed code (bugs in the bootloader), attacks through compromised signing keys, or post-boot attacks.

**"Measured Boot = Secure Boot."**
False. Measured Boot records what happened; Secure Boot enforces what is allowed. A system with Measured Boot but without Secure Boot will boot any code, recording its measurement. A system with only Secure Boot but without Measured Boot cannot support TPM-sealed disk encryption or remote attestation.

**"If we have Verified Boot we don't need Secure Boot."**
False. Verified Boot (FIT + dm-verity) must be anchored to something. If the bootloader (U-Boot) that performs FIT verification is not itself authenticated by Secure Boot (HABv4), an attacker replaces U-Boot with a version that skips FIT verification.

**"Verified Boot means the firmware is correct."**
False. It means the firmware has not been modified since it was signed. A signed firmware with bugs is still verified. Verification establishes provenance, not correctness.

**"Measured Boot provides strong security even without Secure Boot."**
Partially true. Measured Boot prevents access to TPM-sealed secrets if the boot chain changes. But it does not prevent arbitrary code from running. The attacker's malicious bootloader runs; it simply cannot access the sealed disk key.

---

## Decision Guide: Which to Implement

For i.MX8MP embedded Linux in production:

| Requirement | Required Mechanism |
|-------------|-------------------|
| Prevent unsigned bootloader execution | Secure Boot (HABv4 CLOSED) |
| Prevent tampered kernel at boot | Verified Boot (FIT signing) |
| Prevent runtime rootfs modification | Verified Boot (dm-verity) |
| Protect data at rest (encrypted storage) | Measured Boot (TPM PCR sealing) + dm-crypt |
| Detect if boot components changed | Measured Boot (PCR values) |
| Prove to remote server what ran | Measured Boot (remote attestation) |
| Runtime file integrity enforcement | IMA Appraisal (extends Measured Boot) |

All of these should be implemented for a production IoT/industrial embedded Linux system with meaningful security requirements. Implementing only one layer because it is "Secure Boot" provides partial security that may satisfy auditors while leaving material vulnerabilities.

---

## Further Reading

- NXP AN4581: Secure Boot on i.MX50, i.MX53, i.MX6 and i.MX7 Series using HABv4
  https://www.nxp.com/docs/en/application-note/AN4581.pdf
- Android Verified Boot 2.0: https://android.googlesource.com/platform/external/avb/+/refs/heads/master/README.md
- Linux dm-verity documentation: https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/verity.html
- TCG TPM 2.0 Library Specification: https://trustedcomputinggroup.org/resource/tpm-library-specification/
- Linux IMA (Integrity Measurement Architecture): https://sourceforge.net/p/linux-ima/wiki/Home/
- OP-TEE fTPM: https://optee.readthedocs.io/en/latest/extensions/tpm2.html
- NIST SP 800-155: BIOS Integrity Measurement Guidelines
  https://csrc.nist.gov/publications/detail/sp/800-155/draft/2011-12-01
