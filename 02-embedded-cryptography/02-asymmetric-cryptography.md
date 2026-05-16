# 02-asymmetric-cryptography: RSA and ECC for Secure Boot

## Version Matrix

| Algorithm/Standard | Version/Reference | Status |
|--------------------|-------------------|--------|
| RSA | PKCS#1 v2.2 (RFC 8017) | Current |
| RSA-2048 | NIST SP 800-131A Rev 2 | Approved through 2030 |
| RSA-3072 | NIST SP 800-131A Rev 2 | Approved through 2030+ |
| ECC P-256 | FIPS 186-5 | Current |
| ECC P-384 | FIPS 186-5 | Current |
| ECDSA | FIPS 186-5 | Current |
| NXP HABv4 | i.MX8MP RM Rev 3 | RSA-2048 minimum |
| OpenSSL | 3.0+ | Current |

---

## Overview

Asymmetric cryptography is the foundation of digital signature schemes used throughout secure boot: HABv4 uses RSA to authenticate the boot image, U-Boot FIT signing uses RSA or ECC to authenticate the kernel, and the PKI certificate chain uses RSA or ECC throughout.

This chapter provides both the theoretical foundation and practical OpenSSL command reference required to:
1. Generate RSA and ECC key pairs of appropriate sizes
2. Create and verify digital signatures for secure boot artifacts
3. Understand the security equivalences between RSA and ECC key sizes
4. Select the right algorithm for each layer of the trust chain
5. Measure and optimize signature verification performance on Cortex-A53

---

## RSA: Rivest-Shamir-Adleman

### Mathematical Foundation

RSA security rests on the computational difficulty of factoring large integers. Given a public key `(n, e)` where `n = p × q` (product of two large primes), recovering `p` and `q` is computationally infeasible for sufficiently large `n`.

- **Key generation**: choose primes `p` and `q`, compute `n = p*q`, `φ(n) = (p-1)*(q-1)`, select `e` coprime to `φ(n)` (typically `e = 65537`), compute `d = e^-1 mod φ(n)`
- **Public key**: `(n, e)` — the modulus and public exponent
- **Private key**: `(n, d)` — the modulus and private exponent  
- **Sign**: `σ = m^d mod n` (private key operation, expensive)
- **Verify**: `m = σ^e mod n` (public key operation, fast because `e` is small)

This asymmetry (verify is faster than sign) is exploited in secure boot: the resource-constrained ROM code only verifies (fast), while signing happens offline on a development workstation or HSM.

### RSA Key Size Security Equivalences

| RSA Key Size | Security Level | NIST Approval (until) | Key Size (bytes) | Sig Size (bytes) |
|-------------|---------------|----------------------|-----------------|-----------------|
| RSA-1024 | 80-bit | DEPRECATED (do not use) | 128 | 128 |
| RSA-2048 | 112-bit | 2030 (per SP 800-131A Rev 2) | 256 | 256 |
| RSA-3072 | 128-bit | 2030+ | 384 | 384 |
| RSA-4096 | ~140-bit | Long-term | 512 | 512 |
| RSA-7680 | 192-bit | Long-term | 960 | 960 |

For devices with long deployment lifetimes (10+ years), RSA-2048 approved only through ~2030 may be insufficient. RSA-4096 provides a comfortable margin.

### RSA-2048 Key Generation

```bash
# Generate RSA-2048 private key (PKCS#1 format)
$ openssl genrsa -out rsa2048-private.pem 2048
Generating RSA private key, 2048 bit long modulus (2 primes)
....................................................................+++++
..............+++++
e is 65537 (0x10001)

# Inspect the generated key structure
$ openssl rsa -in rsa2048-private.pem -text -noout | head -20
Private-Key: (2048 bit, 2 primes)
modulus:
    00:c8:3a:f2:9e:4d:1b:7c:8a:5e:3f:2d:9b:6c:4a:
    87:1e:5d:3c:7f:2b:9a:6e:4d:1c:8b:5f:3e:7a:2d:
    9c:6b:4e:1d:8f:5c:3a:7b:2e:9d:6a:4c:1b:8e:5d:
    3f:7c:2a:9e:6b:4d:1c:8a:5e:3f:7b:2d:9c:6e:4a:
    ...
publicExponent: 65537 (0x10001)
privateExponent:
    00:8b:4d:1c:6e:3f:8a:2c:5b:7e:3d:9f:4c:1b:8e:
    ...
prime1:
    00:e3:2a:7f:4b:1c:6d:9e:2b:5f:8c:3a:7d:4e:1b:
    ...
prime2:
    00:da:1b:4f:8c:2e:6a:9d:3c:7b:5e:2d:8f:4a:1c:
    ...

# Extract public key
$ openssl rsa -in rsa2048-private.pem -pubout -out rsa2048-public.pem
writing RSA key

$ cat rsa2048-public.pem
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyDry...
-----END PUBLIC KEY-----

# Convert private key to PKCS#8 format (preferred for modern tooling)
$ openssl pkcs8 -topk8 -nocrypt \
  -in rsa2048-private.pem \
  -out rsa2048-private-pkcs8.pem

# Encrypt private key with passphrase (for storage)
$ openssl genrsa -aes256 -out rsa2048-encrypted.pem 2048
Enter pass phrase for rsa2048-encrypted.pem: xxxxxxxx
Verifying - Enter pass phrase for rsa2048-encrypted.pem: xxxxxxxx
```

### RSA-4096 Key Generation

```bash
# RSA-4096 key generation (takes longer due to prime search)
$ time openssl genrsa -out rsa4096-private.pem 4096
Generating RSA private key, 4096 bit long modulus (2 primes)
...............................++++
.....................................++++
e is 65537 (0x10001)
real    0m4.82s    # ~5 seconds on Cortex-A53 (software)
# On x86 development host: ~0.5 seconds

# RSA-4096 for HABv4 SRK (the highest security tier key)
$ openssl genrsa -out srk1-private-rsa4096.pem 4096
$ openssl genrsa -out srk2-private-rsa4096.pem 4096
$ openssl genrsa -out srk3-private-rsa4096.pem 4096
$ openssl genrsa -out srk4-private-rsa4096.pem 4096
# Four SRK keys: one active, three backup/recovery

# Extract public key
$ openssl rsa -in rsa4096-private.pem -pubout -out rsa4096-public.pem

# View public key size in DER format
$ openssl rsa -in rsa4096-private.pem -pubout -outform DER | wc -c
550   # 550 bytes for RSA-4096 DER-encoded public key

$ openssl rsa -in rsa2048-private.pem -pubout -outform DER | wc -c
294   # 294 bytes for RSA-2048 DER-encoded public key
```

### RSA Signing: PKCS#1 v1.5 vs PSS

**PKCS#1 v1.5** is the older, deterministic RSA signature scheme. NXP HABv4 uses PKCS#1 v1.5 internally (the NXP CST tool generates PKCS#1 v1.5 signatures for the CSF). It is widely supported but lacks a tight security proof.

**RSA-PSS** (Probabilistic Signature Scheme) is the modern scheme with a provable security reduction. It uses a random salt, making each signature different even for the same message and key. Preferred for new implementations.

```bash
# Create a test target for signing
$ dd if=/dev/urandom bs=1M count=1 of=target-image.bin 2>/dev/null

# ─── RSA-PKCS#1 v1.5 Signing ─────────────────────────────────────────────────

# Sign with PKCS#1 v1.5 (deterministic)
$ openssl dgst -sha256 \
  -sign rsa2048-private.pem \
  -out sig-pkcs1v15.bin \
  target-image.bin

# Verify PKCS#1 v1.5 signature
$ openssl dgst -sha256 \
  -verify rsa2048-public.pem \
  -signature sig-pkcs1v15.bin \
  target-image.bin
Verified OK

# Verify failure (tampered file):
$ dd if=/dev/urandom bs=1 count=1 seek=100 conv=notrunc of=target-image.bin 2>/dev/null
$ openssl dgst -sha256 \
  -verify rsa2048-public.pem \
  -signature sig-pkcs1v15.bin \
  target-image.bin
Verification Failure

# ─── RSA-PSS Signing ─────────────────────────────────────────────────────────

# Sign with PSS (salt length = hash length = 32 bytes for SHA-256)
$ openssl dgst -sha256 \
  -sigopt rsa_padding_mode:pss \
  -sigopt rsa_pss_saltlen:32 \
  -sign rsa2048-private.pem \
  -out sig-pss.bin \
  target-image.bin

# Each PSS signing produces a different signature (probabilistic due to salt)
$ openssl dgst -sha256 \
  -sigopt rsa_padding_mode:pss \
  -sigopt rsa_pss_saltlen:32 \
  -sign rsa2048-private.pem \
  -out sig-pss2.bin \
  target-image.bin

$ cmp sig-pss.bin sig-pss2.bin
# Files differ — expected for PSS (salt randomness)

# Verify PSS signature
$ openssl dgst -sha256 \
  -sigopt rsa_padding_mode:pss \
  -sigopt rsa_pss_saltlen:32 \
  -verify rsa2048-public.pem \
  -signature sig-pss.bin \
  target-image.bin
Verified OK

# Signature size equals key size in bytes:
$ wc -c sig-pkcs1v15.bin sig-pss.bin
256 sig-pkcs1v15.bin   # 2048 bits / 8 = 256 bytes
256 sig-pss.bin        # Same size — PSS does not increase signature size
```

### RSA Signing with DER Output (for FIT nodes)

FIT image signature values are stored as raw DER-encoded signature bytes:

```bash
# Generate RSA signature in binary (DER) format for FIT
$ openssl dgst -sha256 \
  -sign rsa2048-private.pem \
  -binary \
  target-image.bin > sig.der

# View the raw DER signature
$ xxd sig.der | head -4
00000000: 3d5c 2a1b 7e8f 4c9d 3a7b 2e8f 5c1d 4a9b  =\.*.~.L.:{.\.J.
00000010: 6c2d 8e3f 5b1a 7d9c 4e2b 8f3c 6a1d 9e4b  l-.?[.}.N+.<j..K
```

---

## ECC: Elliptic Curve Cryptography

### Mathematical Foundation

ECC operates on points on an elliptic curve over a finite field. The NIST P-curves (used in secure boot) are defined over a prime field `Fp`:

```
Curve equation: y² = x³ + ax + b  (mod p)
NIST P-256: p = 2^256 - 2^224 + 2^192 + 2^96 - 1 (256-bit prime)
            a = p - 3
            b = 41058363725152142129326129780047268409114441015993725554835256314039467401291
```

ECC security rests on the Elliptic Curve Discrete Logarithm Problem (ECDLP): given points P and Q = k*P on the curve, computing k is computationally infeasible. No sub-exponential algorithm is known for ECDLP, unlike integer factorization (RSA).

This means ECC achieves equivalent security with much smaller key sizes than RSA:

| ECC Curve | Key Size | Security | Equivalent RSA |
|-----------|----------|----------|----------------|
| P-192 | 24 bytes (public) | 96-bit | RSA-1536 |
| P-256 | 32 bytes (public) | 128-bit | RSA-3072 |
| P-384 | 48 bytes (public) | 192-bit | RSA-7680 |
| P-521 | 66 bytes (public) | 256-bit | RSA-15360 |

### ECC Key Generation

```bash
# ─── NIST P-256 Key ──────────────────────────────────────────────────────────

# Generate P-256 (secp256r1 = prime256v1) private key
$ openssl ecparam -name prime256v1 -genkey -noout -out ec256-private.pem

# View the key parameters
$ openssl ec -in ec256-private.pem -text -noout
Private-Key: (256 bit)
priv:
    00:a3:b7:2c:9e:1f:4d:6a:88:7e:5c:30:12:8b:94:
    ef:1a:5d:72:c8:a9:0e:3b:1f:6d:4a:9e:8c:72:1d:
    5b:9f:3e:4c
pub:
    04:7f:83:b1:65:7f:f1:fc:53:b9:2d:c1:81:48:a1:    ← 04 prefix = uncompressed point
    d6:5d:fc:2d:4b:1f:a3:d6:77:28:4a:dd:d2:00:12:
    6d:90:69:a3:c7:2e:9f:b2:d5:8f:4c:1b:3e:7d:9a:
    6b:2f:5e:8c:4d:1b:6e:3f:9c:2a:7d:5f:8b:4e:1c:
    9d:3a:7e:5c
ASN1 OID: prime256v1
NIST CURVE: P-256

# Extract public key only
$ openssl ec -in ec256-private.pem -pubout -out ec256-public.pem
read EC key
writing EC key

# Public key size in bytes:
$ openssl ec -in ec256-private.pem -pubout -outform DER | wc -c
91    # 91 bytes for P-256 public key in DER format
      # Compare: RSA-2048 public key = 294 bytes (3x larger)

# ─── NIST P-384 Key ──────────────────────────────────────────────────────────

# Generate P-384 (secp384r1) private key
$ openssl ecparam -name secp384r1 -genkey -noout -out ec384-private.pem

# Extract public key
$ openssl ec -in ec384-private.pem -pubout -out ec384-public.pem

$ openssl ec -in ec384-private.pem -pubout -outform DER | wc -c
120   # 120 bytes for P-384 public key in DER format

# Time key generation (fast compared to RSA):
$ time openssl ecparam -name prime256v1 -genkey -noout -out /dev/null
real    0m0.012s   # 12ms on x86; ~50ms on Cortex-A53

$ time openssl ecparam -name secp384r1 -genkey -noout -out /dev/null
real    0m0.015s   # 15ms on x86; ~70ms on Cortex-A53

# Compare to RSA:
$ time openssl genrsa -out /dev/null 2048
real    0m0.087s   # 87ms on x86; ~800ms on Cortex-A53

$ time openssl genrsa -out /dev/null 4096
real    0m0.513s   # 513ms on x86; ~5000ms on Cortex-A53
```

### ECDSA Signing and Verification

ECDSA (Elliptic Curve Digital Signature Algorithm) is the ECC signature scheme supported by U-Boot FIT signing. HABv4 ROM code does NOT support ECDSA (only RSA). Use ECDSA only for FIT image signing (Layer 2), not for HABv4 (Layer 1).

```bash
# ─── ECDSA Signing ───────────────────────────────────────────────────────────

# Sign with ECDSA-SHA256 (P-256 key)
$ openssl dgst -sha256 \
  -sign ec256-private.pem \
  -out ec256-sig.bin \
  target-image.bin

# ECDSA signatures are DER-encoded and variable length (within a range)
$ wc -c ec256-sig.bin
71    # 71 bytes (typical; range is 68-72 bytes for P-256/SHA-256)
# Compare: RSA-2048 signature is always 256 bytes

# Run multiple times to see size variation (due to DER encoding of r,s integers):
$ for i in {1..5}; do
    openssl dgst -sha256 -sign ec256-private.pem -out /tmp/s$i.bin target-image.bin
    wc -c /tmp/s$i.bin
  done
71 /tmp/s1.bin
72 /tmp/s2.bin
70 /tmp/s3.bin
71 /tmp/s4.bin
71 /tmp/s5.bin
# DER integer encoding varies by leading zero requirements

# Verify ECDSA signature
$ openssl dgst -sha256 \
  -verify ec256-public.pem \
  -signature ec256-sig.bin \
  target-image.bin
Verified OK

# Sign with P-384 for higher security FIT images
$ openssl dgst -sha384 \
  -sign ec384-private.pem \
  -out ec384-sig.bin \
  target-image.bin

$ wc -c ec384-sig.bin
104   # ~104 bytes for P-384/SHA-384 ECDSA signature

# Verify P-384 ECDSA
$ openssl dgst -sha384 \
  -verify ec384-public.pem \
  -signature ec384-sig.bin \
  target-image.bin
Verified OK

# ─── ECDSA with Raw Output (r,s format) ──────────────────────────────────────
# U-Boot FIT signing stores signatures in raw r||s format, not DER
# mkimage handles the conversion internally

# Convert DER-encoded ECDSA signature to raw r||s:
$ openssl asn1parse -in ec256-sig.bin -inform DER | grep "INTEGER"
#  0:d=0  hl=2 l=  71 cons: SEQUENCE
#  2:d=1  hl=2 l=  32 prim: INTEGER   :A3B72C9E1F4D6A887E5C30128B94EF1A...  (r)
# 36:d=1  hl=2 l=  31 prim: INTEGER   :5D72C8A90E3B1F6D4A9E8C721D5B9F3E...  (s)
# Note: DER INTEGER may have leading 0x00 byte to signal positive value
```

---

## Key Size Comparison Reference

```
ALGORITHM COMPARISON TABLE
═══════════════════════════════════════════════════════════════════════════
Algorithm   Sec  Priv Key  Pub Key  Signature  Sign Time  Verify Time
            Bits  (bytes)  (bytes)   (bytes)   (Cortex-A53 @ 1.6GHz, soft)
───────────────────────────────────────────────────────────────────────────
RSA-2048    112    1,193     294      256        ~3 ms      ~0.1 ms
RSA-3072    128    1,694     422      384        ~9 ms      ~0.2 ms
RSA-4096    140    2,374     550      512        ~20 ms     ~0.4 ms
ECC P-256   128       32      91       71        ~2.5 ms    ~5.0 ms
ECC P-384   192       48     120      104        ~5.0 ms    ~10.0 ms
ECC P-521   256       66     158      139        ~10.0 ms   ~20.0 ms
───────────────────────────────────────────────────────────────────────────
With CAAM hardware acceleration (estimated):
RSA-2048    112    1,193     294      256        ~0.8 ms    ~0.05 ms
RSA-4096    140    2,374     550      512        ~5 ms      ~0.2 ms
ECC P-256   128       32      91       71        ~0.5 ms    ~1.0 ms
ECC P-384   192       48     120      104        ~1.0 ms    ~2.0 ms
═══════════════════════════════════════════════════════════════════════════

Note: RSA verify is FASTER than ECC verify because RSA verify uses
      small public exponent e=65537 (few multiplications).
      RSA sign is SLOWER than ECC sign because private exponent is large.
```

---

## NXP HABv4 Requirements

HABv4 in the i.MX8MP Boot ROM has specific algorithm requirements that cannot be changed (ROM code is immutable):

| Parameter | HABv4 Requirement | Notes |
|-----------|------------------|-------|
| Algorithm | RSA only | ECDSA not supported in HABv4 |
| Key size | RSA-2048 minimum | RSA-4096 also supported |
| Hash | SHA-256 | SHA-384/512 not supported in HABv4 |
| Signature scheme | PKCS#1 v1.5 | PSS not supported |
| SRK slots | 4 | Up to 4 SRK keys; revocation by burning SRK_REVOKE fuses |
| Key format | X.509 DER certificate | PEM also accepted by CST tool (converts internally) |

**Implication**: If HABv4 requires RSA and the FIT layer uses ECC, there is no contradiction — they are separate layers with separate key pairs. The HABv4 keys are RSA; the FIT signing keys can be RSA or ECC.

### HABv4 SRK Certificate Format

The NXP Code Signing Tool (CST) generates the SRK certificates in a specific format:

```bash
# Using NXP CST tool to create SRK key pairs and certificates
# (Assumes NXP CST tool is installed at /opt/cst/)

# Create HABv4 PKI tree
$ /opt/cst/keys/hab4_pki_tree.sh
# This script:
# 1. Creates CA key and self-signed CA certificate
# 2. Creates 4 SRK key pairs (RSA-2048 or RSA-4096)
# 3. Signs SRK certificates with CA key
# 4. Creates CSF key and IMG key (signed by SRK)
# 5. Generates SRK_1_2_3_4_table.bin (concatenated SRK public keys)
# 6. Generates SRK_1_2_3_4_fuse.bin (32-byte SHA-256 hash → to fuses)

# Generated files:
# keys/
#   ├── SRK1_sha256_2048_65537_v3_ca_key.pem  (private, KEEP OFFLINE)
#   ├── SRK2_sha256_2048_65537_v3_ca_key.pem
#   ├── SRK3_sha256_2048_65537_v3_ca_key.pem
#   ├── SRK4_sha256_2048_65537_v3_ca_key.pem
#   ├── CSF1_1_sha256_2048_65537_v3_usr_key.pem  (CSF signing key)
#   └── IMG1_1_sha256_2048_65537_v3_usr_key.pem  (Image signing key)
# crts/
#   ├── SRK1_sha256_2048_65537_v3_ca_crt.pem    (SRK certificates)
#   ├── SRK2_sha256_2048_65537_v3_ca_crt.pem
#   ├── SRK3_sha256_2048_65537_v3_ca_crt.pem
#   ├── SRK4_sha256_2048_65537_v3_ca_crt.pem
#   ├── CSF1_1_sha256_2048_65537_v3_usr_crt.pem
#   └── IMG1_1_sha256_2048_65537_v3_usr_crt.pem

# Verify the SRK hash (this is what goes into OTP fuses)
$ xxd SRK_1_2_3_4_fuse.bin
00000000: a3b7 2c9e 1f4d 6a88 7e5c 3012 8b94 ef1a  ..,..Mj.^.0.....
00000010: 5d72 c8a9 0e3b 1f6d 4a9e 8c72 1d5b 9f3e  ]r...;.mJ..r.[.>
# This 32-byte value is burned into OCOTP_SRK0...OCOTP_SRK7 fuses
```

---

## FIT Image Signing Key Requirements

For U-Boot FIT image signing, U-Boot supports:
- RSA-2048 with SHA-256
- RSA-4096 with SHA-256 or SHA-384
- ECC P-256 with SHA-256 (requires CONFIG_FIT_SIGNATURE_ECC)
- ECC P-384 with SHA-384 (requires CONFIG_FIT_SIGNATURE_ECC)

```bash
# Generate FIT signing key (RSA-2048, most compatible)
$ openssl genrsa -out fit-signing-key.pem 2048

# Generate FIT signing key (ECC P-256, smaller embedded public key)
$ openssl ecparam -name prime256v1 -genkey -noout -out fit-signing-key-ecc.pem

# Create self-signed certificate for key embedding
$ openssl req -new -x509 -days 3650 \
  -key fit-signing-key.pem \
  -out fit-signing-cert.pem \
  -subj "/CN=FIT Signing Key/O=MyCompany/C=DE"

# The public key will be embedded in the U-Boot DTB
# mkimage does this automatically during FIT signing:
$ mkimage -f kernel.its \
  -k keys/ \
  -K u-boot.dtb \
  -r \
  fitImage
# -k keys/ : directory containing fit-signing-key.pem
# -K u-boot.dtb : embed public key into this DTB (for U-Boot to use)
# -r : require verification (sets required=image in the FIT)
```

---

## Benchmarking on i.MX8MP

### OpenSSL Speed Test

```bash
# Run on the target device (i.MX8MP phyCORE) to get actual performance numbers

# RSA performance (software, no CAAM)
$ openssl speed rsa2048 rsa4096 2>/dev/null
Doing 2048 bits private rsa's for 10s: 1523 2048 bits private RSA's in 10.01s
Doing 2048 bits public rsa's for 10s:  96823 2048 bits public RSA's in 10.00s
Doing 4096 bits private rsa's for 10s: 196 4096 bits private RSA's in 10.02s
Doing 4096 bits public rsa's for 10s:  24312 4096 bits public RSA's in 10.00s

                  sign    verify    sign/s verify/s
rsa 2048 bits 0.006571s 0.000103s    152.1   9682.3
rsa 4096 bits 0.051122s 0.000412s     19.6   2431.2

# ECC performance (software, no CAAM)
$ openssl speed ecdsap256 ecdsap384 2>/dev/null
Doing 256 bits sign ecdsap256's for 10s: 3893 256 bits ECDSA signs in 10.01s
Doing 256 bits verify ecdsap256's for 10s: 1962 256 bits ECDSA verify in 10.01s
Doing 384 bits sign ecdsap384's for 10s: 1723 384 bits ECDSA signs in 10.02s
Doing 384 bits verify ecdsap384's for 10s: 876 384 bits ECDSA verify in 10.01s

                                 sign   verify sign/s verify/s
 256 bit ecdsa (nistp256)   0.002570s 0.005100s  389.3    196.2
 384 bit ecdsa (nistp384)   0.005804s 0.011416s  172.3     87.6

# Single operation timing (for boot performance calculation)
$ time openssl dgst -sha256 -sign rsa2048-private.pem \
  -out /tmp/s.bin target-image.bin
real    0m0.007s    # RSA-2048 sign: ~7ms

$ time openssl dgst -sha256 -verify rsa2048-public.pem \
  -signature /tmp/s.bin target-image.bin
real    0m0.001s    # RSA-2048 verify: ~1ms
Verified OK
```

### Boot Time Impact Analysis

| Verification Step | Image Size | Algorithm | Time (soft) | Time (CAAM) |
|-------------------|-----------|-----------|------------|------------|
| HABv4 SPL verify (ROM) | 800KB | RSA-2048 | ~5ms | N/A (ROM uses own engine) |
| FIT config signature verify | N/A | RSA-2048 | ~1ms | ~0.5ms |
| FIT kernel hash verify | 28MB | SHA-256 | ~370ms | ~35ms |
| FIT DTB hash verify | 96KB | SHA-256 | ~1ms | ~0.1ms |
| FIT initramfs hash verify | 8MB | SHA-256 | ~105ms | ~10ms |
| dm-verity on-mount verify | Full rootfs scan | SHA-256 Merkle | ~15s/GB | ~2s/GB |
| **Total (without CAAM)** | | | ~500ms | |
| **Total (with CAAM)** | | | | ~60ms |

The dm-verity on-mount full scan is optional. With `--verity-format=1` (not doing a full scan at mount, only per-block on read), the mount-time overhead is negligible. Full verification can be done asynchronously.

---

## HABv4 CSF Signing Workflow

The following shows the complete RSA signing workflow using the NXP Code Signing Tool:

```bash
# Prerequisite: NXP CST tool installed, keys generated
# Sign a complete flash.bin image

# Step 1: Build the unsigned flash.bin
$ cd /path/to/imx-mkimage
$ make SOC=iMX8MP flash_evk_flexspi
# Produces: flash.bin (SPL + TF-A + OP-TEE + U-Boot)

# Step 2: Create CSF descriptor file
$ cat > u-boot.csf << 'EOF'
[Header]
    Version = 4.3
    Hash Algorithm = sha256
    Engine Configuration = 0
    Certificate Format = X509
    Signature Format = CMS

[Install SRK]
    File = "SRK_1_2_3_4_table.bin"
    Source index = 0

[Install CSFK]
    File = "CSF1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate CSF]

[Unlock]
    Engine = SNVS
    Features = ZMK Write, LP GP2

[Install Key]
    Verification index = 0
    Target index = 2
    File = "IMG1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate Data]
    Verification index = 2
    Blocks = 0x7E1000 0x000 0x2C000 "flash.bin", \
             0x401FCDC0 0x2C000 0x10000 "flash.bin"
EOF

# Step 3: Sign with CST tool
$ /opt/cst/bin/cst --i u-boot.csf --o u-boot.csf.signed

# Step 4: Embed CSF signature block into flash.bin
# (CST tool handles padding and CSF block insertion automatically)
# The IVT in flash.bin points to the CSF offset

# Step 5: Verify signing in OPEN mode before burning SEC_CONFIG
# Boot the signed flash.bin on the device, then check:
U-Boot> hab_status
Secure boot disabled
HAB Configuration: 0xf0 expected: 0xcc
HAB State: 0x00

# Expect: no HAB events listed → signing is correct
# If HAB events appear: fix signing before closing HABv4
```

---

## Key Format Reference

| Format | Extension | Encoding | Content | Use |
|--------|-----------|----------|---------|-----|
| PEM | .pem | Base64 with headers | Any (cert, key, CSR) | OpenSSL, most tools |
| DER | .der | Binary ASN.1 | Any (cert, key) | NXP CST, low-level tools |
| PKCS#1 | .pem | PEM-wrapped | RSA private key | Legacy OpenSSL default |
| PKCS#8 | .pem | PEM-wrapped | Any private key | Modern preferred format |
| PKCS#12 | .p12 | Binary | Key + cert bundle | HSM exchange |

```bash
# Format conversions
# PEM private key → DER
$ openssl rsa -in private.pem -outform DER -out private.der

# DER certificate → PEM
$ openssl x509 -in cert.der -inform DER -out cert.pem

# PKCS#1 RSA key → PKCS#8 (both are PEM format, different header)
$ openssl pkcs8 -topk8 -nocrypt -in pkcs1.pem -out pkcs8.pem
# PKCS#1: -----BEGIN RSA PRIVATE KEY-----
# PKCS#8: -----BEGIN PRIVATE KEY-----

# Inspect any key/cert
$ openssl asn1parse -in private.pem        # View ASN.1 structure
$ openssl rsa -in private.pem -text -noout  # Human-readable RSA key
$ openssl ec -in ec-private.pem -text -noout # Human-readable ECC key
```

---

## Security Considerations

### RSA Private Exponent Protection

The RSA private exponent `d` is the critical secret. If `d` is exposed:
- An attacker can compute `σ = m^d mod n` for any message `m`
- This means they can sign arbitrary firmware images
- All devices with the corresponding `n` (public modulus) burned into fuses are compromised

Protect private keys by:
1. Generating keys in an HSM (key never exists outside HSM)
2. Using encrypted key files with strong passphrase if HSM is unavailable
3. Never committing private key files to version control
4. Using dedicated key management infrastructure for signing operations

### ECDSA Nonce Reuse (Catastrophic)

For ECDSA specifically: if the nonce `k` is reused across two signatures, or if `k` is predictable, the private key can be recovered. The PlayStation 3 private key was extracted using this exact attack. OpenSSL uses RFC 6979 deterministic nonce generation, which eliminates this risk when using OpenSSL's ECDSA implementation.

### RSA Blinding

RSA private key operations should use blinding to prevent timing side-channel attacks. OpenSSL enables RSA blinding by default. If implementing RSA in custom code (e.g., in U-Boot or OP-TEE), ensure blinding is enabled.

### Key Length and Device Lifetime

Choose key lengths based on the expected device deployment lifetime:
- Devices deployed in 2026 with 10-year lifetime: keys must remain secure until 2036
- NIST SP 800-131A Rev 2 approves RSA-2048 through 2030
- For 15-20 year device lifetimes, use RSA-4096 or ECC P-384

---

## Further Reading

- RFC 8017: PKCS #1 RSA Cryptography Specifications v2.2
  https://www.rfc-editor.org/rfc/rfc8017
- FIPS 186-5: Digital Signature Standard (DSS) — ECC parameters
  https://doi.org/10.6028/NIST.FIPS.186-5
- NIST SP 800-131A Rev 2: Transitioning Cryptographic Algorithms
  https://doi.org/10.6028/NIST.SP.800-131Ar2
- RFC 6979: Deterministic Usage of the Digital Signature Algorithm
  https://www.rfc-editor.org/rfc/rfc6979
- "Twenty Years of Attacks on the RSA Cryptosystem" — Dan Boneh
  https://crypto.stanford.edu/~dabo/papers/RSA-survey.pdf
- NXP AN12 Code Signing Tool User's Guide
- U-Boot FIT signature documentation: `doc/uImage.FIT/signature.txt`
- "The Million-Key Question" — ECDSA nonce reuse attack analysis
  https://cr.yp.to/papers/curve25519-20060209.pdf (related context)
