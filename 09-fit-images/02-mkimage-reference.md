# mkimage Command Reference

## Installation

```bash
# Ubuntu/Debian
sudo apt-get install u-boot-tools

# Verify
mkimage --version
# mkimage version 2023.04
```

## Commands

### Create Unsigned FIT

```bash
# Build FIT from ITS source file
mkimage -f fitimage.its fitimage.bin

# Output:
# Image Name:   phyCORE-i.MX8MP Production Secure Boot Image
# Created:      Thu Jan 16 10:23:45 2024
# Image Type:   Flat Image Tree (uncompressed)
# Data Size:    22847032 Bytes = 21.8 MiB = 22.8 MB
# Load Address: unavailable
# Entry Point:  unavailable
# Hash algo:    sha256
# Hash value:   unavailable
```

### Sign Existing FIT

```bash
# -F: modify FIT file in-place
# -k: directory containing key files (*.pem and *.crt)
# -r: mark signatures as REQUIRED (verification enforced)
mkimage -F fitimage.bin -k keys/ -r

# Output:
# Signing images...
#  fit,sha256+rsa2048:fit-signing-key against fitimage.bin... OK
# Verified OK
```

### Sign FIT and Embed Key in U-Boot DTB

```bash
# -K: destination DTB to embed the public key
# This DTB must be used when building U-Boot
mkimage -F fitimage.bin -k keys/ -K u-boot.dtb -r

# After this:
# - fitimage.bin: signed, contains signature node
# - u-boot.dtb: contains /signature/key-fit-signing-key node with public key
```

### Create FIT with Embedded Key in One Step

```bash
# Build FIT, sign it, and embed key in U-Boot DTB simultaneously
mkimage -f fitimage.its \
        -k keys/ \
        -K u-boot.dtb \
        -r \
        fitimage.bin
```

### Inspect FIT Contents

```bash
dumpimage -l fitimage.bin

# Output:
# FIT description: phyCORE-i.MX8MP Production Secure Boot Image
# Created:         Thu Jan 16 10:23:45 2024
# Image 0 (kernel@1)
#  Description:  Linux Kernel 6.6.0
#  Created:      Thu Jan 16 10:23:45 2024
#  Type:         Kernel Image (no loading done)
#  Compression:  uncompressed
#  Data Start:   0x000000b4
#  Data Size:    20971520 Bytes = 20.0 MiB
#  Architecture: AArch64
#  OS:           Linux
#  Load Address: 0x40480000
#  Entry Point:  0x40480000
#  Hash algo:    sha256
#  Hash value:   abc123def456...
#  Sign algo:    sha256,rsa2048:fit-signing-key
#  Sign value:   f9e8d7c6...
# Image 1 (fdt@1)
#  ...
# Default Configuration: 'conf@1'
# Configuration 0 (conf@1)
#  Description:  phyCORE-i.MX8MP Secure Boot (SOM)
#  Kernel:       kernel@1
#  Init Ramdisk: ramdisk@1
#  FDT:          fdt@1
#  Sign algo:    sha256,rsa2048:fit-signing-key
#  Sign value:   a1b2c3d4...
#  Timestamp:    Thu Jan 16 10:23:45 2024
```

### Extract Component from FIT

```bash
# Extract kernel image (position 0)
dumpimage -T kernel -p 0 -o extracted-kernel.bin fitimage.bin

# Extract first DTB
dumpimage -T flat_dt -p 0 -o extracted.dtb fitimage.bin

# Extract ramdisk
dumpimage -T ramdisk -p 0 -o extracted.cpio.gz fitimage.bin
```

---

## Key Directory Structure

```
keys/
├── fit-signing-key.pem    # RSA-2048 private key (PEM format)
└── fit-signing-key.crt    # Self-signed X.509 certificate (PEM format)
```

**Important:** The file basename (without extension) must match `key-name-hint` in the ITS file.

Generating the key pair:
```bash
mkdir -p keys

# Generate RSA-2048 private key
openssl genrsa -out keys/fit-signing-key.pem 2048

# Generate self-signed certificate
openssl req -new -x509 \
    -key keys/fit-signing-key.pem \
    -out keys/fit-signing-key.crt \
    -days 3650 \
    -subj "/CN=FIT Signing Key/O=PHYTEC/C=DE"

# Verify
openssl x509 -in keys/fit-signing-key.crt -text -noout | grep -E "Subject:|Not After"
```

---

## Common Errors

### Error: ITS file not found
```
Error: Can't open fitimage.its: No such file or directory
```
Fix: Verify path to ITS file, check working directory.

### Error: Binary file not found
```
Can't open "Image" as binary file
```
Fix: Ensure kernel `Image` binary exists in current directory, or use full path in `/incbin/()`.

### Error: Key not found
```
Can't open key file 'keys/fit-signing-key.pem'
```
Fix: Verify `keys/` directory exists with matching `.pem` file.

### Error: Key name mismatch
```
Signing fit,sha256+rsa2048:fit-signing-key against fitimage.bin...
Failed to find any key in keys/
```
Fix: `key-name-hint` in ITS must match filename (without `.pem`) exactly.

### Error: DTB too small for key
```
Checking hash(es) for config conf@1 ... sha256+ OK
ERROR: signatures node not found
```
Fix: Use `-p 2000` or larger padding when creating U-Boot DTB:
```bash
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 2000"
```

---

## Padding Considerations

The U-Boot DTB needs padding to accommodate the embedded public key (~1KB+):

```bash
# In Yocto (local.conf):
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 2000"
# -p 2000: add 2000 bytes of padding (enough for RSA-2048 key)
```

Without sufficient padding, the DTB cannot be modified to add the key node.
