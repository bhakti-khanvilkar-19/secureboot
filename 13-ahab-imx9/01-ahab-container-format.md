# AHAB Signed Container Format: Deep Dive

```
Reference: NXP i.MX93 Security Reference Manual (IMX93SRM), Rev. 1
           NXP AN13195: AHAB Guide for i.MX9 Series
           CST 3.4.0 AHAB Container Specification
```

---

## Overview

The AHAB Signed Container is the fundamental artifact that the i.MX9 Boot ROM authenticates. Unlike HABv4 where the IVT and CSF were loosely-coupled structures appended to image data, the AHAB container is a tightly integrated, self-describing structure: it declares every image it covers, provides cryptographic hashes of those images, and carries the signature over the entire declaration. The Boot ROM needs only one structure to locate, load, and authenticate all images in a boot set.

This document covers the complete binary layout, field semantics, inspection tools, key generation for both RSA and ECC paths, and the imx-mkimage AHAB build targets that assemble the final bootable image.

---

## Binary Container Layout

### Top-Level View

```
AHAB Bootable Image (flash.bin as produced by imx-mkimage)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Offset 0x0000: [Padding / MBR area]
Offset 0x8000: Container 1 — ELE Firmware (NXP-signed)
│              ├── Container Header (128 bytes)    tag=0x87
│              ├── Image Entry [0]: ELE firmware   type=0x03
│              └── Signature Block                  tag=0x90
│                  ├── NXP SRK Table
│                  └── NXP ECDSA signature
│
Offset 0x9000+: Container 2 — OEM Images (OEM-signed)
│              ├── Container Header (128 bytes)    tag=0x87
│              ├── Image Entry [0]: TF-A BL31       type=0x07
│              ├── Image Entry [1]: OP-TEE          type=0x07
│              ├── Image Entry [2]: U-Boot SPL      type=0x07
│              ├── Image Entry [3]: U-Boot proper   type=0x07
│              └── Signature Block                  tag=0x90
│                  ├── OEM SRK Table (4 slots)
│                  └── OEM RSA/ECDSA signature
│
Offset varies: Raw image data (referenced by image entries)
               ├── ELE firmware binary
               ├── BL31 binary
               ├── OP-TEE binary
               ├── SPL binary
               └── U-Boot binary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Container Header (128 bytes)

The container header is the entry point structure. Its tag byte `0x87` at offset +3 is the ROM's primary identifier.

```
Byte offset  Size  Field             Description
──────────────────────────────────────────────────────────────────
+0x00        1     version           Container format version; must be 0x00
+0x01        2     length            Total container size (LE); includes
                                     header + image entries + signature block
+0x03        1     tag               Must be 0x87 — identifies AHAB container
+0x04        4     flags             Bit field:
                                       [3:0]  = image set (0=primary, 1=recovery)
                                       [7:4]  = reserved
                                       [31:8] = reserved
+0x08        2     sw_version        Software version for anti-rollback;
                                     ELE rejects containers with sw_version
                                     below the value stored in OTP
+0x0A        1     fuse_version      Minimum fuse version required;
                                     ELE rejects if OTP fuse_version < this
+0x0B        1     num_images        Count of image entries; 1–8
+0x0C        2     sig_blk_offset    Byte offset from container start to
                                     signature block
+0x0E        2     reserved          Must be 0x0000
+0x10        112   reserved          Padding to 128-byte alignment; all zeros
──────────────────────────────────────────────────────────────────
Total: 128 bytes (0x80)
```

### Image Entry (128 bytes each)

Image entries follow the container header contiguously. With `num_images = 4`, the image entry array occupies bytes 128–639 of the container (4 × 128 = 512 bytes).

```
Byte offset  Size  Field             Description
──────────────────────────────────────────────────────────────────
+0x00        4     image_offset      Offset in bytes from container start
                                     to beginning of image data
+0x04        4     reserved          Must be 0x00000000
+0x08        8     load_address      64-bit physical address where ROM
                                     copies this image; little-endian
+0x10        4     image_size        Size of image data in bytes
+0x14        4     hab_flags         Bit field:
                                       [3:0]   = type:
                                                 0x03 = ELE (EdgeLock Enclave)
                                                 0x04 = V2X primary
                                                 0x05 = V2X secondary
                                                 0x06 = V2X dummy
                                                 0x07 = executable (general)
                                                 0x08 = data
                                       [7:4]   = core:
                                                 0x01 = Cortex-A55 (primary)
                                                 0x02 = Cortex-M33 (ELE)
                                                 0x04 = HDMI TX
                                                 0x05 = V2X FW core 1
                                                 0x06 = V2X FW core 2
                                       [11:8]  = hash_type:
                                                 0x00 = SHA-256
                                                 0x01 = SHA-384
                                                 0x02 = SHA-512
                                       [31:12] = reserved
+0x18        64    image_hash        Hash of image data (SHA-256 = 32 bytes
                                     left-padded to 64 bytes; SHA-512 = 64
                                     bytes; SHA-384 = 48 bytes padded)
+0x58        4     meta              Bit field:
                                       [7:0]   = algorithm (0=uncompressed,
                                                 1=zlib, 2=lz4, 3=zstd)
                                       [8]     = encrypted (1=yes)
                                       [31:9]  = reserved
+0x5C        36    reserved          All zeros
──────────────────────────────────────────────────────────────────
Total: 128 bytes (0x80)
```

### Signature Block

The signature block begins at `sig_blk_offset` bytes from the start of the container. Its structure:

```
Byte offset  Size   Field             Description
──────────────────────────────────────────────────────────────────
+0x00        1      version           0x00
+0x01        2      length            Total signature block size (LE)
+0x03        1      tag               Must be 0x90 — identifies signature block
+0x04        2      srk_record_offset Offset from sig block start to SRK record
+0x06        2      srk_table_offset  Offset from sig block start to SRK table
+0x08        2      blob_offset       Offset to DEK blob (0 if not encrypted)
+0x0A        2      signature_offset  Offset from sig block start to signature
+0x0C        4      reserved          All zeros
──────────────────────────────────────────────────────────────────
Header: 16 bytes, then follows:

SRK Record (variable size):
  4 bytes: flags (which SRK slot: bit 0=SRK1, bit 1=SRK2, etc.)
  2 bytes: length of SRK record
  Per-SRK-slot tag/hash (for revocation checking)

SRK Table (variable size):
  4 SRK entries, each containing the full X.509 DER certificate
  of that SRK slot public key

Signature (variable size):
  RSA-PSS or ECDSA signature bytes
  For RSA-2048: 256 bytes
  For ECDSA P-256: 64 bytes (r || s)
  For ECDSA P-521: 132 bytes
──────────────────────────────────────────────────────────────────
```

The signed data region is: container header bytes (128) + all image entry bytes (num_images × 128). The signature block itself is outside the signed region.

---

## Signed Region: What Exactly Is Signed

This is the most common source of confusion when hand-crafting or debugging AHAB containers.

**Signed region:**
- Container header: all 128 bytes
- Image entry array: `num_images × 128` bytes

**Not signed:**
- Image data binaries (BL31, OP-TEE, U-Boot, etc.)
- The signature block itself

Image data is **hashed**, not signed. Each image entry contains the hash of the corresponding image binary. The signature covers the container header and image entries (which include those hashes). This two-level structure (hash-then-sign) allows efficient verification: ELE can verify the signature once (small, fixed-size data), then independently verify each image hash as images are loaded.

The signed-region bytes are fed to ELE for signature verification. If the container header is modified after signing (for example, changing `sw_version`), the signature will no longer verify.

---

## Container Inspection Tools

### NXP ahab-container-info (SPSDK)

SPSDK provides the most readable container inspection:

```bash
# Install SPSDK (Python 3.8+)
pip install spsdk

# Parse container from flash.bin
nxpimage ahab parse --binary flash.bin --output-dir /tmp/ahab-dump

# Output shows:
# Container 1:
#   Header: version=0, length=0x600, sw_version=0, num_images=1
#   Image [0]: type=ELE, core=ELE, hash_type=SHA384, load=0x..., size=0x...
#   Signature Block: SRK[0] used, algorithm=ECDSA-P384
#
# Container 2:
#   Header: version=0, length=0x..., sw_version=0, num_images=4
#   Image [0]: type=exe, core=A55, hash_type=SHA256, load=0xBB000000
#   Image [1]: type=exe, core=A55, hash_type=SHA256, load=0x56000000
#   Image [2]: type=exe, core=A55, hash_type=SHA256, load=0x2049A000
#   Image [3]: type=exe, core=A55, hash_type=SHA256, load=0x40200000
#   Signature Block: SRK[0] used, algorithm=ECDSA-P256

# Verify signature (requires SRK certificate)
nxpimage ahab verify --binary flash.bin --srk-table SRK_1_2_3_4_table.bin
```

### Manual Hexdump Inspection

When SPSDK is not available, locate containers via their tag bytes:

```bash
# Locate container header tag 0x87
python3 << 'EOF'
data = open('flash.bin', 'rb').read()
found = []
for offset in range(0, min(len(data), 0x100000), 4):
    # Tag byte is at offset +3 within 4-byte-aligned structure
    if len(data) > offset + 3 and data[offset + 3] == 0x87:
        version = data[offset]
        length = int.from_bytes(data[offset+1:offset+3], 'little')
        num_images = data[offset + 0x0B]
        sw_version = int.from_bytes(data[offset+8:offset+10], 'little')
        found.append((offset, version, length, num_images, sw_version))
        print(f"Container header at 0x{offset:08x}:")
        print(f"  version={version}, length=0x{length:x}, "
              f"num_images={num_images}, sw_version={sw_version}")

if not found:
    print("No container headers found in first 1MB")
EOF
```

Inspect the first container header in detail:

```bash
# Dump container header (128 bytes at offset 0x8000)
python3 << 'EOF'
import struct
data = open('flash.bin', 'rb').read()

# Container 1 at offset 0x8000 (adjust if different)
base = 0x8000
header = data[base:base+128]

version = header[0]
length = struct.unpack_from('<H', header, 1)[0]
tag = header[3]
flags = struct.unpack_from('<I', header, 4)[0]
sw_version = struct.unpack_from('<H', header, 8)[0]
fuse_version = header[10]
num_images = header[11]
sig_blk_offset = struct.unpack_from('<H', header, 12)[0]

print(f"Container Header at 0x{base:x}:")
print(f"  version:        0x{version:02x}")
print(f"  length:         0x{length:x} ({length} bytes)")
print(f"  tag:            0x{tag:02x} {'(valid)' if tag == 0x87 else '(INVALID)'}")
print(f"  flags:          0x{flags:08x}")
print(f"  sw_version:     {sw_version}")
print(f"  fuse_version:   {fuse_version}")
print(f"  num_images:     {num_images}")
print(f"  sig_blk_offset: 0x{sig_blk_offset:x}")

# Parse image entries
print()
for i in range(num_images):
    entry_base = base + 128 + i * 128
    entry = data[entry_base:entry_base+128]
    img_offset = struct.unpack_from('<I', entry, 0)[0]
    load_addr = struct.unpack_from('<Q', entry, 8)[0]
    img_size = struct.unpack_from('<I', entry, 16)[0]
    hab_flags = struct.unpack_from('<I', entry, 20)[0]
    img_type = hab_flags & 0xF
    core = (hab_flags >> 4) & 0xF
    hash_type = (hab_flags >> 8) & 0xF
    img_hash = entry[24:56]  # First 32 bytes of hash field

    type_names = {3:'ELE', 7:'executable', 8:'data'}
    core_names = {1:'Cortex-A55', 2:'Cortex-M33', 5:'V2X-1', 6:'V2X-2'}
    hash_names = {0:'SHA-256', 1:'SHA-384', 2:'SHA-512'}

    print(f"Image Entry [{i}] at 0x{entry_base:x}:")
    print(f"  image_offset: 0x{img_offset:x} (abs: 0x{base+img_offset:x})")
    print(f"  load_address: 0x{load_addr:016x}")
    print(f"  image_size:   0x{img_size:x} ({img_size} bytes)")
    print(f"  type:         {type_names.get(img_type, hex(img_type))}")
    print(f"  core:         {core_names.get(core, hex(core))}")
    print(f"  hash_type:    {hash_names.get(hash_type, hex(hash_type))}")
    print(f"  image_hash:   {img_hash.hex()}")
    print()
EOF
```

### Verify Image Hashes Manually

Cross-check that the hash in an image entry matches the actual image data:

```bash
python3 << 'EOF'
import hashlib, struct

data = open('flash.bin', 'rb').read()
base = 0x8000  # OEM container offset; adjust per your image

header = data[base:base+128]
num_images = header[11]

for i in range(num_images):
    entry = data[base + 128 + i*128 : base + 256 + i*128]
    img_offset = struct.unpack_from('<I', entry, 0)[0]
    img_size = struct.unpack_from('<I', entry, 16)[0]
    hab_flags = struct.unpack_from('<I', entry, 20)[0]
    hash_type = (hab_flags >> 8) & 0xF
    stored_hash = entry[24:88]  # Full 64-byte hash field

    # Extract image bytes
    abs_offset = base + img_offset
    image_bytes = data[abs_offset : abs_offset + img_size]

    # Compute hash
    if hash_type == 0:
        computed = hashlib.sha256(image_bytes).digest().ljust(64, b'\x00')
    elif hash_type == 1:
        computed = hashlib.sha384(image_bytes).digest().ljust(64, b'\x00')
    elif hash_type == 2:
        computed = hashlib.sha512(image_bytes).digest()
    else:
        computed = b'\xff' * 64

    match = "OK" if computed == stored_hash else "MISMATCH"
    print(f"Image [{i}]: {match}")
    print(f"  Stored:   {stored_hash[:32].hex()}")
    print(f"  Computed: {computed[:32].hex()}")
EOF
```

---

## imx-mkimage AHAB Targets for i.MX93

### Directory and File Setup

```bash
# Clone NXP imx-mkimage
git clone https://github.com/nxp-imx/imx-mkimage.git
cd imx-mkimage
git checkout lf-6.6.3-1.0.0

# All i.MX9 inputs go in iMX9/ directory
mkdir -p iMX9

# Required files:
# From Yocto deploy or individual builds:
cp /path/to/bl31.bin                      iMX9/
cp /path/to/tee.bin                        iMX9/
cp /path/to/u-boot-spl.bin                iMX9/
cp /path/to/u-boot-nodtb.bin              iMX9/
cp /path/to/u-boot.dtb                    iMX9/

# From NXP firmware package (requires NXP account):
# https://www.nxp.com/design/software/embedded-software/i-mx-software/embedded-linux-for-i-mx-applications-processors:IMXLXSW
cp /path/to/mx93a0-ahab-container.img     iMX9/
cp /path/to/lpddr4_dmem_1d*.bin           iMX9/
cp /path/to/lpddr4_dmem_2d*.bin           iMX9/
cp /path/to/lpddr4_imem_1d*.bin           iMX9/
cp /path/to/lpddr4_imem_2d*.bin           iMX9/
cp /path/to/ddr4_*.bin                    iMX9/  # if using DDR4

# Verify all required files present
ls -la iMX9/
```

### Build Targets

```bash
# Primary target: SD card / eMMC single-boot image
make SOC=iMX9 flash_singleboot
# Produces: iMX9/flash.bin

# FlexSPI NOR flash boot image
make SOC=iMX9 flash_singleboot_flexspi
# Produces: iMX9/flash.bin (at different internal offsets)

# Check image layout printed by make:
# iMX9/flash.bin layout:
#   Offset 0x0000: empty
#   Offset 0x8000: ELE firmware container (from mx93a0-ahab-container.img)
#   Offset 0x....: OEM container (SPL + BL31 + OP-TEE + U-Boot)
#   Offset 0x....: DDR firmware
#   Offset 0x....: U-Boot SPL binary
#   Offset 0x....: TF-A BL31 binary
#   Offset 0x....: OP-TEE binary
#   Offset 0x....: U-Boot proper binary

# Print image composition (offsets of each component)
make SOC=iMX9 print_fit_hab
```

### AHAB Container Signing with CST

The OEM container within `flash.bin` must be signed. imx-mkimage does not sign the container — it assembles the unsigned container. CST signs it:

```bash
# Step 1: Build unsigned flash.bin
cd imx-mkimage
make SOC=iMX9 flash_singleboot

# Step 2: Extract offset and length of OEM container from make output
# The make output will print something like:
# "AHAB container: offset=0x9000, length=0x2800"
CONTAINER_OFFSET=0x9000  # adjust from make output
CONTAINER_LENGTH=0x2800  # adjust from make output

# Step 3: Configure CST BD file
# See ahab_container.bd example in README.md
# Key field: offset must match CONTAINER_OFFSET above

# Step 4: Sign with CST (modifies flash.bin in place)
cst --i ahab_container.bd --o iMX9/flash.bin

# Alternative: use SPSDK
nxpimage ahab export \
    --config ahab_config.yaml \
    --output iMX9/flash_signed.bin

# Step 5: Verify signed container
nxpimage ahab parse --binary iMX9/flash.bin
```

---

## SRK Key Generation: RSA Path

### RSA-2048 Key Generation (Legacy-Compatible)

RSA-2048 is compatible with i.MX8M migration workflows and is supported by HABv4-era tooling. Choose this if you need to maintain a unified signing infrastructure across i.MX8M and i.MX9 products.

```bash
# Generate 4 RSA-2048 SRK key pairs
for i in 1 2 3 4; do
    # Generate 2048-bit RSA private key
    openssl genrsa -out SRK${i}-rsa2048-key.pem 2048

    # Generate self-signed certificate (DER format also needed by srktool)
    openssl req -new -x509 \
        -key SRK${i}-rsa2048-key.pem \
        -out SRK${i}-rsa2048-cert.pem \
        -days 3650 \
        -subj "/C=DE/ST=Bavaria/O=OEM Company/OU=Security/CN=AHAB-SRK${i}"

    # Convert to DER
    openssl x509 -in SRK${i}-rsa2048-cert.pem \
        -out SRK${i}-rsa2048-cert.der -outform DER

    echo "SRK${i} generated:"
    openssl x509 -in SRK${i}-rsa2048-cert.pem -noout \
        -fingerprint -sha256 | cut -d= -f2
done

# Generate SRK table and fuse hash
srktool \
    --hab_ver 4.5 \
    --certs SRK1-rsa2048-cert.pem,SRK2-rsa2048-cert.pem,\
SRK3-rsa2048-cert.pem,SRK4-rsa2048-cert.pem \
    --table SRK_1_2_3_4_table.bin \
    --efuses SRK_1_2_3_4_fuse.bin \
    --digest sha256

# Display fuse values for programming reference
python3 << 'EOF'
import struct
data = open('SRK_1_2_3_4_fuse.bin', 'rb').read()
print("SRK fuse values (program these 8 words to OTP):")
for i in range(8):
    val = struct.unpack_from('<I', data, i*4)[0]
    print(f"  Word {i}: 0x{val:08x}")
EOF
```

### RSA-4096 Key Generation

Larger key for longer security margin. Verification is slower (important for boot-time budget).

```bash
for i in 1 2 3 4; do
    openssl genrsa -out SRK${i}-rsa4096-key.pem 4096
    openssl req -new -x509 \
        -key SRK${i}-rsa4096-key.pem \
        -out SRK${i}-rsa4096-cert.pem \
        -days 3650 \
        -subj "/C=DE/O=OEM Company/CN=AHAB-SRK${i}-RSA4096"
done

srktool \
    --hab_ver 4.5 \
    --certs SRK1-rsa4096-cert.pem,SRK2-rsa4096-cert.pem,\
SRK3-rsa4096-cert.pem,SRK4-rsa4096-cert.pem \
    --table SRK_1_2_3_4_table.bin \
    --efuses SRK_1_2_3_4_fuse.bin \
    --digest sha256
```

---

## SRK Key Generation: ECC Path

### ECDSA P-256 (Recommended for New Designs)

ECC P-256 provides equivalent security to RSA-3072 with smaller key sizes and faster signature verification. Preferred for new i.MX9 designs.

```bash
# Generate 4 ECDSA P-256 SRK key pairs
for i in 1 2 3 4; do
    # Generate P-256 (prime256v1) private key
    openssl ecparam -name prime256v1 -genkey -noout \
        -out SRK${i}-p256-key.pem

    # Generate self-signed X.509 certificate
    openssl req -new -x509 \
        -key SRK${i}-p256-key.pem \
        -out SRK${i}-p256-cert.pem \
        -days 3650 \
        -sha256 \
        -subj "/C=DE/O=OEM Company/CN=AHAB-SRK${i}-P256"

    echo "SRK${i} P-256 certificate:"
    openssl x509 -in SRK${i}-p256-cert.pem -noout -text | \
        grep -E "Public Key Algorithm|Public-Key|Subject:|Not After"
done

# Verify key type
openssl ec -in SRK1-p256-key.pem -text -noout 2>/dev/null | \
    grep "ASN1 OID"
# Should show: ASN1 OID: prime256v1

# Generate SRK table (AHAB format, not HABv4 format)
srktool \
    --hab_ver 4.5 \
    --certs SRK1-p256-cert.pem,SRK2-p256-cert.pem,\
SRK3-p256-cert.pem,SRK4-p256-cert.pem \
    --table SRK_1_2_3_4_table.bin \
    --efuses SRK_1_2_3_4_fuse.bin \
    --digest sha256

# Alternatively with SPSDK:
nxpcrypto cert get-template --output srk_config.yaml
# Edit srk_config.yaml for P-256 algorithm
nxpcrypto srk create-table \
    --certificates SRK1-p256-cert.pem SRK2-p256-cert.pem \
                   SRK3-p256-cert.pem SRK4-p256-cert.pem \
    --output-table SRK_table.bin \
    --output-fuses SRK_fuses.bin
```

### ECDSA P-521 Key Generation

P-521 provides ~260-bit security (equivalent to RSA-15360). Use only when your threat model requires post-quantum-adjacent security margins or regulatory requirements mandate it. Signature verification is measurably slower than P-256.

```bash
for i in 1 2 3 4; do
    openssl ecparam -name secp521r1 -genkey -noout \
        -out SRK${i}-p521-key.pem
    openssl req -new -x509 \
        -key SRK${i}-p521-key.pem \
        -out SRK${i}-p521-cert.pem \
        -days 3650 \
        -sha512 \
        -subj "/C=DE/O=OEM Company/CN=AHAB-SRK${i}-P521"
done

srktool \
    --hab_ver 4.5 \
    --certs SRK1-p521-cert.pem,SRK2-p521-cert.pem,\
SRK3-p521-cert.pem,SRK4-p521-cert.pem \
    --table SRK_1_2_3_4_table.bin \
    --efuses SRK_1_2_3_4_fuse.bin \
    --digest sha512
```

---

## Anti-Rollback via sw_version

The `sw_version` field in the container header enables software anti-rollback protection. ELE compares the container's `sw_version` against an OTP fuse value. If the container's `sw_version` is less than the OTP value, ELE rejects the container.

This prevents an attacker from downgrading firmware to an older version with known vulnerabilities.

```bash
# Current sw_version in container (from nxpimage parse output)
# sw_version: 3

# Current sw_version in OTP (read via U-Boot)
=> fuse read <bank> <word>  # bank/word from i.MX93 SRM

# To advance the anti-rollback counter after a security-fixing update:
# 1. Build new image with sw_version = 4 in the BD/YAML config
# 2. Deploy new image
# 3. After verifying deployment succeeded, burn the new sw_version:
=> fuse prog -y <bank> <word> 0x4

# WARNING: This is irreversible. Devices with OTP sw_version=4 will
# refuse to boot any image with container sw_version < 4.
```

---

## Authentication Event Logging

When AHAB authentication fails in OEM Open mode, ELE records events. Inspect them:

```bash
# U-Boot: display AHAB authentication events
=> ahab_status

# Expected output when no errors (OEM Closed):
# ELE Events Total Count: 0

# Example error output:
# ELE Events Total Count: 2
# ELE Event[0]:
#   CMD = ELE_AUTH_IMG (0x17)
#   IND = ELE_INVALID_SIGNATURE (0xF4)
#   ALC = 0x00
#   VINDEX = 0x00
#   MODE = 0x00
#   XSTATUS = 0x00
#
# ELE Event[1]:
#   CMD = ELE_VERIFY_IMAGE (0x1A)
#   IND = ELE_INVALID_HASH (0xF5)
#   ALC = 0x01    # Image index 1 (BL31)
#   VINDEX = 0x00

# Linux: read events via ELE driver
dmesg | grep -E "ele|ahab|ELE|AHAB" | head -20

# SPSDK: parse event codes
nxpimage ahab parse-log --binary flash.bin
```

### Common ELE Error Codes

| ELE Indicator | Code | Meaning |
|---------------|------|---------|
| `ELE_SUCCESS` | 0xD6 | Authentication successful |
| `ELE_INVALID_SIGNATURE` | 0xF4 | RSA/ECDSA signature verification failed |
| `ELE_INVALID_HASH` | 0xF5 | Image hash does not match image entry |
| `ELE_INVALID_LIFECYCLE` | 0xF7 | Operation not permitted in current lifecycle |
| `ELE_FUSE_WRITE_FAILURE` | 0xE8 | OTP programming failed |
| `ELE_INVALID_MESSAGE` | 0xFD | Malformed ELE command message |
| `ELE_BAD_KEY` | 0xF6 | Key format error or key not found |
| `ELE_ROLLBACK_DETECTED` | 0xEE | Container sw_version below OTP minimum |
| `ELE_BAD_PAYLOAD` | 0xF8 | Container header format error |

### Diagnosing Hash Mismatch (ELE_INVALID_HASH)

A hash mismatch means the image data in `flash.bin` does not match the hash stored in the corresponding image entry. Causes:

1. Image was modified after signing (most common during development)
2. imx-mkimage was re-run without re-signing
3. Flash write error caused data corruption
4. Incorrect `image_offset` in image entry

```bash
# Isolate which image has the hash mismatch from ALC field:
# ALC=0 → Image Entry [0] (typically ELE firmware)
# ALC=1 → Image Entry [1] (typically BL31)
# ALC=2 → Image Entry [2] (typically OP-TEE)
# etc.

# Re-run the hash verification script from the Inspection section above
# to identify the mismatched image
```

---

## Complete Signing Workflow Example (i.MX93, ECDSA P-256)

```bash
#!/bin/bash
set -euo pipefail
KEYDIR=/secure/keys/ahab
WORKDIR=/build/imx93
CST=/opt/cst-3.4.0/bin/cst
SPSDK=nxpimage

# 1. Build firmware components with Yocto
cd /build/yocto/build
bitbake u-boot-imx trusted-firmware-a-imx optee-os
# Deploy artifacts copied to ${WORKDIR}

# 2. Run imx-mkimage to produce unsigned flash.bin
cd /build/imx-mkimage
make SOC=iMX9 flash_singleboot 2>&1 | tee build.log
# Parse container offset from log
CONT_OFFSET=$(grep -oP "AHAB container offset: \K0x[0-9a-f]+" build.log || echo "0x9000")

# 3. Sign OEM container with SPSDK
${SPSDK} ahab export \
    --config ${KEYDIR}/ahab_imx93.yaml \
    --output iMX9/flash_signed.bin

# 4. Verify the signed container
${SPSDK} ahab parse --binary iMX9/flash_signed.bin
${SPSDK} ahab verify \
    --binary iMX9/flash_signed.bin \
    --srk-table ${KEYDIR}/SRK_1_2_3_4_table.bin

# 5. Flash to SD card (development)
sudo dd if=iMX9/flash_signed.bin of=/dev/sdX bs=1024 seek=32
# (32KB offset = 0x8000 for SD card boot)

echo "Signing complete: iMX9/flash_signed.bin"
```
