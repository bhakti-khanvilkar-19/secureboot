# CST (Code Signing Tool) Complete Workflow

```
Tested Against:
  - NXP CST: 3.3.1
  - OpenSSL: 3.0.x
  - imx-mkimage: lf-6.1.55-2.2.0
  - Platform: phyboard-pollux-imx8mp-3
Last Validated: 2024-Q2
```

---

## Overview

The NXP Code Signing Tool (CST) is the primary tool for:
1. Generating the PKI key hierarchy (SRK → CSFK → IMG keys)
2. Compiling CSF source files into CSF binaries
3. Signing images using the generated private keys

CST is provided by NXP as a pre-compiled binary and is required for HABv4 signing. It is not open source. Download from the NXP website (free, but requires registration):
https://www.nxp.com/webapp/Download?colCode=IMX_CST_TOOL_NEW

---

## CST Installation and Setup

```bash
# Download CST 3.3.1 (filename varies, example below)
# File: cst-3.3.1.tgz

# Extract to working directory:
tar -xzf cst-3.3.1.tgz
cd cst-3.3.1/

# Linux 64-bit binary location:
ls linux64/bin/
# cst       - Main signing tool
# srktool   - SRK table generator

# Verify CST is executable:
./linux64/bin/cst --version
# Output: CST version 3.3.1 -- HABv4

# Optional: add to PATH for convenience:
export PATH=$PATH:$(pwd)/linux64/bin
```

**CST Dependencies (Ubuntu/Debian):**
```bash
apt-get install libssl3 libcurl4 libssl-dev
# CST uses OpenSSL dynamically; ensure version compatibility
```

---

## CST Directory Structure

After installation and before key generation:

```
cst-3.3.1/
├── linux64/
│   ├── bin/
│   │   ├── cst              # CSF compiler and signing tool
│   │   └── srktool          # SRK hash table generator
│   └── lib/                 # OpenSSL and other shared libraries
├── release/
│   ├── keys/                # EMPTY — will contain private keys after generation
│   ├── crts/                # EMPTY — will contain certificates after generation
│   ├── ca/                  # EMPTY — CA database files after generation
│   └── hab4_pki_tree.sh     # HABv4 PKI tree generation script
├── docs/
│   ├── CST_UM.pdf           # CST User Manual
│   ├── HAB4_API.pdf         # HABv4 API Reference
│   └── SecureBootUserGuide.pdf
└── scripts/
    └── hab4_pki_tree.sh     # (alternate location)
```

After key generation, `keys/` and `crts/` will be populated.

> **⚠️ CRITICAL:** The `keys/` directory will contain private key material. Never commit it to any repository. Never copy it to unsecured locations. For production use, generate keys on an HSM or air-gapped machine and keep private keys in the HSM.

---

## hab4_pki_tree.sh Key Generation Walkthrough

The `hab4_pki_tree.sh` script creates the complete 3-tier PKI hierarchy:
- 4 × SRK (Super Root Key) — CA certificates, self-signed
- 4 × CSFK (CSF Key) — one per SRK, signed by corresponding SRK
- 4 × IMG Key (Image Key) — one per SRK, signed by corresponding CSFK

This gives you flexibility to use any SRK+CSFK+IMG combination.

### Running the Script

```bash
cd cst-3.3.1/release/

# Run the key generation script:
bash hab4_pki_tree.sh
```

The script prompts for several parameters. Here is the complete walkthrough with recommended production values:

```
Do you want to use an existing CA key (y/n)?:
→ Enter: n
(First-time setup; always generate fresh keys for production)

Enter key length in bits for PKI tree:
→ Enter: 4096
(RSA-4096 recommended; RSA-2048 is minimum supported but insufficient for long-lived deployments)

Enter the certificate duration (years):
→ Enter: 30
(HABv4 ignores certificate expiry dates, but choose a value that covers device lifetime + buffer)

How many Super Root Keys should be generated (2, 3, or 4)?:
→ Enter: 4
(Always generate all 4; unused SRKs act as revocation spares)

Do you want the SRK certificates to have the CA flag set? (y/n)?:
→ Enter: y
(Required — SRK must be CA certificate to sign CSFK/IMG certs)

(The script will generate keys and certificates for all 4 SRK entries)
```

### Script Output

After running, the `keys/` and `crts/` directories are populated:

```bash
ls release/keys/
# SRK1_sha256_4096_65537_v3_ca_key.pem    # SRK 1 private key
# SRK2_sha256_4096_65537_v3_ca_key.pem    # SRK 2 private key
# SRK3_sha256_4096_65537_v3_ca_key.pem    # SRK 3 private key
# SRK4_sha256_4096_65537_v3_ca_key.pem    # SRK 4 private key
# CSF1_1_sha256_4096_65537_v3_usr_key.pem # CSFK for SRK1
# CSF2_1_sha256_4096_65537_v3_usr_key.pem # CSFK for SRK2 (if SRK2 ever needed)
# CSF3_1_sha256_4096_65537_v3_usr_key.pem
# CSF4_1_sha256_4096_65537_v3_usr_key.pem
# IMG1_1_sha256_4096_65537_v3_usr_key.pem # IMG key for SRK1
# IMG2_1_sha256_4096_65537_v3_usr_key.pem
# IMG3_1_sha256_4096_65537_v3_usr_key.pem
# IMG4_1_sha256_4096_65537_v3_usr_key.pem

ls release/crts/
# SRK1_sha256_4096_65537_v3_ca_crt.pem    # SRK 1 certificate (public key)
# SRK2_sha256_4096_65537_v3_ca_crt.pem
# SRK3_sha256_4096_65537_v3_ca_crt.pem
# SRK4_sha256_4096_65537_v3_ca_crt.pem
# CSF1_1_sha256_4096_65537_v3_usr_crt.pem # CSFK certificate, signed by SRK1
# ...
# IMG1_1_sha256_4096_65537_v3_usr_crt.pem # IMG certificate, signed by CSFK1
# ...
# SRK_1_2_3_4_table.bin                   # SRK TABLE (required for CSF)
```

**Naming convention decoded:**
```
CSF1_1_sha256_4096_65537_v3_usr_crt.pem
│    │  │      │    │      │  │   └─ crt = certificate file
│    │  │      │    │      │  └─ usr = user (not CA) certificate
│    │  │      │    │      └─ v3 = X.509 v3
│    │  │      │    └─ 65537 = RSA public exponent
│    │  │      └─ 4096 = RSA key size in bits
│    │  └─ sha256 = hash algorithm for certificate signature
│    └─ 1 = SRK index this CSFK is signed by (SRK1)
└─ CSF = key type (CSFK); IMG would be here for image keys
```

---

## srktool Usage and Output

`srktool` generates the SRK table binary (needed for `Install SRK` in CSF) and its SHA-256 hash (needed for burning into fuses).

### Generating SRK Table

```bash
cd cst-3.3.1/release/

./linux64/bin/srktool \
    --hab_ver 4 \
    --certs crts/SRK1_sha256_4096_65537_v3_ca_crt.pem,\
crts/SRK2_sha256_4096_65537_v3_ca_crt.pem,\
crts/SRK3_sha256_4096_65537_v3_ca_crt.pem,\
crts/SRK4_sha256_4096_65537_v3_ca_crt.pem \
    --hash crts/SRK_1_2_3_4_fuse.bin \
    --table crts/SRK_1_2_3_4_table.bin
```

Parameters:
- `--hab_ver 4`: HABv4 format
- `--certs`: Comma-separated list of all 4 SRK certificate files (PEM format)
- `--hash`: Output file for the fuse value (32 bytes = 256-bit hash)
- `--table`: Output file for the SRK table binary (embedded in CSF)

### Extracting Fuse Values

```bash
# Display the SRK hash in hex format for fuse programming:
hexdump -e '/4 "0x%08X\n"' crts/SRK_1_2_3_4_fuse.bin
# Output (example with 4096-bit RSA):
# 0xA1B2C3D4
# 0xE5F60718
# 0x293A4B5C
# 0x6D7E8F90
# 0x1A2B3C4D
# 0x5E6F7081
# 0x92A3B4C5
# 0xD6E7F809

# These 8 words (32 bytes) go into OCOTP fuse bank 6, words 0-7
# (SRK_HASH[255:0] on i.MX8MP)
```

### Verifying SRK Table

```bash
# Verify the SRK table hash matches what was computed:
sha256sum crts/SRK_1_2_3_4_table.bin
# This should match the content of crts/SRK_1_2_3_4_fuse.bin

# Cross-check:
python3 -c "
import hashlib, struct
with open('crts/SRK_1_2_3_4_table.bin', 'rb') as f:
    table = f.read()
h = hashlib.sha256(table).digest()
print('Computed hash:')
for i in range(0, 32, 4):
    print(hex(struct.unpack_from('>I', h, i)[0]))

with open('crts/SRK_1_2_3_4_fuse.bin', 'rb') as f:
    fuse = f.read()
print('Fuse file:')
for i in range(0, 32, 4):
    print(hex(struct.unpack_from('>I', fuse, i)[0]))
"
# Both outputs should be identical
```

---

## CSF File Creation for Different Scenarios

### Scenario 1: SPL Only Signing

Used when the SPL is a standalone binary (not combined with TF-A/OP-TEE/U-Boot):

```bash
# Create csf_spl.csf:
cat > csf_spl.csf << 'EOF'
[Header]
    Version = 4.3
    Hash Algorithm = sha256
    Engine = CAAM
    Engine Configuration = 0
    Certificate Format = X509
    Signature Format = CMS

[Install SRK]
    File = "crts/SRK_1_2_3_4_table.bin"
    Source index = 0

[Install CSFK]
    File = "crts/CSF1_1_sha256_4096_65537_v3_usr_crt.pem"

[Authenticate CSF]

[Install Key]
    Verification index = 0
    Target index = 2
    File = "crts/IMG1_1_sha256_4096_65537_v3_usr_crt.pem"

[Authenticate Data]
    Verification index = 2
    Blocks = 0x920000 0x000 0x20000 "u-boot-spl.bin"

[Unlock]
    Engine = CAAM
    Features = RNG
EOF

# Compile and sign:
./linux64/bin/cst --i csf_spl.csf --o csf_spl.bin
```

### Scenario 2: SPL + U-Boot Combined (flash.bin from imx-mkimage)

The standard i.MX8MP production scenario:

```bash
# First, build the unsigned flash.bin:
cd imx-mkimage/
make SOC=iMX8MP \
     SPL=../build/spl/u-boot-spl.bin \
     ATF_LOAD_ADDR=0x920000 \
     TEE_LOAD_ADDR=0x56000000 \
     flash_evk

# Note the CSF offset printed by imx-mkimage:
# "CSF Offset = 0x2E000" (example value, check actual output)
CSF_OFFSET=0x2E000
SPL_LOAD_ADDR=0x920000

# Create CSF with correct address:
cat > csf_flash.csf << EOF
[Header]
    Version = 4.3
    Hash Algorithm = sha256
    Engine = CAAM
    Engine Configuration = 0
    Certificate Format = X509
    Signature Format = CMS

[Install SRK]
    File = "crts/SRK_1_2_3_4_table.bin"
    Source index = 0

[Install CSFK]
    File = "crts/CSF1_1_sha256_4096_65537_v3_usr_crt.pem"

[Authenticate CSF]

[Install Key]
    Verification index = 0
    Target index = 2
    File = "crts/IMG1_1_sha256_4096_65537_v3_usr_crt.pem"

[Authenticate Data]
    Verification index = 2
    Blocks = ${SPL_LOAD_ADDR} 0x000 ${CSF_OFFSET} "flash.bin"

[Unlock]
    Engine = CAAM
    Features = RNG
EOF

# Sign:
./linux64/bin/cst --i csf_flash.csf --o csf_flash.bin
```

### Scenario 3: imx-boot Container with SPL and U-Boot Signing

In newer NXP BSP versions, the boot image consists of multiple signed regions. Both the SPL region and the U-Boot FIT container may have separate CSFs:

```bash
# CSF for container header (if using AHAB-style container on HABv4):
# This is more complex and depends on imx-mkimage version.
# For pure HABv4 (not AHAB), a single CSF covering all authenticated
# regions is the standard approach.
# See the imx-mkimage Makefile for iMX8MP flash_evk target for
# the exact image layout and CSF requirements.
```

---

## flash.bin Creation with imx-mkimage

### Prerequisites

```bash
# Required binaries for i.MX8MP flash.bin:
ls input-files/
# u-boot-spl.bin          (from Yocto deploy/ or U-Boot build)
# u-boot-nodtb.bin        (U-Boot without DTB, for FIT container)
# imx8mp-phyboard-pollux-rdk.dtb  (U-Boot device tree)
# bl31.bin                (TF-A BL31, from ATF build)
# tee.bin                 (OP-TEE, from OP-TEE build)
# lpddr4_pmu_train_1d_imem_202006.bin  (DDR training firmware)
# lpddr4_pmu_train_1d_dmem_202006.bin
# lpddr4_pmu_train_2d_imem_202006.bin
# lpddr4_pmu_train_2d_dmem_202006.bin
```

### imx-mkimage Build Commands

```bash
cd imx-mkimage/

# For eMMC boot (phyboard-pollux):
make SOC=iMX8MP \
     dtbs=imx8mp-phyboard-pollux-rdk.dtb \
     SPL=../input-files/u-boot-spl.bin \
     UBOOT_BINARY=../input-files/u-boot-nodtb.bin \
     ATF_LOAD_ADDR=0x970000 \
     TEE_LOAD_ADDR=0x56000000 \
     flash_evk

# For FlexSPI NOR boot:
make SOC=iMX8MP \
     dtbs=imx8mp-phyboard-pollux-rdk.dtb \
     SPL=../input-files/u-boot-spl.bin \
     UBOOT_BINARY=../input-files/u-boot-nodtb.bin \
     flash_evk_flexspi

# Output:
# iMX8MP/flash.bin       - The combined boot image
# iMX8MP/print_fit_hab   - Script to print HABv4 authenticate blocks
```

### Using print_fit_hab for Address Computation

imx-mkimage provides a helper for computing HABv4 block addresses:

```bash
# After building flash.bin:
cd iMX8MP/
./print_fit_hab

# Example output:
# 0x920000 0x0 0x2D000
# This is the exact Blocks line for your CSF Authenticate Data command
```

---

## Combining Signed Images

After generating `csf_flash.bin` and injecting it into `flash.bin`:

```bash
# Step 1: Determine the CSF offset in flash.bin (from imx-mkimage log)
CSF_OFFSET=$(./print_fit_hab | awk '{print $3}')
# Or hardcode from imx-mkimage output, e.g.:
CSF_OFFSET=0x2E000

# Step 2: Inject CSF binary into flash.bin at CSF offset
dd if=csf_flash.bin of=flash.bin \
   bs=1 \
   seek=$((CSF_OFFSET)) \
   conv=notrunc

# Step 3: Verify IVT CSF pointer is now non-zero
python3 -c "
import struct
with open('flash.bin', 'rb') as f:
    data = f.read(32)
csf_ptr = struct.unpack_from('<I', data, 24)[0]
print(f'CSF pointer in IVT: {hex(csf_ptr)}')
if csf_ptr == 0:
    print('ERROR: CSF pointer is still 0 — injection failed!')
else:
    print('OK: CSF pointer is set')
"
```

> **📝 NOTE:** The `dd` injection with `conv=notrunc` (no truncation) only works if `flash.bin` was pre-allocated with the CSF space. imx-mkimage allocates 8192 bytes (0x2000) for the CSF by default. Verify `csf_flash.bin` is smaller than 8 KB:
> ```bash
> ls -la csf_flash.bin
> # Should be ~4000-6000 bytes for RSA-4096
> ```

---

## Verification Before Fuse Burning

Before burning the SRK_HASH into fuses, verify the complete signing workflow on the actual hardware in OPEN mode.

### Complete Verification Checklist

```bash
# 1. Flash the signed flash.bin to SD card:
dd if=flash.bin of=/dev/sdX bs=1024 seek=32 conv=notrunc
sync

# 2. Boot the board and check U-Boot serial output:
# Expected: Normal SPL + U-Boot boot messages (no error messages)

# 3. In U-Boot, run hab_status:
=> hab_status

# REQUIRED output for a valid signing:
# HAB Configuration: 0xf0 HAB State: 0xf0
# No HAB Events Found!

# 4. If ANY events appear (even warnings), DO NOT PROCEED to fuse burning.
# Fix the signing issue first and repeat from step 1.

# 5. Verify the SRK hash that will be burned matches your keys:
=> md.b 0x0 32
# Read the first 32 bytes of ROM (not useful for SRK hash directly)
# Instead, use SPSDK to verify:

# From host (SPSDK):
nxpimage hab show-hab-container -b flash.bin
# Verify the SRK table hash matches crts/SRK_1_2_3_4_fuse.bin
```

---

## Testing in HAB OPEN Mode

Testing checklist before closing:

```bash
# Test 1: Signed image boots without HAB events
# Expected: No events in hab_status

# Test 2: Deliberately corrupt the signature and verify detection
# Create a corrupted copy:
cp flash.bin flash_corrupt.bin
# Flip a bit in the authenticated region:
python3 -c "
with open('flash_corrupt.bin', 'r+b') as f:
    f.seek(0x1000)  # Inside authenticated region
    b = f.read(1)
    f.seek(0x1000)
    f.write(bytes([b[0] ^ 0x01]))  # Flip one bit
"
dd if=flash_corrupt.bin of=/dev/sdX bs=1024 seek=32 conv=notrunc

# Boot the corrupted image. In OPEN mode, it will still boot but:
=> hab_status
# Expected: HAB_FAILURE event with HAB_INV_SIGNATURE
# This confirms HABv4 IS detecting the tampering

# Test 3: Restore the correct signed image:
dd if=flash.bin of=/dev/sdX bs=1024 seek=32 conv=notrunc
# Verify: No events in hab_status again

# Test 4: Verify hab_status shows the correct HAB state
=> hab_status
# Expected: Configuration: 0xf0 (OPEN), no events
```

---

## Closing the Device After Validation

After successful validation in OPEN mode, transition to CLOSED mode. This is covered in detail in [HAB Lifecycle](05-hab-lifecycle.md). The essential steps are:

```bash
# 1. Burn SRK_HASH fuses (IRREVERSIBLE):
# From U-Boot (requires fuse programming support):

# Read expected values from SRK_1_2_3_4_fuse.bin:
# Each word in big-endian byte order
# Bank 6, Words 0-7:
=> fuse prog -y 6 0 0xA1B2C3D4
=> fuse prog -y 6 1 0xE5F60718
# ... (repeat for all 8 words)

# 2. Verify fuse values:
=> fuse read 6 0 8
# Compare against expected values from fuse.bin

# 3. Burn SEC_CONFIG[1] to close the device (IRREVERSIBLE):
=> fuse prog -y 1 3 0x2000000
# Bit 25 of OCOTP word at bank 1, word 3 = SEC_CONFIG[1]
# VERIFY this fuse word and bit position against your specific
# i.MX8MP reference manual revision before burning.

# 4. Power cycle and verify:
# The device should boot successfully with HAB_CFG_CLOSED (0xcc)
```

> **⚠️ CRITICAL:** Closing the device is irreversible. If anything is wrong with the signed images or the SRK_HASH fuses, the device will not boot and cannot be recovered. See [HAB Lifecycle](05-hab-lifecycle.md) for the full validation checklist.
