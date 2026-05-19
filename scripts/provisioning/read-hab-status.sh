#!/bin/bash
# read-hab-status.sh — Read and decode HAB status from running device
#
# Run on the target device (requires Linux + nvmem access)
# Or via UART by parsing U-Boot hab_status output
#
# Usage: read-hab-status.sh [--uboot-log <file>]
#
# Reads:
#   - HAB configuration (OPEN/CLOSED) from OCOTP SEC_CONFIG fuse
#   - SRK fuse values from OCOTP Bank 3
#   - Anti-rollback fuse counter from OCOTP Bank 4

set -euo pipefail

NVMEM_PATH="${NVMEM_PATH:-/sys/bus/nvmem/devices/imx-ocotp0/nvmem}"

# ─────────────────────────────────────────────
# Helper: read fuse word from nvmem
# ─────────────────────────────────────────────
read_fuse_word() {
    local bank=$1
    local word=$2
    local offset=$(( (bank * 8 + word) * 4 ))

    if [ ! -r "$NVMEM_PATH" ]; then
        echo "ERROR: Cannot read nvmem at $NVMEM_PATH" >&2
        echo "0x00000000"
        return 1
    fi

    dd if="$NVMEM_PATH" bs=4 skip=$((offset / 4)) count=1 2>/dev/null | \
        od -An -tx4 | tr -d ' \n'
}

# ─────────────────────────────────────────────
# HAB Configuration
# ─────────────────────────────────────────────
echo "=== HAB Configuration ==="

# SEC_CONFIG: Bank 1, Word 3
SEC_CONFIG=$(read_fuse_word 1 3)
SEC_CONFIG_VAL=$(( 16#${SEC_CONFIG} ))
HAB_CLOSED=$(( (SEC_CONFIG_VAL >> 1) & 1 ))

if [ "$HAB_CLOSED" -eq 1 ]; then
    echo "HAB Mode:    CLOSED (SEC_CONFIG bit set)"
    echo "             Device will halt on authentication failure"
else
    echo "HAB Mode:    OPEN (SEC_CONFIG not set)"
    echo "             HAB events logged but boot continues"
fi

# ─────────────────────────────────────────────
# SRK Hash Fuses (Bank 3, Words 0-7)
# ─────────────────────────────────────────────
echo ""
echo "=== SRK Hash Fuses (OCOTP Bank 3) ==="
SRK_EMPTY=true
for i in 0 1 2 3 4 5 6 7; do
    WORD=$(read_fuse_word 3 $i)
    echo "  Word $i: 0x${WORD}"
    if [ "$WORD" != "00000000" ]; then
        SRK_EMPTY=false
    fi
done

if $SRK_EMPTY; then
    echo ""
    echo "  STATUS: SRK fuses are EMPTY (not yet programmed)"
    echo "  Device cannot authenticate firmware until SRK hash is burned"
else
    echo ""
    echo "  STATUS: SRK fuses are programmed"
fi

# ─────────────────────────────────────────────
# Anti-rollback Counter (Bank 4, Words 0-1)
# ─────────────────────────────────────────────
echo ""
echo "=== Anti-rollback Counter (OCOTP Bank 4) ==="
WORD0=$(read_fuse_word 4 0)
WORD1=$(read_fuse_word 4 1)

# Count set bits (popcount)
python3 -c "
w0 = int('${WORD0}', 16)
w1 = int('${WORD1}', 16)
count = bin(w0).count('1') + bin(w1).count('1')
print(f'  Word 0: 0x${WORD0}')
print(f'  Word 1: 0x${WORD1}')
print(f'  Anti-rollback version: {count}')
"

# ─────────────────────────────────────────────
# JTAG Status
# ─────────────────────────────────────────────
echo ""
echo "=== JTAG Configuration ==="
JTAG_WORD=$(read_fuse_word 1 3)
JTAG_VAL=$(( 16#${JTAG_WORD} ))
JTAG_SMODE=$(( (JTAG_VAL >> 6) & 0x3 ))

case $JTAG_SMODE in
    0) echo "  JTAG: Enabled (JTAG_SMODE = 00)" ;;
    1) echo "  JTAG: Disabled in CLOSED mode (JTAG_SMODE = 01)" ;;
    2) echo "  JTAG: Enabled in Secure User mode (JTAG_SMODE = 10)" ;;
    3) echo "  JTAG: Disabled permanently (JTAG_SMODE = 11)" ;;
esac

echo ""
echo "=== Status Summary ==="
echo "  HAB: $([ "$HAB_CLOSED" -eq 1 ] && echo CLOSED || echo OPEN)"
echo "  SRK: $(${SRK_EMPTY} && echo NOT_PROGRAMMED || echo PROGRAMMED)"
