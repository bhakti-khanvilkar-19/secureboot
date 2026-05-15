# 17-01: Provisioning Architecture

## Overview

This document describes the reference architecture for secure device provisioning. The design assumes manufacturing in a contract factory environment with hardware security module (HSM)-backed key operations, an air-gapped provisioning station, and a centralized provisioning database with an immutable audit log.

The architecture scales from a single-device development provisioning bench to a factory line provisioning 1,000+ devices per day.

---

## Factory Provisioning Architecture

```
╔═══════════════════════════════════════════════════════════════════════════╗
║                        FACTORY SECURITY PERIMETER                        ║
║                                                                           ║
║  ┌─────────────────────────────────────────────────────────────────────┐  ║
║  │                   PROVISIONING STATION (Air-Gapped)                 │  ║
║  │                                                                     │  ║
║  │  ┌─────────────┐   ┌──────────────┐   ┌────────────────────────┐   │  ║
║  │  │  Provisioning│   │  HSM Module  │   │   Provisioning Agent   │   │  ║
║  │  │  Controller  │   │  (Luna/AWS)  │   │   (Python/Go service)  │   │  ║
║  │  │              │◄──┤  - SRK keys  │   │                        │   │  ║
║  │  │  - Workflows │   │  - Device CA │   │  - USB/UART comms      │   │  ║
║  │  │  - State mgmt│   │  - Audit key │   │  - Protocol handling   │   │  ║
║  │  │  - Error hdlg│   │              │   │  - Fuse value cache    │   │  ║
║  │  └──────┬───────┘   └──────────────┘   └─────────┬──────────────┘   │  ║
║  │         │                                         │                  │  ║
║  │         └────────────────────┬────────────────────┘                  │  ║
║  │                              │                                       │  ║
║  │                    ┌─────────▼──────────┐                            │  ║
║  │                    │   USB/UART/JTAG     │                            │  ║
║  │                    │   Physical Port     │                            │  ║
║  │                    └─────────┬──────────┘                            │  ║
║  └──────────────────────────────┼────────────────────────────────────────┘  ║
║                                 │ Physical Connection                    ║
║  ┌──────────────────────────────▼────────────────────────────────────────┐  ║
║  │                    DEVICE UNDER PROVISIONING                          │  ║
║  │                                                                       │  ║
║  │  ┌─────────────────────┐  ┌────────────────────────────────────────┐  │  ║
║  │  │   Provisioning      │  │          i.MX8MP SoC                   │  │  ║
║  │  │   Image (Linux)     │  │  ┌─────────┐  ┌──────┐  ┌──────────┐  │  │  ║
║  │  │                     │  │  │  CAAM   │  │ OCOTP│  │  eMMC    │  │  │  ║
║  │  │  - prov_agent.sh    │  │  │  (RNG,  │  │ Fuses│  │  (RPMB)  │  │  │  ║
║  │  │  - fuse tools       │  │  │  Crypto)│  │      │  │          │  │  │  ║
║  │  │  - mmc tools        │  │  └─────────┘  └──────┘  └──────────┘  │  │  ║
║  │  │  - openssl          │  └────────────────────────────────────────┘  │  ║
║  │  └─────────────────────┘                                              │  ║
║  └───────────────────────────────────────────────────────────────────────┘  ║
║                                 │ Isolated Management Network             ║
║  ┌──────────────────────────────▼────────────────────────────────────────┐  ║
║  │                    PROVISIONING INFRASTRUCTURE                        │  ║
║  │                                                                       │  ║
║  │  ┌───────────────┐  ┌────────────────┐  ┌────────────────────────┐   │  ║
║  │  │ Provisioning  │  │  Audit Log     │  │  Device CA (HSM)       │   │  ║
║  │  │ Database      │  │  Server        │  │                        │   │  ║
║  │  │               │  │  (append-only) │  │  Root CA (offline)     │   │  ║
║  │  │  - Device recs│  │                │  │     └── Device CA      │   │  ║
║  │  │  - Batch data │  │  - SIEM feed   │  │           └── Certs    │   │  ║
║  │  │  - Cert index │  │  - Compliance  │  │                        │   │  ║
║  │  └───────────────┘  └────────────────┘  └────────────────────────┘   │  ║
║  └───────────────────────────────────────────────────────────────────────┘  ║
╚═══════════════════════════════════════════════════════════════════════════╝
```

---

## Architecture Components

### Provisioning Station

The provisioning station is the physical workstation that interfaces directly with the device under provisioning. It runs the provisioning controller software and connects to the device via USB (for `uuu`/SDP protocol) or UART (for U-Boot console access).

**Hardware requirements:**
- Dedicated workstation, not shared with other tasks
- HSM attached (USB HSM or PCIe HSM in the case of high-volume lines)
- No general internet connectivity — only internal provisioning network access
- USB Type-C or Micro-USB port for device connection
- Barcode scanner for physical label reading
- Serial number input (keyboard or scanner)

**Software components:**
- Provisioning controller: orchestrates the workflow, handles state machine, reports to database
- NXP `uuu` tool: for USB serial download protocol (SDP) firmware loading
- U-Boot console access: for interactive fuse programming (lower-volume lines)
- OpenSSL: for local certificate operations
- HSM PKCS#11 library: for signing operations via HSM

**Air-gap rationale:**
The provisioning station must not be reachable from outside the factory network. If an attacker can reach the provisioning station via the network, they can:
- Intercept SRK fuse values in transit
- Inject bogus provisioning data
- Replay provisioning sessions to re-provision devices with attacker-controlled keys
- Exfiltrate the provisioning database

The provisioning station communicates with the provisioning database server over an isolated VLAN with strict firewall rules. No internet access. No external USB allowed (lock USB ports against external media).

### HSM for Key Operations

All cryptographic key operations are performed inside a Hardware Security Module:

**Operations performed in HSM:**
- Signing device certificates (Device CA private key never leaves HSM)
- Signing SRK fuse value integrity records (audit signing key never leaves HSM)
- Generating device-unique key material (HSM DRNG for server-side key generation)

**HSM options:**
| HSM | Form Factor | Throughput | Protocol |
|-----|-------------|------------|----------|
| Thales Luna Network HSM 7 | Network appliance | 20,000 RSA ops/sec | PKCS#11 |
| Utimaco SecurityServer | Network appliance | 3,000 RSA ops/sec | PKCS#11 |
| AWS CloudHSM | Cloud-based | Scalable | PKCS#11 |
| NXP SE050 | I2C secure element | Low | GlobalPlatform |
| SoftHSM2 | Software (DEV ONLY) | High | PKCS#11 |

**PKCS#11 interface:**
The provisioning controller uses PKCS#11 to remain HSM-vendor-neutral:

```c
// Example: Sign device CSR using PKCS#11
#include <pkcs11.h>

CK_SESSION_HANDLE session;
CK_OBJECT_HANDLE device_ca_key;

// Initialize PKCS#11
CK_RV rv = C_Initialize(NULL);
// ... (open session, find key object for Device CA)

// Sign the certificate TBS (To Be Signed) portion
CK_MECHANISM mechanism = {CKM_SHA256_RSA_PKCS, NULL, 0};
rv = C_SignInit(session, &mechanism, device_ca_key);
rv = C_Sign(session, tbs_data, tbs_len, signature, &sig_len);
```

### Device Under Provisioning

The device boots a specially crafted provisioning image over USB (via NXP SDP protocol) or from a dedicated provisioning SD card/eMMC partition. This image:

1. Boots into a minimal Linux environment
2. Starts the provisioning agent
3. Establishes a secure channel with the provisioning station
4. Executes the provisioning protocol
5. Powers down or reboots into production firmware upon success

**Boot method for provisioning:**

For i.MX8MP, the standard provisioning boot uses USB Serial Download Protocol (SDP):
```bash
# On provisioning station: load provisioning image over USB-SDP
uuu -b RAM /path/to/provisioning-image.bin
```

The SDP boot does not use HAB verification (it is a pre-HAB step in the ROM boot flow). This is intentional: the device is not yet provisioned, so HAB cannot be enforced. The provisioning station is physically secured.

**Provisioning agent on device:**
The device-side provisioning agent is a shell script or compiled binary that:
1. Reads device identity (silicon UID, board serial from EEPROM)
2. Establishes TLS connection to provisioning controller (using a provisioning station TLS certificate embedded in the provisioning image — not a device certificate, which does not exist yet)
3. Awaits commands from the provisioning controller
4. Executes fuse programming, RPMB setup, certificate storage
5. Reports results back to controller
6. Terminates

### Provisioning Database

The provisioning database is the authoritative record of all provisioning operations. It must be:
- Highly available (provisioning line stops if database is unreachable)
- Append-only for audit records
- Backed up in real time to a separate location
- Accessible only from provisioning stations and authorized operations terminals

**Schema (simplified):**

```sql
-- Device records
CREATE TABLE devices (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    silicon_uid       VARCHAR(16) NOT NULL UNIQUE,
    board_serial      VARCHAR(64),
    product_id        VARCHAR(64),
    provisioning_state VARCHAR(32) NOT NULL DEFAULT 'unprovisioned',
    -- States: unprovisioned, in_progress, provisioned, failed, revoked
    provisioned_at    TIMESTAMP,
    provisioning_batch_id UUID,
    srk_batch_id      UUID REFERENCES srk_batches(id),
    firmware_version  VARCHAR(32),
    cert_serial       BIGINT,
    cert_fingerprint  VARCHAR(64),
    created_at        TIMESTAMP DEFAULT now()
);

-- SRK batches (which SRK hash was used for a production run)
CREATE TABLE srk_batches (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    srk_hash_hex  CHAR(64) NOT NULL,
    created_at    TIMESTAMP DEFAULT now(),
    valid_from    TIMESTAMP,
    valid_until   TIMESTAMP,
    description   TEXT
);

-- Audit log (append-only, never UPDATE/DELETE)
CREATE TABLE audit_log (
    id         BIGSERIAL PRIMARY KEY,
    event_type VARCHAR(64) NOT NULL,
    silicon_uid VARCHAR(16),
    operator_id VARCHAR(64),
    station_id  VARCHAR(64),
    payload     JSONB,
    signature   BYTEA,  -- HSM signature over record
    created_at  TIMESTAMP DEFAULT now()
);

-- Revoke INSERT on audit_log for all users except audit_writer role
REVOKE INSERT ON audit_log FROM PUBLIC;
GRANT INSERT ON audit_log TO audit_writer;
-- No UPDATE or DELETE granted to anyone
```

### Audit Log Server

The audit log server is separate from the provisioning database and receives events over a one-way data diode (hardware or software firewall that only allows writes, not reads, from the provisioning station direction).

**Properties:**
- Write-once: events can be added but not modified or deleted
- Signed: each event carries an HSM signature verifiable by the audit server's public key
- Replicated: events are replicated to at least two geographically separate locations
- Monitored: a SIEM system monitors for anomalies (burst of provisions, same UID twice, etc.)

---

## Provisioning Protocol Steps

The following sequence shows the complete provisioning protocol from device power-on to completion.

```
Provisioning Station                              Device (DUT)
       │                                               │
       │  1. Scan barcode / enter serial number        │
       │  2. Look up device in database (must be       │
       │     in 'unprovisioned' state)                 │
       │  3. Request provisioning ticket from HSM      │
       │     (signed: station_id + serial + nonce +    │
       │     timestamp + expiry)                       │
       │                                               │
       │  4. Load provisioning image via USB-SDP ────► │
       │                                              boot provisioning OS
       │                                               │
       │  ◄──────── 5. TLS Client Hello ───────────── │
       │  ◄──────── (using embedded station cert) ──── │
       │                                               │
       │  6. TLS handshake (station presents cert      │
       │     signed by provisioning CA; device         │
       │     verifies against embedded provisioning    │
       │     CA certificate in provisioning image)     │
       │                                               │
       │  ─── 7. SEND_PROV_TICKET ─────────────────► │
       │     {ticket, nonce_challenge}                 │
       │                                               │
       │  ◄── 8. DEVICE_IDENTITY ───────────────────  │
       │     {silicon_uid, board_serial, hw_rev,       │
       │      nonce_response}                          │
       │                                               │
       │  9. Validate identity against database        │
       │  10. Record PROVISION_START audit event       │
       │                                               │
       │  ─── 11. SRK_FUSE_VALUES ─────────────────► │
       │     {bank, word, value}[0..7]                 │
       │                                               │
       │     Program fuses                             │
       │                                               │
       │  ◄── 12. SRK_FUSES_PROGRAMMED ─────────────  │
       │     {result, fuse_values_readback}            │
       │                                               │
       │  13. Verify fuse values match expected        │
       │  14. Record SRK_FUSES_VERIFIED audit event    │
       │                                               │
       │  ─── 15. PROGRAM_RPMB ─────────────────────► │
       │     {rpmb_key_encrypted}                      │
       │                                               │
       │     Program RPMB key to eMMC                  │
       │                                               │
       │  ◄── 16. RPMB_DONE ─────────────────────────  │
       │     {result}                                  │
       │                                               │
       │  ─── 17. REQUEST_CSR ──────────────────────► │
       │                                               │
       │     Generate key pair in TEE                  │
       │     Generate CSR                              │
       │                                               │
       │  ◄── 18. DEVICE_CSR ────────────────────────  │
       │     {csr_der_base64}                          │
       │                                               │
       │  19. Validate CSR, sign with Device CA (HSM)  │
       │  20. Record DEVICE_CERT_ISSUED audit event    │
       │                                               │
       │  ─── 21. DEVICE_CERT ──────────────────────► │
       │     {cert_der_base64, cert_chain}             │
       │                                               │
       │     Store cert in OP-TEE secure storage       │
       │                                               │
       │  ◄── 22. CERT_STORED ───────────────────────  │
       │     {result}                                  │
       │                                               │
       │  ─── 23. CLOSE_DEVICE ─────────────────────► │
       │                                               │
       │     fuse prog -y 1 3 0x00000002               │
       │     (SEC_CONFIG → CLOSED mode)                │
       │                                               │
       │  ◄── 24. DEVICE_CLOSED ─────────────────────  │
       │     {sec_config_readback}                     │
       │                                               │
       │  25. Verify SEC_CONFIG = 0x2                  │
       │  26. Record SEC_CONFIG_CLOSED audit event     │
       │  27. Mark device 'provisioned' in database    │
       │  28. Record PROVISION_COMPLETE audit event    │
       │                                               │
       │  ─── 29. PROVISION_COMPLETE ───────────────► │
       │                                               │
       │     Power off / boot production firmware      │
       │                                               │
```

---

## Secure Channel Establishment

The provisioning channel uses mutual TLS (mTLS). However, at the start of provisioning, the device does not have a certificate (that is what we are provisioning). The bootstrapping problem is solved as follows:

**Pre-installed provisioning CA certificate:**
The provisioning image contains the provisioning station's TLS certificate (or the provisioning CA root certificate) embedded at build time. The device uses this to authenticate the provisioning station.

**Station certificate:**
The provisioning station presents a TLS certificate issued by the provisioning CA. This certificate is issued to the station, not the device. It is renewed periodically (annually).

**One-way authentication at start:**
Initially, the device authenticates the station (server auth) but the station has no way to authenticate the device (no client cert yet). The device is authenticated via the DEVICE_IDENTITY message (step 8) containing the silicon UID with nonce, which the station cross-references against expected values.

**mTLS after certificate issuance:**
Subsequent connections (for certificate renewal, field provisioning) use full mTLS where the device presents its device certificate.

---

## Key Injection Over Secure Channel

Device-unique key material that originates on the server side (e.g., RPMB key) is delivered over the TLS channel encrypted to the device's ephemeral TLS session key. An additional layer of encryption uses the session's AEAD cipher.

For RPMB key delivery:
```
Server:
  rpmb_key = HMAC-SHA256(HSM_MASTER_KEY, silicon_uid || "rpmb_key_v1")
  session_key = TLS_exportedMaterial("RPMB_KEY_EXCHANGE", 32)
  encrypted_rpmb_key = AES-256-GCM(key=session_key, data=rpmb_key, aad=silicon_uid)
  send(encrypted_rpmb_key || iv || tag)

Device:
  session_key = TLS_exportedMaterial("RPMB_KEY_EXCHANGE", 32)
  rpmb_key = AES-256-GCM-decrypt(encrypted_rpmb_key, session_key)
  mmc rpmb write-key /dev/mmcblk2rpmb  # programs RPMB key
```

The RPMB key is deterministically derived from the HSM master key and silicon UID. This means if a device's RPMB is ever erased (e.g., eMMC replacement), the exact same RPMB key can be re-derived and re-provisioned without storing it in a database (which would be a security risk).

---

## Fuse Programming Sequence

The fuse programming sequence within the provisioning protocol:

```
Step 1: Pre-programming verification
  - Read current OCOTP state
  - Verify all words are 0 (unburned)
  - Verify silicon UID matches expected device
  - Verify SEC_CONFIG is 0 (open mode)

Step 2: Program SRK hash (Bank 3, Words 0-7)
  For each word i in 0..7:
    Receive value[i] from provisioning station
    fuse prog -y 3 i value[i]
    fuse read 3 i  → verify matches value[i]
    If mismatch: ABORT, log error, do not continue

Step 3: Program JTAG security fuses (Bank 1, Word 3, bits 22:23)
  (Set JTAG_SMODE to secure mode, disable JTAG for production)
  fuse prog -y 1 3 0x00C00000  # JTAG_SMODE = 11 (no debug)

Step 4: Program DIR_BT_DIS and BT_FUSE_SEL
  fuse prog -y 1 3 0x00000018  # DIR_BT_DIS | BT_FUSE_SEL

Step 5: Final verification of all fuse values
  Read back and compare all programmed fuses
  Compute SHA-256 of all fuse values
  Compare against expected hash from provisioning server

Step 6: Program SEC_CONFIG (ONLY after step 5 succeeds)
  fuse prog -y 1 3 0x00000002
  Read back Bank 1 Word 3
  Verify bit 1 is set
  Report to provisioning server

NOTE: Steps 3, 4 and 6 OR together into Bank 1 Word 3.
      Care must be taken to OR the values, not overwrite:
      First read Bank 1 Word 3, then OR the new bits.
      However, since all start at 0, programming them
      sequentially with individual bits is equivalent to ORing.
```

---

## Verification Step

After all fuse programming is complete, a comprehensive verification step is performed before the provisioning station marks the device as provisioned.

**Verification checklist:**

```python
def verify_provisioning(device_conn, expected):
    results = {}

    # 1. Read all SRK fuses and compare
    srk_fuses = device_conn.read_fuses(bank=3, start_word=0, count=8)
    results['srk_match'] = (srk_fuses == expected['srk_fuse_values'])

    # 2. Verify SEC_CONFIG is closed
    boot_fuses = device_conn.read_fuses(bank=1, word=3)
    results['sec_config_closed'] = bool(boot_fuses & 0x2)

    # 3. Verify JTAG is disabled
    results['jtag_disabled'] = bool(boot_fuses & 0x00C00000)

    # 4. Verify RPMB access works
    test_data = os.urandom(256)
    device_conn.rpmb_write(address=0, data=test_data)
    readback = device_conn.rpmb_read(address=0, length=256)
    results['rpmb_functional'] = (readback == test_data)

    # 5. Verify device certificate is accessible
    cert_pem = device_conn.read_device_cert()
    cert = x509.load_pem_x509_certificate(cert_pem.encode())
    results['cert_valid'] = (cert.not_valid_after > datetime.utcnow())
    results['cert_subject_matches'] = (
        cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
        == expected['device_serial']
    )

    # 6. Reboot and verify signed firmware boots successfully
    device_conn.reboot()
    time.sleep(10)
    results['secure_boot_active'] = device_conn.wait_for_production_prompt()

    return results
```

---

## Certification Issuance

After successful fuse programming and verification, the provisioning server issues the device certificate.

**Certificate issuance process:**

```
1. Device generates RSA-2048 or EC P-256 key pair inside OP-TEE
   (Key is marked as non-extractable; will never leave the TEE)

2. Device creates a PKCS#10 CSR:
   Subject: CN=<silicon_uid>,O=Customer,OU=IoT-Device-Fleet-A
   SANs: deviceUID:<silicon_uid>, hwRev:1.0
   Public key: device's newly generated public key
   Signature: self-signed with device private key

3. Device sends CSR to provisioning station over TLS channel

4. Provisioning station validates:
   - CSR signature is valid
   - CN matches expected silicon UID
   - Key size meets minimum requirements (2048-bit RSA or P-256 EC)
   - No duplicate CSR in database (replay protection)

5. Provisioning station calls HSM (PKCS#11) to sign the certificate:
   - Issuer: Device CA
   - Subject: from CSR
   - Serial: sequential, from provisioning database
   - Validity: 20 years (or per policy)
   - Extensions: standard X.509 + custom device OID extensions
   - Signature: RSA-SHA256 or ECDSA-SHA256

6. Certificate returned to device
   Device stores in OP-TEE secure storage object "device_cert"

7. Certificate chain (Device CA + Root CA) stored in:
   /etc/ssl/device_cert_chain.pem (readable, for TLS handshakes)
```

---

## Provisioning Completion Marking

Provisioning completion is recorded at three levels:

**Level 1: Device hardware (immutable)**
- SEC_CONFIG fuse is set (HAB enforcement active)
- SRK fuses are burned (device tied to PKI)
- RPMB key is programmed (OP-TEE secure storage active)

**Level 2: Device software**
- RPMB marker written: `provisioning_complete:v1:<timestamp>:<silicon_uid>`
- Device certificate stored in OP-TEE secure storage
- Production firmware booting successfully

**Level 3: Provisioning database**
```sql
UPDATE devices
SET provisioning_state = 'provisioned',
    provisioned_at = now(),
    firmware_version = '2024.01.0',
    cert_serial = 12345,
    cert_fingerprint = 'SHA256:abc123...'
WHERE silicon_uid = '1a2b3c4d5e6f7a8b';

INSERT INTO audit_log (event_type, silicon_uid, operator_id, payload)
VALUES ('PROVISION_COMPLETE', '1a2b3c4d5e6f7a8b', 'operator_007',
        '{"duration_ms": 47230, "firmware": "2024.01.0"}'::jsonb);
```

---

## Handling Device Provisioning Failures

### Failure Classification

| Failure Stage | Recoverable | Action |
|---------------|-------------|--------|
| Pre-programming (identity check fails) | Yes | Return to queue after investigation |
| SRK fuse value mismatch during read-back | Partial | Depends on how many words already burned |
| RPMB programming failure | Yes (retry) | Retry up to 3 times, then fail |
| Network failure during cert issuance | Yes | Retry cert issuance (fuses already burned) |
| SEC_CONFIG burn failure (HAB) | No | Mark defective; investigate hardware |
| SEC_CONFIG burned, wrong SRK hash | No | Mark defective; physically destroy |

### Failure Handling Protocol

```bash
#!/bin/bash
# Provisioning failure handler
handle_failure() {
    local stage="$1"
    local error="$2"
    local device_id="$3"

    log "PROVISIONING FAILURE at stage: $stage"
    log "Error: $error"
    log "Device: $device_id"

    # Report to provisioning server
    curl -X POST https://prov-server/api/v1/failure \
        -H "Content-Type: application/json" \
        -d "{\"stage\":\"$stage\",\"error\":\"$error\",\"device\":\"$device_id\"}"

    # Update database state
    # (provisioning server does this on receiving the failure report)

    case "$stage" in
        "srk_fuses_partial")
            # Some SRK words were burned, others were not
            # Device cannot be used — fuse state is unknown
            log "CRITICAL: Partial SRK fuse programming. Device UNUSABLE."
            alert_operator "PARTIAL_SRK_BURN" "$device_id"
            ;;
        "cert_issuance_failed")
            # Fuses may be burned but cert was not issued
            # Recovery: separate cert-only re-provisioning
            log "WARNING: Cert issuance failed. Device needs cert-only recovery."
            alert_operator "CERT_RECOVERY_NEEDED" "$device_id"
            ;;
        "rpmb_failed")
            # RPMB not programmed
            log "WARNING: RPMB programming failed. Retry or manual intervention."
            alert_operator "RPMB_RETRY" "$device_id"
            ;;
        *)
            log "ERROR: Unknown failure stage: $stage"
            alert_operator "UNKNOWN_FAILURE" "$device_id"
            ;;
    esac

    exit 1
}
```

---

## Scalability: 1 Device/Minute to Batch Provisioning

### Single Station (Development / Low Volume)

- 1 USB connection to device
- Interactive U-Boot console or uuu-based flashing
- ~2-5 minutes per device
- Suitable for: prototype runs, <100 devices/day

### Multi-Station (Medium Volume)

- Multiple provisioning stations connected to same provisioning server
- Each station runs parallel provisioning for 1 device
- ~4-10 devices/hour per station
- 10 stations → 40-100 devices/hour
- Suitable for: pilot production runs, <5,000 devices/day

### Batch Provisioning (High Volume)

For high-volume manufacturing:
- Automated conveyor-based test fixtures
- Device docking station with spring-loaded USB contacts
- Automated power cycling
- Barcode scanning during device loading
- Provisioning time optimized to under 45 seconds per device (no interactive prompts)

**Throughput example:**

```
Provisioning station cycle time: 45 seconds
Devices per station per hour: 80
Stations in parallel: 20
Daily production (8h shift): 12,800 devices/day
```

**Bottleneck analysis:**
| Stage | Typical Duration |
|-------|-----------------|
| USB-SDP boot of provisioning image | 8-15 seconds |
| Provisioning agent start | 2-3 seconds |
| TLS handshake | <1 second |
| Device identity exchange | <1 second |
| SRK fuse programming (8 words) | 3-5 seconds |
| Fuse verification | 2-3 seconds |
| RPMB programming | 3-5 seconds |
| TEE key generation + CSR | 5-10 seconds |
| Certificate issuance (HSM sign) | 1-2 seconds |
| SEC_CONFIG programming | 2-3 seconds |
| Final verification | 3-5 seconds |
| Database write + audit | <1 second |
| **Total** | **~30-55 seconds** |

The TEE key generation step (5-10 seconds) and USB-SDP boot are typically the bottlenecks. The TEE step can be parallelized with other operations; USB-SDP boot time is hardware-limited.
