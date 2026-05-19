# Secure Manufacturing Reference Architecture

## Overview

This reference architecture describes the complete infrastructure for securely manufacturing i.MX8MP-based devices at scale: from blank board to shipped, fully-provisioned, production-secured device.

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                    SECURE MANUFACTURING INFRASTRUCTURE           │
│                                                                  │
│  ┌─────────────────┐    ┌──────────────────────────────────────┐ │
│  │  KEY MANAGEMENT  │    │         FACTORY FLOOR               │ │
│  │  (Air-gapped)    │    │                                      │ │
│  │                  │    │  ┌──────────┐   ┌──────────────────┐ │ │
│  │  ┌────────────┐  │    │  │Station 1 │   │Station 2         │ │ │
│  │  │ Key Gen    │  │    │  │          │   │                  │ │ │
│  │  │ Workstation│  │    │  │Board In  │   │Flash eMMC        │ │ │
│  │  │            │  │    │  │Visual    │   │(unsigned boot +  │ │ │
│  │  │ hab4_pki   │  │    │  │Inspect   │   │provisioning img) │ │ │
│  │  │ srktool    │  │    │  │          │   │                  │ │ │
│  │  └─────┬──────┘  │    │  └──────────┘   └────────┬─────────┘ │ │
│  │        │HSM      │    │                           │           │ │
│  │  ┌─────▼──────┐  │    │                    ┌──────▼─────────┐ │ │
│  │  │ YubiHSM2   │  │    │                    │Station 3       │ │ │
│  │  │ (SRK keys, │◄─┼────┼────── Keys ────────│                │ │ │
│  │  │  FIT keys) │  │    │     (via USB, air-  │Boot prov. img  │ │ │
│  │  └────────────┘  │    │      gapped transfer)│Program fuses  │ │ │
│  │                  │    │                    │Close device    │ │ │
│  └─────────────────┘    │                    │Flash prod img  │ │ │
│                          │                    └────────┬───────┘ │ │
│  ┌─────────────────┐    │                             │          │ │
│  │  SIGNING SERVICE │    │                    ┌────────▼───────┐ │ │
│  │  (HSM-backed)    │    │                    │Station 4       │ │ │
│  │                  │◄───┼─────Artifacts──────│                │ │ │
│  │  REST API        │    │     (unsigned imgs) │QA Test         │ │ │
│  │  PKCS#11 HSM     │    │                    │Functional test │ │ │
│  │  Audit logging   │────┼─────Signed imgs────►│Secure boot     │ │ │
│  │                  │    │                    │ verification   │ │ │
│  └─────────────────┘    │                    └────────┬───────┘ │ │
│                          │                             │          │ │
│  ┌─────────────────┐    │                    ┌────────▼───────┐ │ │
│  │  MES INTEGRATION │◄───┼─────Reports────────│Station 5       │ │ │
│  │  (Factory ERP)   │    │                    │                │ │ │
│  │                  │────┼─────Authorization──►│Serial label    │ │ │
│  │  Serial tracking │    │                    │Pack & ship     │ │ │
│  │  Pass/fail log   │    │                    └────────────────┘ │ │
│  │  Batch reports   │    │                                      │ │
│  └─────────────────┘    └──────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

---

## Station Specifications

### Station 1: Incoming Inspection

```
Purpose: Verify boards before any programming

Equipment:
  - Visual inspection station (magnification camera)
  - Barcode scanner for SOM serial numbers

Process:
  1. Scan SOM serial number
  2. Register in MES as "received"
  3. Visual inspection per incoming inspection checklist
  4. Accept/reject decision → accepted boards proceed to Station 2

Data captured:
  - SOM serial
  - Batch/lot number
  - Inspector ID
  - Timestamp
  - Pass/fail + notes
```

### Station 2: Initial Flash

```
Purpose: Flash provisioning image to blank eMMC

Equipment:
  - PC running Ubuntu 22.04
  - uuu v1.4+
  - USB hub (8 ports for parallel flashing)
  - Cable labeled by port number

Process:
  1. MES check: confirm serial authorized for this batch
  2. Connect USB OTG (device in SDP mode)
  3. uuu -b emmc phytec-provisioning-image-*.wic.gz
  4. Disconnect, place in Station 3 queue

Time: ~3 minutes per board

Script:
  #!/bin/bash
  # station2-flash.sh
  SERIAL=$(scan_barcode)
  mes_authorize "$SERIAL" || exit 1
  uuu -b emmc phytec-provisioning-image-*.wic.gz
  mes_update_status "$SERIAL" "provisioning-image-flashed"
```

### Station 3: Secure Provisioning

```
Purpose: Run provisioning image, program fuses, flash production firmware, close device

Equipment:
  - PC running Ubuntu 22.04 + provisioning tooling
  - UART adapter (for provisioning image console)
  - HSM USB connection (YubiHSM2 for SRK fuse values)
  - Power supply with current monitoring
  - Remote serial console (pyserial/minicom)

Process (automated via provisioning-init.sh):
  1. Board powers on, provisioning image boots
  2. Script reads device serial (OCOTP UID)
  3. MES authorization request → get token
  4. Verify SRK fuses clear
  5. Program SRK fuses (from HSM-secured fuse value file)
  6. Verify fuses written correctly
  7. Flash production firmware (secured image)
  8. Close device (SEC_CONFIG fuse)
  9. Report success to MES
  10. Trigger reboot into production image

Failure handling:
  - Any step failure → mark device "FAIL:PROVISIONING"
  - Set aside for engineering analysis
  - Do NOT attempt re-provisioning without engineering review

Time: ~8 minutes per board
```

### Station 4: Quality Assurance

```
Purpose: Verify secure boot, functional tests, production image

Equipment:
  - UART adapter (115200 8N1)
  - Network connection (for application-level tests)
  - Test fixture with spring-loaded contacts

Tests:
  1. Power on, verify U-Boot output includes "HAB Configuration: 0x02"
  2. Verify "No HAB Events Found!"
  3. Verify kernel boots, dm-verity active
  4. Verify rootfs read-only
  5. Application-specific functional tests
  6. OP-TEE check (tee-supplicant responds)
  7. OTA update test (deliver test update, verify install + rollback)

Script:
  ./scripts/quality-gate.sh --uart /dev/ttyUSB0 --network 192.168.1.X

Pass criteria:
  - All security checks pass
  - Functional test suite: 100% pass rate

Time: ~5 minutes per board
```

### Station 5: Packaging

```
Purpose: Label, pack, and prepare for shipment

Equipment:
  - Label printer
  - Packaging materials

Process:
  1. Scan serial number
  2. MES verifies status = "QA_PASS"
  3. Print and apply label (serial, firmware version, QC date)
  4. Anti-tamper seal on enclosure seam
  5. Pack with accessories
  6. Mark in MES as "SHIPPED"

Labels include:
  - SOM serial number (human-readable + barcode)
  - Firmware version
  - Production date
  - QA inspector ID
```

---

## MES API Endpoints

```python
# Factory MES integration (simplified REST API)

endpoints = {
    # Authorize device for provisioning
    "POST /api/v1/authorize-provisioning": {
        "request": {"serial": "str", "batch": "str"},
        "response": {"authorized": "bool", "token": "str"}
    },

    # Report provisioning complete
    "POST /api/v1/provisioning-complete": {
        "request": {
            "serial": "str",
            "status": "success|fail",
            "timestamp": "ISO8601",
            "srk_sha": "hex_string",
            "firmware_version": "str"
        }
    },

    # Update device status
    "POST /api/v1/device-status": {
        "request": {"serial": "str", "status": "str", "station": "int"}
    },

    # Query device history
    "GET /api/v1/device/{serial}/history": {
        "response": {"events": [{"timestamp": "str", "status": "str", "station": "int"}]}
    },

    # Batch report
    "GET /api/v1/batch/{batch_id}/report": {
        "response": {
            "total": "int",
            "passed": "int",
            "failed": "int",
            "yield": "float"
        }
    }
}
```

---

## Security Controls Summary

```
Physical:
  □ Factory access: badge + PIN required
  □ Station cameras monitored and recorded
  □ No mobile phones in signing/provisioning area
  □ Visitor log maintained
  □ Hardware shipping tracked (serial number manifest)

Network:
  □ Factory network segmented (production vs office)
  □ No internet access from factory floor
  □ MES accessible only from factory VLAN
  □ All communications logged

Key security:
  □ HSM USB never leaves provisioning area
  □ HSM requires PIN + physical touch for operations
  □ HSM audit log exported daily to offline storage
  □ Fuse values transferred via encrypted USB (not network)

Audit:
  □ Every provisioning operation logged with timestamp + operator
  □ Every signing operation logged
  □ Daily reconciliation: MES count vs signing log count
  □ Weekly audit of failed/rejected boards
  □ Monthly security review of factory controls
```

---

## Cross-References

- [../19-manufacturing-security/01-manufacturing-pipeline.md](../19-manufacturing-security/01-manufacturing-pipeline.md) — Pipeline detail
- [../19-manufacturing-security/03-supply-chain-security.md](../19-manufacturing-security/03-supply-chain-security.md) — Supply chain
- [../16-phytec-securiphy/02-securiphy-provisioning.md](../16-phytec-securiphy/02-securiphy-provisioning.md) — PHYTEC provisioning script
- [../28-production-checklists/01-pre-provisioning-checklist.md](../28-production-checklists/01-pre-provisioning-checklist.md) — Pre-production checklist
