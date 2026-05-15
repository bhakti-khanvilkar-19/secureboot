# Scripts

Automation scripts for Embedded Linux Secure Boot operations. All scripts are organized by function and include inline documentation.

## Directory Structure

```
scripts/
├── key-generation/       # Key and certificate generation
│   ├── generate-hab-keys.sh    # HABv4 SRK key hierarchy (NXP CST)
│   └── generate-fit-keys.sh    # FIT image signing key pair
├── signing/              # Image signing operations
│   ├── sign-fit-image.sh       # Sign FIT image with mkimage
│   └── create-csf.sh           # Create HABv4 CSF for a binary
├── provisioning/         # Device provisioning and fuse programming
│   ├── read-hab-status.sh      # Read HAB status on device
│   └── program-srk-fuses.sh    # Program SRK hash into OTP fuses
└── validation/           # Verification and audit
    ├── verify-signed-fit.sh    # Check FIT image signatures
    └── check-hab-events.sh     # Decode HAB event log entries
```

## General Rules

1. **Never commit keys or sensitive values** - All scripts accept key paths via arguments or environment variables. Keys stay on the filesystem, not in scripts or git.

2. **Environment variables for configuration** - Scripts use `${VAR:-default}` pattern so they work with environment or explicit defaults.

3. **Dependency checks at startup** - Every script checks for required tools before doing any work. Read the error output carefully.

4. **Explicit confirmation for destructive operations** - Scripts that burn fuses or program hardware require typing a confirmation phrase. This is intentional.

5. **Air-gapped systems for key generation** - Key generation scripts should run on a machine with no network connectivity. The warning dialogs are not theater.

## Dependencies

| Script | Tools Required |
|--------|---------------|
| `generate-hab-keys.sh` | NXP CST, openssl |
| `generate-fit-keys.sh` | openssl |
| `sign-fit-image.sh` | mkimage (u-boot-tools) |
| `create-csf.sh` | NXP CST (`cst` in PATH) |
| `program-srk-fuses.sh` | root, imx-ocotp kernel module |
| `verify-signed-fit.sh` | dumpimage (u-boot-tools) |

## Quick Reference

```bash
# Generate HABv4 key hierarchy
CST_PATH=/opt/cst ./scripts/key-generation/generate-hab-keys.sh ./production-keys/

# Generate FIT signing key
./scripts/key-generation/generate-fit-keys.sh ./fit-keys/ my-board-key

# Sign a FIT image
./scripts/signing/sign-fit-image.sh fitImage ./fit-keys/ my-board-key u-boot.dtb

# Create CSF for SPL+U-Boot
./scripts/signing/create-csf.sh flash.bin 0x920000 ./hab-keys/

# Verify a signed FIT image
./scripts/validation/verify-signed-fit.sh fitImage

# Decode HAB events (run on target or paste serial output)
./scripts/validation/check-hab-events.sh
```

## Security Notes

- Run key generation on **air-gapped hardware only**
- Store output from `generate-hab-keys.sh` in an HSM or encrypted offline storage
- The `program-srk-fuses.sh` script is **irreversible** - verify values on multiple devices before wide deployment
- Rotate FIT signing keys annually; SRK keys cannot be rotated after fuse programming
