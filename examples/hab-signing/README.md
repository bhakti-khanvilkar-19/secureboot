# Example: HABv4 imx-boot Signing

## Purpose

Complete worked example of signing an imx-boot binary using NXP CST. Includes all steps with expected outputs.

## Prerequisites

```bash
# NXP CST installed at /opt/cst:
/opt/cst/linux64/bin/cst --version
# CST Version: 3.x.x

# HABv4 keys generated (see 11-key-management/01-key-generation.md):
ls /opt/keys/hab/
# SRK_1_2_3_4_table.bin
# SRK_1_2_3_4_fuse.bin
# keys/SRK1_sha256_2048_65537_v3_usr_key.pem
# crts/SRK1_sha256_2048_65537_v3_usr_crt.pem
# keys/CSF1_1_sha256_2048_65537_v3_usr_key.pem
# crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem
# keys/IMG1_1_sha256_2048_65537_v3_usr_key.pem
# crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem

# imx-boot binary from Yocto build:
ls imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk
```

## Complete Signing Workflow

```bash
#!/bin/bash
# sign-imxboot.sh — Complete HABv4 signing example

set -euo pipefail

FLASH_BIN="${1:-imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk}"
KEY_DIR="${2:-/opt/keys/hab}"
CST="/opt/cst/linux64/bin/cst"
OUTPUT="${FLASH_BIN}-signed"

echo "=== HABv4 imx-boot Signing ==="
echo "Input:   $FLASH_BIN"
echo "Keys:    $KEY_DIR"
echo "Output:  $OUTPUT"
echo ""

# Step 1: Compute image parameters
FLASH_SIZE=$(wc -c < "$FLASH_BIN")
PADDED_SIZE=$(( (FLASH_SIZE + 0xFFF) & ~0xFFF ))
SPL_LOAD_ADDR="0x7E1000"  # For i.MX8MP phyCORE

echo "Image size:  $FLASH_SIZE bytes (0x$(printf '%x' $FLASH_SIZE))"
echo "Padded size: $PADDED_SIZE bytes (0x$(printf '%x' $PADDED_SIZE))"
echo "Load addr:   $SPL_LOAD_ADDR"
echo ""

# Step 2: Generate CSF from template
cat > imxboot_csf.cfg << EOF
[Header]
    Version = 4.3
    Hash Algorithm = sha256
    Engine = CAAM
    Engine Configuration = 0
    Certificate Format = X509
    Signature Format = CMS

[Install SRK]
    File = "${KEY_DIR}/SRK_1_2_3_4_table.bin"
    Source index = 0

[Install CSFK]
    File = "${KEY_DIR}/crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate CSF]

[Install Key]
    Verification index = 0
    Target index = 2
    File = "${KEY_DIR}/crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate Data]
    Verification index = 2
    Blocks = ${SPL_LOAD_ADDR} 0x000 $(printf '0x%x' $PADDED_SIZE) "${FLASH_BIN}"
EOF

echo "CSF configuration:"
cat imxboot_csf.cfg
echo ""

# Step 3: Run CST to generate CSF binary
echo "Running CST..."
$CST -o imxboot_csf.bin -i imxboot_csf.cfg

CSF_SIZE=$(wc -c < imxboot_csf.bin)
echo "CSF binary: imxboot_csf.bin ($CSF_SIZE bytes)"
echo ""

# Step 4: Pad original image and append CSF
echo "Padding image to $PADDED_SIZE bytes..."
dd if="$FLASH_BIN" of="${FLASH_BIN}-padded" bs=1 count="$PADDED_SIZE" conv=sync 2>/dev/null

echo "Appending CSF..."
cat "${FLASH_BIN}-padded" imxboot_csf.bin > "$OUTPUT"

# Cleanup temp files
rm -f "${FLASH_BIN}-padded" imxboot_csf.cfg imxboot_csf.bin

FINAL_SIZE=$(wc -c < "$OUTPUT")
echo ""
echo "=== Signing Complete ==="
echo "Output:        $OUTPUT"
echo "Unsigned size: $FLASH_SIZE bytes"
echo "Padded size:   $PADDED_SIZE bytes"
echo "CSF size:      $CSF_SIZE bytes"
echo "Final size:    $FINAL_SIZE bytes"
echo ""
echo "SHA-256: $(sha256sum $OUTPUT | cut -d' ' -f1)"
echo ""
echo "Next steps:"
echo "  1. Flash to eMMC boot0:"
echo "     dd if=$OUTPUT of=/dev/mmcblk2boot0 bs=1k"
echo ""
echo "  2. Verify in U-Boot (OPEN mode):"
echo "     => hab_status"
echo "     Expected: No HAB Events Found!"
```

## Expected Output

```
=== HABv4 imx-boot Signing ===
Input:   imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk
Keys:    /opt/keys/hab
Output:  imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk-signed

Image size:  1999872 bytes (0x1e8000)
Padded size: 2002944 bytes (0x1e9000)
Load addr:   0x7E1000

[CSF configuration printed]

Running CST...
CST: Parsing "imxboot_csf.cfg"
CST: Signing "imx-boot.bin"
Output: imxboot_csf.bin
CSF binary: imxboot_csf.bin (6144 bytes)

Padding image to 2002944 bytes...
Appending CSF...

=== Signing Complete ===
Output:        imx-boot-...-signed
Unsigned size: 1999872 bytes
Padded size:   2002944 bytes
CSF size:      6144 bytes
Final size:    2009088 bytes

SHA-256: abc123def456...

Next steps: [flash instructions]
```
