# FIT Image Debugging

## FIT Verification in U-Boot

### Expected Success Output

```
U-Boot> bootm ${fit_addr}
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ...
     kernel@1 ... sha256+ OK
     fdt@1 ... sha256+ OK
     ramdisk@1 ... sha256+ OK
   Verified OK
## Loading ramdisk from FIT Image at 40400000 ...
## Booting kernel from Legacy Image at 40480000 ...
```

### Failure: Signature Not Found

```
U-Boot> bootm ${fit_addr}
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
FIT: Not a FIT image
```

Or:
```
ERROR: signatures node not found
```

**Cause**: FIT was built without signing, or signature node is malformed.

**Diagnosis**:
```bash
# Check if FIT has signature nodes:
dumpimage -l fitImage | grep -i "sign"
# If no output: FIT was not signed

# Check if U-Boot was built with signing enabled:
grep "FIT_SIGNATURE" u-boot/.config
# CONFIG_FIT_SIGNATURE=y must be present

# Check if signature node exists in FIT:
fdtdump fitImage | grep -A5 "signature"
```

---

### Failure: Signature Check Failed

```
ERROR: Bad signature!
ERROR: FIT: configuration 'conf@1' verification failed
```

**Cause**: Signature doesn't match — wrong key, image modified after signing, or key name mismatch.

**Diagnosis**:

```bash
# Step 1: Check what key was used to sign:
dumpimage -l fitImage | grep "Sign algo"
# Sign algo:    sha256,rsa2048:fit-signing-key

# The key name (fit-signing-key) must match the .pem file in the key directory
# AND the key embedded in U-Boot DTB

# Step 2: Check key embedded in U-Boot DTB:
fdtdump u-boot.dtb | grep -B2 -A20 "signature"
# Look for: key-fit-signing-key { algo = "sha256,rsa2048"; required = "conf"; ... }

# Step 3: Verify signature manually (on host):
fit_check_sign -f fitImage -k fit-signing-key.crt
# OR:
mkimage -F fitImage -k keys/fit/ -K /dev/null -r 2>&1 | grep -E "OK|Error"

# Step 4: Was image modified after signing?
# Extract kernel from FIT and compare hash:
dumpimage -T kernel -p 0 -o /tmp/kernel-from-fit.bin fitImage
sha256sum /tmp/kernel-from-fit.bin
sha256sum Image  # Compare with original kernel binary
```

---

### Failure: Required Signature Not Found

```
ERROR: 'conf@1' requires a signature that is not found!
```

**Cause**: U-Boot has `required = "conf"` policy but FIT is unsigned.

```bash
# Check U-Boot DTB signature policy:
fdtdump u-boot.dtb | grep "required"
# required = "conf";
# This means ALL FIT images MUST be signed

# Solution: Sign the FIT image before booting
mkimage -F fitImage -k keys/fit/ -K u-boot.dtb -r
```

---

### Failure: Key Not Found in Key Directory

```
Can't open key file 'keys/fit/fit-signing-key.pem'
```

```bash
# Key name in ITS must match file basename exactly:
# key-name-hint = "fit-signing-key"  ← in ITS
# keys/fit/fit-signing-key.pem       ← must exist
# keys/fit/fit-signing-key.crt       ← must exist

# Verify:
ls -la keys/fit/
openssl rsa -in keys/fit/fit-signing-key.pem -check -noout
# RSA key ok
```

---

### Failure: DTB Padding Too Small

```
Checking hash(es) for config conf@1 ... sha256+ OK
ERROR: signatures node not found
```

```bash
# The U-Boot DTB is too small to accommodate the embedded public key
# RSA-2048 public key + DTB overhead ≈ 1500 bytes

# Fix: Rebuild U-Boot with more DTB padding
# In Yocto local.conf:
UBOOT_MKIMAGE_DTCOPTS = "-I dts -O dtb -p 4096"

# Or manually:
dtc -I dts -O dtb -p 4096 u-boot.dts -o u-boot.dtb

# Then re-embed key:
mkimage -F fitImage -k keys/fit/ -K u-boot.dtb -r
```

---

### Failure: ITS Binary Not Found

```
Error: Can't open "Image" as binary file
```

```bash
# In fitimage.its:
# data = /incbin/("Image");
# The path is RELATIVE to where mkimage is called

# Fix: run mkimage from directory containing kernel Image
cd /path/to/deploy/images/
mkimage -f fitimage.its fitimage.bin

# Or use absolute paths in ITS:
# data = /incbin/("/home/user/yocto/tmp/deploy/images/.../Image");
```

---

## Advanced: Manual FIT Verification

### Verify FIT Signature on Host

```bash
#!/bin/bash
# verify-fit.sh - Verify FIT image signature on host machine

FIT_IMAGE="$1"
CERT_FILE="$2"

if [ -z "$FIT_IMAGE" ] || [ -z "$CERT_FILE" ]; then
    echo "Usage: $0 <fitImage> <signing-cert.pem>"
    exit 1
fi

# Check FIT structure:
echo "=== FIT Image Contents ==="
dumpimage -l "$FIT_IMAGE"

# Extract signature from FIT:
echo ""
echo "=== Signature Information ==="
# Parse signature node from FIT (it's an FDT)
fdtdump "$FIT_IMAGE" 2>/dev/null | grep -A5 "signature@"

# Verify hashes manually:
echo ""
echo "=== Hash Verification ==="

# Extract kernel and verify its hash matches what FIT says:
dumpimage -T kernel -p 0 -o /tmp/kernel-check.bin "$FIT_IMAGE"
ACTUAL_HASH=$(sha256sum /tmp/kernel-check.bin | cut -d' ' -f1)
echo "Kernel SHA-256: $ACTUAL_HASH"

# Compare with hash stored in FIT:
# (fdtdump shows hash nodes)
fdtdump "$FIT_IMAGE" 2>/dev/null | grep -A3 "hash@" | grep "value"
```

### Verify U-Boot Has Key Embedded

```bash
# Extract public key modulus from U-Boot DTB:
fdtdump u-boot.dtb | grep -A20 "key-fit-signing-key" | \
    grep "rsa,modulus"

# Compare with key modulus from certificate:
openssl x509 -in keys/fit/fit-signing-key.crt -modulus -noout | \
    sed 's/Modulus=//' | tr '[:upper:]' '[:lower:]'

# The modulus values must match
```

---

## FIT Debugging Tools

```bash
# List FIT contents:
dumpimage -l fitImage

# Dump FIT as FDT (shows signature nodes):
fdtdump fitImage 2>/dev/null | head -200

# Extract component by type:
dumpimage -T kernel -p 0 -o kernel.bin fitImage
dumpimage -T flat_dt -p 0 -o board.dtb fitImage
dumpimage -T ramdisk -p 0 -o initramfs.cpio.gz fitImage

# Check U-Boot compiled with FIT support:
strings u-boot.bin | grep -E "FIT|Verified|sha256"

# U-Boot iminfo command (on target):
# => iminfo ${fit_addr}
# Shows all FIT components and their hash/signature status
```

---

## Cross-References

- [../09-fit-images/02-mkimage-reference.md](../09-fit-images/02-mkimage-reference.md) — mkimage command reference
- [../08-u-boot-secure-boot/01-fit-image-verification.md](../08-u-boot-secure-boot/01-fit-image-verification.md) — U-Boot FIT verification code
- [04-common-failure-modes.md](04-common-failure-modes.md) — Failure mode reference table
