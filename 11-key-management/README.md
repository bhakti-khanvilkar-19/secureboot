# Key Management

## ⚠️ Security-Critical Chapter

Key management failures are the most common cause of secure boot deployment failures. This chapter covers the complete lifecycle of all keys used in the secure boot chain.

## Key Inventory

| Key Name | Algorithm | Purpose | Stored In | Rotatable? |
|----------|-----------|---------|-----------|-----------|
| SRK1–SRK4 | RSA-2048 | HABv4 root authentication | HSM (offline) | No (fuse-bound) |
| CSF Key | RSA-2048 | Signs CSF structure | HSM (offline) | Yes (with new CSF) |
| IMG Key | RSA-2048 | Signs boot images | HSM (offline) | Yes (with CSF update) |
| FIT Key | RSA-2048 | Signs FIT images | HSM (signing service) | Yes (OTA update) |
| OTA Key | RSA-2048 | Signs OTA packages | HSM (signing service) | Yes (OTA update) |
| OP-TEE HUK | AES-256 | Device-unique key derivation | CAAM fuses | Never |
| LUKS Key | AES-256 | Full disk encryption | TPM-sealed | Yes |

## Key Hierarchy

```
┌──────────────────────────────────────────────────────────┐
│                   NXP HABv4 HIERARCHY                    │
│                                                          │
│  PKI Root CA (RSA-4096) ── [AIR-GAPPED HSM]             │
│        │                                                 │
│        ├── SRK1 (RSA-2048) ── HASH BURNED IN FUSES       │
│        ├── SRK2 (RSA-2048) ── backup slot                │
│        ├── SRK3 (RSA-2048) ── backup slot                │
│        └── SRK4 (RSA-2048) ── backup slot                │
│              │                                           │
│              └── CSF Key (RSA-2048) ── signs CSF         │
│                        │                                 │
│                        └── IMG Key (RSA-2048) ── signs boot images
│                                                          │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│                  FIT SIGNING HIERARCHY                   │
│              (SEPARATE from HABv4 keys!)                 │
│                                                          │
│  FIT Root CA (RSA-4096) ── [AIR-GAPPED HSM]             │
│        │                                                 │
│        └── FIT Signing Key (RSA-2048)                    │
│             ├── Embedded in U-Boot DTB at build time     │
│             └── Used by mkimage to sign FIT images        │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│                  OTA SIGNING HIERARCHY                   │
│                                                          │
│  OTA Root CA (RSA-4096) ── [AIR-GAPPED HSM]             │
│        │                                                 │
│        └── OTA Signing Key (RSA-2048)                    │
│             └── Used to sign SWUpdate/RAUC packages       │
└──────────────────────────────────────────────────────────┘
```

## Golden Rules

1. **Production keys are never development keys.** Use completely separate key hierarchies.
2. **Private keys never touch networked systems.** Use HSMs and air-gapped signing.
3. **SRK keys are permanent.** Once burned in fuses, they cannot be changed.
4. **Backup SRK keys.** Keep 2-3 backup SRK slots for revocation capability.
5. **Key access requires ≥2 people.** No single person has sole key access.
6. **Audit every signing operation.** Log timestamp, operator, artifact hash.
7. **Test before closing device.** Always validate signed firmware in OPEN mode first.

## Cross-References

- [01-key-generation.md](01-key-generation.md) — Key generation procedures
- [02-srk-fuse-programming.md](02-srk-fuse-programming.md) — SRK hash fuse programming
- [10-image-signing](../10-image-signing/README.md) — Signing workflows
- [12-habv4-imx8m](../12-habv4-imx8m/README.md) — HABv4 and SRK usage
