# Common Failure Modes Reference

## Quick Reference Table

| Symptom | Likely Cause | Section |
|---------|-------------|---------|
| No UART output at all | BOOT_MODE pins, power, UART config | §1 |
| ROM hangs, no SPL output | Wrong boot device, IVT corrupt | §2 |
| HAB event: INV_SIGNATURE (0x18) | Wrong keys, modified image | §3 |
| HAB event: INV_KEY (0xC2) | SRK fuse/table mismatch | §4 |
| HAB event: INV_CERTIFICATE (0x2B) | CSF cert chain broken | §5 |
| "Signature check failed" in U-Boot | FIT key mismatch | §6 |
| "Required signature not found" | Unsigned FIT, CLOSED U-Boot | §7 |
| Kernel panic: "dm-verity" | Root hash mismatch, hash tree wrong | §8 |
| OP-TEE: 0xFFFF0009 | RPMB not provisioned | §9 |
| SWUpdate: "signature mismatch" | Wrong OTA signing key | §10 |
| Device closes but won't boot | SRK hash written wrong | §11 |
| TPM unseal fails at boot | PCR values changed | §12 |

---

## §1: No UART Output

```bash
# Check list:
# 1. UART pins: TX/RX swapped? (connect TX of host to RX of board)
# 2. UART speed: must be 115200 8N1 for U-Boot
# 3. BOOT_MODE pins: must point to valid boot source
# 4. Power: 5V supply sufficient for board + SOM?
# 5. Is eMMC boot0 enabled?

# Linux check eMMC boot configuration:
mmc bootpart enable 1 1 /dev/mmcblk2  # Enable boot0 partition
mmc extcsd read /dev/mmcblk2 | grep "BOOT_"

# Verify ROM output: very first bytes should appear even before SPL
# If total silence, suspect:
# - BOOT_MODE pulling to invalid state
# - Power issue
# - Physical damage to SOM
```

---

## §2: ROM Hangs / SPL Not Starting

```
Symptom: ROM banner (if any) then silence — SPL never loads.

Causes:
  A) IVT at wrong offset
  B) eMMC boot0 partition not programmed
  C) DDR not initialized (SPL crashes during DDR init)
  D) Signed image rejected by ROM (CLOSED mode + wrong signature)

Debug:
  - Try loading via USB SDP (bypasses storage boot, tests if board is alive)
  - Use JTAG to single-step through ROM
  - Check that imx-boot is written to /dev/mmcblk2boot0 (not p1!)
  - Verify eMMC boot0 access enabled:
    mmc bootpart enable 1 1 /dev/mmcblk2
```

---

## §3: HAB_INV_SIGNATURE

```
Event: STS=HAB_FAILURE RSN=HAB_INV_SIGNATURE CTX=HAB_CTX_AUT_DAT

Meaning: The data specified in the "Authenticate Data" CSF block
         does not match the signature in the CSF.

Most common causes:
  A) Image padded to different size than what CSF specifies
  B) Image was recompiled/modified after CSF generation
  C) Wrong IMG key used to sign
  D) CSF file out of date with image

Fix:
  1. Recompute image size and verify CSF Authenticate Data block size matches
  2. Re-sign from scratch using current image
  3. Do NOT modify imx-boot.bin after signing

Checklist:
  [ ] PADDED_SIZE in CSF matches dd-padded image size
  [ ] No relink occurred after signing
  [ ] Using correct IMG key (same run as CSF key)
```

---

## §4: HAB_INV_KEY

```
Event: STS=HAB_FAILURE RSN=HAB_INV_KEY

Meaning: The "Install SRK" command failed — SRK in CSF
         doesn't match the hash burned in OCOTP fuses.

Cause:
  A) Keys were regenerated but fuses still have old hash
  B) Using keys from wrong key generation run
  C) SRK index in CSF doesn't match which SRK was used

Fix:
  1. Recompute SRK table hash:
     python3 -c "
     import hashlib
     data = open('SRK_1_2_3_4_table.bin','rb').read()
     print(hashlib.sha256(data).hexdigest())
     "
  2. Read fuse values:
     U-Boot> fuse read 3 0 8
  3. Compare — they MUST match

  If they don't match:
  - If device OPEN: use matching keys (generate new keys, re-burn fuses, or use original keys)
  - If device CLOSED with wrong hash: see recovery procedures §11
```

---

## §5: HAB_INV_CERTIFICATE

```
Event: STS=HAB_FAILURE RSN=HAB_INV_CERTIFICATE

Meaning: Certificate chain verification failed.
         CSF certificate not properly signed by the installed SRK.

Causes:
  A) CSF cert from different CA than SRK
  B) Using mix of keys from different generation runs
  C) Certificate expired (check date on signing workstation!)

Fix:
  1. Verify CSF cert chains back to SRK:
     openssl verify \
         -CAfile crts/SRK1_sha256_2048_65537_v3_usr_crt.pem \
         crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem

  2. Check workstation clock (certificates are time-sensitive):
     date  # Must be accurate

  3. Regenerate ALL keys together — never mix keys from different generation runs
```

---

## §6: FIT "Signature Check Failed"

```
Symptom: U-Boot prints "ERROR: Bad signature!"

Causes:
  A) Key file used to sign doesn't match key embedded in U-Boot DTB
  B) FIT image was modified after signing (even 1 byte)
  C) Different key used for different build runs

Fix:
  1. Check key name:
     dumpimage -l fitImage | grep "Sign algo"
     # Shows: sha256,rsa2048:fit-signing-key (← key name)
     
     fdtdump u-boot.dtb | grep "key-"
     # Shows: key-fit-signing-key { ... }
     # Names must match!

  2. Verify key modulus matches:
     openssl rsa -in keys/fit/fit-signing-key.pem -modulus -noout | md5sum
     openssl x509 -in keys/fit/fit-signing-key.crt -modulus -noout | md5sum
     # Both must be identical

  3. Was fitImage modified after signing?
     mkimage -F fitImage -k keys/fit/ -K /dev/null 2>&1 | grep -E "OK|Error"
```

---

## §7: Required Signature Not Found

```
Symptom: "ERROR: 'conf@1' requires a signature that is not found!"

Cause: U-Boot compiled with CONFIG_FIT_SIGNATURE + required="conf" policy,
       but the loaded FIT image was not signed.

In CLOSED mode: This will HALT BOOT.

Fix:
  1. Always sign FIT images in production pipelines
  2. Development: use OPEN mode U-Boot (without FIT_SIGNATURE)
     or sign dev images with dev keys

  3. Verify FIT is signed:
     dumpimage -l fitImage | grep "Sign"
     # Must show signature nodes
```

---

## §8: Kernel Panic — dm-verity

```
Symptom: Kernel panics with:
  "dm-verity: /dev/mmcblk2p3: data block XXX is corrupted"

Or:
  "Kernel panic - not syncing: IO-error in critical section"

Causes:
  A) Wrong root hash passed in kernel cmdline
  B) Rootfs was written to wrong partition
  C) Rootfs was corrupted during write
  D) Root hash embedded in old FIT doesn't match new rootfs

Fix:
  1. If root hash wrong: redeploy FIT image with correct hash
  2. If rootfs corrupted: reflash from known-good image via SDP/UUU
  3. Verify root hash at runtime:
     veritysetup verify /dev/mmcblk2p3 /dev/mmcblk2p3 <roothash>

  4. To check what root hash is in current cmdline:
     cat /proc/cmdline | grep "verity"
```

---

## §9: OP-TEE RPMB Error 0xFFFF0009

```
Symptom: OP-TEE logs "RPMB: rpmb_data_req: op failed with error code 0x0009"
         or secure storage TAs fail with RPMB error

Cause: RPMB key not provisioned on this device

Fix:
  1. Run OP-TEE RPMB provisioning (once per device):
     tee-supplicant &  # Must be running
     # RPMB key is provisioned automatically on first OP-TEE secure storage use
     # If it fails, check:
     #   a) RPMB partition accessible: ls /dev/mmcblk*rpmb
     #   b) tee-supplicant is running
     #   c) OP-TEE built with CFG_RPMB_FS=y

  2. Check RPMB key not already set (cannot re-provision):
     tee-supplicant --help
```

---

## §10: SWUpdate Signature Mismatch

```
Symptom: SWUpdate exits with "sw-description signature validation failed"

Cause: Package signed with different key than device has in its keyring

Fix:
  1. Verify device keyring:
     cat /etc/swupdate/swupdate-signing-cert.pem | openssl x509 -fingerprint -sha256 -noout

  2. Verify package was signed with matching key:
     openssl cms -verify \
         -in artifacts/sw-description.sig \
         -inform DER \
         -content artifacts/sw-description \
         -CAfile keys/swupdate/swupdate-signing-cert.pem \
         -noverify  # Or: -CAfile for full chain

  3. Re-sign package with correct key matching device keyring
```

---

## §11: Device Closed with Wrong SRK Hash

```
This is a CATASTROPHIC failure.

Symptoms:
  - Device boots but cannot authenticate any firmware (OPEN mode behavior
    shows HAB_INV_KEY events)
  - Device completely bricked (CLOSED mode)

Recovery options (all are difficult):
  1. SRK revocation (if other SRK slots available):
     Program OCOTP_SRK_REVOKE fuse to revoke the bad SRK index
     Sign new firmware using a different SRK index

  2. Obtain keys matching the burned hash (if keys exist somewhere)

  3. NXP support (limited options, no guarantee)

  4. Device is destroyed

Prevention: ALWAYS verify SRK hash calculation matches fuse values
            before burning. Use two-engineer verification.
```

---

## §12: TPM Unseal Fails at Boot

```
Symptom: LUKS volume cannot be unlocked automatically
         "tpm2_unseal: Failed verifying PCR policy"

Cause: PCR values changed — boot chain changed since key was sealed

Valid causes (expected PCR change):
  - Firmware update changed U-Boot or kernel (PCR 4, 8)
  - U-Boot environment changed (PCR 5)

Fix:
  1. Identify which PCR changed:
     tpm2_pcrread sha256 > /tmp/current-pcrs.txt
     diff /etc/tpm/golden-pcrs.txt /tmp/current-pcrs.txt

  2. Unseal with passphrase (recovery path):
     cryptsetup luksOpen /dev/mmcblk2p5 data  # Enter passphrase

  3. Re-seal key with new PCR values:
     # (After verifying the firmware change was intentional)
     tpm2_unseal -c 0x81000001 ... -o /tmp/key.bin  # Use passphrase method
     tpm2_create ... -L <new-pcr-policy> -i /tmp/key.bin  # Re-seal
     shred -vuz /tmp/key.bin
```

---

## Cross-References

- [01-hab-debugging.md](01-hab-debugging.md) — HABv4 event detail
- [02-fit-image-debugging.md](02-fit-image-debugging.md) — FIT verification detail
- [03-recovery-procedures.md](03-recovery-procedures.md) — Recovery for each scenario
