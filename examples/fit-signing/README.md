# Example: FIT Image Signing

## Purpose

Complete worked example of creating and signing a FIT image for i.MX8MP. Shows all commands with expected outputs.

## Prerequisites

```bash
sudo apt-get install u-boot-tools device-tree-compiler openssl
mkimage --version  # u-boot-tools 2023.04+
openssl version    # OpenSSL 3.0+
```

## Complete Example

```bash
#!/bin/bash
# fit-sign-example.sh

set -euo pipefail

KEY_DIR="./keys/fit"
KEY_NAME="phytec-fit-key"
KERNEL="Image"              # ARM64 kernel binary
DTB="imx8mp-phyboard-pollux-rdk-4.dtb"
RAMDISK="initramfs.cpio.gz"
UBOOT_DTB="u-boot.dtb"     # U-Boot DTB to embed key into

# ─────────────────────────────────────────────
# Step 1: Generate signing key (one time)
# ─────────────────────────────────────────────
if [ ! -f "${KEY_DIR}/${KEY_NAME}.pem" ]; then
    echo "=== Generating FIT Signing Key ==="
    mkdir -p "$KEY_DIR"
    
    openssl genrsa -out "${KEY_DIR}/${KEY_NAME}.pem" 2048
    openssl req -new -x509 \
        -key "${KEY_DIR}/${KEY_NAME}.pem" \
        -out "${KEY_DIR}/${KEY_NAME}.crt" \
        -days 3650 \
        -subj "/CN=${KEY_NAME}/O=Example Corp/C=DE"
    
    echo "Key fingerprint:"
    openssl x509 -in "${KEY_DIR}/${KEY_NAME}.crt" -fingerprint -sha256 -noout
fi

# ─────────────────────────────────────────────
# Step 2: Generate dm-verity hash tree
# ─────────────────────────────────────────────
echo ""
echo "=== Generating dm-verity Hash ==="

ROOTFS="phytec-securiphy-image-phyboard-pollux-imx8mp-3.ext4"

veritysetup format \
    --data-block-size=4096 \
    --hash-block-size=4096 \
    "$ROOTFS" \
    "${ROOTFS}.verity" 2>&1 | tee verity-output.txt

ROOT_HASH=$(grep "Root hash:" verity-output.txt | awk '{print $3}')
SALT=$(grep "Salt:" verity-output.txt | awk '{print $2}')

echo "Root hash: $ROOT_HASH"
echo "Salt:      $SALT"

# ─────────────────────────────────────────────
# Step 3: Create ITS file with root hash
# ─────────────────────────────────────────────
echo ""
echo "=== Creating ITS File ==="

cat > fitimage.its << ITSEOF
/dts-v1/;
/ {
    description = "phyCORE-i.MX8MP Production Secure Boot Image";
    #address-cells = <1>;

    images {
        kernel@1 {
            description = "Linux Kernel";
            data = /incbin/("${KERNEL}");
            type = kernel;
            arch = arm64;
            os = linux;
            compression = none;
            load = <0x40480000>;
            entry = <0x40480000>;
            hash@1 { algo = sha256; };
            signature@1 {
                algo = sha256,rsa2048;
                key-name-hint = "${KEY_NAME}";
            };
        };

        fdt@1 {
            description = "${DTB}";
            data = /incbin/("${DTB}");
            type = flat_dt;
            arch = arm64;
            compression = none;
            hash@1 { algo = sha256; };
        };

        ramdisk@1 {
            description = "initramfs";
            data = /incbin/("${RAMDISK}");
            type = ramdisk;
            arch = arm64;
            os = linux;
            compression = none;
            hash@1 { algo = sha256; };
        };
    };

    configurations {
        default = "conf@1";
        conf@1 {
            description = "phyCORE-i.MX8MP Secure Boot";
            kernel = "kernel@1";
            fdt = "fdt@1";
            ramdisk = "ramdisk@1";
            bootargs = "console=ttymxc1,115200n8 rootwait ro quiet panic=5 lockdown=confidentiality systemd.verity=yes systemd.verity_root_hash=${ROOT_HASH} systemd.verity_root_data=/dev/mmcblk2p3 root=/dev/mapper/vroot rootfstype=ext4";
            signature@1 {
                algo = sha256,rsa2048;
                key-name-hint = "${KEY_NAME}";
                sign-images = "kernel", "fdt", "ramdisk";
            };
        };
    };
};
ITSEOF

echo "ITS created: fitimage.its"

# ─────────────────────────────────────────────
# Step 4: Build FIT image
# ─────────────────────────────────────────────
echo ""
echo "=== Building FIT Image ==="

mkimage -f fitimage.its fitImage

FITSIZE=$(wc -c < fitImage)
echo "FIT created: fitImage ($FITSIZE bytes)"

# ─────────────────────────────────────────────
# Step 5: Sign FIT and embed key in U-Boot DTB
# ─────────────────────────────────────────────
echo ""
echo "=== Signing FIT and Embedding Key ==="

# Ensure DTB has padding (must be done before embedding key):
dtc -I dtb -O dtb -p 2000 "${UBOOT_DTB}" -o "${UBOOT_DTB}.padded"
mv "${UBOOT_DTB}.padded" "${UBOOT_DTB}"

mkimage -F fitImage \
        -k "$KEY_DIR" \
        -K "$UBOOT_DTB" \
        -r

echo "Signing complete"

# ─────────────────────────────────────────────
# Step 6: Verify result
# ─────────────────────────────────────────────
echo ""
echo "=== Verification ==="

echo "FIT signature nodes:"
dumpimage -l fitImage | grep -E "Sign algo|Sign value"

echo ""
echo "U-Boot DTB key node:"
fdtdump "$UBOOT_DTB" 2>/dev/null | grep -A5 "key-${KEY_NAME}" | head -10

echo ""
echo "=== Complete ==="
echo "Artifacts:"
echo "  fitImage      — Signed FIT image (deploy to boot partition)"
echo "  ${UBOOT_DTB}  — U-Boot DTB with embedded public key"
echo "  ${ROOTFS}.verity — dm-verity hash tree"
echo ""
echo "Root hash (embed this in bootargs and FIT cmdline):"
echo "  ${ROOT_HASH}"
```

## Expected Output

```
=== Generating FIT Signing Key ===
Generating RSA private key, 2048 bit ...
SHA256 Fingerprint=AA:BB:CC:...

=== Generating dm-verity Hash ===
VERITY header information for rootfs.ext4.verity
UUID: ...
Root hash: deadbeef1234...

=== Creating ITS File ===
ITS created: fitimage.its

=== Building FIT Image ===
Image Name:   phyCORE-i.MX8MP Production Secure Boot Image
Created:      [timestamp]
FIT created: fitImage (24576000 bytes)

=== Signing FIT and Embedding Key ===
Signing images...
 fit,sha256+rsa2048:phytec-fit-key against fitImage... OK
Verified OK

=== Verification ===
FIT signature nodes:
  Sign algo:    sha256,rsa2048:phytec-fit-key
  Sign value:   f9e8d7c6...

U-Boot DTB key node:
key-phytec-fit-key {
    algo = "sha256,rsa2048";
    required = "conf";
    ...
}

=== Complete ===
[Artifact list and root hash]
```
