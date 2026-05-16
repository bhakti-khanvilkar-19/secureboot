#!/bin/bash
# generate-fit-keys.sh
# Generates RSA key pair for FIT image signing (U-Boot verified boot).
#
# These keys are DIFFERENT from HABv4 SRK keys:
#   - SRK keys: burned into fuses, authenticate SPL+U-Boot to ROM
#   - FIT keys : embedded in U-Boot DTB, authenticate kernel+DTB to U-Boot
#
# The public key (certificate) is embedded into U-Boot's device tree at
# build time. The private key signs the FIT image at image build time.
#
# Dependencies: openssl
# Usage: ./generate-fit-keys.sh [output_dir] [key_name]
#
# Example:
#   KEY_BITS=4096 ./generate-fit-keys.sh ./keys/fit/ production-signing-key

set -euo pipefail

OUTPUT_DIR="${1:-$(pwd)/fit-keys}"
KEY_NAME="${2:-fit-signing-key}"
KEY_BITS="${KEY_BITS:-2048}"
CERT_DAYS="${CERT_DAYS:-3650}"

# Organization details for certificate subject
CERT_ORG="${CERT_ORG:-Secure Boot}"
CERT_OU="${CERT_OU:-Firmware Signing}"
CERT_COUNTRY="${CERT_COUNTRY:-DE}"
CERT_LOCALITY="${CERT_LOCALITY:-}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_prerequisites() {
    if ! command -v openssl &>/dev/null; then
        log_error "openssl not found. Install: apt-get install openssl"
        exit 1
    fi

    OPENSSL_VER=$(openssl version | awk '{print $2}')
    log_info "OpenSSL version: $OPENSSL_VER"

    AVAIL=$(cat /proc/sys/kernel/random/entropy_avail)
    if [ "$AVAIL" -lt 512 ]; then
        log_warn "Low entropy: $AVAIL bits. Consider installing haveged."
    fi
}

generate_key() {
    log_info "Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"

    KEY_FILE="$OUTPUT_DIR/${KEY_NAME}.pem"
    CERT_FILE="$OUTPUT_DIR/${KEY_NAME}.crt"
    PUBKEY_FILE="$OUTPUT_DIR/${KEY_NAME}-public.pem"

    log_info "Generating RSA-${KEY_BITS} private key: ${KEY_NAME}.pem"
    openssl genrsa \
        -out "$KEY_FILE" \
        "$KEY_BITS" 2>/dev/null
    log_info "Private key generated."

    # Build subject string
    SUBJECT="/CN=${KEY_NAME}/O=${CERT_ORG}/OU=${CERT_OU}/C=${CERT_COUNTRY}"
    if [ -n "$CERT_LOCALITY" ]; then
        SUBJECT="${SUBJECT}/L=${CERT_LOCALITY}"
    fi

    log_info "Generating self-signed certificate: ${KEY_NAME}.crt"
    log_info "Subject: $SUBJECT"
    openssl req \
        -new -x509 \
        -key "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days "$CERT_DAYS" \
        -subj "$SUBJECT" \
        -extensions v3_usr 2>/dev/null

    log_info "Certificate generated (valid ${CERT_DAYS} days)."

    # Extract public key for reference
    openssl rsa \
        -in "$KEY_FILE" \
        -pubout \
        -out "$PUBKEY_FILE" 2>/dev/null

    log_info "Public key extracted: ${KEY_NAME}-public.pem"
}

verify_key_pair() {
    log_info "Verifying key pair consistency..."

    # Extract modulus from private key and certificate, compare
    PK_MOD=$(openssl rsa  -in "$OUTPUT_DIR/${KEY_NAME}.pem" -noout -modulus 2>/dev/null | md5sum)
    CT_MOD=$(openssl x509 -in "$OUTPUT_DIR/${KEY_NAME}.crt" -noout -modulus 2>/dev/null | md5sum)

    if [ "$PK_MOD" = "$CT_MOD" ]; then
        log_info "Key pair verified: private key and certificate match."
    else
        log_error "Key pair mismatch! Certificate does not match private key."
        exit 1
    fi
}

print_summary() {
    CERT_FILE="$OUTPUT_DIR/${KEY_NAME}.crt"

    echo ""
    echo "Key details:"
    openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates 2>/dev/null | \
        sed 's/^/  /'

    echo ""
    echo "Certificate fingerprint (SHA-256):"
    openssl x509 -in "$CERT_FILE" -fingerprint -sha256 -noout 2>/dev/null | \
        sed 's/^/  /'

    echo ""
    log_info "Files created:"
    echo "  Private key  : $OUTPUT_DIR/${KEY_NAME}.pem"
    echo "  Certificate  : $OUTPUT_DIR/${KEY_NAME}.crt"
    echo "  Public key   : $OUTPUT_DIR/${KEY_NAME}-public.pem"

    echo ""
    echo "Yocto local.conf configuration:"
    echo "  UBOOT_SIGN_ENABLE  = \"1\""
    echo "  UBOOT_SIGN_KEYDIR  = \"${OUTPUT_DIR}\""
    echo "  UBOOT_SIGN_KEYNAME = \"${KEY_NAME}\""
    echo "  FIT_SIGN_ALG       = \"rsa${KEY_BITS}\""
    echo "  FIT_HASH_ALG       = \"sha256\""

    echo ""
    echo "Manual mkimage signing (reference):"
    echo "  mkimage -F fitImage -k ${OUTPUT_DIR}/ -K u-boot.dtb -r"

    echo ""
    log_warn "Protect ${KEY_NAME}.pem - anyone with this file can sign firmware for your devices."
    log_warn "Back up to encrypted offline storage."
}

set_permissions() {
    chmod 600 "$OUTPUT_DIR/${KEY_NAME}.pem"
    chmod 644 "$OUTPUT_DIR/${KEY_NAME}.crt"
    chmod 644 "$OUTPUT_DIR/${KEY_NAME}-public.pem"
    log_info "Permissions set: private key 600, certificates 644"
}

main() {
    echo "FIT Image Signing Key Generator"
    echo "================================"
    echo "Output dir : $OUTPUT_DIR"
    echo "Key name   : $KEY_NAME"
    echo "Key bits   : $KEY_BITS"
    echo "Cert days  : $CERT_DAYS"
    echo ""

    check_prerequisites
    generate_key
    verify_key_pair
    set_permissions
    print_summary
}

main "$@"
