# Measured Boot and TPM

## Overview

Measured boot extends the trust model beyond signature verification: every boot stage *measures* (hashes) the next stage and records that measurement in a tamper-resistant log. A TPM (Trusted Platform Module) provides the root of trust for this log.

## Measured vs Verified Boot

| Property | Verified Boot | Measured Boot |
|----------|--------------|---------------|
| Action | Signature check → halt if fail | Hash measurement → always boot |
| Purpose | Prevent unauthorized code | Detect what code ran |
| Enforcement | At boot time (hard) | Post-hoc attestation (soft) |
| Requirement | Signing key | TPM (or OP-TEE fTPM) |
| Standard | Varies (HABv4, FIT) | TCG (TPM 2.0 spec) |
| Attestation | No | Yes (PCR quotes) |

**Measured boot does not prevent booting — it records what booted.** You use the record to:
- Seal secrets that are only released if measurements match (LUKS key)
- Remotely attest the device state to a server
- Detect tampering after the fact

## TPM on i.MX8MP

### Hardware TPM

Discrete TPM 2.0 chip over SPI:
- Infineon SLB9670, STMicro ST33KTPM, Microchip ATTPM20, Nuvoton NPCT75x
- Connected via SPI to i.MX8MP
- Device tree: `tpm@0 { compatible = "tcg,tpm_tis-spi"; ... }`

### Firmware TPM (fTPM via OP-TEE)

Software TPM implemented as OP-TEE Trusted Application:
- Uses CAAM for hardware RNG and key operations
- State stored in RPMB (Replay-Protected Memory Block)
- No external chip required
- Enable in OP-TEE build: `CFG_TPM_OPTEE=y`

## PCR Layout (Typical)

```
PCR 0:  BIOS/UEFI code            → SPL + TF-A measurement
PCR 1:  BIOS/UEFI configuration   → Boot configuration
PCR 2:  Option ROMs                → (unused on embedded)
PCR 3:  Option ROM config          → (unused on embedded)
PCR 4:  Boot manager code          → U-Boot measurement
PCR 5:  Boot manager configuration → U-Boot environment
PCR 6:  Wake events                → (unused typically)
PCR 7:  Secure boot policy         → HABv4 state, keys
PCR 8:  Kernel                     → fitImage measurement
PCR 9:  initramfs                  → initramfs measurement
PCR 10: IMA log                    → IMA measurement log
PCR 11: Unified kernel image       → (if applicable)
PCR 14: MOK                        → Machine Owner Key (if applicable)
```

## Cross-References

- [01-tpm-provisioning.md](01-tpm-provisioning.md) — TPM setup and LUKS key sealing
- [../07-spl-tf-a-optee/03-optee-integration.md](../07-spl-tf-a-optee/03-optee-integration.md) — OP-TEE fTPM
- [../27-hardening/01-kernel-hardening.md](../27-hardening/01-kernel-hardening.md) — IMA/EVM
