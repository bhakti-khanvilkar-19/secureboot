# Hardening

## Overview

Secure boot authentication is necessary but not sufficient. A signed rootfs with a vulnerable kernel, permissive capabilities, or world-writable paths provides false security. Hardening addresses the runtime attack surface after boot authentication succeeds.

## Hardening Layers

```
┌─────────────────────────────────────────────────────────┐
│           Hardening Stack                               │
├─────────────────────────────────────────────────────────┤
│  Network: Firewall, TLS pinning, minimal services       │
├─────────────────────────────────────────────────────────┤
│  Application: Seccomp, capabilities, namespaces         │
├─────────────────────────────────────────────────────────┤
│  Filesystem: ro rootfs, noexec mounts, IMA/EVM          │
├─────────────────────────────────────────────────────────┤
│  Kernel: Kconfig hardening, lockdown, LSM (AppArmor)    │
├─────────────────────────────────────────────────────────┤
│  U-Boot: Locked env, no network in production, locked   │
│          console                                        │
├─────────────────────────────────────────────────────────┤
│  Secure boot: HABv4, FIT, dm-verity (previous chapters) │
└─────────────────────────────────────────────────────────┘
```

## Defense in Depth Principle

Each hardening layer should be independent: if one layer is bypassed, the others still provide protection.

```
Attacker exploits network service → gains unprivileged user
      ↓ AppArmor blocks file access
      ↓ Seccomp blocks dangerous syscalls
      ↓ Capabilities dropped (no CAP_SYS_ADMIN)
      ↓ Even as root: dm-verity blocks rootfs modification
      ↓ Even with rootfs write: TPM-sealed keys prevent data access
```

## Cross-References

- [01-kernel-hardening.md](01-kernel-hardening.md) — Linux kernel hardening configuration
- [02-uboot-hardening.md](02-uboot-hardening.md) — U-Boot hardening
- [03-filesystem-hardening.md](03-filesystem-hardening.md) — Filesystem and runtime hardening
- [../26-threat-modeling/01-attack-scenarios.md](../26-threat-modeling/01-attack-scenarios.md) — Threats this hardening addresses
- [../28-production-checklists/02-security-review-checklist.md](../28-production-checklists/02-security-review-checklist.md) — Hardening verification checklist
