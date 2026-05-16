# Chapter 02: Embedded Cryptography

## Learning Objectives

After completing this chapter, you will be able to:

1. Explain why cryptography behaves differently in embedded Linux contexts than in server environments
2. Select appropriate hash functions, symmetric ciphers, and asymmetric algorithms for specific secure boot use cases
3. Understand the X.509 certificate structure and PKI hierarchy required for HABv4 and FIT signing
4. Use OpenSSL to generate keys, sign data, and verify signatures in a secure boot workflow
5. Configure and use CAAM hardware acceleration on i.MX8MP for cryptographic operations
6. Understand key storage options on i.MX8MP: SNVS, CAAM black keys, OP-TEE secure storage
7. Recognize and avoid common cryptographic implementation mistakes in embedded contexts
8. Explain side-channel attack relevance to embedded key management decisions

---

## Why Cryptography Is Different in Embedded Systems

Cryptography implemented correctly on a server is different from cryptography implemented correctly on an embedded device. The following constraints fundamentally change what "correct" means:

### No OS Entropy Pool at Boot Time

On a Linux server, `/dev/random` and `/dev/urandom` are available from early in the boot process, seeded by hardware TRNG, disk timing, interrupt timing, and other entropy sources. By the time application software needs random numbers for key generation or nonce creation, the entropy pool is full.

On an embedded system at power-on, the entropy situation is different:

- **SPL stage**: No kernel, no entropy pool, no `/dev/urandom`. Only the hardware TRNG (CAAM TRNG on i.MX8MP) if it has been initialized.
- **U-Boot stage**: No kernel entropy pool. U-Boot has its own random number generator, but it must be seeded from hardware (CAAM TRNG).
- **Early Linux kernel**: The kernel's entropy pool starts empty and collects entropy from interrupts, TRNG, and other sources. Before the pool is adequately seeded, reads from `/dev/random` block and `/dev/urandom` may return low-quality randomness.

**Practical consequence:** Any key material generated at early boot without a hardware TRNG is potentially weak. On i.MX8MP, the CAAM TRNG (True Random Number Generator) provides hardware entropy. It must be initialized before any key generation or random number use.

```bash
# Check CAAM TRNG status in Linux
cat /proc/sys/kernel/random/entropy_avail
# Should be > 2048 bits on a healthy system with CAAM

# Verify CAAM TRNG is available
ls /dev/hw_random
# /dev/hw_random → CAAM TRNG entropy source

# Force kernel to use hardware entropy
rngd -r /dev/hw_random -o /dev/random  # rng-tools daemon

# Check kernel entropy sources:
cat /proc/sys/kernel/random/entropy_avail
```

### Constrained SRAM and Memory

The i.MX8MP has 256KB of OCRAM for the SPL. Large cryptographic structures — RSA-4096 public keys (512 bytes modulus), X.509 certificate chains (several KB), Merkle trees — must fit within these constraints. Algorithm choices are therefore not just about security but about memory footprint.

| Algorithm | Public Key Size | Signature Size | SRAM Impact |
|-----------|----------------|----------------|-------------|
| RSA-2048 | 256 bytes | 256 bytes | Low |
| RSA-4096 | 512 bytes | 512 bytes | Moderate |
| ECC P-256 | 64 bytes | 64 bytes | Very low |
| ECC P-384 | 96 bytes | 96 bytes | Very low |

### Hardware Accelerators Are Required for Performance

Software-only cryptography on a Cortex-A53 at 1.6GHz:
- SHA-256 (software): ~50-100 MB/s throughput
- RSA-2048 verify (software): ~10ms
- AES-128-CBC (software): ~100-200 MB/s

With CAAM hardware acceleration on i.MX8MP:
- SHA-256 (CAAM): ~800 MB/s throughput
- RSA-2048 verify (CAAM): ~1ms
- AES-128-CBC (CAAM): ~1.5 GB/s throughput

For boot performance, the difference between software and hardware cryptography can mean hundreds of milliseconds of added boot time if large images are hashed in software. Production secure boot implementations must use CAAM acceleration.

### Physical Security Is Not Assumed

In a server data center, physical access is controlled. In an embedded deployment, the device may be in a parking meter, an industrial control cabinet, or a consumer's home. The cryptographic implementation must account for physical attackers.

This affects:
- **Key storage**: Keys must be in hardware-backed secure storage (CAAM, OP-TEE), not plaintext files
- **Side-channel resistance**: Cryptographic implementations in security-critical paths should be constant-time
- **Tamper detection**: SNVS tamper detection can zeroize keys on physical intrusion

---

## Hash Functions

### Theory and Properties

A cryptographic hash function maps an arbitrary-length input to a fixed-length output (the digest). For secure boot applications, the required properties are:

**Collision resistance**: Given `H(m1) == H(m2)`, it must be computationally infeasible to find m1 ≠ m2. Without this, an attacker could substitute a different image that produces the same hash.

**Preimage resistance**: Given a hash `h`, it must be computationally infeasible to find any `m` such that `H(m) == h`. Without this, an attacker could construct an image from a known hash.

**Second preimage resistance**: Given `m1` and `H(m1)`, it must be computationally infeasible to find `m2 ≠ m1` such that `H(m1) == H(m2)`. This prevents targeted substitution attacks.

**Avalanche effect**: A single bit change in the input causes approximately half the output bits to change. This ensures that similar but distinct inputs produce completely different hashes, preventing gradual probing of hash collisions.

### SHA-256

SHA-256 (Secure Hash Algorithm 256-bit) is the standard for NXP HABv4 and FIT image signing. It is part of the SHA-2 family standardized in FIPS 180-4.

- **Output**: 256 bits (32 bytes)
- **Block size**: 512 bits (64 bytes)
- **Security level**: 128-bit collision resistance, 256-bit preimage resistance
- **Speed (CAAM i.MX8MP)**: ~800 MB/s
- **Speed (software Cortex-A53)**: ~80 MB/s

```bash
# Hash a string
$ echo -n "hello" | openssl dgst -sha256
SHA2-256(stdin)= 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824

# Note: echo without -n adds a newline; use -n for literal string
$ echo "hello" | openssl dgst -sha256
SHA2-256(stdin)= b94d27b9934d3e08a52e52d7da7dabfac484efe04294e576e4e28613d9a0f0e5

# Hash a file
$ openssl dgst -sha256 /boot/Image
SHA2-256(/boot/Image)= 7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069

# Hash a large file and measure performance
$ dd if=/dev/urandom bs=1M count=64 of=/tmp/test64m.bin 2>/dev/null
$ time openssl dgst -sha256 /tmp/test64m.bin
SHA2-256(/tmp/test64m.bin)= a3c72e...
real    0m0.847s   # ~75 MB/s software SHA-256 on Cortex-A53

# Verify file integrity with SHA-256
$ openssl dgst -sha256 -out Image.sha256 /boot/Image
$ openssl dgst -sha256 -verify /boot/Image
```

### SHA-384 and SHA-512

SHA-384 and SHA-512 are members of the SHA-2 family with larger output sizes. They use 64-bit word operations internally (vs 32-bit for SHA-256), making them slower on 32-bit processors but equally fast or faster on 64-bit processors like the Cortex-A53.

| Algorithm | Output | Security | Use Case |
|-----------|--------|----------|----------|
| SHA-256 | 32 bytes | 128-bit | Standard HABv4, FIT, dm-verity |
| SHA-384 | 48 bytes | 192-bit | High-security government deployments |
| SHA-512 | 64 bytes | 256-bit | Maximum security, post-quantum margin |

```bash
# SHA-384 and SHA-512
$ echo -n "hello" | openssl dgst -sha384
SHA2-384(stdin)= 59e1748777448c69de6b800d7a33bbfb9ff1b463e44354c3553bcdb9c666fa90125a3c79f90397bdf5f6a13de828684f

$ echo -n "hello" | openssl dgst -sha512
SHA2-512(stdin)= 9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca72323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043

# Performance comparison on Cortex-A53:
$ openssl speed sha256 sha384 sha512 2>/dev/null | grep -E "sha(256|384|512)"
# Approximate results on Cortex-A53 @ 1.6GHz (software only):
# sha256      75-90 MB/s
# sha384     120-140 MB/s  (faster than sha256 on 64-bit hardware)
# sha512     120-140 MB/s
```

### HMAC: Hash-Based Message Authentication Code

HMAC combines a hash function with a secret key to provide both authentication and integrity. Unlike a plain hash (which provides only integrity), HMAC proves that the message came from someone who knows the secret key.

```
HMAC(key, message) = H((key XOR opad) || H((key XOR ipad) || message))
```

HMAC is used in:
- Authenticated encryption (combined with AES for AES-GCM-SIV)
- Key derivation functions (HKDF uses HMAC internally)
- Firmware update authentication (pre-signature alternative for constrained systems)
- OP-TEE secure storage authentication

```bash
# HMAC-SHA256 computation
$ echo -n "firmware update payload" | \
  openssl dgst -sha256 -hmac "secret-key-material" 
HMAC-SHA256(stdin)= 7f1234abcd...

# HMAC with binary key
$ openssl rand 32 > hmac-key.bin
$ echo -n "firmware" | \
  openssl dgst -sha256 -mac hmac -macopt hexkey:$(xxd -p hmac-key.bin | tr -d '\n')
```

### Hash Functions in FIT Images

The FIT image format embeds per-component hash nodes. U-Boot verifies these hashes when loading images:

```
FIT image structure (text representation of FDT):
/ {
    description = "Kernel image with DT and initramfs";
    images {
        kernel@1 {
            description = "Linux kernel";
            data = <binary kernel data>;
            type = kernel;
            arch = arm64;
            os = linux;
            compression = none;
            load = <0x40480000>;
            entry = <0x40480000>;
            hash@1 {
                algo = "sha256";
                value = <32-byte SHA-256 hash of kernel data>;
            };
        };
        fdt@1 {
            description = "Flattened Device Tree";
            data = <binary dtb data>;
            type = flat_dt;
            hash@1 {
                algo = "sha256";
                value = <32-byte SHA-256 hash of DTB>;
            };
        };
    };
    configurations {
        default = "conf@1";
        conf@1 {
            kernel = "kernel@1";
            fdt = "fdt@1";
            signature@1 {
                algo = "sha256,rsa2048";
                key-name-hint = "dev";
                signed-images = "kernel@1", "fdt@1";
                value = <RSA signature over hash of signed image hashes>;
            };
        };
    };
};
```

When `bootm` is invoked without signature verification enabled, U-Boot still verifies the per-image hash nodes. With `CONFIG_FIT_SIGNATURE=y` and the public key embedded in the U-Boot DTB, U-Boot additionally verifies the configuration signature.

---

## Symmetric Encryption

### AES: Advanced Encryption Standard

AES is the standard symmetric cipher. It operates on 128-bit blocks and supports 128-bit, 192-bit, or 256-bit keys. On i.MX8MP, CAAM provides hardware AES acceleration for all standard modes.

```bash
# AES-256-CBC file encryption (for key wrapping or data encryption)
$ openssl rand 32 > aes256-key.bin
$ openssl rand 16 > aes-iv.bin

$ openssl enc -aes-256-cbc \
  -in plaintext.bin \
  -out encrypted.bin \
  -K $(xxd -p aes256-key.bin | tr -d '\n') \
  -iv $(xxd -p aes-iv.bin | tr -d '\n')

$ openssl enc -d -aes-256-cbc \
  -in encrypted.bin \
  -out decrypted.bin \
  -K $(xxd -p aes256-key.bin | tr -d '\n') \
  -iv $(xxd -p aes-iv.bin | tr -d '\n')

# AES-128-GCM: authenticated encryption (preferred for secure boot use cases)
$ openssl enc -aes-128-gcm \
  -in plaintext.bin \
  -out encrypted-gcm.bin \
  -K $(openssl rand -hex 16) \
  -iv $(openssl rand -hex 12)
```

### AES Modes of Operation

| Mode | Encryption | Authentication | IV Reuse Safe? | Use Case |
|------|-----------|----------------|----------------|----------|
| ECB | YES | NO | NO | Never use (reveals patterns) |
| CBC | YES | NO | NO (IV must be random) | Legacy encryption |
| CTR | YES | NO | NO (nonce must be unique) | Stream encryption |
| GCM | YES | YES | NO (nonce must be unique) | Authenticated encryption, preferred |
| CCM | YES | YES | NO | Constrained devices (like CCM in TLS) |
| XTS | YES | NO | N/A (sector-based) | Disk encryption (dm-crypt) |
| SIV | YES | YES | YES (misuse-resistant) | Key wrap, deterministic contexts |

**For disk encryption** (dm-crypt/LUKS): AES-XTS-256 (128-bit key each half = 256-bit total)
**For FIT image encryption** (U-Boot FIT enc): AES-128-CBC or AES-128-CTR
**For OP-TEE secure storage**: AES-256-GCM

### AES Key Wrap (AES-KW)

AES Key Wrap (RFC 3394) is a specific algorithm for encrypting key material with another key. It is used in CAAM black key operations to protect device-unique keys:

```bash
# AES-256 Key Wrap (wrapping a 128-bit key)
$ openssl enc -aes-256-wrap \
  -K $(openssl rand -hex 32) \
  -in session-key-128bit.bin \
  -out session-key-wrapped.bin

# The CAAM hardware does this internally for black key operations:
# 1. CAAM generates KEK (Key Encryption Key) from device-unique hardware secret
# 2. Application key is wrapped with KEK → produces "black blob"
# 3. Black blob can be stored in filesystem; it is useless without the device
# 4. At next boot, CAAM unwraps black blob using the same hardware KEK
```

---

## Asymmetric Cryptography

The full technical reference for RSA and ECC is in `02-asymmetric-cryptography.md`.

### Quick Reference: Algorithm Selection

For HABv4 (ROM-enforced Secure Boot):
- **Minimum**: RSA-2048 (NXP requirement)
- **Recommended**: RSA-4096 (longer device lifetime)
- **Note**: HABv4 in i.MX8MP ROM does not support ECC

For FIT image signing (U-Boot Verified Boot):
- **Options**: RSA-2048, RSA-4096, ECDSA P-256, ECDSA P-384
- **Recommended**: RSA-4096 or ECC P-384

For code signing certificates (intermediate keys):
- **Recommended**: ECC P-256 or P-384 for smaller certificate sizes

---

## Digital Signatures

Digital signatures provide authentication and non-repudiation. In secure boot, they prove that a boot image was produced by the holder of the private key corresponding to the embedded/fused public key.

### RSA-PSS vs RSA-PKCS#1 v1.5

HABv4 uses RSA-PKCS#1 v1.5 (the older scheme). For FIT image signing, both schemes are available but RSA-PSS is preferred:

| Property | PKCS#1 v1.5 | PSS |
|----------|-------------|-----|
| Security proof | Deterministic, no tight security reduction | Tight security reduction in random oracle model |
| Signature size | Same (= key size) | Same (= key size) |
| Nonce | Deterministic (hash+padding, no random) | Probabilistic (random salt in padding) |
| HABv4 compatible | YES (NXP uses this) | NO (HABv4 ROM does not support PSS) |
| FIT signing | YES (legacy) | YES (preferred) |
| Timing | Deterministic | Slightly variable (salt generation) |

```bash
# RSA sign with PKCS#1 v1.5 (for HABv4 compatibility via CST tool)
openssl dgst -sha256 -sign private.pem -out sig-v1.5.bin image.bin

# RSA sign with PSS (for FIT image signing)
openssl dgst -sha256 \
  -sigopt rsa_padding_mode:pss \
  -sigopt rsa_pss_saltlen:32 \
  -sign private.pem \
  -out sig-pss.bin image.bin

# Verify PSS signature
openssl dgst -sha256 \
  -sigopt rsa_padding_mode:pss \
  -sigopt rsa_pss_saltlen:32 \
  -verify public.pem \
  -signature sig-pss.bin image.bin
# Output: Verified OK

# ECDSA signing (for FIT signing with ECC key)
openssl dgst -sha256 -sign ec-private.pem -out ec-sig.bin image.bin
openssl dgst -sha256 -verify ec-public.pem -signature ec-sig.bin image.bin
```

### Timing on Cortex-A53 @ 1.6GHz

| Operation | Algorithm | Software | CAAM Hardware |
|-----------|-----------|----------|---------------|
| Sign | RSA-2048 | ~3 ms | ~0.8 ms |
| Verify | RSA-2048 | ~0.1 ms | ~0.05 ms |
| Sign | RSA-4096 | ~20 ms | ~5 ms |
| Verify | RSA-4096 | ~0.4 ms | ~0.2 ms |
| Sign | ECC P-256 | ~2.5 ms | ~0.5 ms |
| Verify | ECC P-256 | ~5 ms | ~1 ms |
| Sign | ECC P-384 | ~5 ms | ~1 ms |
| Verify | ECC P-384 | ~10 ms | ~2 ms |

RSA verification is faster than ECC verification because modular exponentiation with a small public exponent (typically `e=65537`) requires fewer operations than elliptic curve point multiplication for verification. The opposite is true for signing.

---

## X.509 Certificates and PKI

The full reference for PKI and certificates is in `03-pki-and-certificates.md`.

### Certificate Hierarchy Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                    PKI HIERARCHY FOR SECURE BOOT                     │
│                                                                      │
│   Root CA (offline, HSM-protected, 4096-bit RSA, validity: 20yr)   │
│        │                                                             │
│        │ signs                                                       │
│        ▼                                                             │
│   SRK Certificates (1-4) (HABv4 SRK table entries)                 │
│   [4096-bit RSA, validity: 10yr]                                     │
│        │                                                             │
│        │ signs (per-SRK)                                             │
│        ▼                                                             │
│   CSF Key Certificate  (signs Command Sequence Files)               │
│   [2048-bit RSA, validity: 5yr]                                      │
│        │                                                             │
│        │ signs                                                       │
│        ▼                                                             │
│   IMG Key Certificate  (signs image hash in CSF)                    │
│   [2048-bit RSA, validity: 5yr]                                      │
│        │                                                             │
│        │ is used to authenticate                                     │
│        ▼                                                             │
│   Boot Image (SPL + TF-A + OP-TEE + U-Boot)                         │
│                                                                      │
│   FIT Signing Key (separate hierarchy, for FIT image signing)       │
│   [2048 or 4096-bit RSA, or ECC P-256/P-384]                        │
│        │                                                             │
│        │ embedded in U-Boot DTB (public key)                        │
│        └── signs FIT image (kernel + DTB + initramfs)               │
└──────────────────────────────────────────────────────────────────────┘
```

---

## CAAM: Hardware Cryptographic Acceleration on i.MX8MP

The CAAM (Cryptographic Acceleration and Assurance Module) is the i.MX8MP hardware security subsystem. It provides:

### CAAM Capabilities

| Function | Details |
|----------|---------|
| AES | 128/192/256-bit; ECB, CBC, CTR, GCM, CCM, XTS, SIV, CCM, OFB, CFB |
| RSA | 512 to 4096-bit; PKCS#1 v1.5, PSS |
| ECC | NIST P-192, P-224, P-256, P-384, P-521; ECDSA, ECDH |
| Hash | SHA-1, SHA-224, SHA-256, SHA-384, SHA-512, MD5 |
| HMAC | HMAC-SHA-1, HMAC-SHA-256, HMAC-SHA-384, HMAC-SHA-512 |
| TRNG | True Random Number Generator (NIST SP 800-90B compliant) |
| Key management | Black key generation, black blob encapsulation/decapsulation |
| Secure Memory | Partition-based secure key storage |

### CAAM Linux Driver Interface

```bash
# Check CAAM is initialized and registered
$ dmesg | grep caam
[    1.234567] caam 30900000.crypto: ERA source: CCBVID
[    1.234567] caam 30900000.crypto: Entropy delay = 3200
[    1.234567] caam 30900000.crypto: Instantiated RNG4 SH0, SH1
[    1.234567] caam_jr 30901000.jr: registering rng-caam
[    1.234567] caam_jr 30901000.jr: caam algorithm registration
[    1.234567] caam 30900000.crypto: registering rng

# CAAM-backed kernel crypto engine registrations
$ cat /proc/crypto | grep -A4 "caam"
name         : cbc(aes)
driver       : cbc-aes-caam
module       : kernel
priority     : 3000   ← Higher priority than software (0)

# Use CAAM via /dev/cryp (AF_ALG socket interface)
$ python3 -c "
import socket, struct
ALG = socket.AF_ALG
sock = socket.socket(ALG, socket.SOCK_SEQPACKET, 0)
sock.bind((b'hash', b'', 0, 0, b'sha256-caam'))
"
```

### CAAM Black Keys

CAAM black keys are device-unique encryption keys that are wrapped by a hardware-derived Key Encryption Key (KEK) internal to CAAM. The wrapped form ("black blob") can be stored in the filesystem but is only usable on the specific device that created it:

```bash
# Black key creation (from U-Boot or via CAAM userspace interface)
# This is handled through OP-TEE or directly via CAAM kernel driver

# In Linux, using CAAM keyblob interface (if driver supports it):
# 1. Create a random key and wrap it as a black blob
echo "0000000000000000000000000000000000000000000000000000000000000000" | \
  xxd -r -p | \
  keyctl padd caam-aes-cipher "\$: <nonce>" @s

# In U-Boot (before Linux):
# => caam info
# CAAM block present
# => caam blob enc <src_addr> <dst_addr> <len> <key_modifier>
# Creates CAAM red->black blob

# Production workflow: OP-TEE manages black key lifecycle
# OP-TEE TA generates key → stores in CAAM black blob → stores blob in secure storage
```

---

## Key Storage on i.MX8MP

### SNVS (Secure Non-Volatile Storage)

SNVS is always-on storage that persists across warm resets (but not necessarily cold resets depending on configuration). Key storage uses:

- **SNVS_ZMK** (Zeroizable Master Key): 256-bit register. Can be written as a one-time operation. Automatically zeroized on tamper detection events. Used as root key for CAAM key derivation.
- **SNVS_LPSMKR** (Low Power Software Master Key Register): Holds an additional key.

```
SNVS ZMK usage:
Customer burns ZMK into SNVS (via fuse or software)
  → ZMK becomes device-unique secret
  → CAAM derives OTPMK/KPEK from ZMK
  → KPEK used to wrap black blobs
  → Black blobs are device-specific
```

### OP-TEE Secure Storage

OP-TEE implements a secure key-value store in the Trusted Execution Environment. Contents are:
- Encrypted with a key derived from the OP-TEE hardware key (from CAAM)
- Integrity-protected with HMAC
- Stored in RPMB (Replay Protected Memory Block) on eMMC for replay protection

This is the recommended storage for secrets that must survive across boots but must not be accessible from the Normal World.

---

## Entropy and TRNG

The CAAM TRNG on i.MX8MP is a hardware entropy source compliant with NIST SP 800-90B (Recommendation for the Entropy Sources Used for Random Bit Generation). It uses two ring oscillators with different frequencies; their jitter provides physical randomness.

```bash
# Verify TRNG is operational
$ cat /sys/devices/soc0/soc/30800000.bus/30900000.crypto/30900000.crypto\:rng/rng_current
rng-caam

# Read 32 bytes from CAAM TRNG
$ dd if=/dev/hwrng bs=32 count=1 2>/dev/null | xxd
00000000: a3b7 2c9e 1f4d 6a88 7e5c 3012 8b94 ef1a  ..,..Mj.^.0.....
00000010: 5d72 c8a9 0e3b 1f6d 4a9e 8c72 1d5b 9f3e  ]r...;.mJ..r.[.>

# Configure rngd to feed CAAM entropy into kernel pool
$ systemctl enable rngd
$ systemctl start rngd
$ cat /proc/sys/kernel/random/entropy_avail
4096
```

Why randomness quality matters: RSA key generation requires large random primes. If the prime selection is not truly random (e.g., predictable due to uninitialized entropy pool), an attacker may be able to factor the resulting public modulus. This is not theoretical — the Debian OpenSSL vulnerability (2008) and the Factorable RSA keys paper (2012) demonstrated real-world key compromises from weak randomness.

---

## Common Cryptographic Mistakes in Embedded Contexts

### Using MD5 or SHA-1 for Security

MD5 and SHA-1 are broken for collision resistance. MD5 has practical collision attacks (2^18 operations). SHA-1 has demonstrated collisions (SHAttered, 2017). Neither should be used for any new secure boot implementation.

**Correct:** SHA-256 or SHA-384 for all integrity checking.
**Wrong:** MD5 or SHA-1 for image hashing, certificate hashing, or HMAC.

### Using RSA Keys Smaller Than 2048 Bits

RSA-1024 is factored with ~$10M in cloud compute using GNFS. RSA-1024 keys provide approximately 80-bit security, which is below current NIST minimums (112-bit for near-term use, 128-bit for long-term).

**HABv4 minimum**: RSA-2048 (128-bit security, approved through ~2030 per NIST SP 800-131A Rev 2)
**Recommended for new designs**: RSA-4096 or ECC P-384 (192-bit security)

### Deterministic Nonce Reuse with ECDSA

ECDSA requires a cryptographically random nonce `k` per signature. If the same `k` is reused for two signatures with the same key, the private key can be recovered algebraically from the two signatures. This is not theoretical: the PlayStation 3 ECDSA key was extracted using this method.

```
# Catastrophic ECDSA nonce reuse:
sig1 = (r1, s1) where s1 = (H(m1) + x*r1) / k mod n
sig2 = (r2, s2) where s2 = (H(m2) + x*r2) / k mod n
# If k is same: r1 == r2 (same point on curve)
# x (private key) = (s1*H(m2) - s2*H(m1)) / (r*(s1-s2)) mod n
```

**Mitigation:** Use RFC 6979 deterministic k-generation (k derived from private key + message, deterministically). OpenSSL's ECDSA implementation uses RFC 6979 by default.

### Key Reuse Across Different Devices

Using the same HABv4 signing key across all device variants or production runs creates a single point of failure. If the key is compromised, all devices across all variants are affected. Use per-SKU or per-batch SRK keys where operationally feasible.

### Storing Private Keys in Source Control

An automated scan of public GitHub repositories regularly finds private keys committed to repositories. For secure boot keys, this is catastrophic:

```bash
# Common mistake: committing keys to the repository
git add keys/srk-private.pem   # NEVER DO THIS

# Correct: keys are offline, in HSM, never in VCS
# The build system fetches only public certificates
# Signing is performed by a separate, secured signing service
```

### Using ECB Mode

AES-ECB encrypts each block independently. Identical plaintext blocks produce identical ciphertext blocks, revealing patterns in the plaintext. It is not semantically secure.

Never use AES-ECB for encrypting image data or any structured data with repeating patterns.

### Not Validating Signatures Before Execution

Some implementations check signatures but proceed anyway if verification fails "to avoid bricking devices during development." This is exactly the HABv4 OPEN mode behavior. Development mode must not ship to production. Add explicit production mode checks.

---

## Side-Channel Attack Awareness

Side-channel attacks extract secret information from physical observables (power consumption, electromagnetic emissions, timing variations) rather than from cryptographic weaknesses.

### Relevance for Embedded Systems

- **Power analysis (SPA/DPA)**: Measure power consumption during RSA or ECDSA operations. Key bits are visible in power traces if the implementation is not constant-time. CAAM uses algorithmic countermeasures but is not DPA-certified for all configurations.
- **Timing attacks**: Non-constant-time implementations of modular exponentiation leak key bits through timing variations. OpenSSL uses constant-time operations for RSA (Montgomery multiplication is constant-time).
- **Electromagnetic analysis (EMA)**: Similar to power analysis; EM emissions from the CPU during crypto operations carry the same information.

### HSM vs Software Key Storage

For high-security deployments where side-channel attacks are in the threat model (e.g., medical devices, payment terminals, industrial control), consider:

1. **Discrete HSM** (external hardware security module): Keys never leave the HSM. Signing operations occur inside the HSM. Provides physical tamper protection and side-channel countermeasures certified to FIPS 140-2 Level 3 or CC EAL 4+.
2. **CAAM with physical security**: CAAM provides hardware-backed key storage but is not a certified HSM. Suitable for commercial-grade security requirements.
3. **OP-TEE fTPM**: Software side-channel attacks on TrustZone are a research area. Not suitable for highest-security requirements.

The choice of HSM significantly impacts key management workflow. External HSMs (Thales Luna, AWS CloudHSM, YubiHSM 2) require network connectivity or physical access for signing operations. This is incompatible with automated CI/CD signing unless the HSM is network-accessible and the signing workflow is designed accordingly.

---

## Chapter Files

| File | Content |
|------|---------|
| `01-hash-functions.md` | SHA-2 family deep dive, HMAC, FIT hash nodes, CAAM acceleration |
| `02-asymmetric-cryptography.md` | RSA and ECC: key generation, signing, verification, performance comparison |
| `03-pki-and-certificates.md` | X.509 certificates, PKI hierarchy, HABv4 SRK table, FIT signing keys |

---

## Further Reading

- NIST SP 800-57 Part 1: Recommendation for Key Management
  https://doi.org/10.6028/NIST.SP.800-57pt1r5
- NIST SP 800-131A Rev 2: Transitioning the Use of Cryptographic Algorithms and Key Lengths
  https://doi.org/10.6028/NIST.SP.800-131Ar2
- RFC 8017: PKCS #1 Version 2.2: RSA Cryptography Specifications
  https://www.rfc-editor.org/rfc/rfc8017
- NXP CAAM Reference Manual (Chapter 8 of i.MX8MP RM)
- "Twenty Years of Attacks on the RSA Cryptosystem" — Dan Boneh
  https://crypto.stanford.edu/~dabo/papers/RSA-survey.pdf
- "Practical Cryptography" — Niels Ferguson, Bruce Schneier, Tadayoshi Kohno
- Side-channel attacks overview: "Introduction to Differential Power Analysis"
  https://www.cr.yp.to/papers/dpa-20100927.pdf
