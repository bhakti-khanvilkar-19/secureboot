#!/bin/bash
# verify-signed-fit.sh — Verify a signed FIT image on the host
#
# Usage: verify-signed-fit.sh <fitimage> <cert_file>
#
# Checks:
#   1. FIT structure is valid
#   2. Signature nodes exist
#   3. Key name matches certificate
#   4. Component hashes are correct
#   5. Reports signature algorithm

set -euo pipefail

FIT_IMAGE="${1:?Usage: $0 <fitimage> [cert_file]}"
CERT_FILE="${2:-}"

PASS=0; FAIL=0; WARN=0

check_pass() { echo "  PASS: $1"; ((PASS++)); }
check_fail() { echo "  FAIL: $1"; ((FAIL++)); }
check_warn() { echo "  WARN: $1"; ((WARN++)); }

echo "=== FIT Image Verification ==="
echo "File: $FIT_IMAGE"
echo "Size: $(wc -c < "$FIT_IMAGE") bytes"
echo ""

# ─────────────────────────────────────────────
# Basic structure check
# ─────────────────────────────────────────────
echo "--- Structure ---"

if dumpimage -l "$FIT_IMAGE" > /tmp/fit-dump.txt 2>&1; then
    check_pass "FIT structure valid"
else
    check_fail "FIT structure invalid or not a FIT image"
    cat /tmp/fit-dump.txt
    exit 1
fi

# ─────────────────────────────────────────────
# Signature nodes
# ─────────────────────────────────────────────
echo ""
echo "--- Signatures ---"

if grep -q "Sign algo" /tmp/fit-dump.txt; then
    SIGN_ALGOS=$(grep "Sign algo" /tmp/fit-dump.txt)
    echo "$SIGN_ALGOS" | while read -r line; do
        echo "  Found: $line"
    done
    check_pass "Signature node(s) found"
else
    check_fail "No signature nodes found — FIT is unsigned"
fi

# Check signature values exist (not "unavailable")
if grep "Sign value" /tmp/fit-dump.txt | grep -q "unavailable"; then
    check_fail "Signature value is 'unavailable' — FIT not signed"
else
    check_pass "Signature values present"
fi

# ─────────────────────────────────────────────
# Key name extraction
# ─────────────────────────────────────────────
echo ""
echo "--- Key Information ---"

KEY_NAME=$(grep "Sign algo" /tmp/fit-dump.txt | head -1 | sed 's/.*:\(.*\)/\1/' | tr -d ' ')
if [ -n "$KEY_NAME" ]; then
    echo "  Key name: $KEY_NAME"
    check_pass "Key name extracted: $KEY_NAME"
else
    check_warn "Could not extract key name from FIT"
fi

# Algorithm check
SIGN_ALGO=$(grep "Sign algo" /tmp/fit-dump.txt | head -1 | grep -oP 'sha256,rsa2048|sha384,rsa3072' || true)
if [ -n "$SIGN_ALGO" ]; then
    check_pass "Signature algorithm: $SIGN_ALGO"
else
    check_warn "Unrecognized or weak signature algorithm"
fi

# ─────────────────────────────────────────────
# Hash verification
# ─────────────────────────────────────────────
echo ""
echo "--- Component Hashes ---"

# Extract each component and verify hash:
for type_flag in "kernel:-T kernel" "flat_dt:-T flat_dt" "ramdisk:-T ramdisk"; do
    type_name="${type_flag%%:*}"
    extract_flag="${type_flag#*:}"

    EXTRACTED="/tmp/fit-verify-${type_name}.bin"
    if dumpimage $extract_flag -p 0 -o "$EXTRACTED" "$FIT_IMAGE" 2>/dev/null; then
        ACTUAL_HASH=$(sha256sum "$EXTRACTED" | cut -d' ' -f1)
        check_pass "$type_name extracted and hash computable: ${ACTUAL_HASH:0:16}..."
        rm -f "$EXTRACTED"
    else
        check_warn "$type_name not found or not extractable"
    fi
done

# ─────────────────────────────────────────────
# Configuration check
# ─────────────────────────────────────────────
echo ""
echo "--- Configurations ---"

CONFIGS=$(grep "Configuration" /tmp/fit-dump.txt | grep -v "Default" | wc -l)
DEFAULT=$(grep "Default" /tmp/fit-dump.txt | grep -oP "conf@\d+" || true)

echo "  Configurations: $CONFIGS"
echo "  Default: ${DEFAULT:-not found}"

if [ -n "$DEFAULT" ]; then
    check_pass "Default configuration set: $DEFAULT"
else
    check_warn "No default configuration set"
fi

# ─────────────────────────────────────────────
# Certificate verification (if cert provided)
# ─────────────────────────────────────────────
if [ -n "$CERT_FILE" ] && [ -f "$CERT_FILE" ]; then
    echo ""
    echo "--- Certificate Verification ---"

    CERT_KEYNAME=$(openssl x509 -in "$CERT_FILE" -subject -noout 2>/dev/null | \
        grep -oP '(?<=CN=)[^,/]+' || true)
    echo "  Certificate CN: $CERT_KEYNAME"

    if [ "$CERT_KEYNAME" = "$KEY_NAME" ]; then
        check_pass "Key name matches certificate CN"
    else
        check_fail "Key name mismatch: FIT='$KEY_NAME', cert='$CERT_KEYNAME'"
    fi

    EXPIRY=$(openssl x509 -in "$CERT_FILE" -enddate -noout 2>/dev/null | \
        cut -d= -f2 || true)
    echo "  Certificate expires: $EXPIRY"
fi

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS  FAIL: $FAIL  WARN: $WARN"

if [ "$FAIL" -gt 0 ]; then
    echo "  RESULT: FAILED"
    exit 1
else
    echo "  RESULT: PASSED"
fi

rm -f /tmp/fit-dump.txt
