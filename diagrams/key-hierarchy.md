# Key Hierarchy Diagram

## Complete Key Hierarchy

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        HABv4 KEY HIERARCHY                              │
│                        (NXP i.MX8MP / PHYTEC)                          │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                   Air-Gapped HSM (YubiHSM2)                     │   │
│  │                                                                 │   │
│  │  ProductionCA-2024 (RSA-4096)                                   │   │
│  │  ├── SRK1 (RSA-2048) ─── HASH BURNED IN OCOTP FUSES ✦         │   │
│  │  │   └── [Active signing key]                                   │   │
│  │  ├── SRK2 (RSA-2048) ─── backup slot (available for revoke)    │   │
│  │  ├── SRK3 (RSA-2048) ─── backup slot                           │   │
│  │  └── SRK4 (RSA-2048) ─── backup slot                           │   │
│  │        │                                                        │   │
│  │        └── CSF Key (RSA-2048) ─── signs CSF structure          │   │
│  │                 └── IMG Key (RSA-2048) ─── signs boot images   │   │
│  │                                                                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ✦ SHA-256(SRK1‖SRK2‖SRK3‖SRK4 public keys) = 32 bytes               │
│    Stored in OCOTP Bank 3, Words 0-7 (one-time programmable)           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                       FIT SIGNING HIERARCHY                             │
│                  (COMPLETELY SEPARATE from HABv4!)                      │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │               HSM (Signing Service) or Air-Gapped               │   │
│  │                                                                 │   │
│  │  FIT Root CA (RSA-4096)                                         │   │
│  │  └── FIT Signing Key (RSA-2048)                                 │   │
│  │       ├── Public key embedded in U-Boot DTB at build time       │   │
│  │       └── mkimage uses private key to sign fitImage             │   │
│  │                                                                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  Key name: "phytec-fit-key"  (must match key-name-hint in ITS)         │
│  Key location: u-boot.dtb → /signature/key-phytec-fit-key             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                      OTA SIGNING HIERARCHY                              │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │               Air-Gapped Signing Station                        │   │
│  │                                                                 │   │
│  │  OTA Root CA (RSA-4096)                                         │   │
│  │  └── SWUpdate Signing Key (RSA-2048)                            │   │
│  │       ├── Used by: openssl cms -sign                            │   │
│  │       └── Verified by: /etc/swupdate/swupdate-signing-cert.pem │   │
│  │                                                                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                    DEVICE-UNIQUE KEY HIERARCHY                          │
│                                                                         │
│  CAAM → HUK (Hardware Unique Key, 256-bit, fused at NXP factory)       │
│    └── OP-TEE derives:                                                  │
│         ├── RPMB Key  → authenticates eMMC RPMB partition              │
│         ├── HUK-derived application keys (per-TA key derivation)       │
│         └── fTPM seed → TPM 2.0 operations                             │
│                                                                         │
│  TPM 2.0 (fTPM via OP-TEE):                                            │
│    ├── EK (Endorsement Key) — device identity                          │
│    ├── SRK (TPM Storage Root Key) — sealing/unsealing                  │
│    └── AK (Attestation Key) — remote attestation quotes               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Rotation Capability

| Key | Rotatable? | Method |
|-----|-----------|--------|
| SRK1 | No (fuse-bound) | Revoke via OCOTP_SRK_REVOKE, use SRK2-4 |
| SRK2-4 | Available as rotation slots | Program OCOTP_SRK_REVOKE |
| CSF Key | Yes | New CSF cert signed by SRK |
| IMG Key | Yes | New CSF includes new IMG key |
| FIT Key | Yes | OTA update with new U-Boot DTB |
| OTA Key | Yes | Update via current OTA key before revocation |
| HUK | Never | Hardware-burned at NXP factory |
| LUKS Key | Yes | Re-seal with new key via TPM |
