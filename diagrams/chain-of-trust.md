# Chain of Trust Diagram

## Complete Trust Chain

```mermaid
flowchart TD
    A["🔒 NXP ROM\n(Silicon Root of Trust)\nVerifies: SRK hash vs OCOTP fuses"] -->|HABv4 authenticates| B

    B["📦 imx-boot\n(SPL + TF-A BL2 + OP-TEE + U-Boot)\nSigned with: CSF (IMG key)\nVerified by: ROM"]

    B -->|Loads and jumps to| C["🔐 TF-A BL31\n(EL3 Secure Monitor)\nStays resident\nGatekeeps SMC calls"]
    B -->|Loads and jumps to| D["🛡️ OP-TEE (BL32)\n(Trusted OS, EL1-S)\nProvides: HUK, RPMB, fTPM, TAs"]
    B -->|Loads and jumps to| E["⚙️ U-Boot (BL33)\n(Bootloader, EL2/EL1-NS)\nVerifies: FIT image signature"]

    E -->|Verifies RSA-2048 signature| F["🗜️ fitImage\n(FIT container)\nContains: kernel + DTB + ramdisk\nSigned with: FIT key"]

    F -->|Boots Linux kernel| G["🐧 Linux Kernel\n(EL1-NS)\nActivates: dm-verity\nMounts: /dev/mapper/vroot"]

    G -->|Verifies SHA-256 Merkle tree| H["💾 Root Filesystem\n(dm-verity protected ext4)\nRoot hash in: signed FIT cmdline\nAny tampering: kernel panic"]

    H -->|Starts systemd| I["🔑 OP-TEE Client\n(tee-supplicant)\nUnseals: LUKS key via TPM PCRs\nProvides: secure storage API"]

    I -->|Unlocks| J["🔐 Data Partition\n(LUKS2 encrypted)\nKey sealed to: TPM PCR state\nOnly unlocks: if measured boot matches"]

    style A fill:#d32f2f,color:#fff
    style B fill:#e64a19,color:#fff
    style C fill:#f57c00,color:#fff
    style D fill:#f9a825,color:#000
    style E fill:#558b2f,color:#fff
    style F fill:#1976d2,color:#fff
    style G fill:#0288d1,color:#fff
    style H fill:#0097a7,color:#fff
    style I fill:#6a1b9a,color:#fff
    style J fill:#4a148c,color:#fff
```

## Trust Relationships Table

| Verifier | Verified | Method | Key Material |
|----------|---------|--------|-------------|
| ROM | imx-boot | HABv4 RSA-2048 | SRK hash in OCOTP fuses |
| U-Boot | fitImage | FIT RSA-2048 | Public key in U-Boot DTB |
| Linux kernel | rootfs blocks | dm-verity SHA-256 | Root hash in signed cmdline |
| Kernel | OP-TEE | TrustZone hardware | None — HW enforced |
| Application | data | LUKS2 AES-256 | Key sealed in TPM |

## Failure Modes

```
Failure at ROM/HABv4:
  CLOSED mode → Device halts, no output
  OPEN mode   → HAB event logged, boot continues (development only)

Failure at U-Boot/FIT:
  "ERROR: Bad signature!" → Boot halts
  No recovery without reflash

Failure at dm-verity:
  Any tampered block → kernel panic (production: panic_on_corruption)
  Device reboots, enters recovery if A/B partitions available

Failure at TPM unseal:
  Data partition inaccessible
  Recovery: passphrase entry or re-seal
```
