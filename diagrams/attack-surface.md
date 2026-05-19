# Attack Surface Diagram

## Attack Surface Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SECURE BOOT ATTACK SURFACE                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  REMOTE ATTACK SURFACE (Network):                                   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                                                             │   │
│  │   Internet ──► OTA Update Handler ──► SWUpdate/RAUC        │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: CMS signature verification]           │   │
│  │                                                             │   │
│  │   Internet ──► Application API ──► Application CVEs        │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: AppArmor, seccomp, capabilities]      │   │
│  │                                                             │   │
│  │   Internet ──► SSH / Remote Shell ──► Linux                │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: Key-only auth, no root login]         │   │
│  │                                                             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  LOCAL SOFTWARE ATTACK SURFACE (Requires shell access):             │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                                                             │   │
│  │   Shell ──► Filesystem write ──► rootfs                    │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: dm-verity (read-only rootfs)]         │   │
│  │                                                             │   │
│  │   Shell ──► Kernel exploit ──► EL1-NS kernel               │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: KASLR, lockdown, KPTI, CFI]           │   │
│  │                                                             │   │
│  │   Kernel ──► SMC exploit ──► OP-TEE (EL1-S)               │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: OP-TEE hardening, minimal TAs]        │   │
│  │                                                             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  PHYSICAL ATTACK SURFACE (Requires hardware access):                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                                                             │   │
│  │   JTAG ──► Debug access ──► ROM, SPL, OP-TEE, Linux        │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: JTAG_SMODE fuse disabled]             │   │
│  │                                                             │   │
│  │   eMMC programmer ──► Boot partition ──► firmware replace  │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: HABv4 CLOSED mode, CSF signature]     │   │
│  │                                                             │   │
│  │   USB OTG ──► SDP mode ──► Load unsigned firmware          │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: CLOSED mode authenticates SDP too]    │   │
│  │                                                             │   │
│  │   PCB probe ──► eMMC data lines ──► data extraction        │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: LUKS2 disk encryption]                │   │
│  │                                                             │   │
│  │   Tamper ──► SNVS tamper detect ──► Key zeroization        │   │
│  │                    ↓                                        │   │
│  │             [DEFENSE: SNVS anti-tamper + potting]           │   │
│  │                                                             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  SUPPLY CHAIN ATTACK SURFACE:                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                                                             │   │
│  │   Hardware trojan ──► SoC/PCB ──► Covert channel           │   │
│  │   [DEFENSE: Authorized distributors, incoming inspection]   │   │
│  │                                                             │   │
│  │   Compromised build ──► Yocto sstate ──► Backdoor          │   │
│  │   [DEFENSE: Pinned SRCREVs, reproducible builds, SBOM]     │   │
│  │                                                             │   │
│  │   Key theft ──► Signing infra ──► Arbitrary firmware       │   │
│  │   [DEFENSE: HSM, 2-person control, audit logs]              │   │
│  │                                                             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Defense in Depth: Layer Bypass Required

```
For a complete device compromise, an attacker must bypass ALL of:

Layer 1: HABv4 signature → requires SRK private key
Layer 2: FIT signature   → requires FIT private key
Layer 3: dm-verity       → requires ability to modify signed FIT cmdline
Layer 4: Kernel lockdown → requires kernel exploit
Layer 5: OP-TEE          → requires SMC exploit + OP-TEE bug
Layer 6: LUKS2           → requires TPM PCR bypass or passphrase

Each layer is independent — bypassing one does not grant access
to the next. This is the goal of defense in depth.
```

## Residual Risks (After Full Stack Deployed)

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| 0-day in Linux kernel | Low | High | Kernel lockdown, rapid patching, OTA |
| OP-TEE vulnerability | Very Low | Critical | Minimal TA surface, updates |
| HSM compromise | Very Low | Critical | Air-gapped HSM, 2-person rule |
| Supply chain HW trojan | Extremely Low | Critical | Trusted distributors, inspection |
| Quantum computing (future) | Low (10+ years) | Critical | Plan ECC P-384 migration |
