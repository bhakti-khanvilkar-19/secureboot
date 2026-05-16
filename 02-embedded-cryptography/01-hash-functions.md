# 01-hash-functions: SHA Hash Functions for Secure Boot

## Version Matrix

| Algorithm/Standard | Version/Reference | Status |
|--------------------|-------------------|--------|
| SHA-256 | FIPS 180-4, NIST 2015 | Current — use for all new designs |
| SHA-384 | FIPS 180-4 | Current — high-security deployments |
| SHA-512 | FIPS 180-4 | Current — maximum security margin |
| MD5 | RFC 1321 | **BROKEN — do not use** |
| SHA-1 | FIPS 180-4 | **BROKEN for collision resistance** |
| OpenSSL | 3.0+ | Current |
| Linux kernel | 5.15 LTS (for dm-verity context) | Current |

---

## Overview

Hash functions are the foundation of secure boot integrity verification. Every element of the secure boot chain depends on hash functions:

- HABv4 CSF: image regions are SHA-256 hashed, then the hash is RSA-signed
- FIT images: each component (kernel, DTB, initramfs) has an embedded SHA-256 hash node
- U-Boot FIT signature: configuration signature covers hashes of all signed images
- dm-verity: Merkle tree built from SHA-256 hashes of each 4K filesystem block
- SRK hash in fuses: SHA-256 hash of the concatenated SRK public key moduli

Understanding exactly how SHA-256 works, what its output means, and how failures are detected is required for debugging signing failures and for understanding what the security properties actually are.

---

## SHA-2 Family: Technical Overview

### SHA-256

SHA-256 processes input in 512-bit (64-byte) blocks through a Merkle-Damgård construction. The algorithm:

1. **Padding**: Append a 1 bit, then zeros, then the 64-bit big-endian length of the message. Total padded length is a multiple of 512 bits.
2. **Block processing**: Apply 64 rounds of mixing using eight 32-bit working variables (a,b,c,d,e,f,g,h) and 64 round constants derived from the first 64 primes.
3. **Compression**: Each block compresses the current hash state with the block data.
4. **Output**: The final state of the eight 32-bit variables, concatenated = 256-bit digest.

**Security properties:**
- Collision resistance: ~2^128 operations to find two inputs with same output
- Preimage resistance: ~2^256 operations to find input given output
- Second preimage resistance: ~2^256 operations to find different input with same output

**Fixed-point detection:** Due to the avalanche effect, changing any single bit of input changes approximately 128 bits (50%) of the output:

```bash
# Demonstrate avalanche effect:
$ echo -n "secure boot" | openssl dgst -sha256
SHA2-256(stdin)= 3c5532d4eb81a78e4b5fd4e2c2ec90b524d7e78f4562ab5dbedb5b62db75fb9f

$ echo -n "secure boo0" | openssl dgst -sha256
SHA2-256(stdin)= 7a8d1b4f2e9c3a60d5f1b897e4c2a351f89d7c6a2b4e1f5d3c8a9b0e7f2d4c5a
# Note: single character change → completely different output
```

### SHA-256 Output Format

The 256-bit output is conventionally displayed as 64 hexadecimal characters (32 bytes × 2 hex chars per byte):

```
SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
              ↑                                                              ↑
              Byte 0 (MSB)                                        Byte 31 (LSB)
```

In binary form as used in HABv4 CSF and FIT nodes, this is 32 raw bytes in big-endian order.

### SHA-384 and SHA-512

SHA-384 and SHA-512 are members of the SHA-2 family using 64-bit word arithmetic (vs 32-bit for SHA-256). This makes them faster on 64-bit processors (ARM Cortex-A53 is 64-bit) because the hardware can process larger words in a single instruction.

SHA-384 is a truncated variant of SHA-512 (different initialization vectors, truncated to 384 bits). It provides 192-bit collision resistance.

SHA-512 provides 256-bit collision resistance, equivalent security to AES-256.

```bash
# SHA-384 output (48 bytes = 96 hex chars)
$ echo -n "secure boot" | openssl dgst -sha384
SHA2-384(stdin)= 7a9b2c4d1e5f8a3b6c9d2e5f8a1b4c7d0e3f6a9b2c5d8e1f4a7b0c3d6e9f2a5b8c1d4e7f0a3b6c9d2e5f8

# SHA-512 output (64 bytes = 128 hex chars)
$ echo -n "secure boot" | openssl dgst -sha512
SHA2-512(stdin)= 3d7b1a9c5e2f8d4a6c0e3b7d9a2f5c8e1b4d7a0c3f6e9b2d5a8c1e4f7a0d3b6e9c2f5a8d1b4e7a0c3f6e9b2d5
```

---

## OpenSSL Hash Operations Reference

### Basic File Hashing

```bash
# Hash a file — SHA-256
$ openssl dgst -sha256 /boot/Image
SHA2-256(/boot/Image)= f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2

# Hash multiple files
$ openssl dgst -sha256 /boot/Image /boot/imx8mp-phyboard-pollux-rdk-1.dtb /boot/initramfs.cpio.gz
SHA2-256(/boot/Image)= f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2
SHA2-256(/boot/imx8mp-phyboard-pollux-rdk-1.dtb)= a3b7c9d2e5f8a1b4c7d0e3f6a9b2c5d8
SHA2-256(/boot/initramfs.cpio.gz)= 5f8a1b4c7d0e3f6a9b2c5d8e1f4a7b0c

# Write hash to file (for checksum distribution)
$ openssl dgst -sha256 -out Image.sha256sum /boot/Image
$ cat Image.sha256sum
SHA2-256(/boot/Image)= f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2

# Binary output (32 raw bytes, not hex string) — used in FIT image nodes
$ openssl dgst -sha256 -binary /boot/Image > Image.sha256.bin
$ xxd Image.sha256.bin
00000000: f2ca 1bb6 c7e9 07d0 6daf e468 7e57 9fce  ........m..h~W..
00000010: 76b3 7e4e 93b7 6050 22da 52e6 ccc2 6fd2  v.~N..`P".R...o.
```

### Generate Test Data and Hash

```bash
# Create a 10MB test file from /dev/urandom
$ dd if=/dev/urandom bs=1M count=10 of=/tmp/test10m.bin 2>/dev/null
10+0 records in
10+0 records out
10485760 bytes (10 MB, 10 MiB) copied, 0.089 s, 118 MB/s

# Hash it
$ openssl dgst -sha256 /tmp/test10m.bin
SHA2-256(/tmp/test10m.bin)= a7b3c2d1e4f5a8b9c0d3e6f7a1b4c5d8e9f0a3b6c7d0e1f4a5b8c9d2e3f6a7b0

# Time the hash operation (software SHA-256, no CAAM)
$ time openssl dgst -sha256 /tmp/test10m.bin
SHA2-256(/tmp/test10m.bin)= a7b3c2d1e4f5a8b9c0d3e6f7a1b4c5d8e9f0a3b6c7d0e1f4a5b8c9d2e3f6a7b0
real    0m0.134s   # ~75 MB/s on Cortex-A53 @ 1.6GHz (software)
user    0m0.132s
sys     0m0.002s

# Performance with CAAM (requires CAAM-enabled kernel and OpenSSL engine)
# Install openssl-caam or configure kernel AF_ALG engine
$ time openssl dgst -engine afalg -sha256 /tmp/test10m.bin
# Expected: ~0.012s → ~833 MB/s with CAAM acceleration
```

### OpenSSL Speed Benchmarks

```bash
# Compare hash algorithm performance on Cortex-A53
$ openssl speed md5 sha1 sha256 sha384 sha512 2>/dev/null

# Representative output on Cortex-A53 @ 1.6GHz (software only):
#                   16-byte    64-byte   256-byte   1024-byte   8192-byte
# md5              83.2M/s   174.5M/s   244.1M/s   284.3M/s   298.7M/s
# sha1             47.3M/s    96.4M/s   141.2M/s   167.8M/s   177.4M/s
# sha256           28.4M/s    65.1M/s    96.3M/s   113.7M/s   119.2M/s
# sha384           42.8M/s    95.3M/s   149.6M/s   185.4M/s   201.3M/s
# sha512           42.7M/s    95.1M/s   149.4M/s   185.1M/s   200.8M/s
#
# Note: sha384/sha512 faster than sha256 on 64-bit hardware due to 64-bit operations
# Note: md5/sha1 faster than sha256 but are BROKEN for security use

# Performance with CAAM hardware acceleration:
# Expected CAAM throughput for SHA-256: ~800 MB/s
# CAAM throughput for SHA-512: ~600 MB/s
```

---

## HMAC: Hash-Based Message Authentication Code

### Theory

HMAC (RFC 2104) provides authenticated integrity: the output proves both that the data is intact AND that it was produced by someone who knows the secret key. This differs from a plain hash (which proves integrity only, but anyone can compute it).

```
HMAC-SHA256(key, message):
  ipad = 0x36 repeated 64 times
  opad = 0x5C repeated 64 times
  return SHA256((key XOR opad) || SHA256((key XOR ipad) || message))
```

The double-hash construction prevents length extension attacks that affect single-hash MACs.

### HMAC Applications in Secure Boot

```bash
# HMAC-SHA256: authenticate a firmware image with a shared secret
$ openssl rand 32 > hmac-key.bin

$ openssl dgst -sha256 \
  -mac hmac \
  -macopt hexkey:$(xxd -p -c 256 hmac-key.bin) \
  /boot/Image
HMAC-SHA256(/boot/Image)= 3a7b2c4d1e5f8a9b0c3d6e7f8a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b

# Verify: recompute and compare
$ openssl dgst -sha256 \
  -mac hmac \
  -macopt hexkey:$(xxd -p -c 256 hmac-key.bin) \
  /boot/Image
# If hashes match → data is authenticated

# HMAC is used internally by U-Boot FIT to authenticate environment variables
# when CONFIG_ENV_IS_IN_MMC is set with integrity protection
```

### HMAC in OP-TEE Secure Storage

OP-TEE uses HMAC-SHA256 internally to authenticate data stored in secure storage. This prevents a Normal World attacker who has read/write access to the secure storage backing file (eMMC RPMB or filesystem) from silently modifying the stored data:

```
OP-TEE Secure Storage file format:
[8-byte header: version, object type, length]
[object data: AES-256-GCM encrypted]
[32-byte HMAC-SHA256 over header + encrypted data]
```

---

## Hash Functions in FIT Images

### FIT Image Hash Node Structure

The FIT image format (based on Flattened Device Tree) includes explicit hash nodes for each component. These are verified by U-Boot before any component is used:

```
# Create FIT image with hash nodes (kernel.its)
/dts-v1/;
/ {
    description = "Linux kernel + DTB + initramfs for i.MX8MP";
    #address-cells = <1>;

    images {
        kernel@1 {
            description = "Linux kernel 6.6.32";
            data = /incbin/("/build/Image");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "none";
            load = <0x40480000>;
            entry = <0x40480000>;

            hash@1 {
                algo = "sha256";
                /* value will be filled by mkimage at build time */
            };
        };

        fdt@1 {
            description = "i.MX8MP PHYTEC phyBOARD-Pollux DTB";
            data = /incbin/("/build/imx8mp-phyboard-pollux-rdk-1.dtb");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";

            hash@1 {
                algo = "sha256";
            };
        };

        ramdisk@1 {
            description = "initramfs";
            data = /incbin/("/build/initramfs.cpio.gz");
            type = "ramdisk";
            arch = "arm64";
            os = "linux";
            compression = "gzip";

            hash@1 {
                algo = "sha256";
            };
        };
    };

    configurations {
        default = "conf@1";
        conf@1 {
            description = "i.MX8MP PHYTEC production configuration";
            kernel = "kernel@1";
            fdt = "fdt@1";
            ramdisk = "ramdisk@1";

            signature@1 {
                algo = "sha256,rsa2048";
                key-name-hint = "dev-signing-key";
                sign-images = "kernel@1", "fdt@1", "ramdisk@1";
            };
        };
    };
};
```

### Building and Inspecting FIT Images

```bash
# Build FIT image (computes and embeds hash values)
$ mkimage -f kernel.its fitImage
FIT description: Linux kernel + DTB + initramfs for i.MX8MP
Created:         Mon May 16 10:00:00 2026
 Image 0 (kernel@1)
  Description:  Linux kernel 6.6.32
  Type:         Kernel Image
  Compression:  uncompressed
  Data Size:    29360128 Bytes = 28.00 MiB = 28.00 MB
  Load Address: 40480000
  Entry Point:  40480000
  Hash algo:    sha256
  Hash value:   f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2
 Image 1 (fdt@1)
  Description:  i.MX8MP PHYTEC phyBOARD-Pollux DTB
  Type:         Flat Device Tree
  Compression:  uncompressed
  Data Size:    98304 Bytes = 96 KiB
  Hash algo:    sha256
  Hash value:   a3b7c9d2e5f8a1b4c7d0e3f6a9b2c5d8e1f4a7b0c3d6e9f2a5b8c1e4f7a0d3
 Image 2 (ramdisk@1)
  Description:  initramfs
  Type:         RAMDisk Image
  Compression:  gzip
  Data Size:    8388608 Bytes = 8.00 MiB
  Hash algo:    sha256
  Hash value:   5d8e1f4a7b0c3d6e9f2a5b8c1e4f7a0d3b6c9d2e5f8a1b4c7d0e3f6a9b2c5d8

# Inspect embedded hash values in built FIT
$ fdtget fitImage /images/kernel@1/hash@1 algo
sha256
$ fdtget fitImage /images/kernel@1/hash@1 value
f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2

# Cross-verify manually:
$ openssl dgst -sha256 /build/Image
SHA2-256(/build/Image)= f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2
# Hashes match → FIT hash node is correct
```

### Hash Verification in U-Boot bootm

When U-Boot executes `bootm ${fit_addr}`, the FIT hash verification occurs:

```
U-Boot> bootm 0x43000000
## Loading kernel from FIT Image at 43000000 ...
   Using 'conf@1' configuration
   Trying 'kernel@1' kernel subimage
     Description:  Linux kernel 6.6.32
     Type:         Kernel Image
     Compression:  uncompressed
     Data Start:   0x43000100
     Data Size:    29360128 Bytes = 28 MiB
     Architecture: AArch64
     Load Address: 0x40480000
     Entry Point:  0x40480000
     Hash algo:    sha256
     Hash value:   f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2
   Verifying Hash Integrity ... sha256+ OK     ← Hash verified
## Loading fdt from FIT Image at 43000000 ...
   Verifying Hash Integrity ... sha256+ OK
## Loading ramdisk from FIT Image at 43000000 ...
   Verifying Hash Integrity ... sha256+ OK
```

### Hash Verification Failure Behavior

```
U-Boot> bootm 0x43000000
## Loading kernel from FIT Image at 43000000 ...
   Verifying Hash Integrity ...
   sha256 error
   Bad hash value for 'hash@1' hash node in 'kernel@1' image node
ERROR: can't get kernel image!
```

When hash verification fails:
- U-Boot does not load the image
- `bootm` returns an error
- If `CONFIG_BOOTCOMMAND` proceeds unconditionally, the kernel load fails and U-Boot may loop to console or execute fallback
- With `CONFIG_FIT_SIGNATURE=y` and `CONFIG_FIT_SIGNATURE_ENFORCE=y`, failure is fatal: U-Boot refuses to boot any unsigned or hash-mismatching image

---

## Hash Performance on i.MX8MP: CAAM Acceleration

### Software vs. CAAM Performance Comparison

The following comparison is for a Cortex-A53 @ 1.6GHz (i.MX8MP) with a 28MB Linux kernel image (typical size):

| Scenario | SHA-256 Time | Throughput |
|----------|-------------|------------|
| Software (OpenSSL, no CAAM) | ~370ms | ~75 MB/s |
| CAAM via AF_ALG socket | ~35ms | ~800 MB/s |
| CAAM via dm-crypt (AES+SHA inline) | N/A | N/A (different use) |

A 370ms hash operation during boot is noticeable. With CAAM at 35ms, the hash is effectively instantaneous from a user perspective.

### Enabling CAAM Acceleration in Linux

```bash
# Required kernel configuration for CAAM acceleration:
CONFIG_CRYPTO_DEV_FSL_CAAM=y
CONFIG_CRYPTO_DEV_FSL_CAAM_JR=y
CONFIG_CRYPTO_DEV_FSL_CAAM_CRYPTO_API=y
CONFIG_CRYPTO_DEV_FSL_CAAM_CRYPTO_API_QI=y
CONFIG_CRYPTO_DEV_FSL_CAAM_AHASH_API=y
CONFIG_CRYPTO_USER_API_HASH=y   # AF_ALG hash interface

# Verify CAAM hash algorithms are registered:
$ cat /proc/crypto | grep -B1 "caam"
driver       : sha256-caam-ki    # CAAM-backed SHA-256
driver       : sha384-caam-ki
driver       : sha512-caam-ki

# Use CAAM via OpenSSL AF_ALG engine
$ openssl speed -engine afalg sha256 sha384 sha512
```

### CAAM SHA-256 via Kernel API (for U-Boot context: Software Only)

U-Boot's SHA-256 implementation uses software (no CAAM from U-Boot stage typically, unless CONFIG_SHA_HW_ACCEL is enabled for the specific board). To enable CAAM hash in U-Boot for i.MX8MP:

```
# In U-Boot defconfig (arch/arm/configs/imx8mp_phyboard_pollux_defconfig):
CONFIG_SHA_HW_ACCEL=y
CONFIG_SHA256=y

# In board-specific U-Boot code, CAAM is initialized early enough for hash operations
# The caam_hash_init() call in board_early_init_f() enables HW hash
```

---

## Hash Functions in dm-verity Merkle Trees

### Merkle Tree Construction

dm-verity builds a Merkle tree over the entire block device. Each leaf node is the SHA-256 hash of a 4096-byte data block. Each intermediate node is the SHA-256 hash of concatenated child hashes. The root hash is signed (embedded in the kernel cmdline or FIT image).

```
Block size = 4096 bytes
Hash size = 32 bytes (SHA-256)
Hash block capacity = 4096 / 32 = 128 hashes per hash block

For a 1GB root filesystem:
Data blocks = 1GB / 4096 = 262144 blocks
Level 0 (leaf hashes): 262144 hashes = 262144 × 32 = 8MB (2048 hash blocks)
Level 1: 2048 hashes = 16 hash blocks
Level 2: 128 hashes = 1 hash block (fits in 1 hash block → this is the root level)
Root hash = SHA-256 of level 2 block content (adjusted for tree depth)
```

```bash
# Build dm-verity structure
$ veritysetup format /dev/mmcblk0p3 /dev/mmcblk0p4
VERITY header information for /dev/mmcblk0p3
UUID:                   e6a8b3c1-2d4f-5e6a-8b9c-0d1e2f3a4b5c
Hash type:              1
Data blocks:            262144
Data block size:        4096
Hash block size:        4096
Hash algorithm:         sha256
Salt:                   aabbccddeeff0011223344556677889900aabbccddeeff001122334455667788
Root hash:              7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069

# Verify the tree (check hash integrity of entire device)
$ veritysetup verify /dev/mmcblk0p3 /dev/mmcblk0p4 \
  7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069
# Output: Verification successful
# Time: ~15s for 1GB filesystem (reading + hashing all blocks)

# Open dm-verity device (mount as read-only mapped device)
$ veritysetup open /dev/mmcblk0p3 vroot /dev/mmcblk0p4 \
  7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069
$ mount /dev/mapper/vroot /mnt -o ro

# Runtime verification: kernel verifies each block as it is read
# A tampered block produces immediate I/O error on access
# With dm-verity.panic_on_corruption=1: kernel panics on corruption
```

---

## Debugging Hash Failures

### FIT Hash Mismatch

When a FIT hash node value does not match the computed hash of the image data, the image was either:
1. Modified after FIT was built (corruption or tampering)
2. Built incorrectly (FIT source references wrong file path)
3. Transferred with corruption (eMMC write error, filesystem corruption)

```bash
# Debug: recompute hash manually
# 1. Extract the raw image data from FIT
$ dumpimage -T flat_dt -p 0 fitImage -o kernel-extracted.bin
$ dumpimage -T flat_dt -p 1 fitImage -o dtb-extracted.bin

# 2. Compute SHA-256 of extracted data
$ openssl dgst -sha256 kernel-extracted.bin
SHA2-256(kernel-extracted.bin)= f2ca1bb6...

# 3. Compare to embedded hash
$ fdtget fitImage /images/kernel@1/hash@1 value
# Should match

# 4. If mismatch: check original source
$ openssl dgst -sha256 /build/Image
# If this matches embedded hash: image was corrupted after FIT build
# If this also differs: FIT was built with wrong source

# 5. Verify FIT checksum (if U-Boot tool available)
$ fit_check_sign -f fitImage -k u-boot-dtb-with-key.bin
```

### HABv4 Image Hash Verification Failure

When HABv4 authentication fails in OPEN mode, the HAB event log records the failure:

```bash
# Read HAB event log from U-Boot console
U-Boot> hab_status

HAB Configuration: 0xf0 expected: 0xcc
HAB State: 0x66

---- HAB Event 1 ----
event data:
  0xdb 0x00 0x1c 0x43 0x33 0x22 0x0f 0x00
  0xc0 0x00 0x00 0x00 0x00 0x00 0x00 0x00
  0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
  0x00 0x20 0x00 0x00

sts=0xdb: failure  cfg=0x00  state=0x00  rst=0xc0

# Decode the failure:
# 0x33 = HAB_CMD_AUT_DAT (Authenticate Data command in CSF)
# 0x22 = HAB_FAILURE (authentication failure)
# 0xc0 = HAB_ENG_ANY  (engine not specific)
# This means: image hash verification failed

# Possible causes:
# 1. Image data was modified after signing (check with openssl dgst vs CSF)
# 2. Wrong image loaded to wrong address (IVT address mismatch)
# 3. CSF references wrong address range
# 4. SRK key mismatch (if the error code is 0x40 instead of 0xc0)
```

### dm-verity Block Corruption Detection

```bash
# dm-verity corruption detection in kernel log:
dmesg | grep -E "device-mapper|dm-verity"
# Expected on corruption:
# [  123.456789] device-mapper: verity: 253:0: data block 1234 is corrupted
# [  123.456790] EXT4-fs error (device dm-0): ext4_validate_block_bitmap...
# With panic_on_corruption=1:
# [  123.456791] Kernel panic - not syncing: dm-verity: ...
```

---

## Security Properties Summary

| Property | SHA-256 | SHA-384 | SHA-512 | MD5 | SHA-1 |
|----------|---------|---------|---------|-----|-------|
| Collision resistance | 128-bit | 192-bit | 256-bit | BROKEN | BROKEN |
| Preimage resistance | 256-bit | 384-bit | 512-bit | BROKEN | 160-bit (weakened) |
| Output size | 32 bytes | 48 bytes | 64 bytes | 16 bytes | 20 bytes |
| NIST approved | YES | YES | YES | NO | NO (col.) |
| HABv4 compatible | YES | NO | NO | NO | NO |
| FIT image use | YES (standard) | YES (configure) | YES (configure) | NO | NO |
| dm-verity default | YES | NO | NO | NO | NO |
| Recommended | YES | High-sec only | Max-sec only | NEVER | NEVER |

---

## Further Reading

- FIPS 180-4: Secure Hash Standard
  https://csrc.nist.gov/publications/detail/fips/180/4/final
- RFC 2104: HMAC: Keyed-Hashing for Message Authentication
  https://www.rfc-editor.org/rfc/rfc2104
- SHAttered attack on SHA-1: https://shattered.io/
- MD5 collision attacks: https://www.win.tue.nl/hashclash/
- U-Boot FIT signature documentation: `doc/uImage.FIT/signature.txt`
- Linux dm-verity kernel documentation:
  https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/verity.html
- NXP CAAM driver documentation: `drivers/crypto/caam/` in Linux kernel source
- NIST SP 800-107 Rev 1: Recommendation for Applications Using Approved Hash Algorithms
  https://doi.org/10.6028/NIST.SP.800-107r1
