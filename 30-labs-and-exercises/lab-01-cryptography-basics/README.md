# Lab 01: Cryptography Basics

## Learning Objectives

After completing this lab, you can:
1. Generate RSA-2048 and ECC P-256 key pairs
2. Sign data and verify signatures with OpenSSL
3. Create self-signed X.509 certificates
4. Compute and verify SHA-256 hashes
5. Explain why RSA-2048 is used for secure boot (not AES)

## Prerequisites

- Linux machine (Ubuntu 22.04 recommended)
- `openssl` version 3.0+: `openssl version`

---

## Part 1: Hash Functions (15 min)

### Exercise 1.1: Compute SHA-256 Hash

```bash
# Create a test file
echo "Hello, Secure Boot!" > message.txt

# Compute SHA-256
openssl dgst -sha256 message.txt
# SHA2-256(message.txt)= <32-byte-hex>

# Record the hash: ___________________________

# Change one character and observe the avalanche effect:
echo "Hello, Secure Boot?" > message2.txt
openssl dgst -sha256 message2.txt
# The hashes should be completely different
```

**Question**: If you change a single bit in a 1MB file, how much of the SHA-256 hash changes on average? Why does this matter for secure boot?

### Exercise 1.2: Verify Hash as Integrity Check

```bash
# Simulate a download with hash verification:
cp message.txt download.txt
EXPECTED=$(openssl dgst -sha256 -r message.txt | cut -d' ' -f1)
ACTUAL=$(openssl dgst -sha256 -r download.txt | cut -d' ' -f1)

if [ "$EXPECTED" = "$ACTUAL" ]; then
    echo "Integrity verified"
else
    echo "INTEGRITY FAILURE"
fi

# Now simulate tampering:
echo "injected" >> download.txt
ACTUAL=$(openssl dgst -sha256 -r download.txt | cut -d' ' -f1)
[ "$EXPECTED" = "$ACTUAL" ] && echo "Pass" || echo "TAMPER DETECTED"
```

---

## Part 2: Asymmetric Keys (20 min)

### Exercise 2.1: Generate RSA Key Pair

```bash
mkdir -p lab01-keys

# Generate RSA-2048 private key
openssl genrsa -out lab01-keys/private.pem 2048

# Extract public key
openssl rsa -in lab01-keys/private.pem -pubout -out lab01-keys/public.pem

# View key components
openssl rsa -in lab01-keys/private.pem -text -noout | head -30

# Key sizes:
ls -la lab01-keys/
# private.pem: ~1679 bytes
# public.pem:  ~451 bytes
```

### Exercise 2.2: Sign and Verify

```bash
# Sign the message with private key:
openssl dgst -sha256 -sign lab01-keys/private.pem \
    -out message.sig message.txt

echo "Signature size: $(wc -c < message.sig) bytes"
# Expected: 256 bytes (RSA-2048 signature = modulus size)

# Verify with public key:
openssl dgst -sha256 -verify lab01-keys/public.pem \
    -signature message.sig message.txt
# Verified OK

# Tamper with message and try to verify:
echo "tampered" >> message.txt
openssl dgst -sha256 -verify lab01-keys/public.pem \
    -signature message.sig message.txt
# Verification Failure
```

### Exercise 2.3: Why Asymmetric?

```bash
# If Bob had a symmetric key, anyone who has the key can:
# - Verify signatures (same as asymmetric — OK)
# - CREATE signatures (problem! anyone can forge)

# With asymmetric (RSA):
# - Only private key holder can SIGN
# - Anyone with public key can VERIFY but not forge

# This is why HABv4 uses RSA:
# NXP (ROM) verifies using public key embedded in silicon
# You sign with private key (stored in HSM, never exposed)
```

---

## Part 3: X.509 Certificates (15 min)

### Exercise 3.1: Create Self-Signed Certificate

```bash
# Create a certificate for a signing key:
openssl req -new -x509 \
    -key lab01-keys/private.pem \
    -out lab01-keys/cert.pem \
    -days 365 \
    -subj "/CN=Lab01-Signing-Key/O=Lab Corp/C=DE"

# Inspect the certificate:
openssl x509 -in lab01-keys/cert.pem -text -noout | \
    grep -E "Subject:|Not After|Public Key"
```

### Exercise 3.2: Verify Certificate Chain

```bash
# Create a CA:
openssl genrsa -out lab01-keys/ca-key.pem 4096
openssl req -new -x509 -key lab01-keys/ca-key.pem \
    -out lab01-keys/ca-cert.pem -days 3650 \
    -subj "/CN=Lab CA/O=Lab Corp/C=DE"

# Create a CSR (Certificate Signing Request):
openssl genrsa -out lab01-keys/leaf-key.pem 2048
openssl req -new -key lab01-keys/leaf-key.pem \
    -out lab01-keys/leaf.csr \
    -subj "/CN=Leaf Key/O=Lab Corp/C=DE"

# Sign CSR with CA:
openssl x509 -req \
    -in lab01-keys/leaf.csr \
    -CA lab01-keys/ca-cert.pem \
    -CAkey lab01-keys/ca-key.pem \
    -CAcreateserial \
    -out lab01-keys/leaf-cert.pem \
    -days 365

# Verify chain:
openssl verify -CAfile lab01-keys/ca-cert.pem lab01-keys/leaf-cert.pem
# lab01-keys/leaf-cert.pem: OK

# This mirrors the HABv4 hierarchy:
# ProductionCA → SRK → CSF → IMG
```

---

## Part 4: Reflection Questions

Answer these before moving to Lab 02:

1. What is the relationship between hash size (32 bytes for SHA-256) and the security it provides?

2. Why does HABv4 store a hash of the SRK table in fuses, not the SRK public key itself?
   (Hint: how big is an RSA-2048 public key?)

3. If an attacker intercepts a signed firmware image and modifies it, what will happen when the device tries to boot? Walk through the exact verification steps.

4. Why is it important that the CA private key is kept more secure than the SRK signing key?

---

## Cleanup

```bash
rm -rf lab01-keys message*.txt message.sig
```

## Next Lab

→ [lab-02-fit-image-signing](../lab-02-fit-image-signing/README.md)
