#!/bin/bash
# check-hab-events.sh — Parse and decode HAB events from U-Boot output
#
# Usage:
#   1. Run on device with U-Boot output piped in:
#      screen /dev/ttyUSB0 115200 | tee uboot.log
#      Then: check-hab-events.sh < uboot.log
#
#   2. Or run with a log file:
#      check-hab-events.sh uboot.log

set -euo pipefail

INPUT_FILE="${1:-/dev/stdin}"

# ─────────────────────────────────────────────
# HAB decode tables
# ─────────────────────────────────────────────

decode_status() {
    case "$1" in
        "f0") echo "HAB_SUCCESS" ;;
        "33") echo "HAB_FAILURE" ;;
        "69") echo "HAB_WARNING" ;;
        *) echo "UNKNOWN(0x$1)" ;;
    esac
}

decode_reason() {
    case "$1" in
        "00") echo "HAB_RSN_ANY (generic)" ;;
        "05") echo "HAB_INV_ADDRESS (bad load addr)" ;;
        "18") echo "HAB_INV_SIGNATURE (signature mismatch)" ;;
        "1d") echo "HAB_INV_INDEX (SRK index invalid)" ;;
        "2b") echo "HAB_INV_CERTIFICATE (cert chain broken)" ;;
        "3b") echo "HAB_INV_CLAIM (algorithm mismatch)" ;;
        "3e") echo "HAB_INV_COMMAND (bad CSF command)" ;;
        "3f") echo "HAB_INV_CSF (malformed CSF)" ;;
        "c2") echo "HAB_INV_KEY (SRK not installed / hash mismatch)" ;;
        "ca") echo "HAB_INV_DATA (data != signature)" ;;
        *) echo "UNKNOWN(0x$1)" ;;
    esac
}

decode_context() {
    case "$1" in
        "00") echo "HAB_CTX_ANY" ;;
        "0a") echo "HAB_CTX_COMMAND (CSF command)" ;;
        "10") echo "HAB_CTX_AUT_DAT (Authenticate Data)" ;;
        "20") echo "HAB_CTX_ASSERT (assertion)" ;;
        "22") echo "HAB_CTX_DCD (DCD processing)" ;;
        "24") echo "HAB_CTX_ENTRY (HAB_ENTRY)" ;;
        "25") echo "HAB_CTX_EXIT (HAB_EXIT)" ;;
        "41") echo "HAB_CTX_FAB (cert fabrication)" ;;
        *) echo "UNKNOWN(0x$1)" ;;
    esac
}

suggest_fix() {
    local reason="$1"
    local context="$2"
    case "$reason" in
        "18") echo "Re-sign image. Verify CSF covers correct image size (padded)." ;;
        "c2") echo "SRK hash mismatch. Verify sha256(SRK_table.bin) matches OCOTP Bank 3." ;;
        "2b") echo "CSF cert not signed by same CA as SRK. Use keys from single generation run." ;;
        "05") echo "Image load address wrong. Check SPL_LOAD_ADDR in CSF Authenticate Data." ;;
        "3f") echo "CSF structure malformed. Regenerate CSF using CST." ;;
        *) echo "Check 25-debugging-and-recovery/01-hab-debugging.md for guidance." ;;
    esac
}

# ─────────────────────────────────────────────
# Parse U-Boot output
# ─────────────────────────────────────────────

echo "=== HAB Event Analysis ==="

# Check for "No HAB Events Found!"
if grep -q "No HAB Events Found" "$INPUT_FILE" 2>/dev/null; then
    echo ""
    echo "RESULT: No HAB events found — authentication SUCCESSFUL"

    # Check HAB configuration:
    CONFIG_LINE=$(grep -o "HAB Configuration: 0x[0-9a-fA-F][0-9a-fA-F]" "$INPUT_FILE" 2>/dev/null || true)
    if [ -n "$CONFIG_LINE" ]; then
        CONFIG=$(echo "$CONFIG_LINE" | grep -oP '0x\K[0-9a-fA-F]+')
        case "$CONFIG" in
            "00") echo "HAB Mode: OPEN (development — close device for production)" ;;
            "02") echo "HAB Mode: CLOSED (production secured)" ;;
            *) echo "HAB Mode: Unknown (0x${CONFIG})" ;;
        esac
    fi
    exit 0
fi

# Parse HAB events
EVENT_COUNT=0
IN_EVENT=false
EVENT_BYTES=""

while IFS= read -r line; do
    if echo "$line" | grep -q "HAB Event"; then
        IN_EVENT=true
        EVENT_COUNT=$((EVENT_COUNT + 1))
        EVENT_BYTES=""
        echo ""
        echo "--- HAB Event $EVENT_COUNT ---"
    fi

    if $IN_EVENT; then
        # Extract hex bytes from event data lines
        if echo "$line" | grep -qP '^\s+(0x[0-9a-f]{2}\s*)+'; then
            BYTES=$(echo "$line" | grep -oP '0x[0-9a-f]{2}' | sed 's/0x//' | tr '\n' ' ')
            EVENT_BYTES="$EVENT_BYTES $BYTES"
        fi

        # Parse decoded lines
        if echo "$line" | grep -q "^STS"; then
            STATUS=$(echo "$line" | grep -oP '0x[0-9a-f]{2}' | head -1 | sed 's/0x//')
            echo "  Status:  $(decode_status $STATUS)"
        fi
        if echo "$line" | grep -q "^RSN"; then
            REASON=$(echo "$line" | grep -oP '0x[0-9a-f]{2}' | head -1 | sed 's/0x//')
            echo "  Reason:  $(decode_reason $REASON)"
        fi
        if echo "$line" | grep -q "^CTX"; then
            CTX=$(echo "$line" | grep -oP '0x[0-9a-f]{2}' | head -1 | sed 's/0x//')
            echo "  Context: $(decode_context $CTX)"
            IN_EVENT=false

            echo ""
            echo "  Suggested Fix: $(suggest_fix "${REASON:-00}" "${CTX:-00}")"
        fi
    fi
done < "$INPUT_FILE"

echo ""
if [ "$EVENT_COUNT" -eq 0 ]; then
    echo "No HAB events found in input."
    echo "Is the U-Boot log complete? Run 'hab_status' at U-Boot prompt."
else
    echo "Total events: $EVENT_COUNT"
    echo "RESULT: HAB authentication FAILED"
    echo ""
    echo "See 25-debugging-and-recovery/01-hab-debugging.md for detailed guidance."
fi
