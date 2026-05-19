# Debugging and Recovery

## Overview

Secure boot failures are among the most difficult embedded Linux problems to diagnose. The device may not produce any output, and the failure mode (bricked device) can be irreversible if the wrong recovery steps are taken.

## Diagnostic Flow

```
Device doesn't boot after enabling secure boot
            │
            ▼
    Check UART output
            │
    ┌───────┴────────┐
    │                │
  Output           No output
    │                │
    ▼                ▼
 Parse HAB      Check BOOT_MODE pins
 events         Check power supply
                Check UART config
                Try JLink/JTAG
            │
            ▼
    Run hab_status command
            │
    ┌───────┴────────────────┐
    │                        │
"No HAB Events"          Events found
(other problem)               │
                              ▼
                    Decode event bytes
                    (see 01-hab-debugging.md)
                              │
                    ┌─────────┴─────────┐
                    │                   │
               CSF error           SRK error
                    │                   │
               Re-sign image       Check SRK fuse values
                                   vs SRK table hash
```

## Failure Mode Categories

| Layer | Failure | Symptom | Recovery |
|-------|---------|---------|----------|
| HABv4 | Wrong SRK hash in fuses | Event 0x40/0x00 reason 0x00 | Match keys to burned fuses |
| HABv4 | CSF offset wrong | Event 0x20 | Fix imx-mkimage offsets |
| HABv4 | Image size mismatch | Authentication fail | Recompute CSF coverage |
| FIT | Key name mismatch | "Signature check failed" | Match key-name-hint |
| FIT | DTB padding too small | "signatures node not found" | Rebuild with -p 2000 |
| dm-verity | Root hash mismatch | Kernel panic | Redeploy correct rootfs |
| dm-verity | Hash tree corrupted | I/O errors | Reflash from update |
| OP-TEE | RPMB not initialized | TA error 0xFFFF0009 | Re-provision OP-TEE |

## Critical Tools

```
On target (U-Boot):
  hab_status              → Show HAB events and configuration
  hab_auth_img            → Manually authenticate an image
  fuse read <bank> <word> → Read OCOTP fuse values
  env print               → Show U-Boot environment

On target (Linux):
  dmesg | grep -i "hab\|verity\|tpm"
  dmsetup status
  tpm2_pcrread

On host (signing workstation):
  cst --version
  openssl verify
  dumpimage -l fitImage
  veritysetup verify
```

## Cross-References

- [01-hab-debugging.md](01-hab-debugging.md) — HABv4 event decoding
- [02-fit-image-debugging.md](02-fit-image-debugging.md) — FIT verification failures
- [03-recovery-procedures.md](03-recovery-procedures.md) — Recovery for bricked devices
- [04-common-failure-modes.md](04-common-failure-modes.md) — Failure mode reference
- [../12-habv4-imx8m/03-hab-event-decoding.md](../12-habv4-imx8m/03-hab-event-decoding.md) — HAB event code tables
