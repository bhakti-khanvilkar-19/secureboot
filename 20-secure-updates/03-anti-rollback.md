# Anti-Rollback Protection

## Overview

Anti-rollback prevents an attacker from downgrading firmware to an older version that contains known vulnerabilities. This is critical: if an attacker can roll back to version 1.0 with a known RCE, your entire security chain is bypassed.

## Anti-Rollback Mechanisms

### 1. OCOTP Fuse Counter (Hardware)

The most secure anti-rollback mechanism. Each firmware version increment permanently programs an additional fuse bit.

```
i.MX8MP OCOTP Fuse Counter:
  Bank 4, Words 0-1 (32 bits each = 64 bits total)
  
  Each bit represents one version increment.
  Bit 0 = version 1, bit 1 = version 2, ... bit 63 = version 64

  Version 1: 0x00000001 0x00000000  (bit 0 set)
  Version 2: 0x00000003 0x00000000  (bits 0-1 set)
  Version 5: 0x0000001F 0x00000000  (bits 0-4 set)

  NEVER decrements — once a bit is set, the device will
  refuse any firmware claiming a version number lower than
  the count of set bits.
```

#### Reading Current Version from Fuses

```bash
# U-Boot:
U-Boot> fuse read 4 0 2
Reading bank 4:
Word 0x00000000: 0000001F 00000000

# That's bits 0-4 set = version 5

# Linux:
OFFSET=$((4 * 8 * 4))  # Bank 4, Word 0
dd if=/sys/bus/nvmem/devices/imx-ocotp0/nvmem \
   bs=4 skip=$((OFFSET / 4)) count=2 2>/dev/null | od -An -tx4
```

#### Programming Version Increment

```bash
# U-Boot (increment from version 4 to version 5):
# Version 4 has bits 0-3 set: 0x0000000F
# Version 5 sets bit 4 additionally: 0x0000001F

U-Boot> fuse prog -y 4 0 0x0000001F
Programming bank 4 word 0x00000000 to 0x0000001f...OK

# Verify
U-Boot> fuse read 4 0 1
Word 0x00000000: 0000001F
```

#### Firmware Version Check at Boot

```c
/* In U-Boot SPL or U-Boot proper, check firmware version against fuse counter */

#include <fuse.h>

#define OCOTP_BANK_ANTI_ROLLBACK  4
#define OCOTP_WORD_ANTI_ROLLBACK  0

int check_firmware_version(u32 image_version)
{
    u32 fuse_word;
    u32 fuse_version;
    int ret;

    ret = fuse_read(OCOTP_BANK_ANTI_ROLLBACK, OCOTP_WORD_ANTI_ROLLBACK, &fuse_word);
    if (ret) {
        printf("ERROR: Cannot read anti-rollback fuse\n");
        return -1;
    }

    /* Count set bits = fuse version */
    fuse_version = __builtin_popcount(fuse_word);

    if (image_version < fuse_version) {
        printf("ERROR: Anti-rollback! Image version %u < fuse version %u\n",
               image_version, fuse_version);
        return -EPERM;
    }

    return 0;
}
```

### 2. SWUpdate Version Enforcement (Software)

```lua
-- sw-description: Set minimum version
software = {
    version = "2.1.0";
    minimum-version = "2.0.0";  -- Reject anything older

    -- SWUpdate checks: if installed version < minimum-version, reject update
    -- This prevents rollback via the OTA mechanism itself
};
```

```bash
# SWUpdate --no-downgrade flag:
swupdate -i update.swu --no-downgrade

# In swupdate systemd service:
ExecStart=/usr/bin/swupdate --no-downgrade -l 5 \
          -p /usr/lib/swupdate/progress.sh
```

### 3. RAUC Bundle Version

```ini
[update]
compatible=phyboard-pollux-imx8mp
version=2.1.0
```

```bash
# RAUC tracks installed version in its status database:
rauc status --output-format=json | python3 -c \
    "import json,sys; s=json.load(sys.stdin); \
     print(s['slots']['rootfs.0']['bundle']['version'])"

# Configure RAUC to reject downgrades:
# /etc/rauc/system.conf:
[system]
bundle-formats=verity
# RAUC compares bundle version against installed version
# Rejects if bundle version < installed version
```

### 4. Signed Version Manifest (Application Level)

```python
# version-checker.py — validate firmware version at application startup

import subprocess
import struct
import sys

MIN_FIRMWARE_VERSION = 5  # Hardcoded minimum, not configurable by attacker

def read_fuse_version():
    """Read anti-rollback version from OCOTP fuses."""
    try:
        with open('/sys/bus/nvmem/devices/imx-ocotp0/nvmem', 'rb') as f:
            offset = 4 * 8 * 4  # Bank 4, Word 0
            f.seek(offset)
            word = struct.unpack('<I', f.read(4))[0]
        return bin(word).count('1')  # popcount
    except Exception as e:
        print(f"ERROR reading fuse version: {e}", file=sys.stderr)
        sys.exit(1)

def read_running_version():
    """Read current firmware version from signed manifest."""
    try:
        with open('/etc/firmware-version', 'r') as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"ERROR reading firmware version: {e}", file=sys.stderr)
        sys.exit(1)

fuse_ver = read_fuse_version()
fw_ver = read_running_version()

if fw_ver < fuse_ver:
    print(f"SECURITY: Firmware version {fw_ver} < fuse version {fuse_ver}. Halting.")
    sys.exit(1)

if fw_ver < MIN_FIRMWARE_VERSION:
    print(f"SECURITY: Firmware version {fw_ver} < minimum {MIN_FIRMWARE_VERSION}. Halting.")
    sys.exit(1)

print(f"Version check passed: firmware={fw_ver}, fuse={fuse_ver}")
```

---

## Anti-Rollback Workflow

### Releasing New Firmware Version

```bash
#!/bin/bash
# release-firmware.sh
# Run on signing workstation after Yocto build

NEW_VERSION=6  # Increment by 1 from previous
PREV_VERSION=5

echo "Releasing firmware version $NEW_VERSION"

# Step 1: Verify fuse counter matches previous version
# (Device must have fuse version = PREV_VERSION before this update)

# Step 2: Update version file in rootfs
echo "$NEW_VERSION" > firmware-version
# (This file is baked into the rootfs during build, not modified here)

# Step 3: Create signed update package
./create-swu.sh  # Creates update with NEW_VERSION in sw-description

# Step 4: After this version is deployed to all devices, 
#         program the fuse on each device to NEW_VERSION

# Fuse value for version 6 (bits 0-5 set):
printf "Fuse value for version %d: 0x%08X\n" \
    $NEW_VERSION \
    $((2**NEW_VERSION - 1))
# Fuse value for version 6: 0x0000003F

# Program during next update's post-install script:
cat > post-install.sh << 'EOF'
#!/bin/sh
# Post-install: program anti-rollback fuse
FUSE_WORD=0x0000003F  # Version 6

# Via fw_setenv or direct nvmem write:
# (Implement using U-Boot fuse API or Linux nvmem)
echo "Anti-rollback fuse updated to version 6"
EOF
```

---

## Security Considerations

### Fuse Budget

```
64-bit fuse counter (2 × 32-bit OCOTP words):
  Maximum 64 version increments per device lifetime.
  
  For quarterly releases over 10 years:
  40 versions → well within budget
  
  For monthly releases:
  120 versions → exceeds budget at year 5
  
  Recommendation: Use anti-rollback fuses only for MAJOR versions
  (significant security fixes), not every release.
```

### Fuse vs Software Anti-Rollback

| Mechanism | Tamper Resistance | Granularity | Admin Override | Notes |
|-----------|------------------|-------------|----------------|-------|
| OCOTP fuse | Highest (hardware) | 64 versions | Impossible | Production requirement |
| SWUpdate --no-downgrade | Medium (software) | Unlimited | Yes (local access) | Additional layer |
| Application check | Low | Unlimited | Yes (root access) | Defense in depth |
| RAUC version check | Medium | Unlimited | Yes (physical) | Additional layer |

### Recovery from Anti-Rollback Lockout

If you accidentally advance the fuse counter too far:
- There is **no recovery** — the fuse cannot be decremented
- You must release a firmware with version ≥ fuse counter
- If fuse counter = 64, the device can only accept firmware claiming version 64+

**Test fuse programming on development devices first, never directly on production.**

---

## Cross-References

- [01-swupdate-integration.md](01-swupdate-integration.md) — SWUpdate version enforcement
- [02-rauc-integration.md](02-rauc-integration.md) — RAUC version tracking
- [../18-fuse-programming/01-ocotp-register-map.md](../18-fuse-programming/01-ocotp-register-map.md) — OCOTP fuse map
- [../12-habv4-imx8m/05-hab-lifecycle.md](../12-habv4-imx8m/05-hab-lifecycle.md) — HABv4 lifecycle and fuses
