# Chain of Trust

## Learning Objectives

After completing this chapter you will:
- Understand why every boot stage must verify the next
- Be able to describe the i.MX8MP chain of trust end-to-end
- Know what happens at each failure point
- Understand the relationship between hardware and software trust anchors

## Prerequisites

- [03-root-of-trust](../03-root-of-trust/README.md): Hardware Root of Trust
- [02-embedded-cryptography](../02-embedded-cryptography/README.md): RSA and SHA basics

---

## Definition

A chain of trust is an **unbroken sequence of cryptographic verification** from an immutable hardware root to the running application. Each link in the chain verifies the next before handing control.

**Critical property:** The chain is only as strong as its weakest link. A single unverified stage breaks the entire chain.

---

## i.MX8MP Chain of Trust

```
╔══════════════════════════════════════════════════════════════════╗
║                  i.MX8MP CHAIN OF TRUST                         ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  [HARDWARE - IMMUTABLE]                                          ║
║  OCOTP Fuses: SRK_HASH (256-bit) + SEC_CONFIG                   ║
║       │                                                          ║
║       │ anchors                                                  ║
║       ▼                                                          ║
║  ROM Code (NXP-signed, read-only)                                ║
║       │                                                          ║
║       │ HABv4: verifies CSF signature using SRK_HASH             ║
║       ▼                                                          ║
║  [STAGE 1: imx-boot]                                             ║
║  SPL + TF-A BL31 + OP-TEE + U-Boot                              ║
║  (signed with CST using IMG key from SRK chain)                  ║
║       │                                                          ║
║       │ U-Boot: verifies FIT signature using embedded public key  ║
║       ▼                                                          ║
║  [STAGE 2: FIT Image]                                            ║
║  Kernel + Device Tree + Initramfs                                ║
║  (signed with mkimage using FIT signing key)                     ║
║       │                                                          ║
║       │ Kernel: mounts dm-verity device with stored root hash     ║
║       ▼                                                          ║
║  [STAGE 3: Root Filesystem]                                      ║
║  /dev/mapper/vroot (read-only, dm-verity protected)              ║
║       │                                                          ║
║       │ systemd: starts verified services                         ║
║       ▼                                                          ║
║  [STAGE 4: Userspace]                                            ║
║  Applications (seccomp, AppArmor optional)                       ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## Authentication Mechanism Per Stage

| Stage | Verifier | Algorithm | Key Location | Failure in CLOSED Mode |
|-------|---------|-----------|--------------|------------------------|
| imx-boot (SPL+TF-A+OP-TEE+U-Boot) | ROM HABv4 | RSA-2048 + SHA-256 | OCOTP fuses (SRK hash) | **HALT — no boot** |
| FIT Image (kernel+DTB+initramfs) | U-Boot | RSA-2048 + SHA-256 | U-Boot DTB (embedded) | **HALT — no kernel** |
| Root filesystem | Linux kernel (dm-verity) | SHA-256 Merkle tree | Kernel cmdline / FIT | **I/O error / panic** |
| Runtime files | IMA (optional) | SHA-256 | IMA policy | Policy-dependent |

---

## What Breaks the Chain

### Breaking at ROM Stage
If the ROM cannot verify imx-boot:
- In **OPEN mode**: logs HAB warning, boots anyway (development)
- In **CLOSED mode**: **permanent halt**, no recovery except hardware

### Breaking at U-Boot Stage
If FIT image signature invalid:
- U-Boot prints: `ERROR: Failed to validate required signature`
- System halts at bootloader — no kernel loads

### Breaking at dm-verity Stage
If rootfs block hash doesn't match Merkle tree:
- Per-block I/O error on read
- With `dm_verity.error_behavior=1`: kernel panic immediately
- Prevents silent rootfs corruption

---

## Chain of Trust vs. Defense in Depth

These are complementary, not equivalent:

| Property | Chain of Trust | Defense in Depth |
|----------|---------------|-----------------|
| Focus | Boot-time verification | Runtime layered security |
| Enforcement | Binary (pass/fail) | Gradual degradation |
| Coverage | Boot path | Ongoing runtime |
| Examples | HABv4, FIT signing, dm-verity | Firewall, SELinux, seccomp |

A production system needs **both**.

---

## PHYTEC phyCORE-i.MX8MP Specifics

The phyCORE-i.MX8MP implements the full chain:

1. **ROM** → verifies imx-boot on eMMC boot0 partition at offset 0x0
2. **SPL** (in imx-boot) → DDR init, loads TF-A/OP-TEE/U-Boot from eMMC
3. **TF-A BL31** → EL3 runtime, initializes OP-TEE
4. **OP-TEE** → Secure OS, RPMB storage, fTPM (optional)
5. **U-Boot** → loads fitImage from eMMC p1 (/boot partition), verifies
6. **Linux** → mounts /dev/mapper/vroot (dm-verity on eMMC p2)

---

## Cross-References

- [01-chain-of-trust-diagram.md](01-chain-of-trust-diagram.md) — Visual diagrams
- [12-habv4-imx8m](../12-habv4-imx8m/README.md) — HABv4 authentication detail
- [09-fit-images](../09-fit-images/README.md) — FIT image format
- [21-verified-boot-and-dmverity](../21-verified-boot-and-dmverity/README.md) — dm-verity
