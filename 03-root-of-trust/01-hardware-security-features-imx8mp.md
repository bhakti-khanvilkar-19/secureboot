# i.MX8MP Hardware Security Features

## OCOTP - One-Time Programmable Fuse Controller

**Base address:** `0x30350000`  
**Shadow registers:** `0x30350400 + (bank × 0x80) + (word × 0x10)`  
**Total capacity:** 2048 fuse bits (512 × 32-bit words, ECC-protected)

OCOTP stores permanent device configuration including the SRK hash and security lifecycle state. Once a fuse bit is programmed (0→1), it cannot be reversed.

```
OCOTP Register Map (security-relevant):
Bank 0: Lock registers
Bank 1: Configuration fuses (SEC_CONFIG, JTAG_SMODE, BT_FUSE_SEL)
Bank 2: MAC address, unique ID
Bank 3: SRK_HASH[0..7] — 8 × 32-bit = 256-bit SHA-256 of SRK table
Bank 4: SRK_REVOKE, GP_ROM, MISC_CONF
Bank 9: Anti-rollback counter (GP fuses)
```

Reading shadow registers from Linux:
```bash
# Via nvmem interface
cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem | xxd | head -32

# Or via devmem2 (requires CONFIG_STRICT_DEVMEM=n)
devmem2 0x30350580 w   # Bank 3, Word 0 = SRK_HASH[0]
```

---

## CAAM - Cryptographic Acceleration and Assurance Module

**Base address:** `0x30900000`

CAAM is the primary hardware cryptographic engine in i.MX8MP. It operates independently of the ARM cores and provides:

| Algorithm | Details |
|-----------|---------|
| AES | ECB, CBC, CTR, GCM, CCM, XTS — 128/192/256-bit keys |
| RSA | Key sizes 512–4096-bit, CRT mode |
| ECC | P-256, P-384, P-521 curves |
| SHA | SHA-1, SHA-224, SHA-256, SHA-384, SHA-512 |
| TRNG | True Random Number Generator (NIST SP 800-90B) |
| RNG | DRBG seeded from TRNG |

### CAAM Architecture

```
┌─────────────────────────────────────────────────────┐
│                      CAAM                           │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │  Job     │  │  DECO    │  │   Secure Memory  │  │
│  │  Ring    │  │ (Descr.  │  │  (Black Key      │  │
│  │  0,1,2   │  │  Ctrl)   │  │   Storage)       │  │
│  └────┬─────┘  └────┬─────┘  └──────────────────┘  │
│       │             │                               │
│  ┌────▼─────────────▼─────────────────────────┐     │
│  │           Crypto Engines                   │     │
│  │  AES │ RSA │ ECC │ SHA │ TRNG │ RNG        │     │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

### CAAM Black Keys

CAAM can encrypt key material using a device-unique master key (derived from internal fuses). The encrypted key ("black key") can be stored in non-secure memory without revealing the plaintext key.

```c
/* Key blob: CAAM creates encrypted wrapper of a key */
/* Black key: AES-CBC encrypted with CAAM master key */
/* Only CAAM on the same device can decrypt it */
```

### Linux CAAM Driver

```bash
# Check CAAM is available
ls /dev/caam*
# /dev/caam_jr0  /dev/caam_jr1  /dev/caam_jr2

# CAAM-backed /dev/hwrng
cat /sys/class/misc/hw_random/rng_current
# caam-rng

# Use for entropy
rngd -r /dev/hwrng
```

---

## SNVS - Secure Non-Volatile Storage

SNVS provides two always-on security domains:

### HP Domain (High Power)
- Active when main VDD is on
- Contains: Secure RTC, tamper event log, SNVS status

### LP Domain (Low Power)  
- Active even on battery power (NVCC_SNVS rail)
- Contains: tamper detectors, ZMK (Zeroizable Master Key), LP tamper log

### Tamper Detection Pins
i.MX8MP SNVS supports passive/active tamper detection:

```
Passive tampers: detect voltage level change
Active tampers:  inject pattern, detect if broken

When tamper detected:
→ ZMK (32-byte key) is immediately zeroized
→ SNVS_LPSR tamper flag set
→ Optional: cause security violation → erase keys
```

### Key SNVS Registers

```
SNVS_HPSR (0x30370014): HP Status — tamper detection flags
SNVS_LPCR (0x30370038): LP Control — enable tamper detectors
SNVS_LPSR (0x3037004C): LP Status — tamper event record
SNVS_LPTDCR (0x30370048): Tamper Detector Control
SNVS_LPSRTCMR (0x30370050): Secure RTC high word
SNVS_LPSRTCLR (0x30370054): Secure RTC low word
SNVS_ZMK (0x30370040–0x3037005C): Zeroizable Master Key (8 × 32-bit)
```

---

## ARM TrustZone on Cortex-A53

### Exception Level Architecture

```
EL3  (Secure Monitor) — TF-A BL31
     ├── Handles SMC (Secure Monitor Calls)
     ├── PSCI implementation
     └── Manages NS bit in SCR_EL3

EL2  (Hypervisor)     — Optional (KVM)
     └── Guest OS management

EL1-S (Secure OS)     — OP-TEE
     ├── Trusted Applications
     └── Secure services

EL1-NS (Normal OS)    — Linux kernel
     └── Device drivers, syscalls

EL0-S (Secure User)   — OP-TEE Trusted Apps
EL0-NS (Normal User)  — Linux userspace
```

### SCR_EL3 Security Configuration Register

```
SCR_EL3.NS  = 0: Secure World    (OP-TEE, TF-A)
SCR_EL3.NS  = 1: Non-Secure World (Linux, U-Boot)
SCR_EL3.RW  = 1: AArch64 at lower EL
SCR_EL3.SMD = 0: SMC enabled (allow Secure Monitor Calls)
```

---

## TZASC - TrustZone Address Space Controller

The TZASC-380 divides DRAM into Secure and Non-Secure regions:

```
DRAM (2GB at 0x40000000):
┌──────────────────────┐ 0xC0000000
│   Non-Secure DRAM    │ ← Linux kernel, U-Boot, app data
│   (NS-readable)      │
├──────────────────────┤ 0xFE000000
│   Secure DRAM        │ ← OP-TEE code and data
│   (Secure-only)      │ ← NS reads return 0 or abort
└──────────────────────┘

TZASC regions configured by TF-A BL2 during boot
```

---

## RDC - Resource Domain Controller

RDC assigns peripherals to security domains:

```
Domain 0: Cortex-A53 (Normal World)
Domain 1: Cortex-M7
Domain 2: CAAM (Secure)
Domain 3: Reserved

Each peripheral slot:
- Can be restricted to specific domains
- Can require secure access only
- Violations generate bus errors
```

Example: CAAM accessible from A53 secure (EL3/EL1-S) and denied from NS:
```
RDC_PDAP_CAAM: DOMAIN0_ACCESS = Secure only
```

---

## HABv4 Engine

HABv4 (High Assurance Boot v4) is implemented as a library embedded in the ROM. It:

1. Validates the CSF (Command Sequence File) structure
2. Verifies the SRK certificate chain against the SRK hash in fuses
3. Authenticates image data using RSA-2048 + SHA-256
4. Reports events (success/failure) to a secure log

**HABv4 is ROM-resident:** it cannot be updated or replaced by software. This makes it the hardware root of trust for the boot chain.

```c
/* HABv4 ROM Vector Table (RVT) at fixed address */
/* i.MX8MP: ROM HAB RVT at 0x980  */
struct hab_rvt {
    uint32_t header;
    hab_status_t (*entry)(void);
    hab_status_t (*exit)(void);
    hab_status_t (*check_target)(uint8_t type, const void *start, size_t bytes);
    hab_status_t (*authenticate_image)(uint8_t cid, size_t ivt_offset,
                                        void **start, size_t *bytes,
                                        const void *csf);
    hab_status_t (*run_dcd)(const uint8_t *dcd);
    hab_status_t (*run_csf)(const uint8_t *csf, uint8_t cid, uint32_t flags);
    hab_status_t (*assert)(uint8_t type, const void *data, uint32_t count);
    hab_status_t (*report_event)(uint8_t status, uint32_t index,
                                  uint8_t *event, size_t *bytes);
    hab_status_t (*report_status)(hab_config_t *config, hab_state_t *state);
    void         (*failsafe)(void);
};
```

## Security Feature Summary

| Feature | i.MX8MP Support | Configuration |
|---------|----------------|---------------|
| HABv4 | Yes | SEC_CONFIG fuse |
| CAAM | Yes | Always available |
| TRNG | Yes | CAAM TRNG |
| TrustZone | Yes | ARM architecture |
| TZASC | Yes | TF-A configures |
| SNVS Tamper | Yes | Board design |
| JTAG disable | Yes | JTAG_SMODE fuse |
| Secure debug | Yes | SNVS + HAB |
| RPMB | Yes | eMMC + OP-TEE |
