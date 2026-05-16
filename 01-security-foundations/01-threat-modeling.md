# 01-threat-modeling: Threat Modeling for Embedded Linux Boot Security

## Version Matrix

| Tool/Reference | Version | Status |
|----------------|---------|--------|
| NXP i.MX8MP Reference Manual | Rev 3, 11/2021 | Current |
| STRIDE methodology | Microsoft SDL | Current |
| PHYTEC phyCORE-i.MX8MP | PCB rev 1452.1 | Tested |

---

## Overview

Threat modeling is the structured process of identifying what you're protecting, who might attack it, how they might do so, and what you can do about it. In the context of embedded boot security, threat modeling answers a question that must be answered before any technical decisions are made: *what attack scenarios are we actually trying to prevent?*

Without this analysis, Secure Boot implementations default to cargo cult security—configuration that looks correct and passes audits but does not actually defeat the relevant threats.

This document applies the STRIDE threat model framework to the i.MX8MP boot process, produces an attack tree, identifies assets, and concludes with a risk matrix and platform-specific considerations.

---

## STRIDE Applied to Embedded Boot

STRIDE (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege) is a threat categorization framework. Applied to the i.MX8MP boot process:

### S: Spoofing Identity

In boot security, spoofing means presenting a malicious component as a legitimate one. The boot chain must verify that each component is what it claims to be.

**Boot-time spoofing threats:**
- S1: Attacker replaces SPL with a malicious binary that spoofs the legitimate SPL
- S2: Malicious TF-A image signed by a compromised key appears legitimate
- S3: Malicious kernel module claims to be a legitimate vendor module
- S4: OTA update server impersonated; malicious firmware served as legitimate update

**Mitigations:** HABv4 (S1, S2), FIT image signing (S4), kernel module signing (S3), TLS mutual authentication for OTA (S4)

### T: Tampering with Data

Tampering means modification of stored code or data. In boot security, this covers modification of any boot component.

**Boot-time tampering threats:**
- T1: Modification of U-Boot binary on eMMC boot partition
- T2: Modification of kernel image or initramfs
- T3: Modification of root filesystem
- T4: Modification of device tree to reroute hardware access
- T5: Modification of U-Boot environment variables to change boot behavior

**Mitigations:** HABv4 (T1), FIT signing with kernel+DTB (T2, T4), dm-verity (T3), U-Boot environment protection (T5)

### R: Repudiation

Repudiation means the ability to deny performing an action. In firmware security, this relates to audit trails for firmware signing and device provisioning.

**Boot-time repudiation threats:**
- R1: Engineer signs malicious firmware and claims the build pipeline was compromised
- R2: Manufacturing station flashes wrong keys and audit log is absent

**Mitigations:** Signing audit logs, HSM-enforced signing with logging, manufacturing audit trail (Chapter 23)

### I: Information Disclosure

Disclosure means unauthorized access to sensitive information. In boot security, the primary assets are key material and device-unique secrets.

**Boot-time information disclosure threats:**
- I1: Cold boot attack extracts DRAM contents including keys
- I2: JTAG attachment reads OCRAM or DRAM during boot
- I3: UART console reveals sensitive boot-time information
- I4: Side-channel attack on CAAM extracts private key
- I5: Unencrypted eMMC reveals file system layout and application binaries

**Mitigations:** dm-crypt + OP-TEE key sealing (I1, I5), JTAG disable via fuses (I2), minimal UART output in production (I3), CAAM physical security (I4)

### D: Denial of Service

In embedded systems, DoS means preventing the device from functioning. A Secure Boot misconfiguration is itself a denial of service against the legitimate device operation.

**Boot-time DoS threats:**
- D1: Attacker introduces subtle corruption in OTA update, causing boot loop
- D2: Attacker with physical access burns incorrect fuses, permanently bricking device
- D3: Attacker replaces boot image with garbage, causing immediate boot failure
- D4: Side-channel attack corrupts SNVS persistent state, causing HAB failure

**Mitigations:** A/B boot partition with rollback (D1), multi-person fuse burning review (D2), HABv4 detection without bricking in open mode then enforce after validation (D3), SNVS integrity monitoring (D4)

### E: Elevation of Privilege

Elevation means gaining capabilities beyond what is authorized. In boot security, this means code running at a higher privilege level than intended.

**Boot-time elevation threats:**
- E1: Exploit in U-Boot achieves EL3 code execution (if U-Boot is launched before BL31 setup)
- E2: Exploit in kernel achieves EL3 access via SMC injection
- E3: OP-TEE vulnerability allows Normal World to access Secure World memory
- E4: DMA-capable peripheral gains access to Secure DRAM regions

**Mitigations:** TF-A SMC filter (E2), OP-TEE hardening (E3), TZASC configuration (E4), minimal attack surface in BL33 (E1)

---

## Attack Tree: Boot Compromise

An attack tree shows alternative paths an attacker can take to achieve an objective. The root is the attacker's goal; leaves are primitive attacks that can be combined.

```
GOAL: Execute Arbitrary Code with Persistent Boot Access
══════════════════════════════════════════════════════════
            │
   ┌────────┴────────────────────────────────────┐
   ▼                                             ▼
[1] Bypass Cryptographic              [2] Compromise Signing
    Verification                          Infrastructure
   │                                             │
   ├── [1.1] Exploit Boot ROM                   ├── [2.1] Steal SRK Private Key
   │   vulnerability                            │   ├── [2.1.1] Physical HSM theft
   │   (Very low prob, requires                 │   ├── [2.1.2] Insider access
   │   zero-day in NXP ROM)                     │   ├── [2.1.3] Build server compromise
   │                                            │   └── [2.1.4] Key in SCM (accident)
   ├── [1.2] Attack fuse values                 │
   │   └── [1.2.1] Physical: decap +            ├── [2.2] Compromise Signing Workflow
   │       laser fuse modification              │   ├── [2.2.1] Malicious CST binary
   │       (Nation-state capability)            │   ├── [2.2.2] Build pipeline injection
   │                                            │   └── [2.2.3] Malicious Yocto layer
   ├── [1.3] Exploit HABv4 in open mode         │
   │   └── [1.3.1] If SEC_CONFIG not set,       └── [2.3] Impersonate CA
   │       unsigned code executes                   └── [2.3.1] Create rogue SRK table
   │                                                    with self-signed key
   └── [1.4] Bypass via debug interface                 (Only works if fuse comparison
       ├── [1.4.1] JTAG: load code              is not done, or if attacker can
       │   directly into OCRAM                  reprogram fuses - see 1.2)
       └── [1.4.2] USB Serial Download
           └── [1.4.2.1] If USB DL mode
               not disabled via fuse

[3] Post-Boot Persistence (After Auth Chain Completes)
      │
      ├── [3.1] Exploit kernel vulnerability → install rootkit
      │   ├── Blocked by: kernel lockdown, dm-verity (removes persistence)
      │   └── Not blocked by: HABv4 (boot already complete)
      │
      └── [3.2] Exploit userspace → pivot to kernel
          └── Blocked by: seccomp, AppArmor, capability restrictions
```

---

## Trust Boundary Diagram

```
  TRUST BOUNDARY DIAGRAM - i.MX8MP BOOT SECURITY
  ═════════════════════════════════════════════════

  ┌──────────────────────────────────────────────────────────────┐
  │                    SILICON TRUST BOUNDARY                    │
  │         (Physical boundary: silicon die)                     │
  │                                                              │
  │  ┌──────────────────────┐  ┌────────────────────────────┐  │
  │  │  Boot ROM (RO)       │  │  OCOTP Fuses (Immutable)   │  │
  │  │  HABv4 RVT Tables    │  │  SRK_HASH[0:7]             │  │
  │  │  Cryptographic verify│  │  SEC_CONFIG, JTAG flags     │  │
  │  └──────────┬───────────┘  └────────────────────────────┘  │
  │             │ compares hash of                               │
  └─────────────┼──────────────────────────────────────────────-┘
                │ Trust Boundary 1: ROM ↔ Boot Media
                │ (HABv4 verifies; SEC_CONFIG[1] enforces)
  ┌─────────────┼──────────────────────────────────────────────-┐
  │             ▼                                                │
  │  ┌──────────────────────────────────────────────────────┐  │
  │  │          AUTHENTICATED BOOT IMAGES                   │  │
  │  │          (on eMMC/SD - mutable storage)              │  │
  │  │                                                      │  │
  │  │  SPL │ TF-A BL2 │ OP-TEE │ U-Boot │ (CSF blocks)   │  │
  │  └──────────────────────────────────────────────────────┘  │
  │  STORAGE TRUST BOUNDARY (signed images only if HAB closed)  │
  └─────────────────────────────────────────────────────────────┘
                │ Trust Boundary 2: SPL/TF-A ↔ Execution
                │ (Chain continues after HABv4 delegates to TF-A)
  ┌─────────────┼──────────────────────────────────────────────-┐
  │             │            DRAM                               │
  │  ┌──────────┴───────────────────────────────────────────┐  │
  │  │ EL3: TF-A BL31 Secure Monitor  │  S-EL1: OP-TEE     │  │
  │  │ (Secure World, ARM TrustZone)   │  (Secure OS)        │  │
  │  │ TZASC controls DRAM security    │  Trusted Execution  │  │
  │  └─────────────────────────────────┼────────────────────┘  │
  │                                    │ Trust Boundary 3:      │
  │                                    │ Secure ↔ Normal World  │
  │                                    │ (TrustZone hardware)   │
  │  ┌─────────────────────────────────┴────────────────────┐  │
  │  │ EL1: Linux Kernel (Normal World)                     │  │
  │  │ Trust Boundary 4: U-Boot ↔ Kernel (FIT signing)      │  │
  │  │ Trust Boundary 5: Kernel ↔ RootFS (dm-verity)         │  │
  │  └──────────────────────────────────────────────────────┘  │
  │  RUNTIME TRUST BOUNDARY                                     │
  └─────────────────────────────────────────────────────────────┘
```

---

## Asset Identification

### Asset 1: SRK Private Keys

**Criticality:** CRITICAL
**Description:** The RSA-4096 (or ECDSA P-384) private keys corresponding to the SRK table entries. Compromise of any SRK private key allows signing of arbitrary malicious firmware images.

**Location:** Hardware Security Module (HSM). Should NEVER be on a disk-accessible system.

**Compromise impact:** All devices with the corresponding SRK_HASH burned into fuses can be compromised via firmware updates signed with the stolen key. Recovery requires reflashing all devices with firmware signed by a backup SRK key (if any was provisioned).

**Protection requirements:** HSM storage, multi-person access control, audit logging of all signing operations, air-gapped signing systems.

### Asset 2: OTP Fuse Values (SRK_HASH)

**Criticality:** HIGH
**Description:** The SHA-256 hash of the SRK table, burned into OCOTP fuses. Defines which SRK table is trusted.

**Location:** On-die silicon fuses (OCOTP). Immutable once burned.

**Compromise impact:** Cannot be "compromised" in the traditional sense—they are immutable. The threat is *incorrect* fuse values: burned SRK_HASH does not match actual SRK table → device is permanently bricked. Or attacker with nation-state capabilities physically modifies fuses (extremely rare).

**Protection requirements:** Verified triple-comparison before burning. Secure fuse burning procedure. Second-engineer review.

### Asset 3: Device-Specific Keys (CAAM Black Keys)

**Criticality:** HIGH
**Description:** Device-unique keys stored in CAAM's secure key storage or derived from CAAM's hardware-backed key derivation. Used for dm-crypt volume key sealing, OP-TEE secure storage encryption.

**Location:** CAAM hardware, OP-TEE secure storage.

**Compromise impact:** Decryption of dm-crypt volumes, access to OP-TEE secure storage contents.

**Protection requirements:** Keys exist only within CAAM hardware. Private keys never leave CAAM. Binding to device identity (hardware UID) via CAAM key derivation.

### Asset 4: Boot Images

**Criticality:** HIGH
**Description:** The signed SPL, TF-A, OP-TEE, U-Boot, kernel, and root filesystem images.

**Location:** eMMC boot partitions, root filesystem.

**Compromise impact:** Replaced unsigned images execute if HABv4 is open. Replaced signed-but-malicious images execute if SRK key is compromised.

**Protection requirements:** HABv4 closed mode (prevents unsigned substitution). SRK key security (prevents signed malicious substitution). dm-verity (prevents rootfs tampering).

### Asset 5: Certificates and Intermediate Keys

**Criticality:** MEDIUM-HIGH
**Description:** CSF key (used to sign CSF blocks), IMG key (embedded in HABv4 CSF to sign image hashes), FIT signing keys (U-Boot image signing), kernel module signing keys.

**Location:** Build server (should be HSM or at minimum encrypted, access-controlled).

**Compromise impact:** CSF/IMG key compromise allows forging of boot image signatures (effectively same impact as SRK key compromise). FIT signing key compromise allows forging kernel/DTB signatures.

---

## Threat Actors and Attack Scenarios

### Scenario 1: Physical Attacker — SD Card Substitution

**Attacker:** Physical, non-sophisticated, no specialized equipment beyond SD card reader
**Target:** Device booting from external SD card
**Attack:** Remove SD card → modify boot partition → reinstall → reboot

```
Attack feasibility:  HIGH   (no special equipment)
Detection:           LOW    (no tamper evidence)
Impact:              HIGH   (persistent root access)
```

**Without mitigation:** Attack succeeds. Attacker has full device access.

**With HABv4 open mode:** Boot ROM validates signature → fails (unsigned) → logs HAB event → continues to boot unsigned image anyway. Attack succeeds.

**With HABv4 closed mode:** Boot ROM validates signature → fails → halts execution. Attack fails. Device does not boot.

**With HABv4 closed + eMMC boot:** SD card is not a boot source. Attack requires eMMC access. Attack complexity increases significantly.

**Residual risk:** Attacker with eMMC reading equipment can still read (not modify, due to HABv4) the eMMC contents without dm-crypt.

### Scenario 2: Software Attacker — Persistent Rootkit via OTA

**Attacker:** Remote, exploited application vulnerability → root shell
**Target:** Running device with root filesystem access
**Attack:** Modify kernel or bootloader on storage to persist after reboot

```
Attack feasibility:  MEDIUM (requires initial code execution)
Detection:           LOW    (without file integrity monitoring)
Impact:              HIGH   (persistence survives reboot)
```

**Without mitigation:** Attacker writes malicious bootloader to eMMC → persists across reboot.

**With HABv4 closed:** Attacker writes malicious (unsigned) bootloader → HABv4 rejects → device may not boot. Denial of service achieved, but not persistence.

**With HABv4 + dm-verity:** Attacker cannot modify the read-only root filesystem (dm-verity detects and panics). Attacker can modify writable partitions (`/data`, `/var`) but these don't affect boot. Persistence is not achieved.

**Residual risk:** Attacker can achieve non-persistent access during current session. Reboot (manual or watchdog-triggered) terminates the attack.

### Scenario 3: Supply Chain — Malicious Yocto Layer

**Attacker:** Supply chain, insider in layer maintenance, or compromised upstream repository
**Target:** Firmware build pipeline
**Attack:** Introduce malicious code into a Yocto layer used in the build; it gets signed normally

```
Attack feasibility:  MEDIUM (requires supply chain access)
Detection:           LOW    (without diff-based code review)
Impact:              CRITICAL (signed malicious firmware)
```

**Without mitigation:** Malicious code is compiled, signed with legitimate SRK key, deployed.

**With code review requirement:** Malicious change is visible in git diff at signing approval.

**With reproducible builds + SBOM:** Build output can be verified against expected components. Unrecognized components trigger alerts.

**Residual risk:** Sophisticated supply chain attack embedded in otherwise legitimate code change may pass review. This is the hardest attack to fully mitigate.

### Scenario 4: Physical Attacker — JTAG Debug Access

**Attacker:** Physical, hardware-equipped (JTAG probe: ~$500 commodity equipment)
**Target:** Device with exposed JTAG interface
**Attack:** Connect JTAG → halt processor → dump OCRAM/DRAM → inject code

```
Attack feasibility:  MEDIUM (requires JTAG hardware, access to JTAG pins)
Detection:           LOW    (JTAG connection is often unlogged)
Impact:              HIGH   (bypasses all software security)
```

**Without mitigation:** Full memory access, register inspection, code injection.

**With JTAG disable (JTAG_SMODE fuse):** JTAG functionality disabled. Attack fails at hardware level.

**Partial mitigation (Secure JTAG):** JTAG requires authentication before use. Limits casual access; sophisticated attackers with key material can still use it.

**Residual risk after JTAG disable:** Decapping and probing at silicon level (nation-state capability). Physical memory bus interception with high-speed oscilloscope.

---

## Risk Matrix

| Threat ID | Threat Description | Likelihood | Impact | Risk | Primary Mitigation |
|-----------|-------------------|------------|--------|------|-------------------|
| T-01 | SD card substitution | HIGH | HIGH | CRITICAL | HABv4 closed + eMMC boot |
| T-02 | JTAG debug access | MEDIUM | HIGH | HIGH | JTAG fuse disable |
| T-03 | eMMC boot partition modification | MEDIUM | HIGH | HIGH | HABv4 closed mode |
| T-04 | Kernel/rootfs modification post-boot | HIGH | HIGH | HIGH | dm-verity |
| T-05 | Unsigned kernel module load | MEDIUM | HIGH | HIGH | Kernel module signing |
| T-06 | Supply chain firmware injection | LOW | CRITICAL | HIGH | Code review + SBOM |
| T-07 | SRK key theft | LOW | CRITICAL | HIGH | HSM + key ceremony |
| T-08 | OTA update MITM | MEDIUM | HIGH | HIGH | Signed OTA + TLS |
| T-09 | Cold boot attack on DRAM | LOW | HIGH | MEDIUM | dm-crypt + short boot window |
| T-10 | USB serial download mode | MEDIUM | HIGH | MEDIUM | USB DL disable fuse |
| T-11 | U-Boot console exploitation | MEDIUM | MEDIUM | MEDIUM | Console disable in production |
| T-12 | UART information disclosure | HIGH | MEDIUM | MEDIUM | Minimal UART in production |
| T-13 | Boot ROM zero-day | VERY LOW | CRITICAL | MEDIUM | Nothing; residual risk |
| T-14 | CAAM side-channel attack | VERY LOW | HIGH | LOW | Physical security |
| T-15 | Fuse laser modification | VERY LOW | CRITICAL | LOW | Enclosure tamper protection |

---

## Platform-Specific Threats: i.MX8MP

### i.MX8MP-Specific Consideration 1: USB Serial Download Mode

The i.MX8MP, like all i.MX processors, supports a USB Serial Download mode (SDP) that allows direct flash operations. This mode is entered by setting BOOT_MODE pins to `10b` or by asserting the force download condition.

In open HABv4 mode, USB download can flash unsigned images. In closed HABv4 mode, USB download requires a signed SDP host command.

**Mitigation:** Set the `SJC_DISABLE_SDP` field in OCOTP or use `BT_FUSE_SEL` to prevent manual BOOT_MODE override. Document in `17-fuse-programming/01-burn-procedure.md`.

### i.MX8MP-Specific Consideration 2: eMMC Boot Partition Write Protection

i.MX8MP systems typically boot from eMMC. The eMMC boot partitions (BOOT1, BOOT2) support write protection via eMMC commands. Setting write protection on the active boot partition after provisioning prevents OS-level processes from modifying the bootloader even with root access.

```bash
# Set permanent write protection on eMMC boot partition
# (run from U-Boot or Linux with MMC tools)
mmc writeprotect boot set /dev/mmcblk0 0  # BOOT1
mmc writeprotect boot set /dev/mmcblk0 1  # BOOT2
```

> **⚠️ WARNING:** Permanent write protection is permanent. Set only after the bootloader is fully validated and signed correctly.

### i.MX8MP-Specific Consideration 3: SNVS Tamper Detection

The i.MX8MP SNVS (Secure Non-Volatile Storage) module supports tamper detection events. External signals (voltage glitching, temperature extremes, physical intrusion) can trigger SNVS tamper detection, which can zeroize SNVS persistent registers including any keys stored there.

This is a feature for devices with physical tamper protection hardware (tamper-detect pins, case intrusion switches).

### i.MX8MP-Specific Consideration 4: Secure Boot Debugging Challenges

When HABv4 authentication fails, the Boot ROM behavior is:
- **Open mode:** Logs a HAB event, continues boot
- **Closed mode:** Logs a HAB event, halts

The HAB event log is stored in SNVS. It is readable in U-Boot via `hab_status`. However, in closed mode with a fatally corrupt boot image, U-Boot may never execute, and the event log is only accessible via JTAG (which must be enabled).

**Operational requirement:** Always validate signing workflow in open mode with event log inspection before burning SEC_CONFIG fuse.

---

## PHYTEC-Specific Threat Considerations

### PHYTEC phyCORE-i.MX8MP Module Boundaries

The PHYTEC phyCORE-i.MX8MP is a System-on-Module (SoM). The SoM contains the SoC, eMMC, and PMIC. The carrier board provides connectivity and expansion.

This split creates a supply chain boundary: the SoM is manufactured by PHYTEC and populated with NXP silicon. The carrier board may be designed by the end customer.

**Threat consideration:** If the carrier board has a debug JTAG connector that can be accessed while the SoM is attached, JTAG access threats apply regardless of SoM-level security configuration. Carrier board design must not expose JTAG signals in production configurations.

### PHYTEC BSP and Signing Integration

The PHYTEC BSP (Yocto Kirkstone, phytec-nxp-kirkstone.xml) provides a `meta-phytec` layer that includes U-Boot and TF-A recipes pre-configured for the phyCORE-i.MX8MP. Security signing is not enabled by default in the PHYTEC BSP.

**Action required:** Add `meta-signing` layer (or equivalent) to the BSP to integrate HABv4 signing into the Yocto build. This is documented in `18-yocto-integration/` and `19-phytec-specifics/`.

---

## Summary

The threat model for i.MX8MP Secure Boot is dominated by three practical threat scenarios:

1. **Physical boot media substitution** (high likelihood, high impact) → mitigated by HABv4 closed mode
2. **Post-boot rootfs persistence** (high likelihood, high impact) → mitigated by dm-verity
3. **Supply chain firmware compromise** (medium likelihood, critical impact) → partially mitigated by code review and SBOM; residual risk remains

The highest-impact but lowest-likelihood threat is **SRK private key theft or compromise**. This threat must be addressed through the key ceremony and HSM infrastructure even though the probability of any single key being targeted is low—the impact if it occurs affects all deployed devices.

---

## Further Reading

- Microsoft STRIDE Threat Model: https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool-threats
- OWASP Threat Modeling: https://owasp.org/www-community/Threat_Modeling
- NXP AN4581: Secure Boot Using HABv4 (threat model perspective)
- NIST SP 800-30: Guide for Conducting Risk Assessments
