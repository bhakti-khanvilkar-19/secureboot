# Manufacturing Pipeline Design

## Pipeline Architecture

```
                MANUFACTURING NETWORK (ISOLATED VLAN)

+-------------+   +-------------+   +-------------+   +-------------+
|   STATION   |   |  PROVISION  |   |  CLOSURE    |   |    TEST     |
|     1       |   |  STATION    |   |  STATION    |   |  STATION    |
|             |   |             |   |             |   |             |
| Firmware    |   | SRK fuses   |   | SEC_CONFIG  |   | Functional  |
| flashing    |-->| programming |-->| burn        |-->| + Security  |
| via uuu     |   | via HSM     |   | (closure)   |   | tests       |
|             |   |             |   |             |   |             |
+-------------+   +-------------+   +-------------+   +------+------+
                        |                                     |
                        v                                     v
                +-----------------+                 +------------------+
                |   HSM Server    |                 |   MFG DATABASE   |
                | (YubiHSM2 /    |                 |   (PostgreSQL)   |
                |  Luna Network   |                 |  Serial, SRK,   |
                |  HSM)          |                 |  Status, Time   |
                | SRK values     |                 |  (append-only)  |
                +-----------------+                 +------------------+
```

## Station 1: Firmware Flashing

### Hardware Requirements
- Ubuntu 22.04 LTS PC (dedicated, hardened)
- USB-C cable to DUT (Device Under Test)
- Barcode scanner for serial number capture
- Network access to artifact server only (firewall enforced)

### Software Stack
- NXP uuu (Universal Update Utility) v1.5.21+
- sha256sum (coreutils)
- Station control script (Python 3.10+)
- Audit log agent (sends to MFG database)

### Station 1 Control Script

```bash
#!/bin/bash
# station1-flash.sh
# Flash firmware to device and verify integrity
# Usage: ./station1-flash.sh <device_serial> [usb_device]

set -euo pipefail

SERIAL="${1:?Device serial number required}"
ARTIFACT_BASE="https://artifacts.internal/firmware/releases"
FIRMWARE_VERSION="2.0.1"
FIRMWARE_IMAGE="imx-boot-phyboard-pollux-imx8mp-signed-v${FIRMWARE_VERSION}.bin"
WIC_IMAGE="phytec-securiphy-image-v${FIRMWARE_VERSION}.wic"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [Station1] $*" | tee -a /var/log/mfg/station1.log; }
fail() { log "FAIL: $*"; exit 1; }

log "Starting firmware flash for serial: $SERIAL"

# Step 1: Verify serial number format
if ! [[ "$SERIAL" =~ ^PHY-[0-9]{8}-[A-F0-9]{4}$ ]]; then
    fail "Invalid serial number format: $SERIAL"
fi

# Step 2: Download firmware from artifact server (TLS verified)
log "Downloading firmware artifacts..."
curl -fsSL --cacert /etc/ssl/certs/internal-ca.crt \
    "${ARTIFACT_BASE}/${FIRMWARE_VERSION}/${FIRMWARE_IMAGE}" \
    -o "/tmp/${FIRMWARE_IMAGE}"

curl -fsSL --cacert /etc/ssl/certs/internal-ca.crt \
    "${ARTIFACT_BASE}/${FIRMWARE_VERSION}/${FIRMWARE_IMAGE}.sha256" \
    -o "/tmp/${FIRMWARE_IMAGE}.sha256"

curl -fsSL --cacert /etc/ssl/certs/internal-ca.crt \
    "${ARTIFACT_BASE}/${FIRMWARE_VERSION}/${WIC_IMAGE}" \
    -o "/tmp/${WIC_IMAGE}"

curl -fsSL --cacert /etc/ssl/certs/internal-ca.crt \
    "${ARTIFACT_BASE}/${FIRMWARE_VERSION}/${WIC_IMAGE}.sha256" \
    -o "/tmp/${WIC_IMAGE}.sha256"

# Step 3: Verify integrity before flashing
log "Verifying firmware integrity..."
cd /tmp
sha256sum -c "${FIRMWARE_IMAGE}.sha256" || fail "Bootloader hash mismatch"
sha256sum -c "${WIC_IMAGE}.sha256" || fail "WIC image hash mismatch"
log "Integrity check PASSED"

# Step 4: Wait for device in USB download mode
log "Waiting for device in USB download mode (BOOT_MODE=01)..."
log "Connect USB-C cable, hold USB download button, apply power"
timeout 60 bash -c 'while ! lsusb | grep -q "1fc9:0146"; do sleep 1; done'
log "Device detected in USB download mode"

# Step 5: Flash bootloader and system image
log "Flashing firmware..."
uuu -b emmc_all "/tmp/${FIRMWARE_IMAGE}" "/tmp/${WIC_IMAGE}" \
    || fail "uuu flashing failed"
log "Flashing complete"

# Step 6: Wait for device to boot and report back
log "Waiting for device to boot (allow 30s)..."
sleep 30

# Step 7: Record in manufacturing database
log "Recording flash event in database..."
curl -fsSL -X POST \
    --cert /etc/ssl/station1-client.crt \
    --key /etc/ssl/station1-client.key \
    --cacert /etc/ssl/certs/internal-ca.crt \
    "https://mfgdb.internal/api/v1/events" \
    -H "Content-Type: application/json" \
    -d "{
        \"serial\": \"${SERIAL}\",
        \"event\": \"firmware_flashed\",
        \"station\": \"station1\",
        \"firmware_version\": \"${FIRMWARE_VERSION}\",
        \"firmware_hash\": \"$(sha256sum /tmp/${FIRMWARE_IMAGE} | cut -d' ' -f1)\",
        \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"operator\": \"${SUDO_USER:-${USER}}\"
    }" || fail "Database record failed"

log "Station 1 complete for serial: $SERIAL"
rm -f "/tmp/${FIRMWARE_IMAGE}" "/tmp/${WIC_IMAGE}"
```

## Station 2: Provisioning

### HSM Integration Architecture

Provisioning station communicates with HSM server. SRK values are computed
by the HSM and delivered encrypted to the target device, never stored on
the provisioning station workstation.

```
Provisioning Station         HSM Server                   Device
        |                       |                            |
        |--- Authenticate ------>|                            |
        |<-- Session Token ------|                            |
        |                       |                            |
        |--- Request SRK for --->|                            |
        |    serial X           |                            |
        |<-- Encrypted SRK ------|                            |
        |                       |                            |
        |--- (via USB/UART) fuse prog commands ------------->|
        |                       |                            |
        |--- Log to database --->|                            |
        |                       |                            |
```

### Station 2 Control Script

```python
#!/usr/bin/env python3
# station2-provision.py
# SRK fuse provisioning via HSM

import requests
import serial
import hashlib
import json
import struct
import sys
from datetime import datetime, timezone

HSM_URL = "https://hsm.internal/api/v1"
MFGDB_URL = "https://mfgdb.internal/api/v1"
CLIENT_CERT = ("/etc/ssl/station2-client.crt", "/etc/ssl/station2-client.key")
CA_CERT = "/etc/ssl/certs/internal-ca.crt"

def authenticate_hsm():
    """Authenticate with HSM server, return session token"""
    resp = requests.post(
        f"{HSM_URL}/auth",
        json={"station_id": "station2"},
        cert=CLIENT_CERT,
        verify=CA_CERT
    )
    resp.raise_for_status()
    return resp.json()["session_token"]

def get_srk_fuse_words(session_token: str, serial: str) -> list[int]:
    """Retrieve SRK fuse words for device from HSM"""
    # HSM computes SRK hash server-side and returns as 8 words
    # Words never stored on this station in plaintext
    resp = requests.post(
        f"{HSM_URL}/srk-fuse-words",
        json={"device_serial": serial},
        headers={"Authorization": f"Bearer {session_token}"},
        cert=CLIENT_CERT,
        verify=CA_CERT
    )
    resp.raise_for_status()
    data = resp.json()
    assert len(data["words"]) == 8, "Expected 8 SRK words from HSM"
    return [int(w, 16) for w in data["words"]]

def program_srk_fuses(port: str, words: list[int]) -> bool:
    """Program SRK fuse words via U-Boot serial console"""
    with serial.Serial(port, 115200, timeout=10) as ser:
        # Interrupt autoboot
        ser.write(b' ')
        ser.flush()
        
        for i, word in enumerate(words):
            cmd = f"fuse prog -y 3 {i} 0x{word:08X}\n"
            ser.write(cmd.encode())
            
            # Wait for U-Boot response
            response = b""
            deadline = datetime.now().timestamp() + 10
            while datetime.now().timestamp() < deadline:
                response += ser.read(256)
                if b"OK" in response or b"Error" in response:
                    break
            
            if b"Error" in response:
                print(f"ERROR programming word {i}: {response}")
                return False
            
            # Read back to verify
            ser.write(f"fuse read 3 {i}\n".encode())
            readback = ser.read(256)
            expected = f"{word:08X}".lower()
            if expected not in readback.decode(errors='replace').lower():
                print(f"VERIFY FAILED word {i}: expected {expected}, got {readback}")
                return False
    
    return True

def record_provisioning(serial: str, words: list[int], success: bool):
    """Record provisioning result in MFG database"""
    srk_hex = "".join(f"{w:08x}" for w in words)
    requests.post(
        f"{MFGDB_URL}/events",
        json={
            "serial": serial,
            "event": "srk_fuses_programmed" if success else "srk_fuse_failed",
            "station": "station2",
            "srk_hash": srk_hex,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        },
        cert=CLIENT_CERT,
        verify=CA_CERT
    ).raise_for_status()

def main():
    serial_number = input("Scan device serial number: ").strip()
    uart_port = input("Enter UART port (e.g. /dev/ttyUSB0): ").strip()
    
    print(f"[*] Authenticating with HSM...")
    token = authenticate_hsm()
    
    print(f"[*] Retrieving SRK fuse words for {serial_number}...")
    words = get_srk_fuse_words(token, serial_number)
    
    print(f"[*] Programming SRK fuses to device...")
    success = program_srk_fuses(uart_port, words)
    
    print(f"[*] Recording provisioning result...")
    record_provisioning(serial_number, words, success)
    
    if success:
        print(f"[+] Provisioning COMPLETE for {serial_number}")
        sys.exit(0)
    else:
        print(f"[-] Provisioning FAILED for {serial_number} - device quarantined")
        sys.exit(1)

if __name__ == "__main__":
    main()
```

## Station 3: Device Closure

### Closure Automation Script

```bash
#!/bin/bash
# station3-close.sh
# Close device by burning SEC_CONFIG and disabling JTAG

set -euo pipefail

SERIAL="${1:?Device serial required}"
UART_PORT="${2:-/dev/ttyUSB0}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [Closure] $*" | tee -a /var/log/mfg/closure.log; }
fail() { log "FAIL: $*"; record_failure "$SERIAL" "$*"; exit 1; }

record_to_db() {
    local event="$1" ; shift
    curl -fsSL -X POST \
        --cert /etc/ssl/station3-client.crt \
        --key /etc/ssl/station3-client.key \
        --cacert /etc/ssl/certs/internal-ca.crt \
        "https://mfgdb.internal/api/v1/events" \
        -H "Content-Type: application/json" \
        -d "{\"serial\":\"${SERIAL}\",\"event\":\"${event}\",\"station\":\"station3\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"operator\":\"${USER}\"}"
}

record_failure() {
    record_to_db "closure_failed" || true
}

log "Starting device closure for serial: $SERIAL"

# Step 1: Check database - device must be provisioned
STATUS=$(curl -fsSL \
    --cert /etc/ssl/station3-client.crt \
    --key /etc/ssl/station3-client.key \
    --cacert /etc/ssl/certs/internal-ca.crt \
    "https://mfgdb.internal/api/v1/device/${SERIAL}/status" | jq -r '.status')

if [ "$STATUS" != "srk_provisioned" ]; then
    fail "Device not ready for closure. Status: $STATUS (expected: srk_provisioned)"
fi

# Step 2: Verify hab_status via serial console
log "Checking HAB status (device must be in OPEN mode)..."
HAB_STATUS=$(python3 /usr/local/bin/uboot_cmd.py "$UART_PORT" "hab_status")
if ! echo "$HAB_STATUS" | grep -q "No HAB Events Found"; then
    fail "HAB events detected in OPEN mode. Do not close. Output: $HAB_STATUS"
fi
log "HAB status clean: No events in OPEN mode"

# Step 3: Burn SEC_CONFIG
log "Burning SEC_CONFIG (IRREVERSIBLE)..."
RESULT=$(python3 /usr/local/bin/uboot_cmd.py "$UART_PORT" "fuse prog -y 1 3 0x2")
if echo "$RESULT" | grep -q -i "error"; then
    fail "SEC_CONFIG programming error: $RESULT"
fi

# Verify
SEC=$(python3 /usr/local/bin/uboot_cmd.py "$UART_PORT" "fuse read 1 3")
if ! echo "$SEC" | grep -q "00000002"; then
    fail "SEC_CONFIG verification failed: $SEC"
fi
log "SEC_CONFIG burned and verified"

# Step 4: Disable JTAG
log "Disabling JTAG (IRREVERSIBLE)..."
python3 /usr/local/bin/uboot_cmd.py "$UART_PORT" "fuse prog -y 1 3 0x00C00002"

# Verify
SEC=$(python3 /usr/local/bin/uboot_cmd.py "$UART_PORT" "fuse read 1 3")
if ! echo "$SEC" | grep -q "00c00002"; then
    fail "JTAG disable verification failed: $SEC"
fi
log "JTAG disabled and verified"

# Step 5: Record closure BEFORE reset
record_to_db "device_closed"
log "Closure recorded in database"

# Step 6: Reset and verify CLOSED mode boots
log "Resetting device..."
python3 /usr/local/bin/uboot_cmd.py "$UART_PORT" "reset"
sleep 20

HAB_STATUS=$(python3 /usr/local/bin/uboot_cmd.py "$UART_PORT" "hab_status")
if ! echo "$HAB_STATUS" | grep -q "No HAB Events Found"; then
    fail "HAB events in CLOSED mode after reset: $HAB_STATUS"
fi
if ! echo "$HAB_STATUS" | grep -q "0xf0"; then
    fail "Device not in CLOSED state after reset: $HAB_STATUS"
fi

log "Device closed successfully and booted in CLOSED mode"
record_to_db "closure_verified"
log "Closure COMPLETE for serial: $SERIAL"
```

## Station 4: Security Testing

### Automated Security Test Suite

```python
#!/usr/bin/env python3
# station4-security-tests.py
# Automated security validation after device closure

import subprocess
import serial
import time
import sys

class SecurityTestRunner:
    def __init__(self, serial_number: str, uart_port: str):
        self.serial = serial_number
        self.uart = uart_port
        self.results = []
    
    def run_test(self, name: str, test_fn):
        try:
            result = test_fn()
            status = "PASS" if result else "FAIL"
        except Exception as e:
            status = "ERROR"
            result = str(e)
        
        self.results.append({"test": name, "status": status, "detail": result})
        print(f"  [{status}] {name}")
        return status == "PASS"
    
    def test_hab_closed(self):
        """Verify device is in HAB CLOSED state"""
        out = uboot_cmd(self.uart, "hab_status")
        return "0xf0" in out and "No HAB Events Found" in out
    
    def test_sec_config_burned(self):
        """Verify SEC_CONFIG fuse is set"""
        out = uboot_cmd(self.uart, "fuse read 1 3")
        # Bit 1 must be set (value >= 2)
        import re
        m = re.search(r'[0-9A-Fa-f]{8}', out)
        if m:
            val = int(m.group(), 16)
            return (val & 0x2) == 0x2
        return False
    
    def test_jtag_disabled(self):
        """Verify JTAG disable fuse is set"""
        out = uboot_cmd(self.uart, "fuse read 1 3")
        import re
        m = re.search(r'[0-9A-Fa-f]{8}', out)
        if m:
            val = int(m.group(), 16)
            return (val & 0x00C00000) == 0x00C00000
        return False
    
    def test_unsigned_rejected(self):
        """Verify unsigned firmware is rejected in CLOSED mode"""
        # This requires an unsigned test image loaded at known address
        out = uboot_cmd(self.uart, f"bootm {UNSIGNED_TEST_ADDR}")
        # Should fail with verification error
        return "Authentication failed" in out or "HAB" in out
    
    def test_dmverity_active(self):
        """Verify dm-verity is mounted on rootfs"""
        out = linux_cmd(self.uart, "dmsetup status vroot")
        return "verity" in out.lower()
    
    def run_all(self):
        print(f"\nSecurity Test Suite for {self.serial}")
        print("=" * 50)
        
        tests = [
            ("HAB CLOSED state", self.test_hab_closed),
            ("SEC_CONFIG fuse burned", self.test_sec_config_burned),
            ("JTAG disabled", self.test_jtag_disabled),
            ("Unsigned firmware rejected", self.test_unsigned_rejected),
            ("dm-verity active", self.test_dmverity_active),
        ]
        
        all_pass = True
        for name, fn in tests:
            if not self.run_test(name, fn):
                all_pass = False
        
        print("=" * 50)
        overall = "PASS" if all_pass else "FAIL"
        print(f"Overall result: {overall}")
        return all_pass
```

## Database Schema

```sql
-- Manufacturing database schema
CREATE TABLE devices (
    id BIGSERIAL PRIMARY KEY,
    serial_number VARCHAR(32) UNIQUE NOT NULL,
    pcb_revision VARCHAR(8) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE mfg_events (
    id BIGSERIAL PRIMARY KEY,
    device_serial VARCHAR(32) NOT NULL REFERENCES devices(serial_number),
    event_type VARCHAR(64) NOT NULL,
    station VARCHAR(32) NOT NULL,
    operator VARCHAR(64),
    firmware_version VARCHAR(32),
    srk_hash VARCHAR(64),
    test_results JSONB,
    timestamp TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Append-only enforcement
CREATE RULE no_mfg_update AS ON UPDATE TO mfg_events DO INSTEAD NOTHING;
CREATE RULE no_mfg_delete AS ON DELETE TO mfg_events DO INSTEAD NOTHING;

-- View: current device status (derived from event log)
CREATE VIEW device_status AS
SELECT DISTINCT ON (device_serial)
    device_serial,
    event_type as current_status,
    timestamp as last_updated
FROM mfg_events
ORDER BY device_serial, timestamp DESC;
```
