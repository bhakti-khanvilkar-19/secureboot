# Lab 03: U-Boot FIT Verification in QEMU

## Learning Objectives

After completing this lab, you can:
1. Build U-Boot with FIT signature verification enabled
2. Run U-Boot in QEMU (ARM64)
3. Boot a signed FIT image and observe the verification output
4. Observe boot failure when loading an unsigned FIT
5. Understand the `required = "conf"` lockdown effect

## Prerequisites

- Lab 02 completed
- QEMU ARM64: `sudo apt-get install qemu-system-arm`
- U-Boot build dependencies: `sudo apt-get install gcc-aarch64-linux-gnu flex bison bc`

---

## Part 1: Build U-Boot with FIT Signing (30 min)

```bash
mkdir -p lab03 && cd lab03

# Clone U-Boot:
git clone https://github.com/u-boot/u-boot.git --depth=1 -b v2024.01
cd u-boot

# Use qemu_arm64 defconfig as base:
make ARCH=arm CROSS_COMPILE=aarch64-linux-gnu- qemu_arm64_defconfig

# Enable FIT signature verification:
cat >> .config << 'EOF'
CONFIG_FIT=y
CONFIG_FIT_SIGNATURE=y
CONFIG_FIT_VERBOSE=y
CONFIG_RSA=y
CONFIG_RSA_SOFTWARE_EXP=y
CONFIG_SPL_FIT_SIGNATURE=n
EOF

# Rebuild config:
make ARCH=arm CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# Build U-Boot:
make ARCH=arm CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) 2>&1 | tail -20

# Output:
ls u-boot.bin u-boot.dtb
cd ..
```

---

## Part 2: Generate FIT Key and Embed in U-Boot DTB (15 min)

```bash
# Generate FIT signing key:
mkdir -p keys
openssl genrsa -out keys/lab03-key.pem 2048
openssl req -new -x509 \
    -key keys/lab03-key.pem \
    -out keys/lab03-key.crt \
    -days 365 \
    -subj "/CN=lab03-key/O=Lab/C=DE"

# Prepare U-Boot DTB with padding for key embedding:
cp u-boot/u-boot.dtb u-boot-with-key.dtb

# Build a simple FIT image to force key embedding:
cat > embed-key.its << 'EOF'
/dts-v1/;
/ {
    images { dummy@1 { data = <0>; type = kernel; arch = arm64; os = linux; compression = none; load = <0>; entry = <0>; }; };
    configurations { default = "c@1"; c@1 { kernel = "dummy@1"; signature@1 { algo = sha256,rsa2048; key-name-hint = "lab03-key"; sign-images = "kernel"; }; }; };
};
EOF

mkimage -f embed-key.its dummy.fit
mkimage -F dummy.fit -k keys/ -K u-boot-with-key.dtb -r 2>/dev/null || true

# Verify key is embedded in DTB:
fdtdump u-boot-with-key.dtb 2>/dev/null | grep "key-lab03-key"
# key-lab03-key {   ← Key embedded!
```

---

## Part 3: Create a Signed Test FIT Image (10 min)

```bash
# Create dummy "kernel" binary (simple ARM64 infinite loop):
python3 -c "
# ARM64 NOP instruction: 0xD503201F
import struct
# Write 4KB of NOPs
data = struct.pack('<I', 0xD503201F) * 1024
open('test-kernel.bin', 'wb').write(data)
print('Wrote 4KB test kernel')
"

# Create test FIT ITS:
cat > test.its << 'EOF'
/dts-v1/;
/ {
    description = "Lab03 Test FIT";
    #address-cells = <1>;
    images {
        kernel@1 {
            description = "Test Kernel";
            data = /incbin/("test-kernel.bin");
            type = kernel;
            arch = arm64;
            os = linux;
            compression = none;
            load = <0x40480000>;
            entry = <0x40480000>;
            hash@1 { algo = sha256; };
            signature@1 { algo = sha256,rsa2048; key-name-hint = "lab03-key"; };
        };
    };
    configurations {
        default = "conf@1";
        conf@1 {
            description = "Test Config";
            kernel = "kernel@1";
            signature@1 { algo = sha256,rsa2048; key-name-hint = "lab03-key"; sign-images = "kernel"; };
        };
    };
};
EOF

mkimage -f test.its test-signed.fit
mkimage -F test-signed.fit -k keys/ -r
echo "Signed FIT created: $(wc -c < test-signed.fit) bytes"

# Also create an unsigned version for comparison:
mkimage -f test.its test-unsigned.fit
```

---

## Part 4: Boot in QEMU and Observe Verification (20 min)

```bash
# Create flash image for QEMU (64MB):
dd if=/dev/zero of=flash.bin bs=1M count=64

# Write U-Boot at start:
dd if=u-boot/u-boot.bin of=flash.bin conv=notrunc

# Write signed FIT at offset 4MB:
dd if=test-signed.fit of=flash.bin bs=1M seek=4 conv=notrunc

# Write unsigned FIT at offset 8MB:
dd if=test-unsigned.fit of=flash.bin bs=1M seek=8 conv=notrunc

# Boot U-Boot in QEMU:
qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a53 \
    -m 1024 \
    -nographic \
    -bios u-boot/u-boot.bin \
    -drive if=none,file=flash.bin,format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -serial stdio \
    2>&1 | head -50 &

QEMU_PID=$!
sleep 5

echo ""
echo "U-Boot should be at prompt. In the QEMU terminal, run:"
echo "  => load virtio 0:0 0x40400000 fitimage"
echo "  => bootm 0x40400000"
echo ""
echo "Expected output for signed FIT:"
echo "  Verifying Hash Integrity ... sha256+ OK"
echo "  Verified OK"
echo ""
echo "Expected output for unsigned FIT:"
echo "  ERROR: 'conf@1' requires a signature that is not found!"
```

---

## Part 5: Observe Lockdown Effect (10 min)

When `required = "conf"` is set in the embedded key (in the U-Boot DTB), U-Boot will:
- Accept: FIT signed with the embedded key
- Reject: Unsigned FIT (even if hashes are present)
- Reject: FIT signed with a different key

```
Expected terminal output:

--- Signed FIT ---
=> bootm 0x40400000
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ...
     kernel@1 ... sha256+ OK
   Verified OK
## Booting kernel from FIT at ...
Starting kernel ...

--- Unsigned FIT ---
=> bootm 0x40480000
## Loading kernel from FIT Image at 40480000 ...
   Using 'conf@1' configuration
ERROR: 'conf@1' requires a signature that is not found!
```

---

## Cleanup

```bash
kill $QEMU_PID 2>/dev/null
cd ..
rm -rf lab03/
```

## Next Lab

→ [lab-04-hab-simulation](../lab-04-hab-simulation/README.md)
