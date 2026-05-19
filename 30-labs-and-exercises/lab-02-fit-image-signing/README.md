# Lab 02: FIT Image Signing

## Learning Objectives

After completing this lab, you can:
1. Create a minimal FIT image from an ITS source file
2. Sign a FIT image with a generated RSA key
3. Embed the public key into a U-Boot DTB
4. Verify that a tampered FIT image fails verification
5. Understand `key-name-hint` and `required = "conf"` semantics

## Prerequisites

- Lab 01 completed
- `u-boot-tools` installed: `sudo apt-get install u-boot-tools device-tree-compiler`
- Basic understanding of FIT image format (see [09-fit-images/01-its-file-format.md](../../09-fit-images/01-its-file-format.md))

---

## Setup

```bash
mkdir -p lab02 && cd lab02
mkdir -p keys payload signed
```

---

## Part 1: Generate FIT Signing Key (10 min)

```bash
# Generate RSA-2048 signing key and certificate:
openssl genrsa -out keys/lab02-fit-key.pem 2048
openssl req -new -x509 \
    -key keys/lab02-fit-key.pem \
    -out keys/lab02-fit-key.crt \
    -days 365 \
    -subj "/CN=lab02-fit-key/O=Lab/C=DE"

# Key name is the basename: "lab02-fit-key"
# This MUST match key-name-hint in the ITS file
ls keys/
# lab02-fit-key.crt  lab02-fit-key.pem
```

---

## Part 2: Create Simulated Payloads (5 min)

```bash
# In a real system, these would be kernel, DTB, ramdisk
# For this lab, use dummy files:

# "Kernel" = 64KB of zeros (represents a binary)
dd if=/dev/urandom of=payload/kernel.bin bs=1024 count=64

# "DTB" = 4KB
dd if=/dev/urandom of=payload/device.dtb bs=1024 count=4

# "Ramdisk" = 16KB
dd if=/dev/urandom of=payload/ramdisk.cpio.gz bs=1024 count=16

# Compute hashes for reference:
sha256sum payload/*
```

---

## Part 3: Create ITS File (15 min)

```bash
cat > fitimage.its << 'EOF'
/dts-v1/;

/ {
    description = "Lab02 FIT Image Signing Exercise";
    #address-cells = <1>;

    images {
        kernel@1 {
            description = "Lab Kernel";
            data = /incbin/("payload/kernel.bin");
            type = kernel;
            arch = arm64;
            os = linux;
            compression = none;
            load = <0x40480000>;
            entry = <0x40480000>;
            hash@1 {
                algo = sha256;
            };
            signature@1 {
                algo = sha256,rsa2048;
                key-name-hint = "lab02-fit-key";
            };
        };

        fdt@1 {
            description = "Lab DTB";
            data = /incbin/("payload/device.dtb");
            type = flat_dt;
            arch = arm64;
            compression = none;
            hash@1 {
                algo = sha256;
            };
        };

        ramdisk@1 {
            description = "Lab Ramdisk";
            data = /incbin/("payload/ramdisk.cpio.gz");
            type = ramdisk;
            arch = arm64;
            os = linux;
            compression = none;
            hash@1 {
                algo = sha256;
            };
        };
    };

    configurations {
        default = "conf@1";
        conf@1 {
            description = "Lab Configuration";
            kernel = "kernel@1";
            fdt = "fdt@1";
            ramdisk = "ramdisk@1";
            signature@1 {
                algo = sha256,rsa2048;
                key-name-hint = "lab02-fit-key";
                sign-images = "kernel", "fdt", "ramdisk";
            };
        };
    };
};
EOF
```

---

## Part 4: Build and Sign FIT Image (10 min)

```bash
# Step 1: Build unsigned FIT:
mkimage -f fitimage.its fitimage-unsigned.bin
echo "Unsigned FIT: $(wc -c < fitimage-unsigned.bin) bytes"

# Inspect:
dumpimage -l fitimage-unsigned.bin | grep -E "Hash|Sign"
# Hash algo:    sha256
# Sign algo:    sha256,rsa2048:lab02-fit-key
# Sign value:   unavailable  ← Not yet signed

# Step 2: Create a "U-Boot DTB" to embed the key:
# (In reality this would be the actual U-Boot DTB)
# We create a minimal DTB stub:
cat > uboot-stub.dts << 'EOF'
/dts-v1/;
/ {
    #address-cells = <1>;
    #size-cells = <1>;
    
    signature {
        /* Public key will be embedded here by mkimage */
    };
};
EOF
dtc -I dts -O dtb -p 2000 -o uboot.dtb uboot-stub.dts

# Step 3: Sign FIT and embed key in U-Boot DTB:
cp fitimage-unsigned.bin fitimage-signed.bin
mkimage -F fitimage-signed.bin \
        -k keys/ \
        -K uboot.dtb \
        -r

echo "Signing complete"

# Step 4: Inspect result:
echo ""
echo "=== Signed FIT Contents ==="
dumpimage -l fitimage-signed.bin | grep -E "Hash|Sign"

echo ""
echo "=== U-Boot DTB with Embedded Key ==="
fdtdump uboot.dtb | grep -A10 "key-lab02-fit-key"
```

---

## Part 5: Verify Signing Works (10 min)

```bash
# Simulate what U-Boot does during boot:
# (mkimage -F with no output key = just verify)

# Verify signed FIT against embedded key:
mkimage -F fitimage-signed.bin -k /dev/null 2>&1 | \
    grep -E "OK|Error|Verified"

# Better: use fit_check_sign if available:
fit_check_sign -f fitimage-signed.bin -k keys/lab02-fit-key.crt 2>&1 || true

# Or verify hash nodes manually:
echo ""
echo "Extracting and verifying kernel hash..."
dumpimage -T kernel -p 0 -o /tmp/kernel-extracted.bin fitimage-signed.bin
ACTUAL=$(sha256sum /tmp/kernel-extracted.bin | cut -d' ' -f1)
ORIGINAL=$(sha256sum payload/kernel.bin | cut -d' ' -f1)
echo "Original kernel SHA-256:  $ORIGINAL"
echo "Extracted kernel SHA-256: $ACTUAL"
[ "$ACTUAL" = "$ORIGINAL" ] && echo "MATCH: Integrity verified" || echo "MISMATCH!"
```

---

## Part 6: Demonstrate Tamper Detection (10 min)

```bash
# Copy signed FIT and tamper with it:
cp fitimage-signed.bin fitimage-tampered.bin

# Flip a bit in the kernel section (offset 1000):
python3 -c "
data = bytearray(open('fitimage-tampered.bin', 'rb').read())
data[1000] ^= 0xFF  # Flip byte at offset 1000
open('fitimage-tampered.bin', 'wb').write(data)
print('Tampered byte at offset 1000')
"

# Now try to verify tampered FIT:
echo "Verifying tampered FIT..."
mkimage -F fitimage-tampered.bin -k /dev/null 2>&1 | head -10
# Expected: error or hash mismatch

# Check if extracted kernel matches:
dumpimage -T kernel -p 0 -o /tmp/kernel-tampered.bin fitimage-tampered.bin 2>/dev/null
sha256sum /tmp/kernel-tampered.bin payload/kernel.bin
# Hashes should differ!
```

---

## Part 7: Key Name Mismatch (5 min)

```bash
# Rename the key files to simulate wrong key name:
mkdir -p keys-wrong
cp keys/lab02-fit-key.pem keys-wrong/different-key-name.pem
cp keys/lab02-fit-key.crt keys-wrong/different-key-name.crt

# Try to re-sign with wrong key name:
cp fitimage-unsigned.bin fitimage-wrongkey.bin
mkimage -F fitimage-wrongkey.bin -k keys-wrong/ -r 2>&1 | tail -5
# Expected: error about key name mismatch
# "Failed to find any key matching lab02-fit-key in keys-wrong/"
```

**Observation**: `key-name-hint` in the ITS must match the filename without extension.

---

## Cleanup and Summary

```bash
cd ..
rm -rf lab02/
```

**Key takeaways:**
1. FIT signing uses RSA private key to sign the configuration node
2. The public key is embedded in U-Boot DTB at build time
3. `key-name-hint` binds the ITS to a specific key file
4. `required = "conf"` means U-Boot will halt if FIT is unsigned
5. Tampering with any signed component causes hash mismatch → boot failure

## Next Lab

→ [lab-03-uboot-qemu](../lab-03-uboot-qemu/README.md)
