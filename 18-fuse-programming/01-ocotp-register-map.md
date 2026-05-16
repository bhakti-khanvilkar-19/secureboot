# i.MX8MP OCOTP Security Fuse Register Map

## OCOTP Overview
- Base address: 0x30350000
- Total fuse words: 256 (some ECC protected)
- Shadow registers: runtime-readable copies at base + offset
- Programming: requires 1.8V VDD_FUSE, voltage regulator control

## Shadow Register Address Calculation
Shadow register address = OCOTP_BASE + 0x400 + (bank x 0x80) + (word x 0x10)
- OCOTP_BASE = 0x30350000
- Example: Bank 3, Word 0 = 0x30350000 + 0x400 + (3 x 0x80) + (0 x 0x10) = 0x30350780

## Security-Critical Fuse Fields

### Boot Mode and Security Configuration (Bank 1, Word 3)

| Bits | Field Name | Description |
|------|-----------|-------------|
| [1:0] | TESTER_LOCK | Lock tester fuses |
| [1] | SEC_CONFIG | **0=HAB Open, 2=HAB Closed (IRREVERSIBLE)** |
| [3] | DIR_BT_DIS | Disable direct (unauthenticated) boot |
| [4] | BT_FUSE_SEL | 0=boot mode from pins, 1=from fuses |
| [5] | FIELD_RETURN | Enable field return (RMA) mode |
| [7:6] | WDOG_ENABLE | Watchdog enable at boot |
| [9:8] | BOOT_CFG | Boot device selection (eMMC/SD/SPI) |
| [15:12] | BOOT_CFG[7:4] | Boot device sub-configuration |
| [20] | KTE | Key Transfer Enable |
| [23:22] | JTAG_SMODE | 00=no JTAG, 01=secure JTAG, 10=no debug |
| [25:24] | JTAG_HEO | JTAG HAB override |
| [27] | WDOG_ENABLE[2] | Additional watchdog bit |

### SRK Hash (Bank 3, Words 0-7)
256-bit SHA-256 hash of 4 SRK public keys bundled as SRK table

| Register | Bank | Word | Shadow Address |
|---------|------|------|----------------|
| OCOTP_SRK0 | 3 | 0 | 0x30350780 |
| OCOTP_SRK1 | 3 | 1 | 0x30350790 |
| OCOTP_SRK2 | 3 | 2 | 0x303507A0 |
| OCOTP_SRK3 | 3 | 3 | 0x303507B0 |
| OCOTP_SRK4 | 3 | 4 | 0x303507C0 |
| OCOTP_SRK5 | 3 | 5 | 0x303507D0 |
| OCOTP_SRK6 | 3 | 6 | 0x303507E0 |
| OCOTP_SRK7 | 3 | 7 | 0x303507F0 |

### SRK Revocation (Bank 4, Word 3)
| Bits | Field | Description |
|------|-------|-------------|
| [0] | SRK_REVOKE0 | Revoke SRK key index 0 |
| [1] | SRK_REVOKE1 | Revoke SRK key index 1 |
| [2] | SRK_REVOKE2 | Revoke SRK key index 2 |
| [3] | SRK_REVOKE3 | Revoke SRK key index 3 |

### Anti-Rollback Counter (Bank 9)
Reserved for software anti-rollback counter implementation.

| Register | Bank | Word | Shadow Address | Description |
|---------|------|------|----------------|-------------|
| OCOTP_GP1 | 9 | 1 | 0x30350C90 | General purpose, bits [15:0] usable as ARB counter |
| OCOTP_GP2 | 9 | 2 | 0x30350CA0 | General purpose, additional rollback bits |

## Fuse ECC Protection

Some fuse banks are ECC-protected and require full 32-bit words to be written correctly:
- ECC fuses: programming partial words can corrupt the entire word
- Non-ECC fuses: individual bits can be programmed independently
- SRK fuses (Bank 3): ECC protected -- program full words only

```
ECC encoding: 8-bit Hamming code per 32-bit word
If bit error detected: OCOTP flags ERROR in CTRL register
Read retry: shadow register reload needed after ECC error
```

## OCOTP Controller Registers

| Offset | Register | Description |
|--------|---------|-------------|
| 0x000 | OCOTP_CTRL | Control register, busy/error flags |
| 0x004 | OCOTP_CTRL_SET | Set bits |
| 0x008 | OCOTP_CTRL_CLR | Clear bits |
| 0x00C | OCOTP_CTRL_TOG | Toggle bits |
| 0x010 | OCOTP_TIMING | Fuse programming timing parameters |
| 0x020 | OCOTP_DATA | Write data register (for fuse programming) |
| 0x030 | OCOTP_READ_CTRL | Read control register |
| 0x034 | OCOTP_READ_FUSE_DATA | Sense amplifier output |
| 0x038 | OCOTP_SW_STICKY | Software sticky bits |
| 0x040 | OCOTP_SCS | Software controllable signals |
| 0x100 | OCOTP_VERSION | Controller version |

### OCOTP_CTRL Bit Fields

| Bits | Field | Description |
|------|-------|-------------|
| [7:0] | ADDR | Fuse address for read/write operations |
| [8] | BUSY | 1 = fuse controller busy, poll until 0 |
| [9] | ERROR | 1 = fuse programming error occurred |
| [10] | RELOAD_SHADOWS | Write 1 to reload shadow registers |
| [12] | WR_UNLOCK[3:0] | Must write 0x3E77 to unlock for programming |
| [31:16] | WR_UNLOCK | Unlock key: 0x3E77 enables programming |

## Reading Fuses

### From U-Boot
```
=> fuse read <bank> <word>
=> fuse read 1 3
Bank 1 Word 0x00000003: 00000000
=> fuse read 3 0
Bank 3 Word 0x00000000: AABBCCDD
```

### From Linux (nvmem interface)
```bash
# OCOTP device appears as nvmem device
ls /sys/bus/nvmem/devices/
# imx-ocotp0

# Read all fuses (binary, 256 words x 4 bytes = 1024 bytes)
dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem bs=4 skip=0 count=256 | xxd

# Read specific fuse word
# Byte offset calculation: (bank * 8 + word) * 4
# Bank 3, Word 0: offset = (3 * 8 + 0) * 4 = 96 = 0x60
BANK=3
WORD=0
OFFSET=$(( (BANK * 8 + WORD) * 4 ))
dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem bs=1 skip=$OFFSET count=4 2>/dev/null | xxd

# Read SEC_CONFIG fuse (Bank 1, Word 3)
BANK=1; WORD=3
OFFSET=$(( (BANK * 8 + WORD) * 4 ))
dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem bs=1 skip=$OFFSET count=4 2>/dev/null | xxd
```

### From Linux (/dev/mem - requires CONFIG_STRICT_DEVMEM=n)
```bash
# Read shadow register at 0x30350780 (Bank 3, Word 0)
devmem2 0x30350780 w
# Value at address 0x30350780 (0x30350780): 0xAABBCCDD

# Read shadow register for SEC_CONFIG (Bank 1, Word 3)
# Address = 0x30350000 + 0x400 + (1 * 0x80) + (3 * 0x10)
# Address = 0x30350000 + 0x400 + 0x80 + 0x30 = 0x303504B0
devmem2 0x303504B0 w
```

### Shadow Register Reload (after fuse programming)
```bash
# Force reload of all shadow registers from fuse array
# In Linux (requires devmem or kernel driver support):
# Write RELOAD_SHADOWS bit to OCOTP_CTRL_SET (offset 0x004)
devmem2 0x30350004 w 0x400
# Wait for BUSY to clear
devmem2 0x30350000 w   # BUSY bit [8] should be 0
```

## Programming Fuses

### U-Boot fuse prog
```
# Syntax: fuse prog [-y] <bank> <word> <value>
# -y: skip confirmation prompt (use in scripted environments)

# Example: program first SRK word
=> fuse prog -y 3 0 0xAABBCCDD
Programming bank 3 word 0x00000000 to 0xAABBCCDD...
Warning: Programming fuses is an irreversible operation!
=> fuse read 3 0
Bank 3 Word 0x00000000: AABBCCDD
```

### Voltage Requirements
- VDD_FUSE must be 1.8V during programming (not 1.5V or 3.3V)
- i.MX8MP: PMIC (PCA9450) controls VDD_FUSE via I2C
- U-Boot fuse driver calls `fuse_prog_voltage()` automatically
- Incorrect voltage = failed programming or permanent corruption
- After programming: VDD_FUSE can return to normal operating voltage

### Programming Timing Parameters (OCOTP_TIMING)
```
OCOTP_TIMING fields required for correct fuse programming:
- STROBE_PROG: programming strobe pulse width (microseconds)
- RELAX: relaxation time between operations
- STROBE_READ: read strobe width
- WAIT: wait time after programming

i.MX8MP typical values (at 800 MHz AHB clock):
STROBE_PROG = 10 us minimum
RELAX       = 7 AHB cycles
STROBE_READ = 37 AHB cycles
```

## Complete Fuse Map Reference

| Bank | Word | Name | Description |
|------|------|------|-------------|
| 0 | 0 | LOCK | Lock register for all other fuse rows |
| 0 | 1 | BOOT_CFG0 | Boot configuration word 0 |
| 0 | 2 | BOOT_CFG1 | Boot configuration word 1 |
| 0 | 3 | BOOT_CFG2 | Boot configuration word 2 |
| 1 | 0 | MEM_TRIM0 | Memory trim 0 |
| 1 | 1 | MEM_TRIM1 | Memory trim 1 |
| 1 | 2 | ANA_TRIM | Analog trim |
| 1 | 3 | CFG5 | SEC_CONFIG, JTAG settings, BOOT_FUSE_SEL |
| 2 | 0-7 | UNIQUE_ID | 256-bit hardware unique ID |
| 3 | 0-7 | SRK_HASH | SRK table SHA-256 hash (HABv4) |
| 4 | 0 | MAC_ADDR0 | Ethernet MAC address bytes [3:0] |
| 4 | 1 | MAC_ADDR1 | Ethernet MAC address bytes [5:4] |
| 4 | 2 | MAC_ADDR2 | Second Ethernet MAC (if dual port) |
| 4 | 3 | SRK_REVOKE | SRK revocation bits [3:0] |
| 5 | 0-7 | GP3-GP10 | General purpose fuses |
| 6 | 0-7 | GP11-GP18 | General purpose fuses |
| 7 | 0-3 | OTPMK | OTP Master Key (AES-256 for CAAM) |
| 7 | 4-7 | OTPMK_cont | OTP Master Key continued |
| 8 | 0-7 | SW_GP | Software general purpose fuses |
| 9 | 0-7 | GP_ARB | General purpose / anti-rollback counter |

## Fuse Lock Register (Bank 0, Word 0)

Once a lock bit is set, the corresponding fuse word cannot be programmed again.

| Bits | Field | Locked Register |
|------|-------|----------------|
| [0] | TESTER | Tester fuse row |
| [1] | BOOT_CFG | Boot configuration (Bank 0) |
| [2] | MEM_TRIM | Memory trim |
| [3] | ANALOG | Analog trim |
| [4] | SRK | SRK hash (Bank 3, Words 0-7) |
| [5] | GP | General purpose fuses |
| [6] | OTPMK | OTP Master Key |
| [7] | SW_GP | Software general purpose |

```
# Lock SRK fuses after programming to prevent accidental modification:
=> fuse prog -y 0 0 0x10
# Now Bank 3 (SRK) cannot be reprogrammed
# NOTE: Lock bits themselves can only be set, not cleared
```
