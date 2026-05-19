# Key Generation Procedures

## Environment Requirements

```
System:   Air-gapped workstation (NO network connection)
OS:       Ubuntu Server 22.04 LTS (minimal install)
HSM:      YubiHSM2 or Thales Luna (preferred)
Tools:    NXP CST, OpenSSL 3.0+
Entropy:  Minimum 2000 bits (verify before starting)
Witnesses: Minimum 2 authorized personnel
```

Verify environment before starting:
```bash
# Check network (must be offline)
ip link show | grep "state UP"
# Expected: no output (all interfaces DOWN)

# Check entropy
cat /proc/sys/kernel/random/entropy_avail
# Expected: > 2000

# Check CST installation
/opt/cst/linux64/bin/cst --help
/opt/cst/linux64/bin/srktool --help

# Check OpenSSL
openssl version
# Expected: OpenSSL 3.0.x
```

---

## Part 1: HABv4 Key Generation

### Using NXP CST hab4_pki_tree.sh

```bash
export CST=/opt/cst
cd ${CST}/keys

# Interactive key generation
./hab4_pki_tree.sh

# Prompt responses (example):
# Do you want to use an existing CA key (y/n)? n
# Enter CA key name: ProductionCA-2024
# Enter key length (1024, 2048, 3072, 4096): 2048
# Enter certificate duration (days): 3650
# How many Super Root Keys (2, 3, 4): 4
# Do you want the SRK certificates to have the CA flag set (y/n)?: n

# Duration: varies (a few minutes for 2048-bit RSA × 8 keys)
```

### Expected Output Structure

```
${CST}/
├── keys/
│   ├── ProductionCA-2024_sha256_2048_65537_v3_ca_key.pem   ← CA private key
│   ├── SRK1_sha256_2048_65537_v3_usr_key.pem               ← SRK1 private key
│   ├── SRK2_sha256_2048_65537_v3_usr_key.pem               ← SRK2 private key
│   ├── SRK3_sha256_2048_65537_v3_usr_key.pem               ← SRK3 private key
│   ├── SRK4_sha256_2048_65537_v3_usr_key.pem               ← SRK4 private key
│   ├── CSF1_1_sha256_2048_65537_v3_usr_key.pem             ← CSF key private
│   └── IMG1_1_sha256_2048_65537_v3_usr_key.pem             ← IMG key private
└── crts/
    ├── ProductionCA-2024_sha256_2048_65537_v3_ca_crt.pem   ← CA certificate
    ├── SRK1_sha256_2048_65537_v3_usr_crt.pem               ← SRK1 certificate
    ├── SRK2_sha256_2048_65537_v3_usr_crt.pem               ← SRK2 certificate
    ├── SRK3_sha256_2048_65537_v3_usr_crt.pem               ← SRK3 certificate
    ├── SRK4_sha256_2048_65537_v3_usr_crt.pem               ← SRK4 certificate
    ├── CSF1_1_sha256_2048_65537_v3_usr_crt.pem             ← CSF certificate
    └── IMG1_1_sha256_2048_65537_v3_usr_crt.pem             ← IMG certificate
```

### Generate SRK Table and Fuse Values

```bash
${CST}/linux64/bin/srktool \
    --hab_ver 4 \
    --certs \
        ${CST}/crts/SRK1_sha256_2048_65537_v3_usr_crt.pem \
        ${CST}/crts/SRK2_sha256_2048_65537_v3_usr_crt.pem \
        ${CST}/crts/SRK3_sha256_2048_65537_v3_usr_crt.pem \
        ${CST}/crts/SRK4_sha256_2048_65537_v3_usr_crt.pem \
    --table SRK_1_2_3_4_table.bin \
    --efuse_entries SRK_1_2_3_4_fuse.bin \
    --format bin

# SRK_1_2_3_4_table.bin: 4 SRK public keys bundled (used by CSF)
# SRK_1_2_3_4_fuse.bin:  32 bytes = SHA-256 hash of above (burn in fuses)
```

### Display Expected Fuse Values

```bash
python3 << 'EOF'
data = open('SRK_1_2_3_4_fuse.bin', 'rb').read()
assert len(data) == 32, f"Unexpected size: {len(data)} (expected 32)"
print("=== SRK FUSE VALUES ===")
print("Program these into OCOTP Bank 3, Words 0-7:")
print()
for i in range(8):
    val = int.from_bytes(data[i*4:(i+1)*4], 'little')
    print(f"  fuse prog -y 3 {i} 0x{val:08X}")
print()
print("Verify these values independently before burning!")
EOF
```

---

## Part 2: FIT Image Signing Key Generation

The FIT signing key is completely separate from the HABv4 SRK keys.

```bash
mkdir -p fit-keys
KEY_NAME="fit-production-key-2024"

# Generate RSA-2048 private key
openssl genrsa -out "fit-keys/${KEY_NAME}.pem" 2048

# Generate self-signed certificate
openssl req -new -x509 \
    -key "fit-keys/${KEY_NAME}.pem" \
    -out "fit-keys/${KEY_NAME}.crt" \
    -days 3650 \
    -subj "/CN=${KEY_NAME}/O=Your Company/C=DE" \
    -extensions v3_usr

# Verify
echo "Key fingerprint:"
openssl x509 -in "fit-keys/${KEY_NAME}.crt" -fingerprint -sha256 -noout

echo "Key modulus MD5 (for verification):"
openssl rsa -in "fit-keys/${KEY_NAME}.pem" -modulus -noout | openssl md5
```

---

## Part 3: Key Backup

```bash
# Create encrypted archive of all private keys
# CRITICAL: Store backup in separate physical location from HSM

tar -czf private-keys-backup.tar.gz \
    ${CST}/keys/*.pem \
    fit-keys/*.pem

# Encrypt with strong passphrase (split passphrase using M-of-N)
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
    -in private-keys-backup.tar.gz \
    -out private-keys-backup.tar.gz.enc

# Verify backup is readable
openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
    -in private-keys-backup.tar.gz.enc | tar -tzf - | head

# DELETE plaintext backup
shred -vuz private-keys-backup.tar.gz

echo "Backup complete. Store encrypted backup and passphrase in separate secure locations."
```

---

## Key Verification

After generation, verify the certificate chain:

```bash
# Verify SRK cert signed by CA
openssl verify \
    -CAfile ${CST}/crts/ProductionCA-2024_sha256_2048_65537_v3_ca_crt.pem \
    ${CST}/crts/SRK1_sha256_2048_65537_v3_usr_crt.pem
# Output: SRK1_sha256_2048_65537_v3_usr_crt.pem: OK

# Verify CSF cert signed by CA  
openssl verify \
    -CAfile ${CST}/crts/ProductionCA-2024_sha256_2048_65537_v3_ca_crt.pem \
    ${CST}/crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem
# Output: ...OK

# Verify key pair matches (modulus should be identical)
openssl rsa -in ${CST}/keys/SRK1_sha256_2048_65537_v3_usr_key.pem \
            -modulus -noout | openssl md5
openssl x509 -in ${CST}/crts/SRK1_sha256_2048_65537_v3_usr_crt.pem \
             -modulus -noout | openssl md5
# Both MD5 values must be IDENTICAL
```
