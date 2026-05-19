# Lab 08: dm-verity on Real Hardware

## Learning Objectives

After completing this lab, you can:
1. Create a dm-verity protected ext4 partition using `veritysetup`
2. Mount and verify the protection is active
3. Demonstrate that block-level tampering is detected
4. Integrate dm-verity activation into an initramfs script
5. Pass the correct root hash in kernel cmdline

## Prerequisites

- Embedded Linux board (i.MX8MP or any ARM64 board)
- At least 256MB free on a block device (or use a loopback file)
- Root access on the board
- `cryptsetup` (which includes `veritysetup`) installed

---

## Part 1: Setup with Loopback Device (No Hardware Required) (15 min)

```bash
# This part works on any Linux machine

# Create a 64MB "rootfs" image:
dd if=/dev/urandom of=rootfs.raw bs=1M count=64

# Format as ext4 (no journal — verity rootfs is read-only):
mkfs.ext4 -L lab08-rootfs -O "^has_journal" -b 4096 rootfs.raw

# Mount and populate:
mkdir -p /tmp/lab08-rootfs
mount -o loop rootfs.raw /tmp/lab08-rootfs

# Create some test content:
echo "Test file 1" > /tmp/lab08-rootfs/test1.txt
echo "Test file 2" > /tmp/lab08-rootfs/test2.txt
mkdir -p /tmp/lab08-rootfs/usr/bin
echo "#!/bin/sh" > /tmp/lab08-rootfs/usr/bin/myapp
echo "echo 'App running'" >> /tmp/lab08-rootfs/usr/bin/myapp
chmod +x /tmp/lab08-rootfs/usr/bin/myapp

# Count total blocks:
TOTAL_BLOCKS=$(df -B 4096 /tmp/lab08-rootfs | tail -1 | awk '{print $2}')
echo "Total blocks: $TOTAL_BLOCKS"

umount /tmp/lab08-rootfs
```

---

## Part 2: Generate dm-verity Hash Tree (10 min)

```bash
# Generate hash tree and get root hash:
veritysetup format \
    --data-block-size=4096 \
    --hash-block-size=4096 \
    rootfs.raw \
    rootfs.verity 2>&1 | tee verity-params.txt

# Save root hash:
ROOT_HASH=$(grep "Root hash:" verity-params.txt | awk '{print $3}')
SALT=$(grep "Salt:" verity-params.txt | awk '{print $2}')

echo "Root hash: $ROOT_HASH"
echo "Salt:      $SALT"

# Inspect the verity header:
veritysetup dump rootfs.verity

# Check verity file size (this is the hash tree):
ls -la rootfs.raw rootfs.verity
echo "Hash tree overhead: $(wc -c < rootfs.verity) bytes"
```

---

## Part 3: Activate and Test dm-verity (15 min)

```bash
# Setup loop devices:
LOOP_DATA=$(losetup -f)
losetup $LOOP_DATA rootfs.raw

LOOP_HASH=$(losetup -f)
losetup $LOOP_HASH rootfs.verity

echo "Data device: $LOOP_DATA"
echo "Hash device: $LOOP_HASH"

# Activate dm-verity:
veritysetup create \
    lab08-vroot \
    $LOOP_DATA \
    $LOOP_HASH \
    $ROOT_HASH

# Check device is active:
dmsetup status lab08-vroot
# Expected output:
# lab08-vroot: 0 131072 verity V sha256 /dev/loop0 /dev/loop1 ...

# Mount read-only:
mkdir -p /tmp/lab08-verified
mount -o ro /dev/mapper/lab08-vroot /tmp/lab08-verified

# Verify content:
cat /tmp/lab08-verified/test1.txt
# Test file 1

# Try to write (must fail):
echo "evil" > /tmp/lab08-verified/evil.txt 2>&1
# touch: cannot touch '/tmp/lab08-verified/evil.txt': Read-only file system

echo "dm-verity active and read-only enforced!"
```

---

## Part 4: Demonstrate Block-Level Tampering Detection (15 min)

```bash
# First, unmount and deactivate:
umount /tmp/lab08-verified
veritysetup close lab08-vroot

# Tamper with the raw data device (bypass filesystem):
python3 << 'PYEOF'
with open('rootfs.raw', 'r+b') as f:
    # Find and modify "Test file 1" in the data
    data = f.read()
    pos = data.find(b'Test file 1')
    if pos != -1:
        f.seek(pos)
        f.write(b'EVIL_FILE_1')
        print(f"Tampered at offset {pos}")
    else:
        print("Pattern not found, tampering at offset 4096")
        f.seek(4096)
        f.write(b'\xFF' * 100)
PYEOF

# Re-activate dm-verity (with the same root hash):
veritysetup create \
    lab08-vroot \
    $LOOP_DATA \
    $LOOP_HASH \
    $ROOT_HASH

# Try to read from the tampered block:
mount -o ro /dev/mapper/lab08-vroot /tmp/lab08-verified 2>&1 || true
cat /tmp/lab08-verified/test1.txt 2>&1
# Expected: Input/output error (or contents may be wrong and dmesg shows error)

# Check kernel log:
dmesg | tail -5 | grep -i "dm-verity\|I/O error"
# dm-verity: /dev/loop0: data block X is corrupted

echo ""
echo "Tampered block detected! dm-verity caught the modification."
```

---

## Part 5: Cleanup

```bash
umount /tmp/lab08-verified 2>/dev/null || true
veritysetup close lab08-vroot 2>/dev/null || true
losetup -d $LOOP_HASH 2>/dev/null || true
losetup -d $LOOP_DATA 2>/dev/null || true

rm -rf rootfs.raw rootfs.verity verity-params.txt /tmp/lab08-rootfs /tmp/lab08-verified
```

---

## Part 6: Integration Questions

After completing the lab, answer:

1. **Q**: The root hash (64 hex chars) must be protected. Where do you store it in a production system so an attacker cannot substitute their own hash?

   **A**: In the kernel cmdline, which is embedded in the signed FIT image configuration node. The FIT signature covers the configuration (including cmdline), so the root hash is cryptographically bound to the FIT signing key.

2. **Q**: If you update the rootfs (new firmware), what must change?

   **A**: The rootfs content changes → `veritysetup format` produces a different root hash → the new root hash must be embedded in the new FIT image's bootargs → the FIT image must be re-signed → the signed FIT is the OTA payload.

3. **Q**: What does `--error-behavior=panic` do, and why is it preferable to `eio` in production?

   **A**: `panic` causes the kernel to halt immediately when a tampered block is read, preventing any data from being returned to the application. `eio` returns an I/O error to the application, which might handle it incorrectly or continue processing with partially corrupted data.

## Next Lab

→ [lab-10-phytec-production](../lab-10-phytec-production/README.md)
