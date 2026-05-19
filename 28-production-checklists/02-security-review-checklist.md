# Security Review Checklist

## Purpose

Run this checklist before releasing any firmware version to production. It verifies that the security architecture is intact and no security regressions have been introduced.

---

## Section 1: Build Configuration Review

```
Firmware Version: ___________  Build Date: ___________
Reviewer: ___________________  Date: ___________________

[ ] 1.1  HABv4 signing enabled in build:
         Command: bitbake -e imx-boot | grep "^HAB_ENABLE"
         Expected: HAB_ENABLE="1"

[ ] 1.2  FIT signing enabled:
         Command: bitbake -e virtual/kernel | grep "^UBOOT_SIGN_ENABLE"
         Expected: UBOOT_SIGN_ENABLE="1"

[ ] 1.3  Production keys used (not development keys):
         FIT key fingerprint: ___________________________
         Expected fingerprint: __________________________
         Matches production key inventory: Y / N

[ ] 1.4  dm-verity enabled:
         Command: bitbake -e phytec-securiphy-image | grep "^DM_VERITY"
         Expected: DM_VERITY_IMAGE set

[ ] 1.5  No debug features in production build:
         CONFIG_DEBUG_TWEAKS: absent
         CONFIG_ALLOW_EMPTY_PASSWORD: absent
         CONFIG_ALLOW_ROOT_LOGIN: absent

[ ] 1.6  U-Boot console locked:
         CONFIG_BOOTDELAY=-2 or CONFIG_SILENT_CONSOLE=y

[ ] 1.7  No network commands in U-Boot:
         CONFIG_CMD_NET=n confirmed

[ ] 1.8  Environment locked:
         CONFIG_ENV_WRITEABLE_LIST="" confirmed
```

---

## Section 2: Kernel Security Configuration

```
[ ] 2.1  KASLR enabled: CONFIG_RANDOMIZE_BASE=y
[ ] 2.2  Stack canary: CONFIG_STACKPROTECTOR_STRONG=y
[ ] 2.3  Strict RWX: CONFIG_STRICT_KERNEL_RWX=y
[ ] 2.4  KPTI enabled: CONFIG_UNMAP_KERNEL_AT_EL0=y
[ ] 2.5  Debug FS disabled: CONFIG_DEBUG_FS=n
[ ] 2.6  Magic SysRq disabled: CONFIG_MAGIC_SYSRQ=n
[ ] 2.7  Module signing: CONFIG_MODULE_SIG_FORCE=y (or no modules)
[ ] 2.8  dmesg restricted: CONFIG_SECURITY_DMESG_RESTRICT=y
[ ] 2.9  /dev/mem restricted: CONFIG_STRICT_DEVMEM=y
[ ] 2.10 Lockdown mode: CONFIG_SECURITY_LOCKDOWN_LSM=y
[ ] 2.11 IMA enabled: CONFIG_IMA=y (if required by policy)
[ ] 2.12 AppArmor/SELinux enabled: ___________________________
```

---

## Section 3: Cryptographic Review

```
[ ] 3.1  All keys are RSA-2048 or ECC P-256 minimum
         (No RSA-1024 or SHA-1)

[ ] 3.2  Certificate validity periods checked:
         CA cert expiry: ___________________________
         CSF cert expiry: __________________________
         FIT cert expiry: __________________________
         OTA cert expiry: __________________________
         (Must be > 1 year from now)

[ ] 3.3  No plaintext keys in build outputs:
         Command: grep -rn "BEGIN RSA PRIVATE" tmp/deploy/
         Expected: No output

[ ] 3.4  No plaintext keys in source repository:
         Command: git log --all -p | grep -c "BEGIN RSA PRIVATE"
         Expected: 0

[ ] 3.5  SRK fuse hash matches signing key table:
         SHA-256(SRK_table.bin) = ___________________________
         OCOTP fuse values match: Y / N (verify against key ceremony record)

[ ] 3.6  OTA signing algorithm: RSA-2048 + SHA-256 (minimum)
```

---

## Section 4: Image Verification

```
[ ] 4.1  Run hab_status on test device in OPEN mode:
         Result: "No HAB Events Found!" Y / N
         If N, document events: ___________________________

[ ] 4.2  Run hab_status on test device in CLOSED mode:
         HAB Configuration: 0x02 Y / N
         No HAB Events: Y / N

[ ] 4.3  FIT image signature verified:
         Command: dumpimage -l fitImage | grep "Sign algo"
         Expected: sha256,rsa2048:<keyname>
         Actual: ___________________________

[ ] 4.4  dm-verity root hash embedded in signed FIT:
         Root hash in cmdline: ___________________________
         Matches veritysetup output: Y / N

[ ] 4.5  OTA package signature verified:
         Command: swupdate -c -i update.swu
         Result: 0 (success) / Error: ___________________________

[ ] 4.6  Anti-rollback version correct:
         Expected version number: ___
         Package version: ___
         Fuse counter: ___
```

---

## Section 5: Runtime Security Verification

```
[ ] 5.1  Rootfs is read-only on test device:
         touch /test_rw result: "Read-only file system" Y / N

[ ] 5.2  dm-verity device active:
         dmsetup status shows verity: Y / N

[ ] 5.3  No SUID binaries introduced:
         Command: find / -perm /4000 -not -path '/proc/*' 2>/dev/null
         Unexpected binaries: ___________________________

[ ] 5.4  No world-writable files in rootfs:
         Command: find / -perm -o+w -not -path '/proc/*' \
                       -not -path '/sys/*' -not -path '/dev/*' 2>/dev/null
         Unexpected files: ___________________________

[ ] 5.5  Root login disabled:
         grep root /etc/shadow | grep "^root:!" Y / N

[ ] 5.6  SSH password auth disabled (if SSH present):
         grep PasswordAuthentication /etc/ssh/sshd_config | grep no Y / N

[ ] 5.7  No development tools installed:
         which gdb strace gcc result: not found Y / N
```

---

## Section 6: Dependency and Supply Chain

```
[ ] 6.1  All layer SRCREVs pinned to exact commits:
         Floating BRANCH references: 0 (verified in bblayers.conf)

[ ] 6.2  Known CVEs reviewed:
         CVE scan tool: ___________________________
         High/critical CVEs addressed: Y / N / N/A
         Unresolved CVEs and rationale: ___________________________

[ ] 6.3  Third-party dependencies audited:
         New dependencies added this version: ___________________________
         Licenses reviewed: Y / N

[ ] 6.4  SBOM generated:
         Location: ___________________________
         Format: SPDX / CycloneDX
```

---

## Approval

```
Reviewers must be different from firmware developers.

Security Reviewer 1: ___________________________  Date: ___________
Security Reviewer 2: ___________________________  Date: ___________
Product Manager:     ___________________________  Date: ___________

APPROVED FOR PRODUCTION: YES / NO

Conditions/Notes:
_________________________________________________________________
_________________________________________________________________
```

---

## Cross-References

- [01-pre-provisioning-checklist.md](01-pre-provisioning-checklist.md) — Factory provisioning checklist
- [03-incident-response.md](03-incident-response.md) — If security issues found during review
- [../27-hardening/README.md](../27-hardening/README.md) — Hardening requirements
