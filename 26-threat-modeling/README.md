# Threat Modeling

## Overview

Threat modeling for secure boot systems answers: **What are we protecting, from whom, and how could they attack it?** This drives security requirements and helps prioritize countermeasures.

## Assets to Protect

```
┌────────────────────────────────────────────────────────┐
│ Asset                   │ Compromise Impact             │
├────────────────────────────────────────────────────────┤
│ SRK private keys        │ Sign arbitrary firmware       │
│ FIT signing keys        │ Install malicious kernel      │
│ OTA signing keys        │ Distribute malicious update   │
│ Device firmware          │ Backdoor, data theft          │
│ Root filesystem          │ Runtime compromise            │
│ User data (LUKS)        │ Privacy violation             │
│ OP-TEE secure storage   │ Credential theft, key extract │
│ RPMB key               │ Replay protection defeat       │
│ SRK fuses (integrity)   │ Factory provisioning spoofing │
│ Manufacturing process    │ Mass-scale compromise         │
└────────────────────────────────────────────────────────┘
```

## Attacker Profiles

| Attacker | Capability | Motivation | Access |
|----------|-----------|-----------|--------|
| Remote attacker | Network only | Data theft, ransomware | Internet |
| Malicious user | Local Linux shell | Privilege escalation | SSH/physical |
| Physical attacker | Hardware access, JTAG | Firmware extraction | Lab |
| Insider threat | Build/signing access | Sabotage, theft | Internal |
| Supply chain | Manufacturing access | Mass compromise | Factory |
| Nation state | All of above + chip-level | Espionage | Advanced |

## STRIDE Threat Categories

| Threat | Example | Countermeasure |
|--------|---------|---------------|
| **S**poofing | Attacker flashes firmware claiming to be legitimate | HABv4 signature verification |
| **T**ampering | Modify rootfs to inject backdoor | dm-verity |
| **R**epudiation | Deny unauthorized signing occurred | HSM audit logs |
| **I**nformation disclosure | Extract keys from running system | OP-TEE isolation, TrustZone |
| **D**enial of service | Corrupt bootloader → permanent brick | A/B updates, anti-brick |
| **E**levation of privilege | Escape from normal Linux to secure world | TrustZone, OP-TEE SMC gate |

## Cross-References

- [01-attack-scenarios.md](01-attack-scenarios.md) — Detailed attack scenarios and mitigations
- [../01-security-foundations/01-threat-modeling.md](../01-security-foundations/01-threat-modeling.md) — General threat modeling methodology
- [../27-hardening/README.md](../27-hardening/README.md) — Hardening against identified threats
- [../28-production-checklists/02-security-review-checklist.md](../28-production-checklists/02-security-review-checklist.md) — Security review
