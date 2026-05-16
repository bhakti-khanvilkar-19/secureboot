# Section 18: Fuse Programming

## Overview

Fuses are the hardware foundation of secure boot. They are the mechanism by which a device's trust relationship with your PKI is permanently encoded into silicon, ensuring that no software attack — not even one with full firmware control — can change which keys the device trusts.

This chapter covers everything needed to correctly program, verify, and reason about fuses on the NXP i.MX8MP platform. Incorrect fuse programming is a catastrophic, irreversible error. Every engineer who handles fuse programming must understand this content completely before touching a device.

**The single most important property of fuses:** They can only be set (0 → 1), never cleared (1 → 0). One incorrectly programmed bit permanently alters the device's security posture, potentially rendering it permanently unbootable or permanently insecure.

---

## What Are Fuses: OCOTP (On-Chip One-Time Programmable) Memory

The i.MX8MP implements fuses through the **OCOTP (On-Chip One-Time Programmable)** memory block. OCOTP is an IP block integrated into the SoC that provides:

- **E-fuses:** Microscopic polysilicon or metal links that can be permanently blown (open-circuited) using a precisely controlled programming current.
- **Sense cells:** Read circuitry that detects whether each fuse link is intact or blown.
- **Shadow registers:** SRAM registers loaded from fuse cells at power-on. Software reads fuse values through these shadow registers, not directly from the fuse cells.
- **Programming interface:** Voltage-boosted circuitry for applying the programming current to blow fuse links.

### Physical Fuse Programming Mechanism

Each OCOTP bit is represented by a link that is normally conducting (logic 0). Applying a programming voltage (approximately 2.6V internally generated on i.MX8MP) causes sufficient current to flow through the link to permanently open-circuit it (logic 1).

This is irreversible because:
1. The open-circuit is a physical destruction of the fuse link material.
2. No electrical means can restore a broken link.
3. Even if somehow repaired, the programming attempt would be detected by the OCOTP ECC.

### Shadow Registers

The OCOTP block contains two regions:
- **Fuse array:** The actual E-fuse cells, programmed once.
- **Shadow registers:** SRAM that is loaded from the fuse array during system reset (before the processor begins executing code).

Software reads fuse values through the shadow registers (memory-mapped at the OCOTP base address). The shadow registers are initialized from the fuse array during power-on and cannot be overridden except through a special "fuse override" mechanism used only in test/debug environments.

The shadow registers are useful because:
- Reading from fuse cells directly requires careful timing and is slow.
- The shadow registers provide standard memory-mapped access.
- Fuse readback can be performed at any time, not just during a specific boot phase.

---

## Why Fuses Are Used for Security: Permanent, Immutable, Tamper-Evident

Fuses provide security guarantees that no software mechanism can match:

| Property | Software Security | Fuse-Based Security |
|----------|------------------|---------------------|
| Immutability | Depends on access controls, can be bypassed | Physical — requires destroying the chip |
| Attack resistance | Vulnerable to privilege escalation, buffer overflows | No software path to modification |
| Tamper evidence | Audit logs (can be deleted) | Physical state change — permanent |
| Remote manipulation | Possible if attacker has remote code execution | Impossible — requires physical access + reset |
| Post-factory modification | Depends on write protect config | Architecturally impossible |

For secure boot, this means:
- An attacker who compromises the running OS cannot change which keys the bootloader trusts.
- An attacker who gains U-Boot access cannot retroactively enable HAB after testing with unsigned firmware.
- An attacker who physically replaces the eMMC cannot make the SoC boot from it without having the matching private keys.
- Manufacturing quality control failures (wrong firmware loaded) cannot be papered over by re-blowing fuses.

---

## i.MX8MP OCOTP Register Map Overview

The i.MX8MP OCOTP peripheral is organized as banks of 32-bit words. Each bank contains 8 words (or some banks have 4), for a total of several hundred programmable words.

**Key addressing:**
- OCOTP base address: `0x30350000`
- Each shadow register: `base + 0x400 + (bank * 0x200) + (word * 0x10)`
  - Actually the shadow registers use: `base + 0x400 + (index * 0x10)` where `index = bank*8 + word`
- Programming registers: accessed via OCOTP_CTRL, OCOTP_TIMING, OCOTP_DATA

The `fuse` command in U-Boot handles the address calculation automatically:
```
fuse read <bank> <word>      reads OCOTP shadow register at bank/word
fuse prog <bank> <word> <v>  programs the fuse cell at bank/word
```

---

## Critical Security Fuses

### SRK_HASH (Bank 3, Words 0-7)

**What it is:** The SHA-256 hash of the Super Root Key (SRK) table. The SRK table contains up to 4 public keys (RSA-2048 or EC-P256) used to sign the bootloader and firmware chain.

**Structure:** 256 bits (32 bytes) spread across 8 × 32-bit words in Bank 3:
```
Bank 3, Word 0: SRK_HASH[255:224]   (most significant 32 bits)
Bank 3, Word 1: SRK_HASH[223:192]
Bank 3, Word 2: SRK_HASH[191:160]
Bank 3, Word 3: SRK_HASH[159:128]
Bank 3, Word 4: SRK_HASH[127:96]
Bank 3, Word 5: SRK_HASH[95:64]
Bank 3, Word 6: SRK_HASH[63:32]
Bank 3, Word 7: SRK_HASH[31:0]     (least significant 32 bits)
```

**Consequence of wrong value:** If the wrong SRK hash is burned and the device is closed (SEC_CONFIG set), the device will refuse to boot any firmware signed with your keys, because the ROM computes the hash of the SRK table in the image header and compares it against the burned fuse value. A mismatch → boot failure → permanently bricked device (must be destroyed).

**Source of correct values:** Generated by NXP `srktool`:
```bash
srktool --hab_ver 4 \
        --certs SRK1.pem SRK2.pem SRK3.pem SRK4.pem \
        --table SRK_table.bin \
        --efuse_entries SRK_fuse.bin \
        --format bin
```
The resulting `SRK_fuse.bin` is exactly 32 bytes. Split into 8 big-endian 32-bit words for fuse programming.

### SEC_CONFIG (Bank 1, Word 3, Bit 1)

**What it is:** The bit that transitions the i.MX8MP from "open" boot mode to "closed" (HAB-enforced) boot mode.

| Value | Mode | Description |
|-------|------|-------------|
| 0 | Open | ROM boots any image regardless of signature. HAB API functions still work for testing. |
| 1 | Closed (FAB) | ROM enforces HAB. Only images signed by a key matching SRK_HASH will boot. |

Note: The `fuse prog -y 1 3 0x2` command sets bit 1 (value = 2 = binary 10).

**Irreversibility:** Once bit 1 is set, it cannot be cleared. The device is permanently in closed/HAB-enforced mode.

**Consequence of premature closure:** If SEC_CONFIG is set before SRK fuses are correctly programmed, the device will attempt to validate firmware against an all-zeros hash, which will never match, and the device cannot be recovered.

**Consequence of correct closure:** After correct closure, the device will only boot images signed by a key whose certificate chain roots in the burned SRK hash. This is the desired production state.

### DIR_BT_DIS (Bank 1, Word 3, Bit 3)

**What it is:** "Disable Direct Boot." When set, disables the Serial Downloader mode (USB SDP / UART download). This prevents an attacker from using the USB SDP protocol to load arbitrary code.

**When to set:** Set during production closure. During provisioning, you need USB SDP to boot the provisioning image. After provisioning is complete and the device is closed, USB SDP is no longer needed and should be disabled.

**Value:** Set bit 3 in Bank 1 Word 3: `0x00000008`

**Combined with SEC_CONFIG:** In practice, Bank 1 Word 3 needs multiple bits set:
```
bit 1: SEC_CONFIG (HAB closure)
bit 3: DIR_BT_DIS (disable serial downloader)
bit 4: BT_FUSE_SEL (boot device from fuses)
bits 23:22: JTAG_SMODE (00=JTAG enabled, 11=JTAG disabled)
```
All of these are programmed into Bank 1 Word 3 (ORed together since fuses can only be set, not cleared):
```bash
# Program all security bits in Bank 1 Word 3
# 0x2 = SEC_CONFIG, 0x8 = DIR_BT_DIS, 0x10 = BT_FUSE_SEL, 0xC00000 = JTAG disabled
fuse prog -y 1 3 0x00C0001A
# Binary: 0000 0000 1100 0000 0000 0000 0001 1010
#         ^    ^ ^ ^                       ^ ^ ^
#         bit23-22=11               bit4=1 ^ bit1=1
#         JTAG_SMODE=11           BT_FUSE_SEL DIR_BT_DIS SEC_CONFIG
```

### BT_FUSE_SEL (Bank 1, Word 3, Bit 4)

**What it is:** When set, the boot device is determined by BOOT_CFG fuse values, not by the hardware boot mode pins. This prevents an attacker from using boot mode pins to force boot from an attacker-controlled source.

**When to set:** During production closure. Must be set in conjunction with programming the correct boot configuration into the BOOT_CFG fuses.

### SRK_REVOKE (Bank 4, Word 3, Bits 3:0)

**What it is:** Four bits corresponding to SRK keys 0-3. Setting bit N revokes SRK key N. If the private key for SRK1 is compromised, you can burn bit 0 of SRK_REVOKE to prevent SRK1 from being used, while SRK2, SRK3, SRK4 remain trusted.

| Bit | SRK Key | Default |
|-----|---------|---------|
| 0 | SRK1 | 0 (valid) |
| 1 | SRK2 | 0 (valid) |
| 2 | SRK3 | 0 (valid) |
| 3 | SRK4 | 0 (valid) |

**Revocation model:** HABv4 requires that at least one SRK key remains non-revoked. If all 4 bits are set (all keys revoked), the device will fail all HAB verifications and cannot boot.

**In-field revocation:** SRK_REVOKE bits can be set via a signed firmware update that includes a revocation command in the HAB CSF (Command Sequence File). This allows key revocation without physical access.

### JTAG_SMODE (Bank 1, Word 3, Bits 23:22)

**What it is:** Controls the JTAG debug mode.

| Value | Mode | Description |
|-------|------|-------------|
| 0b00 | All debug enabled | JTAG fully functional (development default) |
| 0b01 | Secure JTAG | JTAG requires challenge/response authentication |
| 0b10 | User mode debug | Limited JTAG access |
| 0b11 | No debug | JTAG port completely disabled |

**Production setting:** `0b11` (JTAG disabled). An attacker with physical access cannot use JTAG to debug, extract memory, or inject code.

**Development consideration:** During development, JTAG is essential. Do not close JTAG in development boards. Use separate fuse programming batches for production closure.

### KTE (Bank 1, Word 3, Bit 20)

**What it is:** Key Transfer Enable. When set, enables key transfer from CAAM to external memory (for Trusted Execution Environment key provisioning scenarios). Typically left at 0 for standard deployments unless explicitly needed.

### FIELD_RETURN (Bank 1, Word 3, Bit 5)

**What it is:** Field Return mode. Setting this bit puts the device into a special mode that NXP support uses to debug field-returned devices. It bypasses some security restrictions.

**Security implication:** Never set this in production devices. If an attacker can set this bit (requires physical hardware programming), they can reduce the security posture. The bit is set intentionally only when returning a device to NXP for failure analysis.

---

## Fuse Read Methods

### Method 1: U-Boot `fuse read` Command

```bash
# Read a single word
=> fuse read <bank> <word>
# Example: Read SEC_CONFIG
=> fuse read 1 3
Bank 1 Word 0x00000003: 00000002

# Read multiple words
=> fuse read <bank> <word> <count>
# Example: Read all 8 SRK hash words
=> fuse read 3 0 8
Bank 3 Word 0x00000000: A1B2C3D4
Bank 3 Word 0x00000001: E5F60718
Bank 3 Word 0x00000002: 293A4B5C
Bank 3 Word 0x00000003: 6D7E8F90
Bank 3 Word 0x00000004: 01234567
Bank 3 Word 0x00000005: 89ABCDEF
Bank 3 Word 0x00000006: FEDCBA98
Bank 3 Word 0x00000007: 76543210
```

U-Boot reads from shadow registers (the same values the ROM used during boot).

### Method 2: Linux `/sys/bus/nvmem`

The OCOTP Linux driver (`drivers/nvmem/imx-ocotp.c`) exposes OCOTP as an nvmem device:

```bash
# Location (may vary by kernel version/DT binding):
ls /sys/bus/nvmem/devices/
# imx-ocotp0

# Read raw fuse data (binary)
hexdump -C /sys/bus/nvmem/devices/imx-ocotp0/nvmem | head -20

# Read specific word (offset = bank*0x20 + word*4 in nvmem layout)
# Bank 1, Word 3 = offset 0x28 (40 bytes from start of bank 1, bank starts at 0x20)
# Actual offset calculation: (bank * 0x80) + (word * 0x10) in fuse controller space
# But nvmem byte offset: bank * 32 + word * 4
dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem bs=4 skip=11 count=1 2>/dev/null | xxd

# Or using the nvmem sysfs read (kernel 5.4+)
# cell names are defined in Device Tree
cat /sys/bus/nvmem/devices/imx-ocotp0/cells/
```

Linux nvmem read requires read permission on the nvmem device. In production, restrict access to root only.

### Method 3: Direct Memory Access (`devmem2`)

For direct register access (development debugging only):

```bash
# OCOTP shadow register base (shadow register set)
# Address = 0x30350400 + index * 0x10
# index = bank * 8 + word
# Bank 3, Word 0: index = 24, addr = 0x30350400 + 24 * 0x10 = 0x30350580
devmem2 0x30350580 w
# /dev/mem address 0x30350580

# Bank 1, Word 3: index = 11, addr = 0x30350400 + 11 * 0x10 = 0x303504B0
devmem2 0x303504B0 w
```

**Note:** Direct memory access to OCOTP registers requires kernel support for `/dev/mem` with `CONFIG_STRICT_DEVMEM=n` or use of a kernel module. Not available in production (CONFIG_STRICT_DEVMEM should be y).

### Method 4: NXP `uuu` Tool

```bash
# uuu supports reading fuse values via scripted commands
# Create a uuu script:
cat > read_fuses.auto << 'EOF'
uuu_version 1.2.135
SDP: boot -f provisioning-image.bin
SDPV: write -f read_fuses.sh -addr 0x80000000
SDPV: jump -addr 0x80000000
EOF

uuu read_fuses.auto
```

The `uuu` tool is primarily used for manufacturing-scale provisioning (see Section 19).

---

## Fuse Programming Methods

### Method 1: U-Boot `fuse prog` Command (Primary Method)

```bash
# Syntax: fuse prog [-y] <bank> <word> <hexval>
# -y: skip confirmation prompt (for scripted use)

# Example: Program SRK hash word 0
=> fuse prog 3 0 0xA1B2C3D4
Warning: Programming fuses is an irreversible operation!
         This may brick your system.
         Use this command only if you are sure of what you are doing!
Really perform this fuse programming? <y/N>
y
Programming bank 3 word 0x00000000 to 0xA1B2C3D4...
```

For scripted provisioning, always use `-y` to suppress the interactive prompt:
```bash
=> fuse prog -y 3 0 0xA1B2C3D4
```

### Method 2: Linux nvmem Write (Limited Support)

The Linux OCOTP driver supports write access on some kernel configurations:

```bash
# Writing to nvmem device requires root + appropriate OCOTP driver config
# NOT all kernel builds enable write support
# This is less common than U-Boot programming
# Offset for Bank 3, Word 0: 3 * 32 + 0 * 4 = 96 = 0x60
printf '\xD4\xC3\xB2\xA1' | dd of=/sys/bus/nvmem/devices/imx-ocotp0/nvmem \
    bs=4 seek=24 count=1 2>/dev/null
```

**Important:** Write byte order. OCOTP shadow registers are accessed as little-endian by the ARM core, but the fuse values in HAB documentation are typically big-endian. Verify byte order carefully when using nvmem write.

### Method 3: NXP `uuu` Tool for Manufacturing

See Section 19. The `uuu` tool supports scripted fuse programming via the SDP boot protocol.

---

## Fuse Verification

After programming, always read back fuse values and compare against expected values before proceeding:

```bash
# Systematic verification of all SRK fuse words
# Expected values from srktool output in /tmp/srk_fuses.txt
# Format: bank word value (space-separated)

verify_fuses() {
    local errors=0
    while read -r bank word expected; do
        actual=$(fuse read "${bank}" "${word}" | awk '/Bank/{print $NF}')
        if [ "${actual}" = "${expected}" ]; then
            echo "OK: bank=${bank} word=${word} value=${actual}"
        else
            echo "MISMATCH: bank=${bank} word=${word} expected=${expected} got=${actual}"
            errors=$((errors + 1))
        fi
    done < /tmp/srk_fuses.txt
    return ${errors}
}
```

---

## One-Way Nature: Cannot Un-Blow Fuses

This point cannot be overemphasized in a reference document:

**There is no "undo" for fuse programming.**

- `fuse prog 3 0 0xA1B2C3D4` → sets 8 bits in that word permanently. Even if you try to `fuse prog 3 0 0x00000000`, the bits that are 1 remain 1.
- `fuse prog -y 1 3 0x2` → SEC_CONFIG is now set. Forever. No software, no hardware access, no NXP support can unset it.
- Incorrect SRK hash + SEC_CONFIG set = device is bricked and must be destroyed.

### Practical Consequences

1. **Test everything before closing.** Boot and test your signed firmware with HAB in non-closed mode before setting SEC_CONFIG.
2. **Use HAB API in open mode.** Call `hab_auth_img` explicitly to verify HAB works with your signed firmware before burning SEC_CONFIG.
3. **Triple-check SRK fuse values.** Use automation to avoid transcription errors.
4. **Provision a canary device first.** Before running a batch, provision one device and verify end-to-end before the full production run.
5. **Keep signed canary firmware.** If you're closing with SRK hash X, keep the firmware signed with the matching key readily available for post-closure validation.

---

## Voltage Requirements for Fuse Programming

The OCOTP fuse programming circuitry on i.MX8MP requires a specific programming voltage:

- **Read operation:** Normal VDD_SOC supply (~0.9V core, 1.8V I/O)
- **Program operation:** The i.MX8MP generates an internal programming voltage (~2.6V) from the 3.3V supply using an on-chip charge pump.

External supply requirements during fuse programming:
- VDD_SOC must be within spec (typically 0.8-1.0V)
- VDD_IO (3.3V domain) must be present and stable (OCOTP charge pump uses this)
- Voltage must be stable during the programming operation (do not allow voltage droop)

**Power supply recommendation:** Use a bench power supply with <5% ripple during fuse programming in development. In production, ensure the manufacturing fixture provides adequate decoupling capacitors.

### Low-Voltage Protection

The OCOTP controller includes a low-voltage detector. If VDD_IO drops below a threshold during programming, the operation is aborted and may leave the fuse in an intermediate state. For this reason:
- Never program fuses from battery-powered systems where the battery may be low.
- Use a stable external power supply during factory provisioning.

---

## Temperature Requirements

Fuse programming is temperature-sensitive:

- **Specification:** NXP specifies fuse programming at 25°C ± 15°C (10°C to 40°C ambient)
- **Outside this range:** Programming reliability decreases. Fuse cells may not blow completely, resulting in intermittent read failures.
- **In production:** Factory temperature control is standard practice. Verify ambient temperature meets spec before starting a provisioning run.
- **At read time:** Temperature is not critical for fuse reading (shadow registers are standard SRAM).

---

## ECC in Fuse Memory

OCOTP uses a lightweight ECC scheme. Each 32-bit fuse word has additional parity bits that detect and (in some cases) correct single-bit errors. The ECC is transparent to software — the OCOTP driver handles it automatically.

**Implication for partial programming failures:**
If a fuse word is partially programmed (some bits blown, others not), the ECC bits will also be partially correct. This can result in a word that reads back differently from what was programmed. This is extremely rare but possible with out-of-spec voltage or temperature.

**Why this matters:** If a readback verification catches a mismatch, the fuse state may be partially programmed and should be treated as unknown/invalid. Do not close the device if any fuse verification fails.

---

## Shadow Register Override (Development Use Only)

U-Boot provides a `fuse override` command that modifies the shadow registers without burning the actual fuse cells:

```bash
# Override shadow register (does NOT program fuse cells)
# Used in development to test fuse-dependent code paths without burning fuses
=> fuse override 3 0 0xA1B2C3D4
```

**Important limitations:**
- The override is lost on the next power cycle (shadow registers are reloaded from fuse array at reset).
- The override affects software that reads shadow registers (U-Boot, Linux kernel), but the HAB ROM uses the fuse cells directly during the pre-boot phase. ROM-level HAB behavior cannot be tested with shadow register overrides.
- Never confuse `fuse override` with `fuse prog`. One is temporary and safe; the other is permanent and irreversible.

---

## Fuse Programming Checklist

### Pre-Programming Checklist

- [ ] SRK certificates verified: correct keys, not expired, match intended signing PKI
- [ ] `srktool` output (`SRK_fuse.bin`) generated and hexdump verified manually
- [ ] Fuse values converted to U-Boot format and triple-checked by second engineer
- [ ] Signed firmware (matching SRK keys) boots successfully in HAB open mode
- [ ] HAB API call (`hab_auth_img`) succeeds on signed firmware in open mode
- [ ] Development board (separate from production batch) has been used to validate end-to-end
- [ ] Power supply voltage stable and within spec
- [ ] Ambient temperature within spec (10-40°C)
- [ ] Provisioning station isolation verified (no unexpected network access)
- [ ] Provisioning database available and responsive
- [ ] Audit log server available

### Post-Programming Checklist (Before SEC_CONFIG Burn)

- [ ] All 8 SRK fuse words read back and match expected values
- [ ] SHA-256 of fuse readback computed and matches expected hash
- [ ] JTAG_SMODE fuses programmed and verified (bits 23:22 of Bank 1 Word 3)
- [ ] DIR_BT_DIS programmed (bit 3 of Bank 1 Word 3)
- [ ] BT_FUSE_SEL programmed (bit 4 of Bank 1 Word 3)
- [ ] RPMB provisioned (if applicable)
- [ ] Device certificate stored
- [ ] Provisioning server has confirmed readiness to close

### Post-SEC_CONFIG Checklist

- [ ] SEC_CONFIG bit read back and confirmed set (Bank 1 Word 3 bit 1 = 1)
- [ ] Device rebooted
- [ ] Production firmware boots successfully (signed firmware)
- [ ] HAB log shows no errors: U-Boot `hab_status` → "HAB Configuration: 0x2, HAB State: 0x0" (Closed + Trusted)
- [ ] Production software functions correctly
- [ ] Device certificate TLS connection test passed
- [ ] Provisioning database updated to "provisioned" state
- [ ] Audit log entry recorded and confirmed received by audit server

---

## Related Sections

- **Section 17 — Provisioning Workflows:** How fuse programming fits into the complete provisioning process
- **Section 18-01 — OCOTP Register Map:** Complete register-level reference
- **Section 18-02 — Fuse Programming Procedures:** Step-by-step procedures with exact U-Boot commands
- **Section 18-03 — SRK Hash Verification:** Computing and verifying SRK fuse values
- **Section 19 — Manufacturing Security:** uuu tool for batch provisioning
