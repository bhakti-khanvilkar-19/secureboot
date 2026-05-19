# Attack Scenarios and Mitigations

## Scenario 1: Firmware Replacement via Physical Flash

**Attacker**: Physical access to device, JTAG or eMMC programmer

**Attack**:
1. Open device
2. Connect eMMC programmer or JTAG
3. Write custom imx-boot.bin to eMMC boot0
4. Reboot device

**Without secure boot**: Attacker's firmware runs at full privilege.

**With HABv4 + CLOSED mode**:
- ROM reads imx-boot from eMMC
- ROM verifies CSF signature against SRK hash in fuses
- Custom firmware has no valid CSF → ROM halts
- **Result**: Attack blocked

**Residual risk**: If attacker has access to signing keys (e.g., key theft), attack succeeds.

**Mitigation**:
- Air-gapped HSM for key storage
- Key ceremony procedures with multiple witnesses
- Physical tamper detection (SNVS) to detect device opening
- Enclosure potting to prevent JTAG access

---

## Scenario 2: OTA Update Injection (Network)

**Attacker**: Network attacker with MITM position or compromised update server

**Attack**:
1. Intercept OTA download (or control update server)
2. Serve malicious firmware update package
3. Device downloads and installs malicious firmware

**Without signed OTA**: Malicious package is installed, device compromised.

**With SWUpdate/RAUC CMS signing**:
- Package signature verified against embedded certificate
- Malicious package (not signed with production key) → verification fails
- SWUpdate rejects package, current firmware intact
- **Result**: Attack blocked

**Residual risk**: If OTA signing key is compromised.

**Mitigation**:
- OTA signing key in air-gapped HSM (never on update server)
- Certificate pinning for update server TLS
- Signed update manifests (not just transport TLS)
- Package includes anti-rollback version check

---

## Scenario 3: Root Filesystem Modification (Runtime)

**Attacker**: Has root shell on running device (via other vulnerability)

**Attack**:
1. Exploit CVE in application to gain root shell
2. Modify /usr/bin/application to add backdoor
3. Persist across reboots

**Without dm-verity**: Attacker successfully modifies rootfs.

**With dm-verity**:
- Rootfs mounted read-only from dm-verity device
- Write to /usr/bin fails: "Read-only file system"
- Even as root, rootfs cannot be modified
- **Result**: Persistence blocked (attacker has shell but cannot persist)

**Residual risk**: Attacker can still modify writable `/data` partition. Application running in rootfs cannot be modified but may be exploited repeatedly.

**Mitigation**:
- Data partition encrypted (LUKS2, TPM-sealed key)
- Application with minimal writable state
- Separate writable partition with `noexec` mount flag
- Application sandboxing (seccomp, capabilities, namespaces)

---

## Scenario 4: Bootloader Environment Tampering

**Attacker**: Physical access, can write to eMMC

**Attack**:
1. Modify U-Boot environment (stored in unprotected eMMC partition)
2. Change bootargs to disable dm-verity: `dm_verity.dev_wait=0`
3. Change boot device to attacker-controlled storage
4. Bypass entire verification chain

**Without signed U-Boot env**: Attack succeeds.

**Mitigations**:
- U-Boot environment variables marked `ENV_WRITEABLE_LIST ""` (no env writable in production)
- Boot arguments compiled into U-Boot binary (not from environment)
- dm-verity root hash in signed FIT bootargs (not from environment)
- CONFIG_ENV_IS_NOWHERE for fully locked-down builds
- FIT image verification prevents loading attacker's fitImage

**Layered result**: Even if env is modified, FIT signature check still runs against embedded key.

---

## Scenario 5: Supply Chain Hardware Trojan

**Attacker**: Insider at SoC fab, board assembly, or logistics

**Attack**:
1. Hardware trojan inserted in SoC die (extreme) or PCBA component substitution
2. Trojan activates under specific conditions (power-on sequence, date, network traffic)
3. Exfiltrates data or establishes covert channel

**Detection**:
- Hardware security testing (X-ray inspection, electrical characterization)
- SoC authentication (JTAG IDCODE verification)
- Behavioral monitoring at runtime (IDS/IPS)
- Side-channel analysis comparison against known-good boards

**Mitigation** (partial — hardware trojans very difficult to detect):
- Source components only from authorized distributors
- Certificate of Conformance required with each shipment
- Incoming inspection program (10% sample)
- Board design review for unauthorized components
- Trusted foundry programs for highest-security applications

---

## Scenario 6: Key Exfiltration from Signing Infrastructure

**Attacker**: Insider with access to signing workstation or HSM

**Attack**:
1. Compromise signing server (malware, insider)
2. Extract private key material
3. Sign arbitrary firmware off-band
4. Deploy via OTA or physical replacement

**Without HSM**: Keys in plaintext files → trivially extracted.

**With HSM (YubiHSM2/Thales Luna)**:
- Private key cannot be exported (hardware-enforced)
- All signing operations require HSM presence
- HSM logs all operations
- Dual-person control: two smartcards required for any signing

**Mitigation**:
- All production keys in HSMs with non-exportable flag
- Signing operations require 2-of-N authentication
- Audit log exported to tamper-evident external logging server
- Key ceremony with 2+ witnesses and video recording
- Regular HSM firmware updates and audit log review

---

## Scenario 7: Anti-Rollback Bypass

**Attacker**: Has OTA delivery capability (e.g., compromised update server)

**Attack**:
1. Find a critical vulnerability in firmware version 1.5 (already patched in 2.0)
2. Deliver firmware v1.5 as "downgrade" OTA package
3. Device reverts to vulnerable version
4. Exploit CVE

**Without anti-rollback**: Attack succeeds.

**With anti-rollback (OCOTP fuse counter)**:
- Device has fuse counter = 4 (version 2.0)
- Package claims version 1.5 < 4 → rejected at boot
- **Result**: Downgrade blocked at hardware level

**With software-only anti-rollback**:
- SWUpdate `--no-downgrade` flag
- Can be bypassed if attacker has physical access and reflashes via SDP
- Software-only anti-rollback insufficient for physical adversary

---

## Scenario 8: OP-TEE Exploit → Secure World Escape

**Attacker**: Advanced attacker with kernel-level code execution

**Attack**:
1. Exploit kernel vulnerability → arbitrary kernel code
2. Issue crafted SMC call to OP-TEE
3. Exploit OP-TEE vulnerability to run code in EL1-S
4. Access CAAM, SNVS, HUK → extract device-unique secrets

**Mitigations**:
- Keep OP-TEE updated (security patches)
- Restrict which applications can call OP-TEE (client library, seccomp)
- OP-TEE compiled with hardened stack (CFI, ASLR)
- Minimal OP-TEE attack surface: disable unnecessary TAs
- Kernel hardened against privilege escalation (see §27)
- TrustZone separation ensures even kernel cannot directly read secure RAM

---

## Attack Surface Summary

```
External attack surface:
  Network ──────────→ OTA update handler
                  ──→ Application network services
                  ──→ Remote access (SSH)

Physical attack surface:
  JTAG/Debug ───────→ ROM, SPL, TF-A, OP-TEE, Linux
  eMMC access ──────→ Boot partition, rootfs
  USB OTG ──────────→ SDP recovery mode
  PCB tamper ───────→ SNVS tamper detection

Software attack surface:
  Application CVEs ─→ Local privilege escalation
  Kernel CVEs ──────→ Ring 0 execution
  OP-TEE CVEs ──────→ Secure world access

Key management attack surface:
  Build system ─────→ Compromise signing
  HSM access ───────→ Key theft
  Insider threat ───→ Unauthorized signing
```

---

## Cross-References

- [../27-hardening/README.md](../27-hardening/README.md) — Countermeasures for each threat
- [../28-production-checklists/02-security-review-checklist.md](../28-production-checklists/02-security-review-checklist.md) — Security review
- [../19-manufacturing-security/03-supply-chain-security.md](../19-manufacturing-security/03-supply-chain-security.md) — Supply chain scenario detail
- [../01-security-foundations/02-attack-surfaces.md](../01-security-foundations/02-attack-surfaces.md) — Attack surface overview
