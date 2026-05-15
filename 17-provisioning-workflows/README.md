# Section 17: Provisioning Workflows

## Overview

Provisioning is the process of transforming a blank, untrusted hardware unit into a device that participates in your chain of trust. In the context of secure boot, provisioning is not merely loading firmware: it is the act of permanently binding a physical device to your PKI hierarchy, recording that binding in immutable hardware, and issuing the cryptographic identity that the device will carry for its operational lifetime.

A device that has never been provisioned is indistinguishable from a counterfeit. A device whose provisioning workflow is insecure can be cloned, subverted, or poisoned before it ever reaches a customer. Provisioning is therefore both the most critical and the most operationally complex phase of a secure boot deployment.

This chapter covers the complete provisioning lifecycle from initial factory programming through field-deployed certificate renewal and recovery provisioning. All procedures reference the NXP i.MX8MP (PHYTEC phyCORE-i.MX8MP) platform but the principles apply broadly.

---

## What Provisioning Means in a Secure Boot Context

In a conventional embedded deployment, "provisioning" might mean "flashing firmware." In a secure boot deployment, provisioning means:

1. **Hardware identity establishment** — Reading the unique device serial number from ROM, the silicon unique ID (UID), and recording these in the provisioning database.
2. **SRK fuse programming** — Burning the SHA-256 hash of the Super Root Key table into OCOTP fuses. This permanently and irrevocably links the device to your signing PKI.
3. **SEC_CONFIG closure** — Setting the HAB SEC_CONFIG fuse bit that transitions the device from "open" (no verification) to "closed" (HAB enforced). This is the point of no return.
4. **Device identity key injection** — Injecting a device-unique private key (or having the device generate one in a TEE) and issuing a device certificate signed by your device CA.
5. **RPMB provisioning** — Programming the Replay Protected Memory Block authentication key into the eMMC, enabling OP-TEE secure storage.
6. **Secure element provisioning** — If a discrete secure element (e.g., NXP SE050, Microchip ATECC608) is present, provisioning its credentials.
7. **Production certificate issuance** — Recording the device in a PKI database, issuing its operational certificate, and marking it as provisioned.

Only after all these steps has the device achieved the security posture you designed for. A device that has completed SRK fuse programming but not SEC_CONFIG closure is not secure — an attacker can boot unsigned firmware on it.

---

## Provisioning Phases

### Phase 1: Initial Factory Provisioning

Performed during manufacturing, before the device ships. This is the highest-privilege, highest-risk phase. The device is physically present, accessible over USB/JTAG, and has not yet had its boot path locked down.

**Goals:**
- Program all one-time-programmable (OTP) security fuses
- Flash signed bootloader and production firmware
- Inject device identity credentials
- Verify all security controls are active
- Record provisioning evidence in the manufacturing database

**Threat model:** An insider attacker at the factory who wants to:
- Inject a backdoor into firmware before the device ships
- Capture device keys to impersonate devices remotely
- Clone a device serial number to produce counterfeit devices
- Skip security fuse programming to produce "open" devices

**Controls:**
- HSM-backed signing: no private key material exists unencrypted outside an HSM
- Provisioning image signed by production keys (bootstrapping problem managed by secure provisioning image)
- Mandatory verification after every fuse programming operation
- Centralized audit log that cannot be modified by the provisioning station
- Manufacturing network isolation: provisioning stations cannot reach the internet

### Phase 2: Field Provisioning

Some deployments require provisioning (or re-provisioning) in the field. Examples:
- A device that was shipped with a temporary TLS certificate that expires
- A device receiving a new customer-specific identity after sale
- Credential rotation for a long-deployed fleet

Field provisioning is constrained: the device is in closed HAB mode, so only signed software can execute. Field provisioning operates entirely through:
- Signed OTA update packages (SWUpdate, RAUC)
- Authenticated API calls to a TEE Trusted Application
- Certificate renewal through an ACME-like protocol

Field provisioning cannot change fuses. SRK fuses are permanent. If you discover you burned the wrong SRK hash in the factory, you cannot fix it in the field — the device must be returned or destroyed.

### Phase 3: Recovery Provisioning

A device may need recovery provisioning when:
- The device certificate has expired and automatic renewal failed
- The device has been marked as compromised (key revocation event)
- A firmware corruption requires factory recovery mode
- The device has been returned from a customer for refurbishment

Recovery provisioning typically uses a dedicated signed recovery image that boots from a known-good state and provides a limited re-provisioning interface. Because the device is already in closed mode, even recovery images must be signed by a key that chains to the SRK burned in fuses.

---

## Provisioning Components

### SRK Fuse Programming

The Super Root Key (SRK) hash is the cryptographic anchor of the entire secure boot chain. Once burned, it cannot be changed.

**What is programmed:** The SHA-256 hash of the SRK table (4 × 2048-bit RSA public keys, or 4 × P-256 ECDSA public keys). The SRK table itself is embedded in signed images; the hash burned in fuses is the fingerprint that verifies the table.

**Tool:** NXP `srktool` generates `SRK_1_2_3_4_fuse.bin` from the SRK certificates. This binary is 32 bytes (256 bits) split across 8 OCOTP words.

**Programming method:**
- U-Boot `fuse prog` command (see Section 18)
- NXP `uuu` tool (see Section 19)

**Irreversibility:** Once SRK fuses are burned, you cannot change them. You can revoke individual SRK keys by burning the SRK_REVOKE fuses (up to 3 of 4 keys can be revoked), but you cannot install new SRK keys.

**Risk:** Burning the wrong SRK hash permanently bricks the device (it can never boot from internal storage again). Pre-programming verification is mandatory.

### SEC_CONFIG Fuse Burning

SEC_CONFIG bit 1 in OCOTP Bank 1 Word 3 transitions the device from open mode to closed (HAB-enforced) mode.

**Before burning:** All SRK fuses must be programmed and verified. The production firmware must be signed with the correct keys and must pass HAB verification. Any mistake caught after SEC_CONFIG is burned cannot be corrected.

**Timing:** Always the last fuse operation performed, after all other checks pass.

**The point of no return:** After SEC_CONFIG is set, the ROM bootloader will reject any image that does not carry a valid HAB CSF (Command Sequence File) signed by a key whose certificate chains to the burned SRK hash.

### RPMB Provisioning

RPMB (Replay Protected Memory Block) is a hardware-protected area inside eMMC that provides authenticated write access. OP-TEE uses RPMB as its secure storage backend.

RPMB is protected by a 256-bit authentication key that is programmed once and never readable again. The eMMC controller uses HMAC-SHA-256 with this key to authenticate all RPMB read/write operations.

**Provisioning sequence:**
1. Generate a device-unique RPMB key (from CAAM RNG or OP-TEE HUK derivation)
2. Program the RPMB key to the eMMC using `mmc` tool or OP-TEE RPMB provisioning TA
3. Verify RPMB access works (authenticated read returns correct data)
4. Record that RPMB is provisioned in the manufacturing database

**Security:** The RPMB key must be programmed during factory provisioning in a controlled environment. If an attacker programs the RPMB key first, they control the secure storage for that device.

### Secure Element Provisioning

If the design includes a discrete secure element (NXP SE050, Microchip ATECC608B, Infineon SLB9645), it requires its own provisioning:

- **SE050:** Uses GlobalPlatform SCP03 secure channel for provisioning. NXP EdgeLock 2GO service provides cloud-based SE050 provisioning without exposing keys.
- **ATECC608B:** Uses Microchip's secure element provisioning (locked configuration zone, loaded key slots).

Secure element provisioning requires vendor-specific tooling and is outside the scope of this chapter, but the provisioning workflow must account for it as a gate.

### Device Identity Key Injection

Each device needs a unique private key for mTLS authentication, attestation, and other device-identity use cases.

**Two models:**

**Model 1: Server-generated key injection**
The provisioning server generates the device private key in an HSM, issues a certificate, and injects both into the device's TEE secure storage (via OP-TEE). The key never exists outside an HSM or TEE.

Disadvantage: The server has seen the device's private key. If the server is compromised, all device keys provisioned through it are compromised.

**Model 2: Device-generated key, signed by server**
The device generates its own key pair inside the TEE (never exportable). It creates a Certificate Signing Request (CSR), which the provisioning server signs to produce the device certificate.

Advantage: The private key never leaves the device. Server compromise cannot compromise existing device keys.
Disadvantage: More complex provisioning protocol; requires OP-TEE Trusted Application on the device.

**Recommendation for production:** Use Model 2. The TEE key generation model is more secure and aligns with FIDO Device Onboard (FDO) and DICE (Device Identifier Composition Engine) standards.

### Production Certificates

The provisioning workflow culminates in certificate issuance. The device certificate typically contains:

- **Subject:** Device serial number as Common Name (e.g., `CN=PHYTEC-IMX8MP-SN12345678`)
- **Subject Alternative Names:** Device type, hardware revision, provisioning batch
- **Key usage:** Digital Signature, Key Agreement
- **Extended key usage:** TLS Client Authentication
- **Issuer:** Device CA (intermediate CA, offline root CA)
- **Validity:** Typically 10-20 years for embedded devices (or shorter with automated renewal)
- **Custom extensions:** Device attestation data (optional), hardware identifier

Certificates are stored in:
- eMMC plaintext partition (for TLS handshakes that require them)
- OP-TEE secure storage (for private keys)
- TPM NV storage (if TPM present)

---

## Provisioning Image Architecture

The provisioning image is a minimal Linux system whose sole purpose is performing factory provisioning. It is not the production firmware.

### Minimal Linux + Provisioning Scripts

The provisioning image contains:
- Minimal kernel (stripped to essentials: MMC, USB, eMMC driver, cryptographic subsystem)
- BusyBox userspace (no package manager, no unnecessary services)
- Provisioning scripts (see Section 17-02)
- NXP `fuse` utility (from `imx-utils`)
- `mmc` tool (for RPMB)
- OpenSSL (for certificate operations)
- Provisioning agent (communicates with provisioning server over USB or Ethernet)

**Size target:** Under 32 MB. The provisioning image fits in a RAM disk or a small dedicated partition.

### Signed by Production Keys

The provisioning image must be signed by the same PKI hierarchy that signs production firmware. If you use temporary keys for provisioning and then burn SRK fuses that reference production keys, the provisioning image itself cannot boot after the device is closed.

This means:
1. The SRK table used for fuse programming must match the keys used to sign the provisioning image.
2. The provisioning image is built and signed as part of the same Yocto workflow that produces production firmware.
3. The provisioning image is signed with a signing certificate that chains to SRK1 (or whichever SRK slot you designate for factory use).

### One-Time Execution Logic

A successfully provisioned device must never run the provisioning image again. One-time execution is enforced at two levels:

**Hardware level:** Once SEC_CONFIG is burned, the only images that can boot are production-signed images. The provisioning image can be signed to include the production SRK certificate chain, but production images should never boot from the provisioning partition.

**Software level:** The provisioning script checks whether the device has already been provisioned (by reading SEC_CONFIG and a provisioning marker in RPMB). If the device is already provisioned, the script exits immediately without taking any action.

```bash
# One-time execution guard
check_already_provisioned() {
    # Check SEC_CONFIG fuse: if closed, provisioning is complete
    SEC_CONFIG=$(fuse read 1 3 2>/dev/null | awk 'NR==1{print $NF}')
    if [ "$((SEC_CONFIG & 0x2))" = "2" ]; then
        log "FATAL: Device already in CLOSED mode. Provisioning not permitted."
        exit 0
    fi

    # Check RPMB provisioning marker
    if rpmb_read_marker 2>/dev/null | grep -q "PROVISIONED"; then
        log "FATAL: RPMB provisioning marker present. Aborting."
        exit 0
    fi
}
```

### Tamper Detection

The provisioning image includes integrity checks that abort provisioning if:
- The device hardware has been modified (unexpected OCOTP values)
- The provisioning server certificate does not validate
- The secure channel to the provisioning server cannot be established
- Any step in the provisioning sequence fails to verify

---

## U-Boot Provisioning Commands

U-Boot provides direct access to fuse programming via the `fuse` command. This is used both in interactive sessions (for development/debug) and in scripted provisioning.

```
# U-Boot fuse command syntax:
# fuse read  <bank> <word> [<cnt>]
# fuse sense <bank> <word> [<cnt>]
# fuse prog  [-y] <bank> <word> <hexval> [<hexval>...]
# fuse override <bank> <word> <hexval> [<hexval>...]

# Read SRK fuse bank (bank 3, words 0-7)
=> fuse read 3 0 8
Bank 3 Word 0x00000000: 00000000
Bank 3 Word 0x00000001: 00000000
Bank 3 Word 0x00000002: 00000000
Bank 3 Word 0x00000003: 00000000
Bank 3 Word 0x00000004: 00000000
Bank 3 Word 0x00000005: 00000000
Bank 3 Word 0x00000006: 00000000
Bank 3 Word 0x00000007: 00000000

# Program SRK hash (values from srktool output)
=> fuse prog -y 3 0 0xA1B2C3D4
=> fuse prog -y 3 1 0xE5F60718
=> fuse prog -y 3 2 0x293A4B5C
=> fuse prog -y 3 3 0x6D7E8F90
=> fuse prog -y 3 4 0xA1B2C3D4
=> fuse prog -y 3 5 0xE5F60718
=> fuse prog -y 3 6 0x293A4B5C
=> fuse prog -y 3 7 0x6D7E8F90

# Verify
=> fuse read 3 0 8

# Close device (IRREVERSIBLE - only after verification)
=> fuse prog -y 1 3 0x00000002
```

U-Boot environment variables for scripted provisioning:

```
# setenv provisionscript 'run check_srk; run prog_srk; run verify_srk; run close_device'
# setenv check_srk 'fuse read 3 0 8; ...'
# saveenv
# run provisionscript
```

---

## Linux-Side Provisioning Scripts

See `02-provisioning-scripts.md` for complete script reference.

The Linux-side provisioning scripts operate after booting the provisioning image and handle:
- Device identity discovery (serial number, hardware revision)
- Secure channel establishment with the provisioning server
- SRK fuse programming (via U-Boot or via Linux OCOTP driver)
- RPMB key provisioning
- Device certificate request and issuance
- Production firmware deployment
- Final verification
- Audit log submission

---

## Provisioning Server Architecture

The provisioning server is the counterpart to the device-side provisioning agent. It runs in a factory-controlled environment, backed by an HSM.

```
┌─────────────────────────────────────────────────────────────────┐
│                     PROVISIONING SERVER                         │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │  Provisioning│  │   Device CA   │  │   Provisioning DB    │  │
│  │     API      │  │   (HSM-backed)│  │   (PostgreSQL +      │  │
│  │  (REST/gRPC) │  │               │  │    audit log)        │  │
│  └──────┬───────┘  └──────┬────────┘  └──────────┬───────────┘  │
│         │                 │                      │              │
│  ┌──────▼─────────────────▼──────────────────────▼───────────┐  │
│  │              Provisioning Orchestrator                     │  │
│  │  - Device attestation                                      │  │
│  │  - Serial number allocation                                │  │
│  │  - SRK hash distribution                                   │  │
│  │  - Certificate signing                                     │  │
│  │  - Audit event recording                                   │  │
│  └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Key Provisioning Server Components

**HSM Interface**
The provisioning server never handles private key material in software. All signing operations (device certificate issuance, SRK fuse value signing for integrity) are performed by calls to the HSM API (PKCS#11 for software HSM compatibility, vendor-specific for hardware HSMs like Thales Luna or AWS CloudHSM).

**Provisioning Database**
Stores:
- Device serial number, hardware revision, PCB lot number
- Provisioning timestamp
- Provisioned firmware version
- Device certificate serial number and fingerprint
- SRK batch identifier
- Provisioning operator ID (who ran this provisioning session)
- All audit events

**Certificate Authority**
Issues device certificates. Structure:
```
Root CA (offline, HSM, air-gapped)
  └── Device CA (online, HSM, provisioning server)
        └── Device Certificate (per-device, unique)
```

**Rate Limiting and Anomaly Detection**
The server monitors provisioning rate to detect:
- Sudden increase in provisioning requests (counterfeit device attack)
- Provisioning of the same serial number twice (replay or cloning attempt)
- Provisioning outside scheduled manufacturing windows

---

## Device Attestation Before Provisioning

Before injecting any keys or credentials, the provisioning server must verify it is talking to a genuine hardware platform and not a simulation or replay.

**Attestation mechanisms for i.MX8MP:**

### ROM Attestation (CAAM RNG Attestation)
The i.MX8MP CAAM includes a hardware RNG. The provisioning server can request a fresh random nonce signature using the device's CAAM, verifiable by an NXP attestation root.

### HAB Status Attestation
Before closing the device, the server can verify the current HAB status via the `hab_status` HAB command or `hab_status` U-Boot command output.

### Silicon UID
Every i.MX8MP die has a unique 64-bit silicon UID in OCOTP Bank 0, Word 1. This ID is fixed at manufacturing by NXP and cannot be changed. The server records and verifies this ID.

```bash
# Read silicon UID from Linux
UID_LOW=$(cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem | dd bs=4 skip=1 count=1 2>/dev/null | xxd -p)
UID_HIGH=$(cat /sys/bus/nvmem/devices/imx-ocotp0/nvmem | dd bs=4 skip=2 count=1 2>/dev/null | xxd -p)
echo "Silicon UID: ${UID_HIGH}${UID_LOW}"
```

---

## Serial Number and Device Identity

The device serial number serves as the primary identifier in the provisioning database. For i.MX8MP, the provisioning workflow uses a multi-part identity:

| Field | Source | Example |
|-------|--------|---------|
| Silicon UID | OCOTP Bank 0 Word 1-2 | `0x1A2B3C4D5E6F7A8B` |
| Board Serial | Laser-etched barcode | `PHYTEC-2024-SN001234` |
| Product ID | EEPROM on carrier board | `PCM-068-1110111.A1` |
| Provisioning Serial | Server-assigned | `PROV-20240115-003421` |

The provisioning serial number is a unique identifier assigned by the server at the start of provisioning. It links all provisioning events to a specific provisioning session.

---

## Provisioning Audit Trail

Every provisioning event generates an audit record. The audit trail is essential for:
- Forensic analysis after a security incident
- Compliance evidence (IEC 62443, NIST SP 800-193)
- Detecting anomalies in manufacturing
- Tracing a compromised device back to its provisioning session

**Audit events (minimum):**

| Event | Fields |
|-------|--------|
| `PROVISION_START` | silicon_uid, board_serial, operator_id, timestamp, station_id |
| `DEVICE_ATTESTED` | silicon_uid, attestation_result, nonce |
| `SRK_FUSES_PROGRAMMED` | silicon_uid, srk_hash_hex, timestamp |
| `SRK_FUSES_VERIFIED` | silicon_uid, verify_result, timestamp |
| `RPMB_PROVISIONED` | silicon_uid, rpmb_key_id (not the key), timestamp |
| `DEVICE_CERT_ISSUED` | silicon_uid, cert_serial, cert_fingerprint, ca_id |
| `SEC_CONFIG_CLOSED` | silicon_uid, timestamp, operator_id |
| `PROVISION_COMPLETE` | silicon_uid, total_duration_ms, firmware_version |
| `PROVISION_FAILED` | silicon_uid, failure_stage, error_code, timestamp |

**Audit log security:**
- Append-only (write through to immutable log store, e.g., AWS CloudTrail, Splunk)
- Each record signed with provisioning server's audit key
- Replicated off-site before provisioning session completes
- Cannot be deleted by provisioning station operators

---

## Rollback Prevention for Provisioning

The provisioning workflow itself must be protected against rollback:

1. **Provisioned-once enforcement:** The SEC_CONFIG fuse and RPMB marker prevent re-provisioning.
2. **Anti-replay nonces:** The provisioning server generates a fresh nonce at session start. Old nonces are rejected.
3. **Database marker:** The provisioning database marks each silicon UID as provisioned. A second provisioning attempt for the same UID triggers an alert and is rejected.
4. **Signed provisioning ticket:** The server issues a signed provisioning ticket at session start with a timestamp and expiry. The device validates this ticket before accepting any provisioning commands.

---

## Provisioning Failure Handling

### Failure Before SEC_CONFIG

If any step fails before SEC_CONFIG is burned, the device is still recoverable:
- SRK fuses incorrectly programmed: The device may be marked as defective if the wrong values were burned (cannot be corrected). If no fuses were burned yet, the session can be restarted.
- RPMB programming failure: Can be retried.
- Certificate issuance failure: Can be retried with a new CSR.

**Protocol:** The provisioning server retains the device in "provisioning in progress" state for up to 1 hour. If the session is not completed, the device is marked as "provisioning failed" and must be manually reviewed before being returned to the provisioning queue.

### Failure After SEC_CONFIG

If SEC_CONFIG is burned but subsequent steps fail (e.g., certificate issuance network failure):
- The device is in closed mode with SRK fuses burned.
- It can boot signed images.
- It does not yet have a device certificate.

**Recovery:** A recovery provisioning image (signed with the production SRK) can be deployed that skips fuse programming and only performs the missing steps (certificate issuance, RPMB programming if not done).

### Unrecoverable Failures

- Wrong SRK hash burned AND SEC_CONFIG burned: The device cannot be recovered. Mark as defective, document in database, physically destroy or return to NXP.
- RPMB permanently locked with wrong key: OP-TEE secure storage is inaccessible. May require board rework to replace eMMC.

---

## Recovery Provisioning

Recovery provisioning addresses devices that have been deployed but need re-provisioning due to:
- Expired credentials
- Key compromise event
- Hardware replacement (new eMMC, losing RPMB state)

Recovery provisioning flow:
1. Device enters recovery mode (either via signed recovery image pushed via OTA, or physical recovery procedure with known-good signed recovery image)
2. Recovery agent authenticates to provisioning server using existing device certificate (if not yet expired/revoked) or using a hardware attestation (CAAM-backed)
3. Server verifies device identity, checks revocation status
4. Server issues new credentials
5. Device stores new credentials in OP-TEE secure storage
6. Old credentials are revoked in the server's CRL/OCSP

**What recovery cannot do:**
- Change SRK fuses (permanent)
- Change SEC_CONFIG (permanent)
- Recover RPMB if eMMC was replaced without preserving RPMB key

For eMMC replacement scenarios, the replacement procedure must include a physical factory re-provisioning step for RPMB (since RPMB key is tied to the specific eMMC die).

---

## Related Sections

- **Section 18 — Fuse Programming:** Detailed OCOTP register map, `fuse` command reference, programming procedures
- **Section 19 — Manufacturing Security:** Factory pipeline, secure manufacturing tools, supply chain security
- **Section 22 — Measured Boot and TPM:** TPM provisioning, fTPM via OP-TEE, PCR sealing
- **Section 10 (OP-TEE):** RPMB secure storage implementation
- **Section 15 (Key Management):** SRK hierarchy, HSM integration
