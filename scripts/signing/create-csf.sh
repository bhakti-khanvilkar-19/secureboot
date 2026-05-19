#!/bin/bash
# create-csf.sh — Generate HABv4 CSF binary for imx-boot signing
#
# Usage: create-csf.sh <flash_bin> <key_dir> [srk_index]
#
# Arguments:
#   flash_bin   - Path to imx-boot binary (e.g., imx-boot.bin)
#   key_dir     - Path to HABv4 key directory
#   srk_index   - SRK index to use (default: 0)
#
# Outputs:
#   <flash_bin>-signed  - Signed image (padded + CSF appended)
#   imxboot_csf.bin     - CSF binary (intermediate, removed after signing)

set -euo pipefail

FLASH_BIN="${1:?Usage: $0 <flash_bin> <key_dir> [srk_index]}"
KEY_DIR="${2:?Usage: $0 <flash_bin> <key_dir> [srk_index]}"
SRK_INDEX="${3:-0}"
CST="${CST_PATH:-/opt/cst/linux64/bin/cst}"

# ─────────────────────────────────────────────
# Validate inputs
# ─────────────────────────────────────────────

if [ ! -f "$FLASH_BIN" ]; then
    echo "ERROR: Flash binary not found: $FLASH_BIN" >&2
    exit 1
fi

if [ ! -d "$KEY_DIR" ]; then
    echo "ERROR: Key directory not found: $KEY_DIR" >&2
    exit 1
fi

if [ ! -f "$CST" ]; then
    echo "ERROR: CST not found at: $CST" >&2
    echo "Set CST_PATH environment variable or install CST to /opt/cst/" >&2
    exit 1
fi

for required_file in \
    "SRK_1_2_3_4_table.bin" \
    "crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem" \
    "crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem"; do
    if [ ! -f "${KEY_DIR}/${required_file}" ]; then
        echo "ERROR: Required key file not found: ${KEY_DIR}/${required_file}" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────
# Compute image parameters
# ─────────────────────────────────────────────

FLASH_SIZE=$(wc -c < "$FLASH_BIN")
PADDED_SIZE=$(( (FLASH_SIZE + 0xFFF) & ~0xFFF ))
SPL_LOAD_ADDR="${SPL_LOAD_ADDR:-0x7E1000}"
OUTPUT="${FLASH_BIN}-signed"

echo "=== HABv4 CSF Generation ==="
echo "Input:       $FLASH_BIN"
echo "Size:        $FLASH_SIZE bytes (0x$(printf '%x' $FLASH_SIZE))"
echo "Padded:      $PADDED_SIZE bytes (0x$(printf '%x' $PADDED_SIZE))"
echo "Load addr:   $SPL_LOAD_ADDR"
echo "SRK index:   $SRK_INDEX"
echo "Key dir:     $KEY_DIR"
echo ""

# ─────────────────────────────────────────────
# Generate CSF configuration
# ─────────────────────────────────────────────

CSF_CFG=$(mktemp /tmp/imxboot_csf_XXXXXXXX.cfg)
trap "rm -f $CSF_CFG imxboot_csf.bin" EXIT

cat > "$CSF_CFG" << EOF
[Header]
    Version = 4.3
    Hash Algorithm = sha256
    Engine = CAAM
    Engine Configuration = 0
    Certificate Format = X509
    Signature Format = CMS

[Install SRK]
    File = "${KEY_DIR}/SRK_1_2_3_4_table.bin"
    Source index = ${SRK_INDEX}

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

# ─────────────────────────────────────────────
# Run CST
# ─────────────────────────────────────────────

echo "Running CST..."
"$CST" -o imxboot_csf.bin -i "$CSF_CFG"

CSF_SIZE=$(wc -c < imxboot_csf.bin)
echo "CSF binary:  $CSF_SIZE bytes"

# ─────────────────────────────────────────────
# Combine padded image + CSF
# ─────────────────────────────────────────────

PADDED_BIN=$(mktemp)
trap "rm -f $CSF_CFG imxboot_csf.bin $PADDED_BIN" EXIT

dd if="$FLASH_BIN" of="$PADDED_BIN" bs=1 count="$PADDED_SIZE" conv=sync 2>/dev/null
cat "$PADDED_BIN" imxboot_csf.bin > "$OUTPUT"

FINAL_SIZE=$(wc -c < "$OUTPUT")

echo ""
echo "=== Signing Complete ==="
echo "Output:  $OUTPUT"
echo "Size:    $FINAL_SIZE bytes"
echo "SHA-256: $(sha256sum "$OUTPUT" | cut -d' ' -f1)"
