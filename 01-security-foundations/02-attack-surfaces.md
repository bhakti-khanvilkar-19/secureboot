# 02-attack-surfaces: Technical Attack Surface Analysis

## Overview

An attack surface is the set of entry points through which an adversary can attempt to compromise a system. For embedded Linux boot security, the attack surfaces span hardware debug interfaces, software protocols, storage media, cryptographic implementations, and operational processes.

This document enumerates each attack surface with technical specificity: what the surface is, how an attacker exploits it, what equipment they need, how detectable the attack is, and what mitigations reduce the risk.

---

## Boot Chain Attack Surface Map

```
  COMPLETE ATTACK SURFACE MAP - i.MX8MP
  ══════════════════════════════════════════════════════════════════

  ┌──────────────────────────────────────────────────────────────┐
  │                         HARDWARE                              │
  │                                                              │
  │  JTAG ──────────────────────────────────── [SURF-01]        │
  │  UART Console ──────────────────────────── [SURF-02]        │
  │  USB Serial Download (SDP) ─────────────── [SURF-03]        │
  │  Boot Mode Pins ────────────────────────── [SURF-04]        │
  │  eMMC Bus (physical) ───────────────────── [SURF-05]        │
  │  DRAM Bus (physical) ───────────────────── [SURF-06]        │
  │  Power Supply Manipulation ─────────────── [SURF-07]        │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │                        STORAGE                               │
  │                                                              │
  │  SD Card Boot Media ────────────────────── [SURF-08]        │
  │  eMMC Boot Partitions ──────────────────── [SURF-09]        │
  │  SPI NOR Flash (if used) ───────────────── [SURF-10]        │
  │  Root Filesystem (eMMC user area) ──────── [SURF-11]        │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │                        SOFTWARE                              │
  │                                                              │
  │  U-Boot Environment Variables ──────────── [SURF-12]        │
  │  U-Boot Command Interface ──────────────── [SURF-13]        │
  │  Kernel Command Line ───────────────────── [SURF-14]        │
  │  Kernel Module Loading ─────────────────── [SURF-15]        │
  │  OTA Update Mechanism ──────────────────── [SURF-16]        │
  │  initramfs ─────────────────────────────── [SURF-17]        │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │                    CRYPTOGRAPHIC                             │
  │                                                              │
  │  Weak Key Generation ───────────────────── [SURF-18]        │
  │  Algorithm Downgrade ───────────────────── [SURF-19]        │
  │  Side-Channel Attacks on CAAM ──────────── [SURF-20]        │
  │  Replay Attacks ────────────────────────── [SURF-21]        │
  │  Certificate Chain Issues ──────────────── [SURF-22]        │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │                      OPERATIONAL                             │
  │                                                              │
  │  Insecure Key Storage ──────────────────── [SURF-23]        │
  │  Build Pipeline Compromise ─────────────── [SURF-24]        │
  │  Manufacturing Station Access ──────────── [SURF-25]        │
  │  Incomplete Fuse Programming ───────────── [SURF-26]        │
  │  Key Personnel Insider Threat ──────────── [SURF-27]        │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘
```

---

## SURF-01: JTAG Debug Interface

**What it is:** Joint Test Action Group (IEEE 1149.1) is a 4-wire debug interface (TCK, TMS, TDI, TDO) that provides processor-level debug access. On i.MX8MP, JTAG is accessible via the SWD/JTAG connector or dedicated JTAG pins.

**Attack capability:**
- Halt any processor core
- Read/write any accessible memory (OCRAM, DRAM, peripheral registers)
- Set hardware breakpoints anywhere in execution
- Single-step through boot code
- Extract CAAM black key material if CAAM is accessible
- Reprogram fuses (if JTAG is enabled during fuse operations)

**Equipment required:**
- JTAG probe: ARM DSTREAM (~$5000), Segger J-Link Pro (~$1000), cheap clones (~$50)
- Physical access to JTAG pins (may require opening enclosure)

**Detectability:** LOW. JTAG connections are typically unlogged in hardware.

**Exploitation sequence:**
```
1. Identify JTAG pins (consult schematic or probe test points)
2. Connect JTAG probe
3. Use OpenOCD or vendor debug software to connect:
   openocd -f interface/jlink.cfg -f target/imx8mp.cfg
4. At OpenOCD prompt:
   > halt                     # Stop all cores
   > targets                  # Show available targets
   > mdw 0x40000000 16        # Read 16 words from DRAM
   > mww 0x00900000 0x...     # Write to OCRAM (inject code)
5. Transfer execution to injected code
```

**Mitigations:**

| Mitigation | Mechanism | Residual Risk |
|-----------|-----------|---------------|
| Burn `JTAG_SMODE` fuse | JTAG permanently disabled | Physical probing at silicon level |
| Secure JTAG (SJC) | JTAG requires challenge-response | Key material for SJC still accessible to sophisticated attacker |
| Physical enclosure | JTAG pins inaccessible | Enclosure opening tools; time-bounded |
| Production fuse check in SW | App detects JTAG and wipes | Race condition; not reliable |

**Recommended production configuration:**
```
# Burn JTAG disable fuse (i.MX8MP OCOTP_CFG5)
# JTAG_SMODE[1:0] = 2'b11 (secure JTAG mode with SJC challenge)
# or 
# DIR_BT_DIS + JTAG_HEO = disable all JTAG
# See 17-fuse-programming for exact fuse addresses
```

---

## SURF-02: UART Console

**What it is:** Universal Asynchronous Receiver-Transmitter serial console, typically connected to UART1 on i.MX8MP at 115200 8N1. Provides interactive U-Boot console access and kernel console.

**Attack capability (without U-Boot console protection):**
- Interactive U-Boot shell with `md`, `mw`, `go`, `bootz` commands
- Load arbitrary code via `loadx` (xmodem) or network boot (`tftpboot`)
- Modify U-Boot environment: `setenv bootargs`, `setenv bootcmd`
- Override boot command: execute arbitrary kernel or skip kernel
- Access kernel filesystem during initramfs stage

**Attack capability (with U-Boot console protection, via information leakage):**
- Boot timing information (version strings, DDR size, peripheral detection)
- Error messages revealing kernel version, hardware configuration
- ASLR randomization seeds (in some configurations, the kernel prints its load address)

**Equipment required:** USB-to-UART adapter (~$5), physical access to UART pins

**Detectability:** LOW. UART connections are not typically logged.

**U-Boot console attack example:**
```
# At U-Boot boot delay prompt, press any key:
U-Boot 2023.04 (Sep 15 2023)
...
Hit any key to stop autoboot:  3  2  1  [ENTER]

# Now at U-Boot prompt:
=> env default -a          # Reset all environment variables
=> setenv bootcmd 'echo hacked'  # Override boot command
=> saveenv                 # Save to persistent storage
=> boot                    # Reboot with new environment
```

**Mitigations:**

| Mitigation | Mechanism | Tradeoff |
|-----------|-----------|----------|
| Set U-Boot boot delay to 0 | `CONFIG_BOOTDELAY=0` | No key intercept window; must use pre-set BOOTCMD |
| Password protect console | `CONFIG_USE_BOOTCOMMAND` + password | Password must be stored somewhere |
| Disable console in production | Silent U-Boot build | Loses all debug visibility |
| U-Boot environment in read-only flash | MMC write-protect on boot partition | Environment changes require firmware update |
| Minimal UART output | Filter sensitive strings from output | Custom U-Boot build |

**Recommended production configuration:** Boot delay = 0, console disabled or protected, U-Boot environment stored in an authenticated partition.

---

## SURF-03: USB Serial Download Protocol (SDP)

**What it is:** The i.MX8MP Boot ROM supports a USB Serial Download Protocol that allows direct communication with the Boot ROM before any software loads. Entered by setting BOOT_MODE[1:0] = 2'b01 or when the normal boot device fails to contain a valid image.

**Attack capability:**
- Direct communication with Boot ROM via USB
- Load arbitrary code into OCRAM and execute it (in open mode)
- Read device configuration
- Flash boot media via UTP (Universal Transfer Protocol) commands
- In HABv4 open mode: execute unsigned SDP commands

**Equipment required:** USB cable, NXP `uuu` tool (Universal Update Utility, freely available), physical access

**Detectability:** LOW. USB connection may be logged by host but not by target.

**Attack sequence (open mode or no HABv4):**
```bash
# Install NXP uuu tool
sudo apt-get install uuu

# Set BOOT_MODE pins to USB download mode
# (or remove SD card with no valid image)

# Connect USB cable (USB OTG port on phyBOARD-Pollux)
# Device appears as USB VID:PID 15a2:0076

# List detected device
uuu -lsusb
# Output: FB      SN:21e6f93b   SE:Blank

# Flash arbitrary firmware (in open mode)
uuu -b emmc_all <u-boot-without-signature.imx> <rootfs.img>
```

**Mitigations:**

| Mitigation | Mechanism | Residual Risk |
|-----------|-----------|---------------|
| HABv4 closed mode | SDP authentication required | Requires signed SDP images |
| Disable USB download | Set `BT_FUSE_SEL` or override BOOT_MODE fuse | Can re-enable with physical BOOT_MODE pins if not fused |
| Fuse BOOT_MODE override disable | `DIR_BT_DIS` fuse | Cannot enter SDP by any means |

**i.MX8MP Specific:** The `BT_FUSE_SEL` fuse (OCOTP_CFG4[4]) forces boot from fuse-defined boot device, ignoring BOOT_MODE pins. Combined with `HABv4 closed`, this prevents USB SDP attacks effectively.

---

## SURF-05: Physical eMMC Bus Interception

**What it is:** The eMMC device communicates with the i.MX8MP via the MMC/SDIO bus (8-bit data, CMD, CLK). With appropriate high-speed logic analysis equipment, this bus traffic can be captured.

**Attack capability:**
- Passive capture: read all eMMC data during normal boot
- If bus is unencrypted: extract bootloader, kernel, and root filesystem
- Active man-in-the-middle: requires hardware proxy between SoC and eMMC (very complex)

**Equipment required:**
- High-speed logic analyzer (Saleae Pro 16 or equivalent, ~$500-$1500)
- eMMC physical access (requires board disassembly)
- Tools to decode MMC protocol from captured data

**Detectability:** ZERO (passive capture is completely invisible to software)

**What attacker gets:** Unencrypted boot images (if dm-crypt is not used). Filesystem layout. Application binaries. Configuration files.

**What attacker cannot easily do:** Modify bus traffic in real-time (requires hardware interposer).

**Mitigations:**
- dm-crypt full disk encryption (SURF-05 reveals only encrypted data)
- Physical tamper protection (potted enclosure, tamper-evident seals)
- Note: Secure Boot does not protect against passive interception; it only prevents modification

---

## SURF-06: DRAM Cold Boot Attack

**What it is:** DRAM retains its contents for seconds to minutes after power removal, especially when chilled. An attacker who can remove the device from power at a critical moment (e.g., immediately after dm-crypt key derivation) may be able to read DRAM contents from another system.

**Attack capability:**
- Read dm-crypt volume key from DRAM after power removal
- Read any sensitive data in DRAM: keys, credentials, application data

**Equipment required:**
- Physical access to device
- Ability to remove DRAM from board (or connect external memory reader)
- Cold spray or refrigerant (extends retention time)
- Memory analysis tools

**Detectability:** ZERO (passive post-mortem attack)

**Feasibility on i.MX8MP:**
- i.MX8MP uses LPDDR4 packages that are BGA-mounted (difficult to remove)
- Chill and read-in-place is possible with custom equipment
- This is a sophisticated attack requiring significant engineering

**Mitigations:**
- CAAM hardware key sealing (key material stays in CAAM, not accessible in DRAM)
- OP-TEE secure key operations (keys in Secure World DRAM, protected by TrustZone TZASC)
- Physical tamper protection with SNVS tamper detection
- Key derivation at last possible moment (reduces window)

---

## SURF-07: Power Supply Glitching

**What it is:** Voltage glitching involves intentionally introducing brief voltage drops or spikes to the processor's power supply to cause fault injection. Fault injection can cause the processor to skip instructions (including security checks) or execute with corrupt register state.

**Attack capability:**
- Skip a comparison instruction (e.g., skip the HAB authentication result check)
- Corrupt a counter register (skip loop iterations in signature verification)
- Cause speculative execution of code paths not taken in normal operation

**Equipment required:**
- Voltage glitcher hardware (ChipWhisperer, ~$500 to $5000, or custom)
- Physical access to power delivery network
- Significant expertise and repeated attempts

**Detectability:** Can be detected by brown-out detector if properly configured, or by timing anomaly detection.

**On i.MX8MP:**
- SNVS has a voltage glitch detector
- SNVS tamper detection can trigger key zeroization
- Boot ROM authentication is designed to resist simple glitching

**Mitigations:**
- SNVS tamper detection enable (detect abnormal voltage)
- Physical protection of power rails (decoupling capacitors, physical enclosure)
- CAAM-hardware-performed authentication (harder to glitch than software)

---

## SURF-08 and SURF-09: Storage Media Attacks

### SD Card Boot (SURF-08)

SD cards are removable, making replacement trivial. Even without JTAG access, an attacker with 30 seconds of physical access can swap the boot SD card.

**Complete exploitation without Secure Boot:**
```bash
# On attacker's system:
# 1. Obtain target device firmware (may be public or purchasable)
# 2. Modify bootloader or kernel
dd if=modified-spl.bin of=/dev/sdb bs=1k seek=33

# 3. Boot target with modified SD card
# → Attacker controls boot process
```

**Mitigation effectiveness:**
- HABv4 closed: substituted unsigned SPL → rejected → device doesn't boot
- HABv4 closed + correct signing: attacker needs SRK private key to create valid replacement
- Transition to eMMC boot: removes SD card as attack vector entirely

### eMMC Boot Partitions (SURF-09)

eMMC has dedicated BOOT1 and BOOT2 boot partitions. These are separate from the user data area and contain the primary bootloader.

**Attack requires:** eMMC read/write access. Possible vectors:
1. U-Boot `mmc write` command (if U-Boot console accessible)
2. OS-level `dd` to `/dev/mmcblk0boot0` (requires Linux root)
3. JTAG + memory write during boot (if JTAG enabled)
4. Physical eMMC interposer/reader (specialized equipment)

**Mitigation:** eMMC hardware write protection (`mmcblk0boot0` with `ro` attribute set via `mmc writeprotect boot`). With boot partition write protected, even root-privileged code cannot modify the bootloader.

```bash
# Check write protection status
cat /sys/block/mmcblk0boot0/ro
# 0 = writable, 1 = read-only

# Enable permanent write protection (IRREVERSIBLE on most eMMC)
echo 0 > /sys/block/mmcblk0boot0/force_ro  # Temporarily allow
mmc writeprotect boot set /dev/mmcblk0 0
cat /sys/block/mmcblk0boot0/ro
# Expected: 1
```

> **⚠️ WARNING:** eMMC permanent write protection cannot be reversed. Set only after the boot image is fully validated.

---

## SURF-11: Root Filesystem Tampering

**What it is:** If the root filesystem partition is writable (or the attacker has write access), they can modify any file in the filesystem, including system binaries, init scripts, and configuration files.

**Attack scenarios:**
- Install a rootkit in `/lib/ld.so` or `/usr/lib/`
- Modify `/etc/init.d/` or systemd units to execute attacker code at startup
- Replace system utilities with trojaned versions
- Add SUID binaries for persistent privilege escalation

**Persistence:** Without dm-verity, filesystem modifications persist across reboots.

**dm-verity mechanism:**
```
dm-verity uses a Merkle tree of SHA-256 hashes:

┌──────────────────────────────────────────────────┐
│            Root Hash (embedded in kernel cmdline  │
│            or signed FIT image)                   │
└──────────────────────────┬───────────────────────┘
                           │
              ┌────────────┴───────────┐
              │                        │
      ┌───────┴──────┐         ┌───────┴──────┐
      │  Hash Node    │         │  Hash Node    │
      └──────┬────────┘         └──────┬────────┘
     ┌───────┴───────┐         ┌───────┴───────┐
  [Block 0] [Block 1]       [Block N] [Block N+1]

Any modification to any block invalidates its hash,
which propagates up to invalidate the root hash.
Kernel detects mismatch and panics (or returns I/O error).
```

**Mitigation effectiveness:**
- dm-verity: rootfs modifications are detected on next block read
- Read-only rootfs + dm-verity: modifications fail immediately at write attempt
- Separate writable `/data` partition: legitimate writable storage without compromising boot integrity

---

## SURF-12: U-Boot Environment Variables

**What it is:** U-Boot stores its configuration in a persistent environment (stored in eMMC or SPI NOR). Environment variables control critical boot behavior: `bootcmd`, `bootargs`, `fdtfile`.

**Attack scenario:**
- An attacker with root access modifies U-Boot environment: `fw_setenv bootcmd 'run maliciouscmd'`
- On next boot, U-Boot executes the attacker's command instead of the legitimate boot sequence

**Tools:** `fw_printenv` / `fw_setenv` (user-space tools for U-Boot environment access)

```bash
# List current U-Boot environment
fw_printenv

# Modify boot command (requires root, writes to eMMC env partition)
fw_setenv bootcmd 'setenv bootargs console=ttymxc0,115200 root=/dev/mmcblk0p2; \
    load mmc 0:1 ${loadaddr} custom-kernel; bootz ${loadaddr} - ${fdt_addr}'
```

**Mitigations:**
- Store environment in an authenticated partition
- U-Boot `CONFIG_ENV_IS_IN_MMC` with write protection on env partition
- Environment signature verification (U-Boot supports `CONFIG_ENV_AES` or custom)
- Accept environment in read-only signed FIT image rather than separate env partition

---

## SURF-18: Weak Key Generation

**What it is:** If cryptographic keys are generated with insufficient entropy, they may be predictable or brute-forceable.

**Embedded-specific risk:** At early boot, before the Linux kernel entropy pool is seeded, `/dev/random` and `/dev/urandom` may be low-entropy. Key generation during early boot is risky.

**Concrete risk:** If device-unique keys (e.g., for OP-TEE secure storage) are generated using a low-entropy PRNG, they may be predictable from device serial number or boot timestamp.

**i.MX8MP CAAM TRNG:** The i.MX8MP CAAM includes a hardware True Random Number Generator (TRNG). Keys generated by CAAM TRNG have adequate entropy. Keys generated by software before the TRNG is properly seeded do not.

```c
/* Correct approach: generate key using CAAM TRNG */
/* In Linux with CAAM driver: use /dev/hwrng */
# cat /dev/hwrng | head -c 32 | xxd  # Should show random-looking data

/* Wrong approach: generate key in bootloader using software RNG */
/* before entropy pool is seeded */
rand() % KEY_SPACE  /* Completely predictable */
```

**Mitigations:**
- Use CAAM TRNG for all key generation
- Wait for kernel entropy pool to initialize before generating application keys
- Use `rngd` or `haveged` to feed hardware entropy into software pool
- For provisioning keys: generate on host system with verified entropy, not on target

---

## SURF-20: Side-Channel Attacks on CAAM

**What it is:** Side-channel attacks exploit physical characteristics of cryptographic operations—power consumption, electromagnetic emissions, or timing—to infer key material without directly accessing it.

**Relevance to i.MX8MP:**
- CAAM performs RSA, ECC, and AES operations in hardware
- Power traces during RSA decryption can leak private key bits (Simple Power Analysis, SPA)
- Differential Power Analysis (DPA) can extract keys from AES operations

**Equipment required:** Power measurement circuitry (shunt resistor + oscilloscope), signal processing capability. Sophisticated attack: custom hardware for DPA, thousands of traces needed.

**Feasibility:** SPA against RSA operations is feasible with standard test equipment. DPA against AES requires more traces but is well-documented in academic literature.

**CAAM countermeasures:** The i.MX8MP CAAM implements some side-channel countermeasures (algorithm blinding, randomized execution), but their specific implementation is not fully documented publicly.

**Mitigations:**
- Physical enclosure to prevent direct circuit access
- Power supply filtering (reduce power signal leakage)
- Accept as residual risk for non-nation-state threat model
- For FIPS-level requirements: use a certified CAAM configuration

---

## SURF-23: Insecure Key Storage

**What it is:** Private keys stored on disk-accessible storage (filesystem files, CI/CD environment variables) are accessible to any process with sufficient privilege.

**Common real-world mistake:**
```bash
# WRONG: Key stored in build directory
cat build/keys/srk1-private.pem
# -----BEGIN RSA PRIVATE KEY-----
# MIIJKAIBAAKCAgEAy9m8GFv...
# [This key is accessible to any process that can read the filesystem]

# WRONG: Key in CI/CD environment
echo $SRK_PRIVATE_KEY | cst --o out.bin --i csf.yaml

# WRONG: Key committed to git repository
git log --all --full-history -- '*.pem'
# commit 3f8a2...
# Author: Engineer <eng@company.com>
# [Private key committed, possibly to remote]
```

**Mitigations:**
- HSM storage: private key material never leaves HSM
- Air-gapped signing station: no network connection, full-disk encrypted
- Separation of signing from build: build produces unsigned artifacts; separate signed step uses HSM
- Git pre-commit hooks to detect key material:

```bash
# .git/hooks/pre-commit
#!/bin/bash
# Detect potential private key material in staged files
if git diff --cached | grep -q "BEGIN.*PRIVATE KEY"; then
    echo "ERROR: Potential private key material in commit. Aborting."
    exit 1
fi
```

---

## SURF-24: Build Pipeline Compromise

**What it is:** The Yocto build pipeline that produces firmware artifacts is itself an attack surface. Compromise of a Yocto layer, upstream repository, CI/CD system, or build host allows insertion of malicious code before signing.

**Attack chain:**
```
Compromise upstream Yocto layer
     → Malicious code enters u-boot recipe
     → Yocto builds modified U-Boot binary
     → Signing step signs the malicious binary
     → Signed malicious firmware deployed to all devices
```

**Detectability without mitigations:** VERY LOW. The modification appears as a legitimate change.

**Mitigations:**

| Mitigation | Implementation |
|-----------|---------------|
| Reproducible builds | Build from pinned source commits; same input → same output |
| Build artifact hashing | SHA-256 of build artifacts before signing; compare to expected |
| SBOM generation | `bitbake -g image` generates dependency list for review |
| Separate build and signing | Build produces unsigned artifact; second party reviews before signing |
| CI/CD hardening | Locked build environments, signed CI/CD configurations, no outbound network during build |
| Source pinning | `SRCREV` in recipes; no floating `AUTOREV` |

---

## Attack Surface Summary: Feasibility and Mitigation Status

| Surface | Attacker Type | Feasibility | Impact | Standard Mitigation | Notes |
|---------|--------------|-------------|--------|---------------------|-------|
| SURF-01: JTAG | Physical, equipped | HIGH | CRITICAL | Fuse disable | Highest priority |
| SURF-02: UART | Physical, minimal | HIGH | HIGH | Boot delay=0, disable console | |
| SURF-03: USB SDP | Physical, minimal | HIGH | HIGH | HABv4 closed + BT_FUSE_SEL | |
| SURF-04: Boot Mode pins | Physical, minimal | HIGH | HIGH | BT_FUSE_SEL fuse | |
| SURF-05: eMMC bus | Physical, equipped | MEDIUM | HIGH | dm-crypt (data), physical enclosure | |
| SURF-06: DRAM cold boot | Physical, very equipped | LOW | HIGH | CAAM key sealing, TrustZone | |
| SURF-07: Power glitch | Physical, lab equipment | LOW | HIGH | SNVS tamper detect, physical | |
| SURF-08: SD card swap | Physical, no equipment | CRITICAL | CRITICAL | HABv4 closed, eMMC boot | Primary boot threat |
| SURF-09: eMMC write | SW (root) or physical | MEDIUM | CRITICAL | eMMC write protect | |
| SURF-11: Rootfs tamper | SW (root) | HIGH | HIGH | dm-verity | |
| SURF-12: U-Boot env | SW (root) | HIGH | HIGH | Authenticated env | |
| SURF-15: Kernel modules | SW (root) | HIGH | HIGH | Kernel module signing | |
| SURF-16: OTA updates | Network | MEDIUM | CRITICAL | Signed OTA, TLS | |
| SURF-18: Weak key gen | Development | MEDIUM | CRITICAL | CAAM TRNG | Common mistake |
| SURF-20: CAAM side-channel | Physical, lab | LOW | HIGH | Physical security | Accept residual |
| SURF-23: Insecure key storage | Insider, network | MEDIUM | CRITICAL | HSM storage | Key management |
| SURF-24: Build pipeline | Supply chain | MEDIUM | CRITICAL | Reproducible builds, SBOM | Hard problem |

---

## Further Reading

- NXP AN12483: i.MX8M Series Security Reference Design
- A. Tolvanen: "Android Verified Boot 2.0" (dm-verity reference implementation)
- C. O'Flynn, Z.D. Chen: "ChipWhisperer: An Open-Source Platform for Hardware Embedded Security Research"
- NIST SP 800-147: BIOS Protection Guidelines (analogous concepts for embedded)
- ARM: "Trusted Board Boot Requirements (TBBR)" specification
