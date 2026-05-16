#!/bin/bash
# sign-fit-image.sh
# Signs a FIT image with an RSA key and optionally embeds the public key
# into a U-Boot DTB for runtime verification.
#
# What this script does:
#   1. Validates inputs (FIT image exists, key exists)
#   2. Signs all image nodes that have a signature@ sub-node
#   3. Optionally writes the public key into u-boot.dtb (required for
#      U-Boot to perform signature verification at boot time)
#   4. Prints the updated FIT structure for review
#
# Dependencies: mkimage (u-boot-tools), dumpimage
#
# Usage:
#   ./sign-fit-image.sh <fit-image> <key-dir> <key-name> [u-boot-dtb]
#
# Arguments:
#   fit-image   : Path to unsigned (or previously signed) FIT image
#   key-dir     : Directory containing <key-name>.pem and <key-name>.crt
#   key-name    : Base name of key files (without extension)
#   u-boot-dtb  : Optional. If given, the public key is embedded here.
#                 This file is used when building the final U-Boot binary.
#
# Example:
#   ./sign-fit-image.sh \
#     build/fitImage \
#     /keys/fit/ \
#     production-key \
#     build/u-boot.dtb

set -euo pipefail

FIT_IMAGE="${1:?Error: FIT image path required}"
KEY_DIR="${2:?Error: Key directory required}"
KEY_NAME="${3:?Error: Key name required}"
UBOOT_DTB="${4:-}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_prerequisites() {
    if ! command -v mkimage &>/dev/null; then
        log_error "mkimage not found."
        log_error "Install: apt-get install u-boot-tools"
        exit 1
    fi

    if ! command -v dumpimage &>/dev/null; then
        log_warn "dumpimage not found - post-sign verification will be skipped."
        log_warn "Install: apt-get install u-boot-tools"
    fi

    MKIMAGE_VER=$(mkimage -V 2>&1 | head -1 || true)
    log_info "mkimage version: $MKIMAGE_VER"
}

validate_inputs() {
    if [ ! -f "$FIT_IMAGE" ]; then
        log_error "FIT image not found: $FIT_IMAGE"
        exit 1
    fi

    if [ ! -d "$KEY_DIR" ]; then
        log_error "Key directory not found: $KEY_DIR"
        exit 1
    fi

    if [ ! -f "$KEY_DIR/${KEY_NAME}.pem" ]; then
        log_error "Private key not found: $KEY_DIR/${KEY_NAME}.pem"
        log_error "Generate it first with: ./scripts/key-generation/generate-fit-keys.sh"
        exit 1
    fi

    if [ ! -f "$KEY_DIR/${KEY_NAME}.crt" ]; then
        log_error "Certificate not found: $KEY_DIR/${KEY_NAME}.crt"
        log_error "The .crt file must be present alongside the .pem"
        exit 1
    fi

    if [ -n "$UBOOT_DTB" ] && [ ! -f "$UBOOT_DTB" ]; then
        log_error "U-Boot DTB not found: $UBOOT_DTB"
        log_error "Provide a valid path or omit the argument to skip key embedding."
        exit 1
    fi
}

show_pre_sign_info() {
    log_info "Pre-signing FIT contents:"
    echo ""

    if command -v dumpimage &>/dev/null; then
        dumpimage -l "$FIT_IMAGE" 2>/dev/null | sed 's/^/  /' || {
            log_warn "Could not parse FIT structure (may be a raw binary)"
        }
    fi

    echo ""
    log_info "Signing with key: $KEY_DIR/${KEY_NAME}"
    if [ -n "$UBOOT_DTB" ]; then
        log_info "Embedding public key in: $UBOOT_DTB"
    else
        log_warn "No U-Boot DTB specified. Public key will NOT be embedded."
        log_warn "U-Boot must already contain the key, or verification will fail."
    fi
}

sign_image() {
    log_info "Signing FIT image..."

    if [ -n "$UBOOT_DTB" ]; then
        # Sign FIT and embed public key into U-Boot DTB
        mkimage \
            -F "$FIT_IMAGE" \
            -k "$KEY_DIR" \
            -K "$UBOOT_DTB" \
            -r
        log_info "FIT image signed and public key embedded in U-Boot DTB."
    else
        # Sign FIT only (key assumed already present in U-Boot)
        mkimage \
            -F "$FIT_IMAGE" \
            -k "$KEY_DIR" \
            -r
        log_info "FIT image signed (no DTB embedding)."
    fi
}

verify_result() {
    if ! command -v dumpimage &>/dev/null; then
        return 0
    fi

    echo ""
    log_info "Post-signing FIT structure:"
    dumpimage -l "$FIT_IMAGE" 2>/dev/null | sed 's/^/  /'

    echo ""
    # Check that signature nodes are present and have value data
    SIG_COUNT=$(dumpimage -l "$FIT_IMAGE" 2>/dev/null | grep -c "Signature algo" || echo "0")
    HASH_COUNT=$(dumpimage -l "$FIT_IMAGE" 2>/dev/null | grep -c "Hash algo" || echo "0")

    if [ "$SIG_COUNT" -gt 0 ]; then
        log_info "Signature nodes present: $SIG_COUNT"
    else
        log_warn "No signature nodes found in signed FIT!"
        log_warn "Verify your ITS file contains signature@ sub-nodes."
    fi

    if [ "$HASH_COUNT" -gt 0 ]; then
        log_info "Hash nodes present: $HASH_COUNT"
    fi

    # Check key-name-hint matches
    KEY_HINTS=$(dumpimage -l "$FIT_IMAGE" 2>/dev/null | grep "key-name-hint" || true)
    if [ -n "$KEY_HINTS" ]; then
        log_info "Key name hints: $KEY_HINTS"
    fi

    # Warn if key hint does not match our key name
    if echo "$KEY_HINTS" | grep -q "$KEY_NAME"; then
        log_info "Key name hint matches signing key: OK"
    else
        log_warn "Key name hint in FIT may not match signing key '$KEY_NAME'"
        log_warn "U-Boot will look for a key matching the hint in its DTB."
    fi
}

print_next_steps() {
    echo ""
    echo "Next steps:"
    echo ""
    if [ -n "$UBOOT_DTB" ]; then
        echo "  1. Rebuild U-Boot with the updated DTB:"
        echo "     The DTB now contains the public key. Rebuild u-boot.bin"
        echo "     (or copy $UBOOT_DTB to your Yocto sstate cache area)"
        echo ""
        echo "  2. Flash: flash.bin containing updated U-Boot + fitImage"
        echo ""
    else
        echo "  1. Ensure the signing public key is already in U-Boot's DTB."
        echo ""
    fi
    echo "  2. Boot device and check U-Boot output for:"
    echo "     'Verifying Hash Integrity ... sha256+rsa2048:... OK'"
    echo ""
    echo "  3. If verification fails, check:"
    echo "     - key-name-hint in ITS matches key filename"
    echo "     - U-Boot required-node present in DTB for mandatory verification"
    echo "     - FIT_KEY_REQUIRED set in Yocto if using meta-secure-core"
}

main() {
    echo "FIT Image Signing"
    echo "================="
    echo "FIT image  : $FIT_IMAGE"
    echo "Key dir    : $KEY_DIR"
    echo "Key name   : $KEY_NAME"
    echo "U-Boot DTB : ${UBOOT_DTB:-<not specified>}"
    echo ""

    check_prerequisites
    validate_inputs
    show_pre_sign_info
    sign_image
    verify_result
    print_next_steps

    log_info "Signing complete: $FIT_IMAGE"
}

main "$@"
