# 03-pki-and-certificates: PKI and X.509 Certificates for Secure Boot

## Version Matrix

| Standard/Tool | Version/Reference | Status |
|---------------|-------------------|--------|
| X.509 | RFC 5280 | Current |
| ASN.1 | ITU-T X.680 | Current |
| NXP CST (Code Signing Tool) | 3.3.1+ | Current for HABv4 |
| OpenSSL | 3.0+ | Current |
| PKCS#10 (CSR) | RFC 2986 | Current |
| PKCS#12 | RFC 7292 | Current (for key transport) |

---

## Overview

Public Key Infrastructure (PKI) is the framework of policies, procedures, and technologies that manages digital certificates and their associated cryptographic keys. In embedded secure boot, PKI defines:

1. **Who creates and holds the signing keys** (key ceremony, HSM policy)
2. **The trust hierarchy** (which certificates are trusted to sign which other certificates)
3. **Certificate formats** (X.509 DER/PEM, specific extensions required)
4. **Key lifecycle management** (generation, use, revocation, expiry)

For HABv4, the PKI structure is mandated by NXP: exactly four SRK certificates, a CSF certificate, and an IMG certificate per SRK slot. Understanding how this structure maps to standard X.509 PKI concepts is essential for operating the key infrastructure correctly.

---

## X.509 Certificate Structure

An X.509 certificate is an ASN.1-encoded data structure that binds a public key to an identity. The certificate is signed by a Certificate Authority (CA), whose signature vouches for the binding.

### Certificate Fields Relevant to Secure Boot

```
X.509v3 Certificate structure:

Certificate:
    Data:
        Version: 3 (0x2)                      ← Must be v3 for extensions
        Serial Number: 1 (0x1)                 ← Unique within issuer scope
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: CN=Secure Boot Root CA, O=MyCompany, C=DE
        Validity:
            Not Before: Jan  1 00:00:00 2026 GMT
            Not After : Dec 31 23:59:59 2045 GMT   ← 20yr for CA; 5-10yr for leaves
        Subject: CN=SRK 1, O=MyCompany, C=DE
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (4096 bit)
                Modulus: 00:c8:3a:f2...
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE                        ← For SRK certs (they sign CSF/IMG)
            X509v3 Key Usage: critical
                Certificate Sign                ← SRK signs CSF/IMG certificates
            X509v3 Subject Key Identifier:
                A3:B7:2C:9E:1F:4D...
            X509v3 Authority Key Identifier:
                keyid:7F:83:B1:65:7F:F1...
    Signature Algorithm: sha256WithRSAEncryption
    Signature Value: 00:d3:1c:7a...          ← Root CA's RSA signature over Data
```

### Critical Extensions for Secure Boot Certificates

**Basic Constraints**: Determines whether a certificate is a CA (can sign other certificates) or a leaf (end-entity).
- CA certificates (`CA:TRUE`): Root CA, Intermediate CA, SRK certs
- Leaf certificates (`CA:FALSE`): CSF cert, IMG cert, FIT signing cert

**Key Usage**: Specifies the intended cryptographic operations.
- For CA/signing certificates: `keyCertSign` (signs other certificates)
- For leaf signing certificates: `digitalSignature` (signs data directly)
- For encryption certificates: `keyEncipherment`

**Extended Key Usage**: Further restricts usage (not required for HABv4 but useful for FIT).
- `codeSigning`: appropriate for image signing certificates

```bash
# Inspect a certificate's critical extensions:
$ openssl x509 -in srk1-cert.pem -text -noout | grep -A10 "X509v3"
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE, pathlen:1
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
            X509v3 Subject Key Identifier:
                A3:B7:2C:9E:1F:4D:6A:88:7E:5C:30:12:8B:94:EF:1A
            X509v3 Authority Key Identifier:
                7F:83:B1:65:7F:F1:FC:53:B9:2D:C1:81:48:A1:D6:5D
```

### Validity Periods and Embedded Device Implications

X.509 certificates have validity periods (Not Before, Not After). Normally, a certificate past its Not After date should be rejected. This creates a problem for embedded devices:

1. A device manufactured in 2026 may still be running in 2040
2. The signing certificates may have expired
3. The device has no reliable clock (RTC may be unset or drifted)
4. There is no internet access to verify CRL/OCSP

**HABv4 handling**: The HABv4 ROM code does NOT validate certificate validity dates. It validates only the cryptographic chain (hash and signature). This is the correct behavior for embedded boot.

**FIT signing**: U-Boot's FIT verification also does not validate certificate expiry by default.

**Implication**: Plan certificate validity periods for the device's maximum deployment lifetime. If devices will operate for 20 years, issue 20-year certificates. Certificate expiry is a management problem, not a boot security failure.

---

## DER vs PEM Encoding

### DER: Distinguished Encoding Rules

DER is a binary encoding of ASN.1. It is compact and unambiguous. This is what the HABv4 ROM code and cryptographic hardware actually process.

```bash
# Generate DER-encoded certificate
$ openssl req -new -x509 -days 3650 -key private.pem -out cert.der -outform DER \
  -subj "/CN=Test CA/O=Example/C=DE"

# View DER structure
$ xxd cert.der | head -8
00000000: 3082 0387 3082 026f a003 0201 0230 0d06  0...0..o.....0..
00000010: 0960 8648 01865 0403 0201 0500 3040 310b  .`.H...0..0@1.
# 0x30 = SEQUENCE (certificate is a SEQUENCE of TBSCertificate, algorithm, signature)

# DER file size
$ wc -c cert.der
903   # 903 bytes for a typical 2048-bit RSA CA certificate

# Parse DER ASN.1 structure
$ openssl asn1parse -in cert.der -inform DER | head -20
    0:d=0  hl=4 l= 903 cons: SEQUENCE
    4:d=1  hl=4 l= 623 cons: SEQUENCE          ← TBSCertificate (to-be-signed)
    8:d=2  hl=2 l=   3 cons: cont [ 0 ]
   10:d=3  hl=2 l=   1 prim: INTEGER            ← Version = 2 (v3)
   13:d=2  hl=2 l=   1 prim: INTEGER            ← Serial number
   16:d=2  hl=2 l=  13 cons: SEQUENCE          ← Signature algorithm OID
   31:d=2  hl=2 l=  64 cons: SEQUENCE          ← Issuer
   97:d=2  hl=2 l=  30 cons: SEQUENCE          ← Validity (two GeneralizedTime)
  129:d=2  hl=2 l=  64 cons: SEQUENCE          ← Subject
  195:d=2  hl=2 l= 290 cons: SEQUENCE          ← SubjectPublicKeyInfo
  489:d=2  hl=2 l=  97 cons: cont [ 3 ]        ← Extensions
```

### PEM: Privacy Enhanced Mail

PEM is DER encoded as base64 with header/footer lines. It is ASCII-safe and human-readable in part. Most tools accept PEM format; NXP CST also accepts PEM and converts to DER internally.

```bash
# PEM certificate example structure:
-----BEGIN CERTIFICATE-----
MIICpTCCAY0CFDdXnMkf9hT5wFxcR9PXSHthAWuMMA0GCSqGSIb3DQEBCwUAMCEx
HzAdBgNVBAMMFlNlY3VyZSBCb290IFJvb3QgQ0EgdjEwHhcNMjYwMTAxMDAwMDAw
... (base64-encoded DER, 64 chars per line) ...
5D72C8A90E3B1F6D4A9E8C721D5B9F3Ef2ca1bb6c7e907d06dafe4687e579fce
-----END CERTIFICATE-----

# Convert PEM to DER
$ openssl x509 -in cert.pem -outform DER -out cert.der

# Convert DER to PEM
$ openssl x509 -in cert.der -inform DER -outform PEM -out cert.pem

# Inspect PEM certificate (human-readable)
$ openssl x509 -in cert.pem -text -noout

# Display certificate fingerprint (useful for verification)
$ openssl x509 -in cert.pem -fingerprint -sha256 -noout
SHA256 Fingerprint=A3:B7:2C:9E:1F:4D:6A:88:7E:5C:30:12:8B:94:EF:1A:...
```

---

## Creating the PKI Hierarchy for HABv4

The HABv4 PKI hierarchy requires a specific structure. The following creates it using OpenSSL (an alternative to the NXP CST `hab4_pki_tree.sh` script, useful for understanding the structure).

### Step 1: Root Certificate Authority

```bash
# Create directory structure
$ mkdir -p secure-boot-pki/{root-ca,srk,csf,img,fit-signing}
$ cd secure-boot-pki

# ─── Root CA ─────────────────────────────────────────────────────────────────

# Generate Root CA private key (RSA-4096, highest tier)
$ openssl genrsa -aes256 -out root-ca/root-ca-key.pem 4096
Enter pass phrase for root-ca/root-ca-key.pem: <strong-passphrase>
Verifying - Enter pass phrase for root-ca/root-ca-key.pem: <strong-passphrase>

# OpenSSL config for Root CA certificate
$ cat > root-ca/root-ca.cfg << 'EOF'
[ req ]
default_md      = sha256
distinguished_name = dn
x509_extensions = v3_root_ca
prompt          = no

[ dn ]
CN              = Secure Boot Root CA v1
O               = MyCompany Ltd
C               = DE
emailAddress    = secureboot@mycompany.com

[ v3_root_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical,CA:TRUE,pathlen:2
keyUsage               = critical,keyCertSign,cRLSign
EOF

# Self-sign the Root CA certificate (valid 20 years)
$ openssl req -new -x509 -days 7300 \
  -key root-ca/root-ca-key.pem \
  -config root-ca/root-ca.cfg \
  -out root-ca/root-ca-cert.pem

# Verify the Root CA certificate
$ openssl x509 -in root-ca/root-ca-cert.pem -text -noout | head -30
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            7f:83:b1:65:7f:f1:fc:53:b9:2d:c1:81:48:a1:d6:5d
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: CN = Secure Boot Root CA v1, O = MyCompany Ltd, C = DE
        Validity
            Not Before: Jan  1 00:00:00 2026 GMT
            Not After : Dec 29 00:00:00 2045 GMT
        Subject: CN = Secure Boot Root CA v1, O = MyCompany Ltd, C = DE
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (4096 bit)
                ...
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE, pathlen:2
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
```

### Step 2: SRK Certificates (4 slots)

```bash
# SRK extension configuration
$ cat > srk/srk-ext.cfg << 'EOF'
[ v3_srk ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical,CA:TRUE,pathlen:1
keyUsage               = critical,keyCertSign,cRLSign
EOF

# Create 4 SRK key pairs and certificates
$ for i in 1 2 3 4; do
    echo "=== Generating SRK${i} ==="

    # Generate SRK key (RSA-4096 for maximum security margin)
    openssl genrsa -out srk/srk${i}-key.pem 4096

    # Create CSR for SRK
    openssl req -new \
      -key srk/srk${i}-key.pem \
      -out srk/srk${i}.csr \
      -subj "/CN=SRK${i} v1/O=MyCompany Ltd/C=DE"

    # Sign SRK cert with Root CA (valid 10 years)
    openssl x509 -req \
      -days 3650 \
      -in srk/srk${i}.csr \
      -CA root-ca/root-ca-cert.pem \
      -CAkey root-ca/root-ca-key.pem \
      -CAcreateserial \
      -extfile srk/srk-ext.cfg \
      -extensions v3_srk \
      -out srk/srk${i}-cert.pem

    echo "SRK${i} certificate:"
    openssl x509 -in srk/srk${i}-cert.pem -subject -issuer -noout
done

# Verify SRK certificate chain
$ openssl verify -CAfile root-ca/root-ca-cert.pem srk/srk1-cert.pem
srk/srk1-cert.pem: OK
```

### Step 3: CSF and IMG Certificates (per SRK slot)

```bash
# CSF extension configuration
$ cat > csf/csf-ext.cfg << 'EOF'
[ v3_csf ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = codeSigning
EOF

$ cat > img/img-ext.cfg << 'EOF'
[ v3_img ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = codeSigning
EOF

# Create CSF and IMG keys (signed by SRK1)
$ openssl genrsa -out csf/csf1-key.pem 2048
$ openssl genrsa -out img/img1-key.pem 2048

# CSF certificate (signed by SRK1)
$ openssl req -new \
  -key csf/csf1-key.pem \
  -out csf/csf1.csr \
  -subj "/CN=CSF Signing Key 1/O=MyCompany Ltd/C=DE"

$ openssl x509 -req \
  -days 1825 \
  -in csf/csf1.csr \
  -CA srk/srk1-cert.pem \
  -CAkey srk/srk1-key.pem \
  -CAcreateserial \
  -extfile csf/csf-ext.cfg \
  -extensions v3_csf \
  -out csf/csf1-cert.pem

# IMG certificate (signed by SRK1)
$ openssl req -new \
  -key img/img1-key.pem \
  -out img/img1.csr \
  -subj "/CN=IMG Signing Key 1/O=MyCompany Ltd/C=DE"

$ openssl x509 -req \
  -days 1825 \
  -in img/img1.csr \
  -CA srk/srk1-cert.pem \
  -CAkey srk/srk1-key.pem \
  -CAcreateserial \
  -extfile img/img-ext.cfg \
  -extensions v3_img \
  -out img/img1-cert.pem

# Verify complete chain: Root → SRK1 → CSF/IMG
$ openssl verify \
  -CAfile root-ca/root-ca-cert.pem \
  -untrusted srk/srk1-cert.pem \
  csf/csf1-cert.pem
csf/csf1-cert.pem: OK

$ openssl verify \
  -CAfile root-ca/root-ca-cert.pem \
  -untrusted srk/srk1-cert.pem \
  img/img1-cert.pem
img/img1-cert.pem: OK
```

### Step 4: FIT Image Signing Key

```bash
# FIT signing key (separate from HABv4 chain — embedded in U-Boot DTB)
$ openssl genrsa -out fit-signing/fit-key.pem 2048

# Self-signed certificate for FIT signing key
# (embedded in U-Boot DTB, so chain validation is not required — the
#  certificate is only used to carry the public key in standard format)
$ openssl req -new -x509 -days 3650 \
  -key fit-signing/fit-key.pem \
  -out fit-signing/fit-cert.pem \
  -subj "/CN=FIT Signing Key Production/O=MyCompany Ltd/C=DE"

# Alternatively, sign with Root CA for a full chain (optional):
$ openssl req -new \
  -key fit-signing/fit-key.pem \
  -out fit-signing/fit.csr \
  -subj "/CN=FIT Signing Key Production/O=MyCompany Ltd/C=DE"

$ openssl x509 -req \
  -days 3650 \
  -in fit-signing/fit.csr \
  -CA root-ca/root-ca-cert.pem \
  -CAkey root-ca/root-ca-key.pem \
  -CAcreateserial \
  -out fit-signing/fit-cert-signed.pem
```

---

## PKI Hierarchy Diagram

```
SECURE BOOT PKI HIERARCHY - FULL VIEW
════════════════════════════════════════════════════════════════════════════════

  ┌─────────────────────────────────────────────────────────────────────────┐
  │                    Root Certificate Authority                           │
  │  CN: Secure Boot Root CA v1  •  RSA-4096  •  Valid: 20yr               │
  │  Role: Trust anchor. Self-signed. OFFLINE only. HSM-stored private key  │
  │  OTP: This certificate is NOT in fuses. Only the SRK HASH is in fuses. │
  └──────────────────────────────┬──────────────────────────────────────────┘
                                 │ signs
          ┌──────────────────────┼──────────────────────┐
          │                      │                      │ (up to 4 SRK slots)
          ▼                      ▼                      ▼
  ┌───────────────┐    ┌───────────────┐    ┌───────────────┐    ┌───────────────┐
  │     SRK1      │    │     SRK2      │    │     SRK3      │    │     SRK4      │
  │  RSA-4096     │    │  RSA-4096     │    │  RSA-4096     │    │  RSA-4096     │
  │  Valid: 10yr  │    │  Valid: 10yr  │    │  Valid: 10yr  │    │  Valid: 10yr  │
  │  [ACTIVE]     │    │  [BACKUP]     │    │  [BACKUP]     │    │  [BACKUP]     │
  └───────┬───────┘    └───────────────┘    └───────────────┘    └───────────────┘
          │                                                            
          │ signs both:                                               
          ┌─────────────────────────────┐                            
          │                             │                            
          ▼                             ▼                            
  ┌───────────────────┐      ┌────────────────────┐                 
  │   CSF Key 1       │      │    IMG Key 1        │                
  │  RSA-2048         │      │   RSA-2048          │                
  │  Valid: 5yr       │      │   Valid: 5yr        │                
  │  Signs: CSF block │      │   Signs: image hash │                
  │  (online, HSM)    │      │   (online, HSM)     │                
  └───────────────────┘      └────────────────────┘                 
                                        │                            
                              authenticates:                         
                                        ▼                            
  ┌────────────────────────────────────────────────────────────────┐
  │   Boot Image = SPL + TF-A BL2 + OP-TEE + U-Boot               │
  │   (flash.bin)                                                   │
  │   Content authenticated by HABv4 CSF block                     │
  └────────────────────────────────────────────────────────────────┘

  FUSE BINDING (binding SRK certificates to hardware):
  SHA-256(SRK1.modulus || SRK2.modulus || SRK3.modulus || SRK4.modulus)
    = SRK_HASH[0:31] → burned into OCOTP_SRK0 through OCOTP_SRK7

  SEPARATE HIERARCHY (FIT image signing — not connected to HABv4 PKI):
  ┌────────────────────────────────────────────────────────────────┐
  │   FIT Signing Key (RSA-2048 or ECC P-256)                      │
  │   Public key embedded in U-Boot DTB at build time               │
  │   Private key: build server HSM, separate from HABv4 keys       │
  │                                                                  │
  │   Authenticates: FIT Image = kernel + DTB + initramfs           │
  └────────────────────────────────────────────────────────────────┘
```

---

## SRK Table and SRK Hash Computation

The NXP HABv4 SRK table is not a certificate chain in the traditional sense. It is a binary file containing the concatenated public key information from all four SRK certificates. The ROM code extracts the public key moduli and exponents directly from this table.

```bash
# Generate the SRK table and fuse hash (NXP CST tool)
$ /opt/cst/bin/srktool \
  --hab_ver 4 \
  --certs srk/srk1-cert.pem,srk/srk2-cert.pem,srk/srk3-cert.pem,srk/srk4-cert.pem \
  --out srk/SRK_table.bin \
  --hash srk/SRK_hash.bin \
  --efuses srk/SRK_fuse.bin

# View the SRK hash (32 bytes = what goes into fuses)
$ xxd srk/SRK_hash.bin
00000000: a3b7 2c9e 1f4d 6a88 7e5c 3012 8b94 ef1a  ..,..Mj.^.0.....
00000010: 5d72 c8a9 0e3b 1f6d 4a9e 8c72 1d5b 9f3e  ]r...;.mJ..r.[.>

# View the fuse programming file (split into 8 × 4-byte words for OCOTP registers)
$ xxd srk/SRK_fuse.bin
00000000: a3b7 2c9e  ← OCOTP_SRK0 fuse word (bytes 0-3 of hash, big-endian)
00000004: 1f4d 6a88  ← OCOTP_SRK1
00000008: 7e5c 3012  ← OCOTP_SRK2
0000000c: 8b94 ef1a  ← OCOTP_SRK3
00000010: 5d72 c8a9  ← OCOTP_SRK4
00000014: 0e3b 1f6d  ← OCOTP_SRK5
00000018: 4a9e 8c72  ← OCOTP_SRK6
0000001c: 1d5b 9f3e  ← OCOTP_SRK7

# Manually compute SRK hash without CST tool (for verification):
# 1. Extract RSA moduli from SRK certificates
$ for i in 1 2 3 4; do
    openssl x509 -in srk/srk${i}-cert.pem -pubkey -noout | \
      openssl rsa -pubin -outform DER | \
      dd bs=1 skip=24 count=512 2>/dev/null  # Skip DER header, extract 512-byte modulus
  done > /tmp/srk-moduli-concat.bin

# 2. Hash the concatenated moduli
$ openssl dgst -sha256 -binary /tmp/srk-moduli-concat.bin > /tmp/srk-hash-manual.bin
$ xxd /tmp/srk-hash-manual.bin
# Should match SRK_hash.bin above

# CRITICAL VERIFICATION: always compare the two computations before burning fuses
$ cmp srk/SRK_hash.bin /tmp/srk-hash-manual.bin && echo "MATCH: Safe to burn" || echo "MISMATCH: DO NOT BURN"
```

---

## Certificate Chain Validation

### Manual Certificate Chain Verification

```bash
# Verify the complete HABv4 certificate chain
$ openssl verify \
  -CAfile root-ca/root-ca-cert.pem \
  -untrusted srk/srk1-cert.pem \
  -untrusted csf/csf1-cert.pem \
  img/img1-cert.pem
img/img1-cert.pem: OK

# Check certificate validity period
$ openssl x509 -in srk/srk1-cert.pem -dates -noout
notBefore=Jan  1 00:00:00 2026 GMT
notAfter=Dec 31 23:59:59 2035 GMT

# Check who issued a certificate
$ openssl x509 -in csf/csf1-cert.pem -issuer -noout
issuer=CN = SRK1 v1, O = MyCompany Ltd, C = DE

# Check subject
$ openssl x509 -in csf/csf1-cert.pem -subject -noout
subject=CN = CSF Signing Key 1, O = MyCompany Ltd, C = DE

# Verify key matches certificate
$ openssl x509 -in csf/csf1-cert.pem -noout -pubkey > /tmp/cert-pubkey.pem
$ openssl rsa -in csf/csf1-key.pem -pubout > /tmp/key-pubkey.pem
$ diff /tmp/cert-pubkey.pem /tmp/key-pubkey.pem
# No output = keys match (signing this certificate used the correct private key)

# Cross-check fingerprints:
$ openssl x509 -in csf/csf1-cert.pem -fingerprint -sha256 -noout
SHA256 Fingerprint=A3:B7:2C:9E:1F:4D:6A:88:7E:5C:30:12:8B:94:EF:1A:5D:72:C8:A9:0E:3B:1F:6D:4A:9E:8C:72:1D:5B:9F:3E
```

---

## Creating Certificate Signing Requests (CSRs)

CSRs are used when a subordinate entity requests a certificate from a CA. In the HABv4 context, CSRs represent the request from SRK key holders for signed SRK certificates.

```bash
# Create a CSR with specific SANs (Subject Alternative Names)
$ openssl req -new \
  -key srk/srk1-key.pem \
  -out srk/srk1.csr \
  -subj "/CN=SRK1 v1/O=MyCompany Ltd/C=DE/OU=Secure Boot"

# Inspect CSR
$ openssl req -in srk/srk1.csr -text -noout
Certificate Request:
    Data:
        Version: 1 (0x0)
        Subject: CN = SRK1 v1, O = MyCompany Ltd, C = DE, OU = Secure Boot
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (4096 bit)
        Attributes:
            (none)
    Signature Algorithm: sha256WithRSAEncryption
    Signature Value: ...

# Verify CSR signature (proves requester has the private key)
$ openssl req -in srk/srk1.csr -verify -noout
Certificate request self-signature verify OK
```

---

## PKI for FIT Image Signing

FIT image signing uses a separate PKI from HABv4. The trust anchor is the public key embedded in the U-Boot binary (in the U-Boot DTB). There is no OTP fuse involvement.

```bash
# Create FIT signing key and certificate
$ openssl genrsa -out fit-signing/production-fit-key.pem 4096

$ openssl req -new -x509 -days 3650 \
  -key fit-signing/production-fit-key.pem \
  -out fit-signing/production-fit-cert.pem \
  -subj "/CN=Production FIT Signing/O=MyCompany Ltd/C=DE" \
  -extensions v3_req \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

# Prepare key directory for mkimage
$ mkdir -p fit-keys/
$ cp fit-signing/production-fit-key.pem fit-keys/production.key
$ cp fit-signing/production-fit-cert.pem fit-keys/production.crt

# Sign FIT image and embed public key in U-Boot DTB
$ mkimage -f kernel.its \
  -k fit-keys/ \
  -K u-boot-initial.dtb \
  -r \
  fitImage

# Verify public key is embedded in U-Boot DTB:
$ fdtget u-boot-initial.dtb /signature/production algo
sha256,rsa4096

$ fdtget u-boot-initial.dtb /signature/production key-name-hint
production

# The modified u-boot.dtb must be used in the U-Boot build that will
# verify FIT images. Rebuild U-Boot with the key-embedded DTB:
# $ cp u-boot-initial.dtb arch/arm/dts/imx8mp-phyboard-pollux.dtb
# $ make -j8

# Verify FIT signature with fit_check_sign utility
$ fit_check_sign -f fitImage -k u-boot-with-key.dtb
Signature check OK
```

---

## Certificate Inspection Reference

```bash
# Complete certificate inspection commands reference

# Basic text output
$ openssl x509 -in cert.pem -text -noout

# Specific field extraction
$ openssl x509 -in cert.pem -subject -noout
$ openssl x509 -in cert.pem -issuer -noout
$ openssl x509 -in cert.pem -serial -noout
$ openssl x509 -in cert.pem -dates -noout
$ openssl x509 -in cert.pem -fingerprint -sha256 -noout
$ openssl x509 -in cert.pem -pubkey -noout  # Extract public key

# Check if certificate is CA
$ openssl x509 -in cert.pem -text -noout | grep "CA:"
                CA:TRUE   ← is a CA
                CA:FALSE  ← is a leaf certificate

# Check key usage
$ openssl x509 -in cert.pem -text -noout | grep -A2 "Key Usage"
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign

# Check Extended Key Usage
$ openssl x509 -in cert.pem -text -noout | grep -A2 "Extended Key Usage"
            X509v3 Extended Key Usage:
                Code Signing

# Get public key size
$ openssl x509 -in cert.pem -text -noout | grep "Public-Key"
                Public-Key: (4096 bit)

# Get certificate in DER and measure size
$ openssl x509 -in cert.pem -outform DER | wc -c
912   # bytes

# Verify certificate signature (checks if CA signed it correctly)
$ openssl verify -CAfile root-ca-cert.pem cert.pem
cert.pem: OK

# Check if private key matches certificate
$ openssl x509 -in cert.pem -noout -modulus | md5sum
$ openssl rsa -in private.pem -noout -modulus | md5sum
# If both md5 hashes match → key and cert are a matching pair
```

---

## HABv4 Certificate Format Requirements

NXP HABv4 has specific requirements for the SRK certificate format:

| Requirement | Specification |
|-------------|---------------|
| Certificate version | X.509 v3 |
| Signature algorithm | sha256WithRSAEncryption |
| Public key algorithm | RSA |
| Minimum key size | 2048 bits |
| Certificate encoding | DER (binary) |
| SRK Basic Constraints | CA:TRUE |
| SRK Key Usage | keyCertSign |
| Serial number | Positive integer |
| Validity | Start before current date (HABv4 does not validate expiry) |

The NXP CST `hab4_pki_tree.sh` script creates certificates that meet these requirements automatically. When creating certificates manually (as in this chapter), verify compliance before attempting HABv4 signing.

---

## Security Warning

> **WARNING:** Root CA and SRK private keys are the highest-value cryptographic material in the secure boot system. Their compromise affects every device manufactured with the corresponding SRK_HASH fuses. These keys MUST be stored in a Hardware Security Module (HSM). If HSM storage is not available, minimum acceptable practice is:
> - AES-256-encrypted key files on encrypted storage
> - Passphrase stored separately from the key file (separate physical location)
> - Air-gapped workstation for all signing operations
> - Physical access logging for the workstation
>
> **WARNING:** Burning SRK_HASH fuses based on incorrect certificates is permanent. The device will be permanently bricked. Verify the SRK hash three times with three independent methods before burning.

---

## Further Reading

- RFC 5280: Internet X.509 Public Key Infrastructure Certificate and CRL Profile
  https://www.rfc-editor.org/rfc/rfc5280
- RFC 2986: PKCS #10: Certification Request Syntax Specification
  https://www.rfc-editor.org/rfc/rfc2986
- NXP AN12 HABv4 Code Signing Tool User's Guide (iMX_CST_UG.pdf)
- NXP Application Note AN4581: Secure Boot on i.MX Using HABv4
  https://www.nxp.com/docs/en/application-note/AN4581.pdf
- "Understanding Certification Path Building" — NIST Special Publication
  https://csrc.nist.gov/CSRC/media/Publications/white-paper/2000/12/18/understanding-certification-path-building/final/documents/certpathbuildingwhitepaper.pdf
- OpenSSL Certificate Authority: https://jamielinux.com/docs/openssl-certificate-authority/
