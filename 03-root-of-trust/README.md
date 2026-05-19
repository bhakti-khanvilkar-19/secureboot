# Chapter 03: Root of Trust

## Learning Objectives

After completing this chapter, you will be able to:

1. Define hardware Root of Trust precisely and explain why software-only roots of trust are insufficient
2. Identify all hardware security components on i.MX8MP and their roles in the trust chain
3. Understand the OCOTP fuse controller: address map, fuse words relevant to security, shadow registers
4. Explain CAAM capabilities: AES, RSA, ECC, SHA, TRNG, black keys, job ring interface
5. Understand the SNVS module: HP/LP domains, tamper detection, ZMK, secure RTC
6. Explain ARM TrustZone on Cortex-A53: EL3/EL1-S/EL1-NS privilege levels, SCR_EL3, NS bit
7. Understand TZASC memory partitioning and RDC peripheral access control
8. Explain how each hardware component participates in secure boot and why hardware immutability is necessary

---

## Overview

A Root of Trust is the entity at the foundation of a security system whose trustworthiness is assumed, not verified by another entity. Everything above it in the trust hierarchy derives its security from this foundation. If the Root of Trust is compromised, the entire security model fails, regardless of how well everything else is implemented.

The practical challenge is that "assumed trustworthy" is not a useful engineering specification. We want to know *what makes it trustworthy*, *what could compromise it*, and *what the residual risk is*. This chapter answers those questions specifically for the i.MX8MP hardware.

The i.MX8MP Root of Trust is not a single component — it is a collection of hardware components whose combined properties make the foundation of the trust chain. Each component contributes a specific property: immutability, secure storage, isolation, or entropy. Understanding each component is required for correct configuration and for understanding what the security model actually guarantees.

---

## Why Hardware Root of Trust Is Necessary

### The Software-Only Root of Trust Problem

Consider a hypothetical "software-only" secure boot: the first stage of the boot chain checks a signature on the second stage using a public key stored in a configuration file. An attacker who can modify storage (the boot device) can:

1. Replace the second-stage binary
2. Modify the public key configuration file to contain their own public key
3. Sign the malicious binary with their private key corresponding to the modified public key
4. The "verification" passes

The core problem is that both the verification mechanism (the public key) and the verified data (the binary) are in mutable storage. The attacker modifies both together.

**Hardware Root of Trust resolution**: Move the verification mechanism to hardware that cannot be modified by software. Specifically:
- The verification code is in **Boot ROM** (on-die silicon, mask-programmed, immutable)
- The public key is stored as a **hash in OTP fuses** (electrically blown, irreversible, readable but not writable)

An attacker who can write to the boot device cannot change the ROM or the fuses. The ROM reads the fuse-stored hash, computes the hash of the candidate public key material, compares them, and rejects any mismatch. The mutable data (boot image) is verified against the immutable data (fuse hash), and the verification code itself (ROM) is also immutable.

### The Immutability Spectrum

Security in an embedded system scales with how far from mutability a given component is:

```
IMMUTABILITY SPECTRUM
════════════════════════════════════════════════════════════════════════════

Most Immutable (cannot be changed after silicon manufacture)
  │
  ├── Boot ROM (mask ROM)
  │     Immutable: mask-programmed at chip foundry
  │     Threat to immutability: decap + laser modification (nation-state)
  │     Trust property: first code to execute is NXP's code
  │
  ├── OTP Fuses (OCOTP)
  │     Immutable once blown: electrical current destroys polysilicon links
  │     Threat to immutability: laser fuse re-welding (nation-state; very difficult)
  │     Trust property: SRK_HASH and SEC_CONFIG are permanently set at provisioning
  │
  ├── CAAM Secure Memory / Hardware Keys
  │     Not truly immutable: can be zeroized by SNVS tamper events
  │     Protected: hardware-encrypted, not software-accessible
  │     Trust property: keys cannot be extracted without CAAM hardware cooperation
  │
  ├── SNVS ZMK Register
  │     Retained across warm resets; zeroized on tamper events
  │     Protected: write-once after provisioning (if configured)
  │     Trust property: tamper detection automatically destroys key material
  │
  ├── OP-TEE Secure Storage
  │     Hardware-backed (RPMB + CAAM encryption), software-inaccessible from NW
  │     Threat: OP-TEE vulnerability could expose contents
  │     Trust property: access controlled by TrustZone hardware isolation
  │
  ├── eMMC/SD (signed boot images)
  │     Mutable: can be overwritten with OS-level write access
  │     Protected: HABv4 signature verification (immutable anchor)
  │     Trust property: only signature prevents substitution
  │
  └── RAM (running code)
        Least immutable: changes on every instruction
        Protected only by execution context isolation (TrustZone, MMU)
        Trust property: execution context determines trust, not storage
Least Immutable
```

---

## i.MX8MP Hardware Security Components

### Boot ROM

**Role**: First code to execute after power-on reset. Contains HABv4 authentication engine.

**Characteristics**:
- Physically: mask-programmed polysilicon in the silicon die
- Address: aliased to ARM reset vector (0x00000000 for Cortex-A53 in reset)
- Size: approximately 256KB (NXP does not publish exact size)
- Content: ROM boot code + HABv4 Routine Vector Table (RVT)
- NXP internal: programmed at chip manufacture; no field update mechanism

**HABv4 Routine Vector Table (RVT)**:
The ROM exposes HABv4 functionality through a table of function pointers at a known address. U-Boot and SPL can call ROM HABv4 functions for additional verification operations:

```c
/* HABv4 RVT structure (from NXP Reference Manual) */
struct hab_rvt {
    hab_hdr_t   hdr;            /* 0x000: magic header */
    hab_entry_t entry;          /* 0x004: authenticate and execute entry */
    hab_exit_t  exit;           /* 0x008: exit ROM services */
    hab_check_target_t  check_target;
    hab_authenticate_image_t    authenticate_image;  /* 0x010: key function */
    hab_run_dcd_t   run_dcd;
    hab_run_csf_t   run_csf;
    hab_assert_t    assert;
    hab_report_event_t  report_event;
    hab_report_status_t report_status;  /* read HAB status / event log */
    hab_failsafe_t  failsafe;
};
/* RVT address varies by i.MX8MP ROM version — typically around 0x900 */
```

**U-Boot HAB status call**:
```c
/* U-Boot board/freescale/common/hab.c */
enum hab_status hab_rvt_report_status(enum hab_config *config,
                                       enum hab_state *state)
{
    /* Call ROM RVT function pointer */
    return ((hab_rvt_report_status_t *)HAB_RVT_REPORT_STATUS)(config, state);
}
```

**What Boot ROM protects**:
- Executes HABv4 authentication before jumping to SPL
- In CLOSED mode: halts on verification failure
- In OPEN mode: logs HAB events, continues boot

**What Boot ROM does NOT protect**:
- ROM bugs: if the ROM has a security vulnerability, the entire model fails
- Historical context: Secure boot ROM bypasses have been found in devices from multiple vendors (though not publicly documented for i.MX8MP at time of writing)

---

### OCOTP: On-Chip One-Time Programmable Controller

**Role**: Stores the binding information between hardware and the signing keys. The SRK_HASH fuses define which public key material is trusted.

**Base address**: 0x30350000
**Shadow registers**: Runtime-readable copies at offset within OCOTP; copied from physical fuses at power-on

**Fuse architecture**:
- 2048 bits of physical fuse storage (512 4-bit ECC-protected words)
- Programming is permanent: blown fuses cannot be restored
- Each fuse bit is an electrically destroyed polysilicon link
- ECC correction: up to 1-bit error correction per word

```
OCOTP Fuse Map (Security-Relevant Entries)
═══════════════════════════════════════════════════════════════════════════════

Shadow Reg       Fuse Name           Bits    Security Function
Offset (hex)
─────────────────────────────────────────────────────────────────────────────
0x580  OCOTP_SRK0   SRK hash[31:0]       32   SHA-256 hash of SRK table (bytes 0-3)
0x590  OCOTP_SRK1   SRK hash[63:32]      32   SHA-256 hash (bytes 4-7)
0x5A0  OCOTP_SRK2   SRK hash[95:64]      32   SHA-256 hash (bytes 8-11)
0x5B0  OCOTP_SRK3   SRK hash[127:96]     32   SHA-256 hash (bytes 12-15)
0x5C0  OCOTP_SRK4   SRK hash[159:128]    32   SHA-256 hash (bytes 16-19)
0x5D0  OCOTP_SRK5   SRK hash[191:160]    32   SHA-256 hash (bytes 20-23)
0x5E0  OCOTP_SRK6   SRK hash[223:192]    32   SHA-256 hash (bytes 24-27)
0x5F0  OCOTP_SRK7   SRK hash[255:224]    32   SHA-256 hash (bytes 28-31)

0x460  OCOTP_CFG5   SEC_CONFIG[1:0]       2   HABv4 open(00) / closed(11)
                    DIR_BT_DIS            1   Disable direct boot
                    BT_FUSE_SEL           1   Boot from fuses vs pins
                    FORCE_COLD_BOOT       1   Force cold boot
                    KTE                   1   Key Transfer Enable (for SNVS)

0x430  OCOTP_CFG2   BOOT_CFG[31:0]       32   Boot device configuration
                    (eMMC bus width, clock frequency, etc.)

0x420  OCOTP_CFG1   BOOT_CFG[63:32]      32   Extended boot configuration

0x470  OCOTP_CFG6   SRK_REVOKE[3:0]       4   Revoke SRK1-4 (one bit per SRK)
                    JTAG_SMODE[1:0]       2   JTAG security mode
                    WDOG_ENABLE           1   Force watchdog enable
                    TZASC_ENABLE          1   Enable TrustZone address controller

0x4D0  OCOTP_GP1    General Purpose 1     32   Customer-defined use
0x4E0  OCOTP_GP2    General Purpose 2     32   Customer-defined use

0x660  OCOTP_MAC0   MAC address[31:0]     32   Ethernet MAC address (lower 32 bits)
0x670  OCOTP_MAC1   MAC address[47:32]    16   Ethernet MAC address (upper 16 bits)
═══════════════════════════════════════════════════════════════════════════════
```

**Reading OCOTP shadow registers from Linux**:
```bash
# Read current fuse values via NVMEM interface
$ cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem | xxd -s 0x580 -l 32
# Shows current SRK hash from shadow registers

# Read using devmem (if available)
$ devmem 0x30350580 32    # OCOTP_SRK0

# Read via sysfs
$ cat /sys/fuse/imx_ocotp_ctrl/fuse7            # SEC_CONFIG fuse group

# Read HABv4 status bits (indirect OCOTP read via HABv4 RVT)
# From U-Boot:
U-Boot> fuse read 0 6                             # bank 0, word 6 = OCOTP_CFG5
Reading bank 0:
Word 0x00000006: 00000000  ← 0 = HABv4 OPEN (not yet closed)

# The fuse value for HABv4 CLOSED = SEC_CONFIG[1] = 1 → word value: 0x00000002
```

**OCOTP Programming (Fuse Burning)**:
Fuse burning is covered in detail in Chapter 18. The hardware requirements:
- Supply voltage: 1.8V for read; 2.5V for programming
- Programming current: ~1mA per fuse bit
- Programming time: ~10µs per fuse word
- Irreversible: once a fuse is blown (bit set to 1), it cannot be reset to 0

---

### CAAM: Cryptographic Acceleration and Assurance Module

**Role**: Hardware cryptographic accelerator providing AES, RSA, ECC, SHA, and TRNG. Also provides secure key storage ("black keys") and is integral to the OP-TEE fTPM implementation.

**Base address**: 0x30900000
**Job Ring 0**: 0x30901000
**Job Ring 1**: 0x30902000
**Secure Memory**: 0x30904000

**CAAM Architecture**:

```
CAAM INTERNAL ARCHITECTURE
════════════════════════════════════════════════════════════════════════════

External Interface:
  ├── AXI slave (register access, configuration)
  ├── AXI master (DMA: read input, write output to DRAM)
  └── Secure Memory (128KB on-chip SRAM, no DMA)

Job Ring Architecture (rings 0 and 1 for Linux):
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Job Ring 0 (assigned to Normal World / Linux)                      │
  │  ├── Input ring: 1024-entry ring of job descriptors                 │
  │  │   (driver enqueues DMA-accessible descriptor pointers here)      │
  │  ├── Output ring: completed job results + status codes              │
  │  └── IRBA (Input Ring Base Address): 0x30901004                    │
  │                                                                     │
  │  Job Ring 1 (assigned to Secure World / OP-TEE, if partitioned)    │
  └─────────────────────────────────────────────────────────────────────┘

DECO (Descriptor Controller):
  Executes crypto operations in descriptor order:
  ├── LOAD: load key material into CAAM internal key registers
  ├── FIFO LOAD: load input data
  ├── OPERATION: specify algorithm (AES-CBC, SHA-256, RSA sign, etc.)
  ├── STORE: store output to DRAM
  └── JUMP: conditional jumps, HW-enforced abort on error

Key hierarchy in CAAM:
  ├── MKVR (Master Key Version Register): selects active MK
  ├── OTPMK (OTP Master Key): device-unique key from OTP fuses/SNVS
  ├── JDKEK (Job Descriptor Key Encryption Key): derived from OTPMK
  │         Used to encrypt black blobs
  ├── TDKEK (Trusted Descriptor Key Encryption Key): derived from OTPMK
  └── Internal keys: loaded per operation, cleared after use
```

**CAAM Capabilities Detail**:

```
CAAM Algorithm Support:
═════════════════════════════════════════════════════
Symmetric:
  AES-128/192/256: ECB, CBC, CTR, GCM, CCM, XTS,
                   XCBC-MAC, CMAC, OFB, CFB
  DES, 3DES: ECB, CBC, CFB (legacy, not recommended)
  CHACHA20 (i.MX8MP ERA10+ CAAM)

Asymmetric:
  RSA: 128 to 4096 bits
    Modes: encrypt, decrypt, sign (private exp), verify (public exp)
    Schemes: PKCS#1 v1.5, PSS (via descriptor composition)
  ECC: NIST P-192, P-224, P-256, P-384, P-521
    Operations: scalar multiply, ECDSA sign, ECDSA verify, ECDH

Hash:
  SHA-1, SHA-224, SHA-256, SHA-384, SHA-512
  MD5 (legacy)
  HMAC variants of all above

Random:
  TRNG: True Random Number Generator
    Compliant: NIST SP 800-90B
    Implementation: dual ring oscillator jitter-based
    Post-processing: CTR_DRBG (NIST SP 800-90A)
    Output rate: ~32 KB/s
    Seeded automatically on CAAM init

Key Blob:
  Black key generation (AES-wrapped device-unique keys)
  Red blob: plaintext key wrapped with JDKEK → black blob
  Black blob: JDKEK-encrypted key blob (storable in filesystem)
  Import: re-wrap black blob for use in CAAM operation
═════════════════════════════════════════════════════
```

**CAAM Job Descriptor Example (SHA-256 from Linux)**:

```c
/* Linux kernel driver: drivers/crypto/caam/caamalg.c */
/* A CAAM job descriptor for SHA-256 hash: */
u32 desc[] = {
    [0] = 0xB0800008,           /* HEADER: 8 words, no share, trusted desc */
    [1] = 0x02000020,           /* KEY: load 32-byte HMAC key from pointer */
    [2] = (u32)key_dma,         /* DMA address of key */
    [3] = 0x55940014,           /* FIFO LOAD: init+continue SHA-256, 20 bytes */
    [4] = (u32)input_dma,       /* DMA address of input data */
    [5] = 0x5A940001,           /* FIFO LOAD: finalize, 1 byte */
    [6] = 0x60240020,           /* STORE: 32-byte output */
    [7] = (u32)output_dma,      /* DMA address of output buffer */
};
/* Submit to CAAM Job Ring 0 input ring → hardware executes → interrupt on completion */
```

**CAAM Black Key Workflow**:

```
Device Provisioning (one-time):
  CAAM generates OTPMK from SNVS ZMK and internal OTP
  OTPMK → derives JDKEK (never leaves CAAM)

Application Key Creation:
  1. Application generates or receives plaintext key (e.g., 32-byte AES key)
  2. Pass plaintext key to CAAM black blob encapsulation
  3. CAAM wraps key with JDKEK → produces black blob (48+ bytes)
  4. Black blob stored in filesystem (encrypted; useless without this device)

Application Key Use:
  1. Load black blob from filesystem
  2. Pass to CAAM black blob decapsulation
  3. CAAM unwraps with JDKEK → produces key in CAAM internal memory only
  4. Use key for CAAM crypto operation (never touches DRAM as plaintext)

Attack resistance:
  - Attacker steals filesystem → has encrypted black blob only
  - Attacker reads DRAM → key is only in CAAM secure memory during use
  - Attacker needs JDKEK → JDKEK never leaves CAAM hardware
  - Attacker steals entire device → same JDKEK; black blob works on stolen device
    (Device theft requires additional mitigation: dm-crypt with TPM key sealing)
```

---

### SNVS: Secure Non-Volatile Storage

**Role**: Always-on domain that persists state across warm resets, provides tamper detection, and holds the Zeroizable Master Key (ZMK). The SNVS is powered by the PMIC even when the main SoC is powered off (depending on board design).

**Architecture**:
```
SNVS BLOCK DIAGRAM
════════════════════════════════════════════════════════════

High-Power (HP) Domain:           Low-Power (LP) Domain:
  Powered during normal            Always-on (SNVS power rail)
  SoC operation                    Persists through warm reset
  ────────────────────────         ────────────────────────────
  SNVS_HPSR  (status)              SNVS_LPCR  (LP control)
  SNVS_HPCOMR (command)            SNVS_LPTDCR (tamper detect ctrl)
  SNVS_HPCR  (HP control)          SNVS_LPSR  (LP status)
  SNVS_HPSR  (HP status)           SNVS_LPSRTCMR (secure RTC high)
  SNVS_HPHACIVR (irq vector)       SNVS_LPSRTCLR (secure RTC low)
  SNVS_HPSVSR (violation status)   SNVS_LPPGDR  (power glitch detect)
                                    SNVS_ZMK[0:7] (256-bit ZMK)
                                    SNVS_LPSMKR (SW master key)
```

**SNVS Register Reference**:

```
Key SNVS registers (i.MX8MP base: 0x30370000)

SNVS_LPCR (Low Power Control Register) — offset 0x38:
  Bit 0  (SRTC_ENV): Secure RTC enable
  Bit 1  (LPTA_EN): Low-power tamper alarm enable
  Bit 3  (DPWC): Power-on detect enable for power glitch
  Bit 5  (TOP): Tamper on physical tamper detect
  Bit 6  (PK_OVERRIDE): Power Key override
  Bit 8  (ZMK_WSL): ZMK write software lock (1 = ZMK write locked)
  Bit 9  (ZMK_RSL): ZMK read software lock (1 = ZMK reads return 0)
  Bit 10 (SRTC_INV_EN): SRTC invalid enable
  Bit 12 (LPWUI_EN): LP wake-up interrupt enable
  Bit 24 (BTN_PRESS_TIME[1:0]): button press glitch filter
  Bit 30 (MKVR): Master Key Valid Register (which key to use)
  Bit 31 (MKS_EN): Master Key Select Enable

SNVS_LPSR (Low Power Status Register) — offset 0x4C:
  Bit 0  (LPTA): Low-power tamper alarm status
  Bit 1  (SRTCR): Secure RTC roll-over flag
  Bit 3  (CTD): Counter tamper detected
  Bit 6  (MCR): Master Counter Rollover
  Bit 7  (PGD): Power Glitch Detected
  Bit 16 (ETD1): External Tamper 1 Detected (ET1_TAMP pin)
  Bit 17 (ETD2): External Tamper 2 Detected (ET2_TAMP pin)
  Bit 18 (EBD): Active Tamper Detected (active tamper pin)

SNVS_ZMK (Zeroizable Master Key) — offset 0x6C-0x88 (8 × 4-byte words):
  Total: 256 bits (32 bytes)
  Access: write-only from Normal World (if ZMK_WSL=0); reads return 0
  Hardware use: CAAM uses ZMK to derive OTPMK for black key operations
  Tamper action: hardware automatically zeros this register on any SNVS tamper event
```

**SNVS Tamper Detection**:

```bash
# Configure external tamper detection (from Linux):
# SNVS has two external tamper pins (ET1, ET2) and active tamper outputs

# Enable tamper detection on ET1 pin (must be done from secure software):
$ devmem 0x30370038 32 0x00000001   # Enable SRTC (required first)
$ devmem 0x30370054 32 0x00000400   # SNVS_LPTDCR: enable ET1 tamper

# After tamper event:
# 1. SNVS_LPSR bit 16 (ETD1) is set
# 2. ZMK is automatically zeroed to 0x00...00
# 3. Any CAAM black keys derived from ZMK become permanently invalid
# 4. System continues running; security state is "violated"

# Read tamper status:
$ devmem 0x3037004C 32
# Non-zero in bits 0-18 → tamper event occurred
```

---

### TrustZone: ARM Hardware Isolation

**Role**: ARM TrustZone provides hardware-enforced isolation between the "Secure World" (OP-TEE, TF-A) and "Normal World" (Linux, applications). The Secure World has access to additional hardware registers and memory regions that the Normal World cannot access.

**Exception Level Architecture on Cortex-A53**:

```
ARM64 EXCEPTION LEVELS AND TRUSTZONE
════════════════════════════════════════════════════════════════════════

  ┌──────────────────────────────────────────────────────────────────┐
  │                    SECURE WORLD                                  │
  │                                                                  │
  │  EL3 (Secure Monitor) = TF-A BL31                               │
  │  ├── Handles SMC (Secure Monitor Call) exceptions               │
  │  ├── Manages world switches (Normal ↔ Secure)                   │
  │  ├── Controls SCR_EL3 (NS bit) — who is currently executing     │
  │  ├── Owns GIC secure interrupts                                 │
  │  └── Always runs in Secure state                                │
  │                                                                  │
  │  S-EL1 (Secure Kernel) = OP-TEE OS                              │
  │  ├── Runs OP-TEE operating system                               │
  │  ├── Manages Trusted Applications (TAs)                         │
  │  ├── Controls Secure World MMU mapping                          │
  │  └── Access to CAAM, SNVS without TZ restriction                │
  │                                                                  │
  │  S-EL0 (Secure User) = OP-TEE Trusted Applications             │
  │  ├── Crypto TAs: fTPM, key management, secure storage           │
  │  └── Limited privileges within OP-TEE sandbox                   │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘
                          │ World switch via SMC
                          │ (managed by EL3/TF-A)
  ┌──────────────────────────────────────────────────────────────────┐
  │                    NORMAL WORLD                                  │
  │                                                                  │
  │  EL2 (Hypervisor) = KVM or not used                             │
  │  ├── Hardware virtualization (if CONFIG_KVM enabled)            │
  │  └── Not used in typical embedded deployments                   │
  │                                                                  │
  │  EL1 (Kernel) = Linux kernel                                    │
  │  ├── Full kernel privileges in Normal World                     │
  │  ├── Cannot access Secure World memory (TZASC enforces)         │
  │  ├── Cannot access Secure peripherals (RDC enforces)            │
  │  └── Communicates with OP-TEE via SMC (through TEE driver)      │
  │                                                                  │
  │  EL0 (User) = Linux userspace applications                      │
  │  └── Reduced privileges; cannot access kernel memory directly   │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘
```

**SCR_EL3 (Secure Configuration Register)**:

The NS (Non-Secure) bit in SCR_EL3 determines the security state of the current execution:

```c
/* TF-A: setting NS bit to switch to Normal World */
/* lib/el3_runtime/aarch64/context.c */
void cm_prepare_el3_exit(uint32_t security_state)
{
    if (security_state == NON_SECURE) {
        /* Set NS bit in SCR_EL3 → next EL change goes to Normal World */
        write_scr_el3(read_scr_el3() | SCR_NS_BIT);
    } else {
        /* Clear NS bit in SCR_EL3 → next EL change goes to Secure World */
        write_scr_el3(read_scr_el3() & ~SCR_NS_BIT);
    }
}
```

**SMC Interface (Normal World → Secure World)**:

```c
/* Linux OP-TEE driver: drivers/tee/optee/smc_abi.c */
/* Normal World calls OP-TEE via SMC instruction */
static void optee_smccc_smc(unsigned long a0, unsigned long a1, ...) {
    arm_smccc_smc(a0, a1, a2, a3, a4, a5, a6, a7, &res);
    /* SMC triggers EL3 exception → TF-A → forwards to OP-TEE if appropriate */
}

/* Function IDs for OP-TEE SMC calls (from SMCCC standard): */
#define OPTEE_SMC_CALL_GET_OS_UUID          0x32000001  /* Get OS UUID */
#define OPTEE_SMC_CALL_WITH_ARG            0x32000004  /* Invoke TA */
#define OPTEE_SMC_GET_SHARED_MEMORY_CONFIG  0x32000007  /* Get shared memory info */
```

---

### TZASC-380: TrustZone Address Space Controller

**Role**: Controls access to DRAM regions based on the NS (Non-Secure) bit on the AXI bus. Prevents Normal World software from accessing memory regions reserved for Secure World.

**Configuration**: 8 configurable regions with access permissions:
- `secure-read + secure-write + non-secure-read + non-secure-write` can each be independently enabled per region

```c
/* TF-A: TZASC configuration (plat/imx/common/imx_tzasc.c) */
static const struct tzc380_reg imx_tzc380_regions[] = {
    /* Region 0: default — all Non-Secure access allowed */
    {0, 0x00000000, 0x80000000, TZC380_ATTR_SP_ALL},

    /* Region 1: 32MB Secure World DDR (OP-TEE) — Secure access only */
    {1, SECURE_DRAM_BASE, SECURE_DRAM_SIZE,
     TZC380_ATTR_SP_S_RW},       /* Secure read+write; Non-Secure: no access */

    /* Region 2: OP-TEE shared memory */
    {2, TEE_SHMEM_BASE, TEE_SHMEM_SIZE,
     TZC380_ATTR_SP_ALL},        /* Both worlds can access (for parameter passing) */
};

/* TZASC base address: 0x32F80000 (i.MX8MP) */
void imx8mp_tzc380_setup(void)
{
    tzc380_init(TZASC1_BASE);
    for (int i = 0; i < ARRAY_SIZE(imx_tzc380_regions); i++)
        tzc380_configure_region(i, ...);
    tzc380_enable_filters();
}
```

---

### RDC: Resource Domain Controller

**Role**: Controls peripheral bus access per "domain". Domain 0 is assigned to the Cortex-A53 cluster. Domain 1 is assigned to the Cortex-M7. This allows the M7 to access certain peripherals independently of the A53, and vice versa.

For secure boot, RDC is used to restrict access to security-critical peripherals (CAAM, SNVS, OCOTP) to specific domains (Secure World domain).

```
RDC PERIPHERAL ACCESS CONTROL (selected peripherals)

Peripheral          Address      Domain 0 (A53)  Domain 1 (M7)  TZ-required
─────────────────────────────────────────────────────────────────────────────
CAAM               0x30900000   Secure-only      No access       YES (NS=0)
SNVS               0x30370000   Secure-only      No access       YES (NS=0)
OCOTP              0x30350000   Both (read)      No access       Partial
UART1              0x30860000   Normal World     M7 also         NO
eMMC (USDHC3)      0x30B60000   Normal World     No default      NO
GIC                0x38800000   Both             Both            Partial
─────────────────────────────────────────────────────────────────────────────

Access violations trigger a bus error (AXI decode error → ABT exception)
```

---

### Secure Debug: JTAG Control

The ARM Coresight debug interface (JTAG) is controlled by:
1. **DAPC** (Debug Authentication Protocol Controller): ARM standard debug authentication
2. **OCOTP fuses**: JTAG can be permanently disabled by fuse
3. **HABv4 state**: In CLOSED mode, HABv4 can disable debug access

```
JTAG Security Configuration:

OCOTP_CFG6 bit 8-9 (JTAG_SMODE[1:0]):
  0b00: JTAG enabled (default, no restriction)
  0b01: Secure JTAG mode (requires authentication challenge-response)
  0b11: JTAG disabled (no debug access, permanent)

ARM v8 Debug Authentication (DAP):
  External debugger must assert DBGEN, NIDEN, SPIDEN, SPNIDEN
  These signals are gated by i.MX8MP debug security logic
  In HABv4 CLOSED mode: debug signals gated unless unlocked

Secure JTAG Challenge-Response (if JTAG_SMODE = 01):
  1. Debugger requests debug access → i.MX8MP issues 256-bit challenge
  2. Debugger must prove knowledge of debug unlock key (via signed response)
  3. If response valid → debug access granted for this session
  4. Challenge changes on each power cycle (replay protection)
```

```bash
# Check current JTAG fuse state from Linux:
$ devmem 0x30350470 32    # OCOTP_CFG6
# Bits 8-9: JTAG_SMODE
# 0x00000000 = JTAG fully enabled
# 0x00000200 = Secure JTAG
# 0x00000300 = JTAG disabled

# From U-Boot:
U-Boot> fuse read 0 7     # bank 0, word 7 = OCOTP_CFG6
Reading bank 0:
Word 0x00000007: 00000000
```

---

## What an Attacker Must Break

To defeat the hardware Root of Trust completely, an attacker must defeat ALL of:

| Component | Attack Required | Attacker Capability Required |
|-----------|----------------|------------------------------|
| Boot ROM | ROM vulnerability (zero-day) OR laser fuse modification | Nation-state or extraordinary |
| OCOTP SRK_HASH | Laser fuse modification to change hash | Nation-state |
| OCOTP SEC_CONFIG | Change CLOSED to OPEN via fuse modification | Nation-state |
| CAAM JDKEK | Extract from CAAM hardware (no software interface) | Nation-state (decap + probe) |
| SNVS ZMK | Power glitch to prevent tamper zeroization | Sophisticated |
| TrustZone isolation | OP-TEE vulnerability + EL3 bypass | Security researcher level |

The residual risk that cannot be mitigated is nation-state physical attacks. For commercial and industrial deployments, the hardware Root of Trust is sufficient.

---

## Further Reading

- i.MX8MP Reference Manual, Chapter 6: Security (NXP Rev 3, 11/2021)
  Available from NXP.com (requires registration)
- NXP AN4581: Secure Boot on i.MX Using HABv4
  https://www.nxp.com/docs/en/application-note/AN4581.pdf
- NXP CAAM Reference Manual: Chapter 8 of i.MX8MP RM
- ARM TrustZone Technology: https://developer.arm.com/ip-products/security-ip/trustzone
- TF-A (Trusted Firmware-A) documentation: https://trustedfirmware-a.readthedocs.io/
- OP-TEE documentation: https://optee.readthedocs.io/
- "ARM TrustZone: Design Principles and User Guide"
  https://developer.arm.com/documentation/102418/0101
- TCG PC Client Platform Firmware Profile Specification (for comparison with TPM approach)
  https://trustedcomputinggroup.org/resource/pc-client-specific-platform-firmware-profile-specification/
