# Pre-Provisioning Checklist

## Purpose

This checklist must be completed before any production device is provisioned. It is executed by two engineers jointly. All items must be checked before proceeding.

**This checklist is irreversible at Step 5. Do not rush.**

---

## Section A: Environment Verification

```
Date: _______________  Batch ID: _______________  Lot Size: ___

Engineer 1: ___________________________  Badge: ___________
Engineer 2: ___________________________  Badge: ___________
Security Officer: _____________________  Badge: ___________

[ ] A1. Air-gapped signing workstation confirmed offline
        Command: ip link show | grep "state UP"
        Expected: No output (all interfaces DOWN)
        Actual: _________________________________

[ ] A2. HSM is operational and authenticated
        Device: _________________________________
        Serial: _________________________________
        Firmware: _______________________________

[ ] A3. Signing workstation clock is accurate
        Command: date -u
        Actual: _________________________________
        NTP source: (must be offline — manually set from GPS or atomic clock)

[ ] A4. Required tools installed and correct version
        CST version: ____________________________
        openssl version: ________________________
        python3 version: ________________________
        uuu version: ____________________________
```

---

## Section B: Key Material Verification

```
[ ] B1. SRK table file present and correct size
        File: SRK_1_2_3_4_table.bin
        Command: ls -la SRK_1_2_3_4_table.bin
        Expected size: ~1024 bytes (4× RSA-2048 public keys)
        Actual size: ___________________________

[ ] B2. SRK fuse file present and correct size
        File: SRK_1_2_3_4_fuse.bin
        Command: stat --printf="%s\n" SRK_1_2_3_4_fuse.bin
        Expected: 32
        Actual: ___________________________

[ ] B3. SRK fuse values computed and recorded (Engineer 1)
        Command: python3 scripts/print-srk-fuses.py
        Bank 3, Word 0: 0x_______________
        Bank 3, Word 1: 0x_______________
        Bank 3, Word 2: 0x_______________
        Bank 3, Word 3: 0x_______________
        Bank 3, Word 4: 0x_______________
        Bank 3, Word 5: 0x_______________
        Bank 3, Word 6: 0x_______________
        Bank 3, Word 7: 0x_______________

[ ] B4. SRK fuse values independently verified (Engineer 2)
        Engineer 2 computed values: (run independently)
        Bank 3, Word 0: 0x_______________  Match: Y / N
        Bank 3, Word 1: 0x_______________  Match: Y / N
        ... (all 8 words must match)

[ ] B5. SRK table SHA-256 hash recorded
        Command: sha256sum SRK_1_2_3_4_table.bin
        Hash: _______________________________________________

[ ] B6. Backup SRK slots: at minimum 1 slot unused
        Active SRK index: ___  (0, 1, 2, or 3)
        Backup slots available: ___  (minimum 1 required)
```

---

## Section C: Firmware Verification

```
[ ] C1. Production firmware image is the correct build
        File: _______________________________________________
        Build date: _________________________________________
        Git commit: _________________________________________
        Expected SHA-256: ___________________________________
        Actual SHA-256:   ___________________________________
        Command: sha256sum <image_file>

[ ] C2. HABv4 CSF was generated with correct parameters
        CSF file: ___________________________________________
        SPL load address: ___________________________________
        Image size (padded): ________________________________

[ ] C3. imx-boot is signed (CSF appended)
        File: imx-boot-...-signed
        Size difference vs unsigned: _______________ bytes
        Expected: 4096–8192 bytes (CSF block)

[ ] C4. FIT image is signed
        Command: dumpimage -l fitImage | grep "Sign algo"
        Expected: sha256,rsa2048:<keyname>
        Actual: ____________________________________________

[ ] C5. U-Boot DTB has FIT public key embedded
        Command: fdtdump u-boot.dtb | grep "key-"
        Expected: key-<keyname> { required = "conf"; ... }
        Actual: ____________________________________________

[ ] C6. dm-verity root hash recorded
        Hash: _______________________________________________
        Salt: _______________________________________________

[ ] C7. SWUpdate/RAUC package signed and verified
        Command: swupdate -c -i update.swu  (or rauc info update.raucb)
        Result: ____________________________________________
```

---

## Section D: Test Device Validation (Pre-Production Batch)

```
Before provisioning production lot, validate on test device:

[ ] D1. Flash signed imx-boot to test device (OPEN mode)
[ ] D2. Boot and verify hab_status:
        Expected: "HAB Configuration: 0x00 No HAB Events Found!"
        Actual: ____________________________________________

[ ] D3. Boot signed FIT and verify kernel starts
        FIT verification output: ___________________________

[ ] D4. Verify dm-verity active:
        Command: dmsetup status
        Expected: vroot device with sha256 algorithm
        Actual: ____________________________________________

[ ] D5. Verify rootfs is read-only:
        Command: touch /test_rw
        Expected: "Read-only file system"
        Actual: ____________________________________________

[ ] D6. Run quality gate script:
        Command: ./scripts/quality-gate.sh
        Result: PASS / FAIL
        If FAIL, stop and investigate before continuing.

[ ] D7. Close test device (program SEC_CONFIG fuse):
        Command: fuse prog -y 1 3 0x2
        Post-closure hab_status:
        Expected: "HAB Configuration: 0x02 No HAB Events Found!"
        Actual: ____________________________________________

[ ] D8. Test OTA update on closed test device:
        Update version: ________ → ________
        Result: PASS / FAIL

[ ] D9. Test recovery procedure on test device:
        USB SDP recovery: PASS / FAIL
```

---

## Section E: Factory Station Verification

```
[ ] E1. Factory flashing station calibrated and tested
        Station ID: _______________________________________

[ ] E2. UUU version confirmed: ___________________________

[ ] E3. Network connection to MES verified:
        MES URL: _________________________________________
        Test API call: PASS / FAIL

[ ] E4. Provisioning script dry-run complete:
        Command: ./scripts/provisioning-init.sh --dry-run
        Result: PASS / FAIL

[ ] E5. Fallback/manual procedure documented and understood
```

---

## Approval to Proceed

```
All above sections must be complete and all items checked.

Any FAIL or discrepancy must be resolved before proceeding.
Do NOT provision production devices with unresolved items.

Engineer 1 sign-off: ___________________________  Date: ___________
Engineer 2 sign-off: ___________________________  Date: ___________
Security Officer:    ___________________________  Date: ___________

APPROVED TO PROCEED: YES / NO
Notes:
_________________________________________________________________
_________________________________________________________________
```

---

## Cross-References

- [02-security-review-checklist.md](02-security-review-checklist.md) — Security review (run before this checklist)
- [../16-phytec-securiphy/02-securiphy-provisioning.md](../16-phytec-securiphy/02-securiphy-provisioning.md) — Provisioning workflow
- [../11-key-management/02-srk-fuse-programming.md](../11-key-management/02-srk-fuse-programming.md) — SRK fuse verification
