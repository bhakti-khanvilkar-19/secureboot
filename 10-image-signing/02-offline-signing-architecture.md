# Offline Signing Architecture

## Why Offline Signing

The private signing key is the single most valuable asset in a secure boot deployment. If it is compromised, an attacker can sign malicious firmware that will boot on all devices using that key.

**Threat: Build server compromise**
If the signing key lives on a CI/CD build server, a compromised server = compromised key = all devices compromised.

**Solution: Air-gapped signing station**
The private key never exists on a networked system. Only hashes/signatures transit the air gap.

---

## Architecture: Signing Proxy Pattern

```
CI/CD Build Server (networked)          Air-gapped Signing Station
──────────────────────────────          ──────────────────────────
1. Yocto build: unsigned artifacts
2. Compute SHA-256 of artifacts
3. Write hashes to USB drive ──────►
                                        4. Verify artifact hashes
                                        5. HSM signs: sign(hash, private_key)
                               ◄────── 6. Return signatures on USB drive
7. Embed signatures into artifacts
8. Upload signed artifacts to store
```

---

## Air-Gapped Station Hardware

| Component | Recommendation | Notes |
|-----------|---------------|-------|
| Computer | Dedicated PC, no WiFi/Bluetooth | Remove radio hardware physically |
| OS | Ubuntu Server 22.04 LTS (hardened) | Minimal install, no GUI |
| HSM | YubiHSM2 (budget) or Thales Luna PCIe (enterprise) | |
| Storage | Encrypted USB for key transport | Veracrypt container |
| Display | Required for operator | No remote access |
| Network | **NONE** | Physically disconnected |
| USB | 2× ports: one for HSM, one for data | Data USB is write-protected |

---

## HSM Options

### YubiHSM2 (Budget, ~$650)
```
Capabilities: RSA-2048/4096, ECC P-256/P-384, AES, HMAC, PKCS#11
Storage: 128 key slots
Interface: USB HID
FIPS: No (but PKCS#11 compatible)
Use case: Small-scale, development, startup
```

### Thales Luna Network HSM (Enterprise, $20k+)
```
Capabilities: RSA, ECC, AES, full crypto suite
Storage: Thousands of keys
Interface: Network (but airgapped network)
FIPS: 140-3 Level 3
Use case: High-volume manufacturing, compliance
```

### AWS CloudHSM (Cloud)
```
Note: NOT suitable for air-gapped use
Use: If signing service is in AWS and airgap is not required
FIPS: 140-2 Level 3
```

---

## PKCS#11 Interface for Signing

PKCS#11 (Cryptoki) is the standard interface for HSM operations:

```python
#!/usr/bin/env python3
# hsm_sign_rsa.py - Sign data using PKCS#11 HSM
import pkcs11
from pkcs11 import Mechanism, KeyType
import hashlib

# Initialize PKCS#11 library (YubiHSM2 example)
lib = pkcs11.lib('/usr/lib/x86_64-linux-gnu/pkcs11/yubihsm_pkcs11.so')

# Open session
token = lib.get_token(token_label='YubiHSM')
session = token.open(user_pin='0001password')  # YubiHSM default

# Find RSA private key
privkey = next(session.get_objects({
    pkcs11.Attribute.CLASS: pkcs11.ObjectClass.PRIVATE_KEY,
    pkcs11.Attribute.LABEL: 'fit-production-key',
}))

# Data to sign (pre-hashed)
data = open('fitImage', 'rb').read()
data_hash = hashlib.sha256(data).digest()

# Sign with RSA-PKCS (PKCS#1 v1.5)
signature = privkey.sign(
    data_hash,
    mechanism=Mechanism.SHA256_RSA_PKCS
)

with open('fitImage.sig', 'wb') as f:
    f.write(signature)

print(f"Signature: {len(signature)} bytes")
session.close()
```

---

## Key Ceremony Protocol

A key ceremony is a formal, witnessed procedure for generating and activating production signing keys.

### Ceremony Requirements
- Minimum 2 authorized personnel present
- Ceremony recorded (video or written log)
- All participants must sign ceremony log
- HSM initialized and tested beforehand
- Air-gapped environment verified (no network)

### Ceremony Steps

```
1. PRE-CEREMONY (1 day before)
   ├─ Verify air-gapped station is operational
   ├─ Verify HSM is initialized and accessible
   ├─ Prepare ceremony log document
   └─ Invite authorized witnesses

2. CEREMONY DAY
   ├─ All participants sign attendance log
   ├─ Verify station is offline (physically and logically)
   ├─ Generate keys on HSM:
   │     pkcs11-tool --module <hsm.so> --generate-key --key-type rsa:2048
   │                 --label "fit-production-key-2024"
   ├─ Verify key generated in HSM (cannot be exported)
   ├─ Generate certificate (CSR + sign offline)
   ├─ Create HSM backup:
   │     Split backup across 3 operators (M-of-N scheme)
   │     Each operator stores their share in separate secure location
   ├─ Document: key ID, certificate fingerprint, backup shares
   └─ All participants sign ceremony completion log

3. POST-CEREMONY
   ├─ Distribute HSM backup shares to designated custodians
   ├─ Upload certificate (public part) to key management system
   ├─ Test signing with test artifact
   └─ Archive ceremony documentation
```

---

## Key Rotation Procedure

### For FIT Signing Keys (can rotate without fuse changes)

```bash
# 1. Generate new key pair (on air-gapped station)
openssl genrsa -out fit-signing-key-2025.pem 2048
openssl req -new -x509 -key fit-signing-key-2025.pem \
            -out fit-signing-key-2025.crt -days 3650

# 2. Update Yocto build to use new key
# In local.conf:
# UBOOT_SIGN_KEYNAME = "fit-signing-key-2025"

# 3. Rebuild U-Boot (with new key embedded in DTB)
# 4. Rebuild FIT images (signed with new key)
# 5. Deploy via OTA update

# Old key: can still verify old firmware images in field
# New key: all new firmware uses new key
```

### For HABv4 SRK Keys (CANNOT rotate after fuse burn)

SRK keys are burned permanently into device fuses. Once burned:
- Cannot change which key is active without fuse changes
- CAN revoke individual SRK slots (SRK_REVOKE fuse)
- If all 4 SRK keys are compromised: devices are permanently insecure

This is why having 4 SRK keys (backup slots) matters.
