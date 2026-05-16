# Manufacturing Security

## Overview

Manufacturing is the most vulnerable phase of a device's lifecycle.
An attacker with factory access can:
- Install malicious firmware before secure boot is enabled
- Intercept signing keys during programming
- Clone devices using captured serial numbers
- Bypass provisioning checks on test lines
- Substitute counterfeit components during assembly

This chapter covers the security controls, procedures, and tooling required
to maintain device integrity from blank PCB through packaged product.

## Manufacturing Threat Model

### Assets at Risk

| Asset | Value | If Compromised |
|-------|-------|----------------|
| Private signing keys | Highest | Attacker can sign any firmware |
| Device certificates | High | Attacker can impersonate any device |
| SRK fuse values | High | If transmitted unencrypted to factory |
| Firmware images | Medium | Could be tampered before flash |
| Production test data | Medium | Device status could be falsified |
| Factory network credentials | Medium | Access to provisioning infrastructure |
| Hardware unique IDs | Low-Medium | Used for cloning attacks |

### Threat Actors in Manufacturing

| Threat Actor | Access Level | Motivation |
|-------------|-------------|------------|
| Malicious factory employee | Physical + logical | Financial, espionage |
| External attacker (network) | Logical via internet | Remote exploitation |
| Rogue contractor | Physical temporary | Targeted sabotage |
| Supply chain attacker | Component level | Nation-state, IP theft |
| Competitor spy | Social engineering | IP theft, product cloning |

### Attack Vectors

```
Supply Chain Attack Surface:

Component Suppliers              Factory Floor
      │                               │
      ▼                               ▼
[IC fabrication]──────────────▶[PCB Assembly]──▶[Firmware Flash]
[PCB fab]                              │                │
[Component distrib]                    │          [Provisioning]
                                       │                │
                               Factory Network          │
                                       │         [Security Tests]
                               [IT Systems]             │
                               [Build Servers]    [Packaging]
                                       │                │
                               [Code Repositories]      ▼
                                                   [Distribution]
```

## Manufacturing Security Controls

### Principle 1: Zero Trust Factory

Assume the factory network and physical environment are untrusted.
All security operations must be:
- Cryptographically authenticated (no trust based on network location)
- Logged and auditable with tamper-evident records
- Fail-safe (any failure means device does NOT advance to next stage)
- Verified by the device itself, not just the factory station

Implementation:
```
- Signing keys NEVER leave HSM (Hardware Security Module)
- All provisioning requests authenticated and authorized
- Factory stations receive only what they need (least privilege)
- Manufacturing database is write-once append-only
- All communications encrypted (mTLS)
```

### Principle 2: Least Privilege

Each manufacturing station only has access to what it needs for that stage:

| Station | Has Access To | Does NOT Have Access To |
|---------|--------------|------------------------|
| PCB Test | Test scripts, JTAG | Firmware, signing keys |
| Firmware Flash | Signed firmware images | Signing keys, provisioning creds |
| Provisioning | HSM API endpoint | Raw signing keys, other device certs |
| Security Test | Test scripts, expected results | Keys, certs, provisioning API |
| Packaging | Barcode data | Any security assets |

### Principle 3: Immutable Audit Trail

Every device provisioned must generate a permanent, tamper-evident record:

```
Required fields in MFG database per device:
- Hardware serial number (burned into fuse or EEPROM)
- PCB revision
- SRK hash programmed (hex, 64 chars)
- SEC_CONFIG burn timestamp (UTC, ISO 8601)
- Firmware version flashed
- Provisioning server ID + certificate fingerprint
- Operator badge ID
- Station ID + calibration date
- All test results (pass/fail + raw data)
- RPMB provisioning status
- Shipping destination
```

## Manufacturing Stages

### Stage 1: Blank Board Testing

Purpose: Verify PCB is electrically functional before investing in programming.

Activities:
- Power-on test (all voltage rails)
- Interface continuity test (UART, SPI, I2C, USB)
- DRAM test (basic read/write pattern)
- eMMC detect test (presence, capacity)
- Network interface test (if applicable)
- JTAG connectivity verification

Security state: Fully open (JTAG enabled, no firmware, no secure boot)

Database record: board serial, PCB revision, test results, technician ID

### Stage 2: Firmware Programming

Purpose: Load signed firmware onto eMMC boot partitions.

Activities:
- Download signed firmware from secure artifact repository
- Verify firmware SHA-256 before programming (supply chain integrity)
- Program using uuu/imx_loader over USB
- Readback verify programmed regions
- Boot firmware for first time (confirm it reaches U-Boot)

Security state: HAB OPEN, firmware signed but fuses not yet burned

Security controls:
```bash
# Firmware artifact must be cryptographically verified before programming:
# 1. Download from artifact repo with TLS verification
# 2. Check SHA-256 against published release hash
# 3. Optionally: verify GPG signature on release manifest
sha256sum -c firmware-release-v2.0.1.sha256
```

### Stage 3: Secure Provisioning

Purpose: Program security fuses and inject device-specific secrets.

Activities:
- HSM-backed provisioning server programs SRK fuses (via U-Boot API)
- Device certificate injection (if PKI infrastructure deployed)
- RPMB key provisioning for OP-TEE
- Anti-rollback counter initialization

Security controls:
- Station is in isolated network segment
- All requests to HSM are authenticated with station certificate
- SRK values provided by HSM, never stored on station in plaintext
- All provisioning transactions logged to tamper-evident database

### Stage 4: Device Closure

Purpose: Irreversibly enable secure boot enforcement.

Activities:
- Validate signed firmware boots cleanly (hab_status = No Events)
- Burn SEC_CONFIG = CLOSED (irreversible)
- Disable JTAG via fuse (irreversible)
- Optionally: disable serial download mode (irreversible)

CRITICAL: Record all closure actions in database BEFORE any subsequent steps.
If device fails at this stage, it is bricked; database must reflect this.

Fail-safe rule: If ANY step in this stage fails, device is quarantined
and not allowed to proceed to Stage 5 or shipping.

### Stage 5: Production Image and Testing

Purpose: Load final production image and verify security posture.

Activities:
- Flash production firmware image (may differ from provisioning image)
- Full functional test suite
- Security regression tests:
  - Verify signed firmware is accepted
  - Verify unsigned firmware is REJECTED (proves closure worked)
  - Verify JTAG is disabled (attempt connection, expect failure)
  - Verify dm-verity is active (check /proc/devices, dmsetup status)
  - Verify expected kernel cmdline (no debug flags)

Security test assertions:
```bash
# On device under test (automated test script):

# Test 1: Unsigned firmware rejected
test_unsigned_rejection() {
    # Try to load and boot unsigned kernel via U-Boot test interface
    # Expect: boot fails with HAB event
    result=$(uboot_command "bootm ${UNSIGNED_ADDR}")
    assert_contains "$result" "ERR_VERIFICATION" "Unsigned image must be rejected"
}

# Test 2: dm-verity active
test_dmverity() {
    status=$(cat /proc/mounts | grep vroot)
    assert_not_empty "$status" "verity device must be mounted"
    
    verity_status=$(dmsetup status vroot)
    assert_contains "$verity_status" "verity" "vroot must be verity device"
}

# Test 3: No debug interfaces
test_no_debug() {
    # No serial console in production (optional but recommended)
    # JTAG must not respond
    jtag_result=$(openocd_connect 2>&1)
    assert_contains "$jtag_result" "Error" "JTAG must be disabled"
}
```

### Stage 6: Packaging and Shipping

Purpose: Package and label device for distribution.

Activities:
- Tamper-evident seal applied
- Barcode label: device serial + hardware revision + firmware version
- Packing list: firmware version + provisioning timestamp + order info
- Final database record update: shipped, destination, carrier, tracking

Security controls:
- Tamper-evident packaging prevents undetected physical access
- All shipped devices have database record (enables recall/audit)
- Shipping manifest signed by authorized shipping clerk

## Manufacturing Network Security

```
FACTORY NETWORK ARCHITECTURE

Internet
    │
    ▼
[Firewall]
    │
    ├──▶ [Corporate LAN] (Engineering, IT)
    │
    └──▶ [Manufacturing VLAN] (ISOLATED)
              │
              ├──▶ [Artifact Server]    (read-only firmware images)
              ├──▶ [Provisioning HSM]   (SRK values, via authenticated API)
              ├──▶ [MFG Database]       (write audit records)
              ├──▶ [Station 1..N]       (programming/test PCs)
              └──▶ [NTP Server]         (accurate timestamps for logs)

Rules:
- Manufacturing VLAN cannot reach internet
- Manufacturing stations cannot reach corporate LAN
- HSM only accessible from provisioning station (firewall rule)
- All inter-system communication uses mTLS
```

## Quality Gates

Each stage transition requires explicit database approval:

```
Stage 1 PASS ──▶ Database: "ready_for_flash"    ──▶ Stage 2 begins
Stage 2 PASS ──▶ Database: "ready_for_provision" ──▶ Stage 3 begins
Stage 3 PASS ──▶ Database: "ready_for_closure"   ──▶ Stage 4 begins
Stage 4 PASS ──▶ Database: "closed_pending_test" ──▶ Stage 5 begins
Stage 5 PASS ──▶ Database: "ready_for_ship"      ──▶ Stage 6 begins
Stage 5 FAIL ──▶ Database: "quarantine"          ──▶ Engineering review
Any FAIL     ──▶ Fail-safe: device physically tagged and isolated
```

## Counterfeit Prevention

Measures to prevent device cloning and counterfeiting:

1. Hardware Unique ID (HWUID) burned in fuses at Stage 3
2. Device certificate signed by OEM CA (unique per device)
3. RPMB key unique per device (prevents storage cloning)
4. Cryptographic attestation: server can verify device identity remotely
5. Database query: before shipping, verify serial is in database

```bash
# Counterfeit check at distribution center:
# Query manufacturing database with device serial
curl -s "https://mfg-db.internal/api/v1/device/${SERIAL}/status" \
     --cert dist-cert.pem --key dist-key.pem \
     | jq '.status, .firmware_version, .ship_date'
# If serial not found: counterfeit or rogue unit
```
