# Chapter 01: Security Foundations

## Learning Objectives

After completing this chapter, you will be able to:

1. Articulate the threat model that motivates Secure Boot on embedded Linux systems
2. Identify the attack surfaces in an embedded Linux boot chain
3. Explain trust boundaries, trust anchors, and the hardware Root of Trust
4. Distinguish between Secure Boot, Verified Boot, and Measured Boot
5. Evaluate real-world attack scenarios against a Secure Boot implementation
6. Identify what Secure Boot does NOT protect against
7. Describe the security/functionality tradeoffs specific to embedded systems

---

## Overview

Security engineers designing protection mechanisms frequently make a foundational error: they design for the attacks they can imagine rather than the attacks an adversary will actually attempt. Secure Boot is often implemented as a compliance checkbox—the goal is to "have Secure Boot" rather than to defeat a specific, analyzed threat.

This chapter establishes the intellectual foundation for avoiding that mistake. We begin with the threat model: who attacks embedded systems, what they want, and what capabilities they have. We then map those threats to attack surfaces and introduce the mechanisms—cryptographic verification, hardware root of trust, chain of trust—that mitigate them.

Every mechanism described in later chapters is only meaningful in the context of this threat model. An engineer who understands HABv4 configuration syntax but does not understand the threat model it defeats will configure it incorrectly. This chapter is not optional background reading. It is the map without which all subsequent navigation is guesswork.

---

## The Fundamental Problem: Untrusted Execution

A general-purpose computer executes code. The security question is always: *whose* code?

On a server, this question is managed through access controls, cryptographic authentication, and audit logs. The assumption is that the operating system and its security mechanisms are already running when the question matters.

On an embedded system, the problem is recursive: the operating system that enforces access controls is itself a piece of code that must be loaded and executed. Before the OS runs, there is no access control. Before the bootloader runs, there is nothing except the processor's reset vector and what the silicon vendor has burned into ROM.

This creates the fundamental problem: **at power-on, the system is at its most vulnerable**. Any code loaded at boot time runs before any security mechanism is active. An attacker who can substitute their code for the legitimate bootloader at boot time owns the system permanently—not just until reboot, but especially including all subsequent reboots.

Secure Boot is the mechanism that prevents this substitution. It ensures that only cryptographically authenticated code executes at each stage of the boot process. But this statement contains several implicit assumptions that are worth making explicit:

1. There is a piece of code whose authenticity is *assumed*, not verified (the Root of Trust)
2. The cryptographic keys used for verification must be protected from substitution
3. The verification must happen *before* the code executes, not after
4. Every stage of the boot process must be authenticated, not just the first

Failure of any of these conditions breaks the security property. The rest of this repository is about making these conditions concrete and implementing them correctly.

---

## CIA Triad in the Embedded Boot Context

The classical security objectives—Confidentiality, Integrity, and Availability—manifest differently in an embedded boot context than in server security.

**Integrity** is the primary concern of Secure Boot. The goal is to ensure that the code executing is the code the vendor signed. Integrity failures are irreversible at the device level: an attacker who compromises the boot process can maintain persistent access regardless of OS-level security measures.

**Confidentiality** is relevant for key material. The private keys used to sign bootloaders must be kept confidential, or an attacker can sign their own malicious bootloaders. Additionally, confidential data (encryption keys for dm-crypt volumes, device-specific secrets) must be protected during the boot process.

**Availability** is a unique concern in embedded systems because devices often operate without human oversight. A Secure Boot misconfiguration can permanently brick a device (refusing to boot any image, including a recovery image). The tradeoff between security and availability is real: closing HABv4 without validated keys bricks the device. This is not theoretical. It happens in production.

---

## Attack Surfaces in the Embedded Boot Chain

The boot chain of an i.MX8MP system has multiple attack surfaces, each exploitable by different threat actors with different capabilities.

```
                    ATTACK SURFACES IN i.MX8MP BOOT CHAIN
                    ════════════════════════════════════

  ┌────────────────────────────────────────────────────────────────────┐
  │                        i.MX8MP SoC                                 │
  │                                                                    │
  │  ┌──────────────┐    Attack Surface:                              │
  │  │  Boot ROM     │◄── [A1] ROM vulnerability (extremely rare,    │
  │  │  (Immutable)  │         hardware mask revision required)       │
  │  └──────┬───────┘                                                 │
  │         │ Loads from boot device                                  │
  └─────────┼──────────────────────────────────────────────────────────┘
            │
            ▼
  ┌─────────────────────────────────┐
  │      Boot Media (eMMC/SD)       │◄── [A2] Physical: replace SD card
  │                                  │◄── [A3] Physical: write to eMMC
  │  ┌──────────────────────────┐   │        (via JTAG or USB download)
  │  │  SPL + TF-A + OP-TEE     │   │◄── [A4] Software: bootloader exploit
  │  │  + U-Boot image          │   │◄── [A5] Supply chain: compromised build
  │  └──────────────────────────┘   │
  └─────────────────────────────────┘
            │
            ▼
  ┌─────────────────────────────────┐
  │      DRAM                        │◄── [A6] Cold boot attack (DRAM contents)
  │  (Initialized by SPL)            │◄── [A7] DMA attack (bus master to DRAM)
  └─────────────────────────────────┘
            │
            ▼
  ┌─────────────────────────────────┐
  │      Kernel + Root FS           │◄── [A8] Unsigned kernel module
  │  (Loaded by U-Boot)             │◄── [A9] Root filesystem tampering
  │                                  │◄── [A10] initramfs tampering
  └─────────────────────────────────┘
            │
            ▼
  ┌─────────────────────────────────┐
  │      Userspace                  │◄── [A11] Process injection
  │                                  │◄── [A12] Library hijacking
  │                                  │◄── [A13] Privilege escalation
  └─────────────────────────────────┘

  Debug Interfaces:
  ┌──────────────────────────────────────────────────────────────────┐
  │ JTAG ────────────────────────────────────► [A14] JTAG debug      │
  │ UART ────────────────────────────────────► [A15] U-Boot console  │
  │ USB Download Mode ───────────────────────► [A16] Direct flash    │
  └──────────────────────────────────────────────────────────────────┘
```

Secure Boot directly addresses **A2, A3, A5, A8, A9, A10** (code integrity). It partially addresses **A4** (exploiting a valid but vulnerable bootloader remains possible). It does NOT address **A6, A7, A11, A12, A13** (post-boot attacks) or **A1** (ROM vulnerabilities—out of scope for software security).

**A14, A15, A16** are addressed by hardware configuration (JTAG disable via fuses, secure debug, disabling USB serial download mode) documented in Chapter 17.

---

## Trust Boundaries and Trust Anchors

### Trust Boundaries

A trust boundary is a line in the system architecture across which data or code passes from a less-trusted context to a more-trusted one. At each trust boundary crossing, the system must authenticate the incoming entity. Failing to authenticate at a trust boundary breaks the security model.

In the i.MX8MP boot chain, trust boundaries exist at:

1. **Boot ROM ↔ Boot Media**: ROM trusts code on boot media only if authenticated
2. **SPL ↔ TF-A+OP-TEE**: SPL trusts subsequent stages only if authenticated
3. **U-Boot ↔ Kernel**: U-Boot trusts kernel only if FIT signature is verified
4. **Kernel ↔ Root Filesystem**: Kernel trusts rootfs only if dm-verity is active
5. **Normal World ↔ Secure World**: TrustZone enforces hardware boundary

### Trust Anchors

A trust anchor is the entity at the top of the trust chain whose trust is *assumed*, not derived from another authority. In computer security, trust anchors are dangerous because their compromise propagates down the entire trust hierarchy.

In the i.MX8MP Secure Boot system, the trust anchors are:

1. **Boot ROM code** (burned into silicon at manufacture; not field-modifiable)
2. **OTP fuse values** (burned at device provisioning; irreversible)
   - Specifically: the **SRK_HASH** fuses (the SHA-256 hash of the SRK table)

The relationship between these trust anchors:

```
Silicon Vendor (NXP)
       │ Manufactures and programs
       ▼
┌──────────────────┐
│  Boot ROM        │ ← Trust Anchor 1: Assumed trusted (NXP's code)
│  (immutable)     │   No mechanism to verify ROM itself.
└──────┬───────────┘
       │ ROM verifies SRK_HASH against fuses
       ▼
┌──────────────────┐
│  OTP Fuses       │ ← Trust Anchor 2: Assumed trusted (set at provisioning)
│  SRK_HASH[0:7]  │   Trust depends on key ceremony and provisioning security.
└──────┬───────────┘
       │ Fuses bind to SRK public key table
       ▼
┌──────────────────┐
│  SRK Public Keys │ ← Trust derived from fuses
│  (in boot image) │
└──────┬───────────┘
       │ SRK signs image
       ▼
┌──────────────────┐
│  Boot Images     │ ← Trust derived from SRK
└──────────────────┘
```

**The critical insight:** The entire security of the Secure Boot system rests on two assumptions:
1. NXP's Boot ROM code is correct (no exploitable vulnerabilities)
2. The SRK_HASH was burned correctly from a genuine SRK key generated in a secure ceremony

Both assumptions have had real-world failures. ARM TrustZone bypasses have been found in Boot ROM code of various SoCs. Key ceremonies have been conducted insecurely, with resulting key compromise. Neither is a reason not to implement Secure Boot—they are reasons to implement it correctly and honestly.

---

## Hardware Root of Trust: The Anchor Concept

```
  HARDWARE ROOT OF TRUST - CONCEPTUAL DIAGRAM
  ════════════════════════════════════════════

  ┌─────────────────────────────────────────────────────────────┐
  │                    i.MX8MP Silicon                          │
  │                                                             │
  │  ┌────────────────────────────────────────────────────┐    │
  │  │           Boot ROM (Mask ROM)                       │    │
  │  │                                                     │    │
  │  │  • Immutable: cannot be modified after tape-out    │    │
  │  │  • First code to execute after power-on reset      │    │
  │  │  • Contains HABv4 authentication engine (RVT)      │    │
  │  │  • Reads SRK_HASH from OCOTP fuses                 │    │
  │  │  • Verifies boot image before executing it         │    │
  │  └────────────────────────────────────────────────────┘    │
  │                          │                                  │
  │                          │ reads                            │
  │                          ▼                                  │
  │  ┌────────────────────────────────────────────────────┐    │
  │  │           OCOTP (One-Time Programmable)             │    │
  │  │                                                     │    │
  │  │  • Physical fuses: electrically blown, read-only   │    │
  │  │  • SRK_HASH[0:7]: 256-bit hash of SRK table        │    │
  │  │  • SEC_CONFIG[1]: open/closed HAB mode             │    │
  │  │  • Cannot be changed after programming             │    │
  │  └────────────────────────────────────────────────────┘    │
  │                                                             │
  │  CRITICAL: Both ROM and fuses are on-die silicon.           │
  │  An attacker cannot modify them without destroying          │
  │  the chip. This is the "hardware" in Hardware RoT.          │
  └─────────────────────────────────────────────────────────────┘
```

### Immutable vs. Mutable Trust

**Immutable trust** is trust that cannot be revoked or modified after the fact. In i.MX8MP:
- Boot ROM code: immutable (silicon mask)
- OTP fuse values: immutable once burned

**Mutable trust** is trust that can be modified (either legitimately for updates, or maliciously by attackers). In i.MX8MP:
- Boot images on eMMC/SD: mutable (can be written by any process with storage access)
- Certificate chains: mutable (can be replaced)
- Kernel and filesystem: mutable (without dm-verity)

The key principle: **mutable trust must always be verified against immutable trust**. HABv4 implements this by verifying boot images (mutable) against the SRK_HASH (immutable, in fuses). If the fuse-burned hash matches the SRK table in the image, and the image is signed with the corresponding SRK private key, the immutable trust anchor has verified the mutable boot image.

---

## Threat Actors and Their Capabilities

Understanding Secure Boot requires understanding who you are defending against. Different threat actors have different capabilities, motivations, and attack vectors.

### Threat Actor 1: Physical Attacker (Non-Nation-State)

**Motivation:** Device theft, reverse engineering a competitor's product, extracting proprietary algorithms or keys, counterfeiting.

**Capabilities:**
- Physical access to the device
- Standard laboratory equipment (oscilloscopes, logic analyzers)
- Tools to open enclosures, desolder chips
- Basic JTAG debug equipment
- SD card reader, USB interfaces
- Budget: thousands to tens of thousands of dollars

**Attack scenarios:**
- Remove SD card, write malicious bootloader, reinstall
- Connect JTAG debugger to debug port
- Connect UART to observe boot output and access U-Boot console
- Read eMMC contents using bus interception
- Boot into USB serial download mode and flash arbitrary firmware

**What Secure Boot provides:** Prevents replacement of SD/eMMC boot images with unsigned images. Prevents U-Boot console exploitation (if console is disabled in production). Prevents USB download mode (via JTAG/USB disable fuses).

**What Secure Boot does NOT provide:** Protection against decapping and probing at the silicon level. Protection against side-channel attacks (power analysis, EM analysis) used to extract keys from CAAM.

### Threat Actor 2: Remote Software Attacker

**Motivation:** Botnet recruitment, ransomware, espionage, lateral movement within industrial/IoT networks.

**Capabilities:**
- Remote code execution via application vulnerabilities
- Kernel exploits
- No physical access
- May have root access on a compromised device

**Attack scenarios:**
- Exploit application vulnerability → root shell → write malicious kernel module
- Exploit kernel vulnerability → disable security features in running kernel
- OTA update mechanism compromise → deliver unsigned firmware update
- Compromise build pipeline → sign malicious firmware with legitimate keys

**What Secure Boot provides:** Kernel module signing prevents loading unsigned kernel modules (if enabled). dm-verity prevents persistent modification of the root filesystem (modifications survive only until reboot).

**What Secure Boot does NOT provide:** Protection against in-memory exploitation. A root-privileged attacker on a running system has full access to the Normal World—Secure Boot has already done its job (or failed). The attacker is defeated only on the *next* reboot.

### Threat Actor 3: Supply Chain Attacker

**Motivation:** Mass compromise, state-level intelligence collection, infrastructure disruption.

**Capabilities:**
- Access to the software supply chain (Yocto layers, upstream U-Boot, Linux kernel)
- May have insider access to build infrastructure
- Nation-state resources: very sophisticated, patient, well-funded

**Attack scenarios:**
- Malicious commit to upstream Yocto layer that adds backdoor to bootloader
- Compromise of CI/CD signing system → sign malicious image with legitimate keys
- Malicious compiler that inserts backdoor into compiled binary
- Compromise of NXP's CST tool to generate "valid" signatures for malicious images
- Counterfeit hardware with modified Boot ROM

**What Secure Boot provides:** Signed images prevent delivery of unsigned firmware, even if the build pipeline is compromised (the signing step requires the private key). SBOM (Software Bill of Materials) enables detection of unauthorized components.

**What Secure Boot does NOT provide:** Protection against compromise of the signing infrastructure. If the signing key is compromised, signed malicious images are indistinguishable from legitimate ones.

> **⚠️ WARNING:** Secure Boot's chain of trust is only as strong as the key ceremony and the signing infrastructure. An attacker who compromises the build pipeline AND the signing key can produce signed malicious firmware. Key security is not a solved problem—it is an ongoing operational requirement.

### Threat Actor 4: Insider Threat

**Motivation:** Financial (selling device secrets), ideology, coercion, negligence.

**Capabilities:**
- Legitimate access to development and production systems
- May have access to signing keys
- Knows the system architecture

**Attack scenarios:**
- Engineer with key access signs malicious firmware during "approved" firmware update
- Disgruntled employee leaks SRK private keys
- Negligent engineer commits test keys to public repository
- Deliberate introduction of vulnerability in firmware before signing

**What Secure Boot provides:** Key ceremony requirements (multi-person control) reduce single-person compromise risk. Key storage in HSM limits access to key material.

**What Secure Boot does NOT provide:** Protection against a colluding group with all required ceremony roles. Complete audit of signed firmware content (an insider can sign malicious firmware with the legitimate keys).

---

## Real Attack Examples

### BadUSB and Boot Media Substitution

The BadUSB attack class demonstrates that USB storage devices can be reprogrammed to execute arbitrary code. In the i.MX8MP context, an attacker with physical access to a device booting from SD card can:

1. Remove the SD card
2. Write a malicious bootloader at the expected offset
3. Reinstall the SD card
4. On next power-on, the malicious bootloader executes with full hardware access

**Without Secure Boot:** This attack succeeds trivially.
**With Secure Boot (HABv4 closed):** The Boot ROM rejects the unsigned bootloader. Boot fails.
**With Secure Boot (HABv4 open):** The Boot ROM checks but does not enforce. The malicious bootloader executes. The "open" vs "closed" distinction is critical.

### Evil Maid Attack

The "evil maid" attack is a generic term for physical access attacks during an unattended device opportunity. In industrial/IoT contexts, devices are often in physically unsecured locations (factory floors, utility boxes, remote installations).

An attacker who has 30 minutes of physical access to a device can:
- Clone the eMMC contents
- Analyze the boot images offline
- Create a modified bootloader that bypasses application security
- Return to the device and flash the modified image

**Mitigation:** HABv4 closed mode + eMMC repartitioning restrictions. The cloned image analysis is still possible (full disk encryption via dm-crypt + OP-TEE-sealed keys addresses this).

### SolarWinds-Class Supply Chain

The SolarWinds attack (2020) compromised a software build pipeline to insert malicious code into a legitimate signed software product. The code was signed with the vendor's legitimate signing key and passed all verification checks.

The embedded equivalent: compromise of the Yocto build pipeline to insert a backdoor into the bootloader or kernel, which is then signed with the legitimate SRK key in the normal signing workflow.

**Partial mitigation:** Reproducible builds, SBOM, code review requirements for signing approval. Full mitigation requires comprehensive build pipeline security—beyond the scope of HABv4 itself.

### Firmware Backdoors in Supply Chain

Multiple security research publications (e.g., Bloomberg's coverage of supply chain implants, academic work on hardware backdoors) document cases of hardware with firmware-level backdoors installed at the manufacturer level.

For NXP i.MX8MP, the Boot ROM is programmed by NXP. Its integrity depends entirely on trust in NXP as a silicon vendor. This is an accepted industry assumption, not a solvable problem at the device manufacturer level.

---

## Common Misconceptions About Secure Boot

### Misconception 1: "Secure Boot makes the device secure"

**Reality:** Secure Boot makes the boot process resistant to specific code substitution attacks. A device with Secure Boot can still be fully compromised by software vulnerabilities in the signed code. Heartbleed, Log4Shell, and equivalent vulnerabilities affect signed software.

### Misconception 2: "Once HABv4 is configured, the device is locked down"

**Reality:** HABv4 in open mode does not prevent execution of unsigned code. Closing HABv4 (burning SEC_CONFIG[1]) is required for enforcement. Many implementations run in open mode in production due to fear of bricking devices.

### Misconception 3: "Secure Boot prevents malware"

**Reality:** Secure Boot prevents persistent malware that requires modification of the boot chain to survive reboot. Memory-resident malware, exploitation of running processes, and malware in the application layer are all unaffected by Secure Boot.

### Misconception 4: "The SRK private key only needs to be secure at signing time"

**Reality:** The SRK private key must be kept secure for the **entire lifetime of all devices signed with it**. A key compromised five years after devices are deployed enables retroactive compromise of all firmware update channels.

### Misconception 5: "Secure Boot and encryption mean the device data is protected"

**Reality:** dm-crypt/LUKS encryption protects data at rest (when the device is powered off). A running system with a compromised kernel has access to all decrypted data. Secure Boot ensures the kernel that does the decrypting is authentic; it does not protect against exploitation of that kernel post-decryption.

---

## What Secure Boot Does NOT Protect Against

This list is as important as the list of what Secure Boot does protect against:

| Not Protected | Explanation |
|--------------|-------------|
| Post-boot software exploits | Signed code can be vulnerable. Secure Boot ends at handoff to OS. |
| Malicious but signed code | If the signing key is compromised, malicious images can be signed. |
| Side-channel attacks | Power analysis, EM analysis can extract keys from CAAM hardware. |
| Decapping and probing | Nation-state level attackers can read OTP fuses off the die. |
| Cold boot attacks on DRAM | DRAM contents can be preserved and read after power removal. |
| DMA attacks | Bus mastering DMA from compromised peripheral can access DRAM. |
| Vulnerabilities in signed bootloader | HABv4 authenticates; it does not audit code quality. |
| Operational failures | Lost keys, bad provisioning, human error in fuse programming. |
| ROM code vulnerabilities | Boot ROM exploits bypass the entire Secure Boot mechanism. |
| Insider threat with key access | An authorized signer can sign malicious firmware. |

---

## Security vs. Functionality Tradeoffs

Every security mechanism has a cost. In embedded systems, the tradeoffs are harsher than in server environments because:

1. **No recovery path:** A bricked embedded device often cannot be recovered remotely. Physical access to a JTAG programmer may be the only option, and in deployed devices, this may be impractical.

2. **Long device lifetimes:** Consumer devices are replaced every 2-3 years. Industrial and IoT devices may operate for 10-20 years. Cryptographic choices made today must remain secure for the device's lifetime.

3. **Key rotation is hard:** On a server, you can rotate a TLS certificate with an HTTP POST request. On an embedded device, key rotation may require a signed OTA update that the device must receive, validate, and install without failure.

4. **No human in the loop:** A server administrator can respond to a security alert. An embedded device in the field has no such option.

The tradeoffs for i.MX8MP Secure Boot:

| Decision | Security Benefit | Operational Cost |
|----------|-----------------|------------------|
| Close HABv4 (burn SEC_CONFIG) | Unsigned images rejected | Recovery requires signed image; bricking risk |
| 4096-bit RSA vs 2048-bit | Stronger against future attacks | ~2x signing time; larger CSF block |
| Disable JTAG via fuses | Debug access removed | No debug access ever, including for crash analysis |
| Disable U-Boot console | Attack surface removed | No interactive debug; use persistent env or automation |
| eMMC over SD | SD card can't be swapped | Less flexible in field; requires eMMC programmer for reflash |

There is no universal correct answer. The right configuration depends on the threat model, the device deployment environment, and the operational requirements.

---

## Summary

- Secure Boot solves the specific problem of unauthorized code execution at boot time via cryptographic verification
- The threat model includes physical attackers, remote attackers, supply chain attackers, and insiders
- The hardware Root of Trust (Boot ROM + OTP fuses) is the foundation; its security assumptions must be explicitly accepted
- Trust boundaries and trust anchors define the architecture; each boundary must be verified
- HABv4 in open mode is security theater; closed mode is required for enforcement
- Secure Boot does not protect against post-boot exploits, signed malicious code, or operational failures
- The key ceremony and signing infrastructure security are as important as the HABv4 configuration itself

---

## Further Reading

- NXP Application Note AN4581: "Secure Boot on i.MX Using HABv4"
  https://www.nxp.com/docs/en/application-note/AN4581.pdf

- ARM Security Technology: Building a Secure System using TrustZone Technology
  https://developer.arm.com/documentation/prd29-genc-009492/

- NIST SP 800-193: Platform Firmware Resiliency Guidelines
  https://doi.org/10.6028/NIST.SP.800-193

- "Understanding the Linux Boot Process" (IBM Developer)
  https://developer.ibm.com/articles/l-linuxboot/

- Trusted Computing Group: TPM Main Specification
  https://trustedcomputinggroup.org/resource/tpm-library-specification/
