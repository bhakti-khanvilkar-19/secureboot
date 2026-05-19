# i.MX8MP OCOTP Fuse Map

## Security-Critical Fuse Fields

```
OCOTP Fuse Map (i.MX8MP) — Security Fields Only
Shadow Register Base: 0x30350000

Bank  Word  Shadow Addr   Field Name            Bits    Description
═══════════════════════════════════════════════════════════════════════════

 0     0    0x30350400   LOCK                   [31:0]  Fuse lock bits
             bit 9:  SRK_REVOKE lock            [9]     Lock SRK_REVOKE field
             bit 10: JTAG_SMODE lock            [10]    Lock JTAG mode
             bit 14: SEC_CONFIG lock            [14]    Lock SEC_CONFIG

 1     3    0x30350470   SEC_CONFIG & JTAG      [31:0]
             SEC_CONFIG[1:0]                    [1:0]   00=FAB, 01=RET, 10=CLOSED, 11=CLOSED
             ← bit 1 = 1 → CLOSED mode
             JTAG_SMODE[1:0]                    [7:6]   00=ENABLED, 01=DISABLED_IN_CLOSED,
                                                        10=USER, 11=DISABLED
             KTE (Key Transfer Enable)          [9]     Enable key transfer to CAAM

 3     0    0x30350580   SRK_HASH[31:0]                SHA-256 of SRK table, word 0
 3     1    0x30350590   SRK_HASH[63:32]               SHA-256 of SRK table, word 1
 3     2    0x305305A0   SRK_HASH[95:64]               SHA-256 of SRK table, word 2
 3     3    0x305305B0   SRK_HASH[127:96]              SHA-256 of SRK table, word 3
 3     4    0x305305C0   SRK_HASH[159:128]             SHA-256 of SRK table, word 4
 3     5    0x305305D0   SRK_HASH[191:160]             SHA-256 of SRK table, word 5
 3     6    0x305305E0   SRK_HASH[223:192]             SHA-256 of SRK table, word 6
 3     7    0x305305F0   SRK_HASH[255:224]             SHA-256 of SRK table, word 7

 4     0    0x30350600   ANTI_ROLLBACK[31:0]           Anti-rollback counter, bits 0-31
 4     1    0x30350610   ANTI_ROLLBACK[63:32]          Anti-rollback counter, bits 32-63

 8     0    0x30350800   MAC1_ADDR[31:0]               Ethernet MAC address (low)
 8     1    0x30350810   MAC1_ADDR[47:32]              Ethernet MAC address (high)

 9     0    0x30350900   UNIQUE_ID[31:0]               Die unique ID (low)
 9     1    0x30350910   UNIQUE_ID[63:32]              Die unique ID (high)

═══════════════════════════════════════════════════════════════════════════
```

## Linux nvmem Access

```bash
# All fuses accessible via nvmem interface:
NVMEM="/sys/bus/nvmem/devices/imx-ocotp0/nvmem"

# Read fuse at bank B, word W:
read_fuse() {
    local bank=$1
    local word=$2
    local offset=$(( (bank * 8 + word) * 4 ))
    dd if="$NVMEM" bs=4 skip=$((offset / 4)) count=1 2>/dev/null | od -An -tx4 | tr -d ' '
}

# Examples:
read_fuse 1 3   # SEC_CONFIG
read_fuse 3 0   # SRK_HASH word 0
read_fuse 4 0   # Anti-rollback word 0
```

## U-Boot fuse Command

```
U-Boot> fuse read <bank> <word> [<count>]
U-Boot> fuse prog [-y] <bank> <word> <hexval>

# Read all SRK hash fuses:
U-Boot> fuse read 3 0 8

# Read SEC_CONFIG:
U-Boot> fuse read 1 3

# Program SEC_CONFIG (CLOSE device — IRREVERSIBLE):
U-Boot> fuse prog -y 1 3 0x2

# Program anti-rollback version 5 (bits 0-4 set):
U-Boot> fuse prog -y 4 0 0x0000001F
```

## Fuse Programming Rules

```
IMPORTANT CONSTRAINTS:
  1. Fuses can only be changed 0→1, NEVER 1→0
  2. Once a bit is set, it cannot be cleared
  3. VDD_FUSE (1.8V) must be applied before programming
  4. Programming one fuse takes ~10ms
  5. Shadow registers updated immediately; permanent on power cycle

PROGRAMMING ORDER:
  Always program and verify SRK hash BEFORE closing device
  Close device ONLY after verifying HAB authentication in OPEN mode

NEVER program:
  - During DDR stress test
  - With unstable power supply
  - While application is running (risk of corruption)
```
