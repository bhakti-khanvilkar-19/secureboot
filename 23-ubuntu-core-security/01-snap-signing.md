# Snap Package Signing: Architecture and Operations

## Snap Signing Architecture Overview

Snap signing involves two independent cryptographic layers that must both be satisfied before `snapd` installs or runs a snap:

```
Layer 1: Assertion chain (metadata integrity)
  account-key assertion  ←  signed by Canonical root key
       │
       ▼
  account assertion      ←  signed by Canonical root key
       │
       ▼
  snap-declaration       ←  signed by brand/store account key
       │
       ▼
  snap-revision          ←  signed by store key
       │  (contains snap-sha3-384 hash)
       ▼
  SquashFS snap file     ←  SHA3-384 must match snap-revision

Layer 2: SquashFS integrity (content integrity)
  The snap file's SHA3-384 hash must match the value in snap-revision.
  snapd verifies this hash before mounting the snap.
  The snap itself is NOT a signed binary — it relies on the assertion chain.
```

There is no code-signing of the SquashFS in the traditional sense (no detached signature file). The hash in the `snap-revision` assertion IS the content binding. If an attacker can forge an assertion, they can substitute any snap content. If they cannot (because they lack the brand key), the hash check prevents tampered content.

---

## Snapcraft Key Management

### Key Generation (Air-Gapped Recommended)

```bash
# Install snapcraft on your signing workstation
sudo snap install snapcraft --classic

# Log in to your brand store account
snapcraft login

# Create a new key pair
# Keys are stored in: ~/.snap/gnupg/
snapcraft create-key production-signing-key

# Inspect the key (before registering)
snapcraft list-keys
# Output:
#     Name                       SHA3-384 fingerprint
# *   production-signing-key     BWDEoaqyr25nF5SNCvL1W1J2HxJ0c5Ws9BjFRlV4nMEikfBW3bDcAA

# Register key with the Snap Store (this uploads the public key as an account-key assertion)
snapcraft register-key production-signing-key
```

The private key is stored in `~/.snap/gnupg/` as a GnuPG keyring. For production use, this directory should be encrypted (LUKS container) or the key should be backed by an HSM (see section on offline signing below).

### Key Backup

```bash
# Export the GPG key for backup
gpg --homedir ~/.snap/gnupg --export-secret-keys --armor \
    "production-signing-key" > production-signing-key-backup.asc

# Store backup offline in two physically separate secure locations
# Test key recovery before production use:
gpg --homedir /tmp/test-restore --import production-signing-key-backup.asc
```

### Signing a Snap

```bash
# Build the snap first
snapcraft pack .

# Sign the snap (creates a detached assertion file)
# -k specifies which registered key to use
snap sign -k production-signing-key myapp_1.0_amd64.snap > myapp_1.0_amd64.snap.assert

# Verify the assertion was created correctly
snap known --typeable snap-revision < myapp_1.0_amd64.snap.assert

# View assertion content
cat myapp_1.0_amd64.snap.assert
```

### Offline/Custom Store Signing

For devices that do not connect to snapcraft.io, you can operate a completely local signing infrastructure:

```bash
# 1. Generate brand account key (offline, air-gapped)
snapcraft create-key brand-offline-key

# 2. Create model assertion manually (do NOT use snapcraft for this — it requires store connectivity)
cat > model.yaml << 'EOF'
type: model
authority-id: YOUR-BRAND-ACCOUNT-ID
brand-id: YOUR-BRAND-ACCOUNT-ID
model: phyboard-pollux-imx8mp-prod
architecture: arm64
timestamp: 2024-01-15T00:00:00.000Z
base: core22
grade: signed
snaps:
  - name: core22
    id: amcUKQILKXHHTlmSa7NMdnXSx02dNeeT
    type: base
    default-channel: latest/stable
  - name: phyboard-pollux-gadget
    id: YOUR-GADGET-SNAP-ID
    type: gadget
    default-channel: 22/stable
  - name: phyboard-pollux-kernel
    id: YOUR-KERNEL-SNAP-ID
    type: kernel
    default-channel: 22/stable
EOF

# 3. Sign the model assertion
snap sign -k brand-offline-key model.yaml > model.assert

# 4. Verify the signed model
snap known --typeable model < model.assert
```

---

## Snap Assertion Format

Assertions use a custom format that is human-readable but machine-verifiable:

```
type: snap-revision
authority-id: canonical
snap-sha3-384: QlqR0uAWEAWF5Nwnzj5kqmmwFslYPu1IL16MKtLKnkTzetculyVpMm1amltSCBDz
snap-id: buPKUD3TKqCOgLEjjHx5kSiCpIs5cMuQ
snap-revision: 99
snap-size: 12345678
developer-id: mydeveloper
timestamp: 2024-01-15T10:00:00Z
sign-key-sha3-384: BWDEoaqyr25nF5SNCvL1W1J2HxJ0c5Ws9BjFRlV4nMEikfBW3bDcAA

(empty line separating header from signature body)
AcLBXAQAAQoABgUCZacpAAAKCRAAAA...
(base64-encoded OpenPGP signature over the header)
```

### Assertion Encoding Rules

- Header fields: `key: value` pairs, one per line
- Multi-line values use indentation (YAML-like)
- Empty line separates header from signature block
- Signature block is base64-encoded OpenPGP (using `--armor` format without the PGP headers)
- Hash algorithm: SHA3-384 for snap content hashes; SHA-512 for assertion signatures (OpenPGP)

### Assertion Chain Verification (snapd internal logic)

```
snapd verification of snap-revision assertion:

1. Find account-key assertion matching sign-key-sha3-384
2. Verify account-key assertion signature (root key)
3. Verify snap-revision signature with public key from account-key
4. Download snap file from store
5. Compute SHA3-384 of snap file
6. Compare with snap-sha3-384 in snap-revision
7. Verify snap-id matches snap-declaration assertion for this snap
8. Check model assertion permits this snap-id
```

---

## Verifying Snap Signatures

### Verifying a Downloaded Snap

```bash
# List all known assertions for a snap
snap known snap-revision snap-sha3-384=$(sha384sum --binary /path/to/myapp.snap | \
  python3 -c "import sys, hashlib; d = sys.stdin.buffer.read(96); print(d.decode('ascii')[:96])" | \
  cut -d' ' -f1)

# More practical approach: check installed snap verification status
snap list --all
# Output includes revision numbers; all installed snaps have passed assertion verification.

# Manually verify a snap file against its assertion
python3 << 'EOF'
import hashlib, base64, sys

snap_file = "/path/to/myapp_1.0_arm64.snap"
assert_file = "/path/to/myapp_1.0_arm64.snap.assert"

# Compute SHA3-384 of snap file
with open(snap_file, "rb") as f:
    digest = hashlib.sha3_384(f.read()).digest()

# base64url encode (snap store uses standard base64)
snap_hash = base64.urlsafe_b64encode(digest).decode().rstrip("=")
print(f"Snap SHA3-384: {snap_hash}")

# Extract hash from assertion
with open(assert_file) as f:
    for line in f:
        if line.startswith("snap-sha3-384: "):
            assert_hash = line.strip().split(": ", 1)[1]
            break

print(f"Assert hash:  {assert_hash}")
print(f"Match: {snap_hash == assert_hash}")
EOF
```

### Verifying Gadget Snap Boot Assets

For the gadget snap, boot assets (imx-boot, u-boot.env) are verified by `snapd` using hashes stored in `$SNAP/meta/gadget.yaml`:

```bash
# Check that gadget boot asset hashes match
snap debug boot-vars

# Show what bootloader files snapd tracks
ls -la /var/lib/snapd/boot-assets/
# Output: managed-assets with their expected hashes
```

---

## Model Assertions for Custom Devices

### Creating a Model Assertion

Model assertions require you to have brand account credentials. The brand account is registered on the Snap Store:

```bash
# Register a brand account (one-time, requires Canonical approval for IoT use)
# Go to: https://snapcraft.io/account → IoT → Register brand

# After brand account approval, generate your brand key:
snapcraft create-key brand-key-prod

# Register the brand key with the store
snapcraft register-key brand-key-prod
```

### Model Assertion for Production Device

```yaml
# Full production model assertion for phyBOARD-Pollux i.MX8MP
type: model
authority-id: your-brand-id
brand-id: your-brand-id
model: phyboard-pollux-imx8mp-v1
architecture: arm64
base: core22
grade: signed          # Use "secured" to enable TPM-based FDE

# Store proxy for offline operation
# store: https://store.example.com  # uncomment for private store

snaps:
  # Base snap (Ubuntu 22.04 minimal)
  - name: core22
    id: amcUKQILKXHHTlmSa7NMdnXSx02dNeeT
    type: base
    default-channel: latest/stable

  # Kernel snap - must be custom for i.MX8MP
  - name: phyboard-pollux-imx8mp-kernel
    id: <kernel-snap-id-from-store>
    type: kernel
    default-channel: 22/stable
    presence: required

  # Gadget snap - provides partition layout and bootloader
  - name: phyboard-pollux-imx8mp-gadget
    id: <gadget-snap-id-from-store>
    type: gadget
    default-channel: 22/stable
    presence: required

  # Your application
  - name: your-production-app
    id: <app-snap-id-from-store>
    type: app
    default-channel: latest/stable/phyboard
    presence: required

  # Optional: IoT agent for remote management
  - name: canonical-iot-agent
    id: RmBXKl6SiJnP29SmMGrfQnM7O3eBsGdA
    type: app
    default-channel: latest/stable

timestamp: 2024-01-15T00:00:00.000Z
sign-key-sha3-384: BWDEoaqyr25nF5SNCvL1W1J2HxJ0c5Ws9BjFRlV4nMEikfBW3bDcAA

AcLBXAQAAQoABgUCZacpAAA...
(signature)
```

Sign the model:

```bash
snap sign -k brand-key-prod model.yaml > model.assert
```

---

## Serial Vault for Device Identity

### Serial Vault Architecture

```
Factory floor:
  Device (first boot)
      │
      │  1. Generate RSA-4096 device key in OP-TEE secure storage
      │  2. Send device key public part + model + serial to serial vault
      ▼
  Serial Vault (HTTPS, factory network)
      │
      │  3. Validate serial number against manufacturing DB
      │  4. Issue signed serial assertion
      │  5. Record in database: serial → device-key → timestamp
      ▼
  Device
      │  6. Store serial assertion in /var/lib/snapd/assertions/
      │  7. Ubuntu Core identity established
```

### Self-Hosted Serial Vault Setup

Canonical provides an open-source Serial Vault implementation:

```bash
# Clone Canonical's serial vault
git clone https://github.com/canonical/serial-vault

# Configuration (docker-compose.yaml)
cat > docker-compose.yaml << 'EOF'
version: '3.8'
services:
  serial-vault:
    image: canonical/serial-vault:latest
    environment:
      VAULT_SERVICE_MODE: signing
      VAULT_STORE_BACKEND: filesystem
      VAULT_JWT_SECRET: <random-256-bit-hex>
      VAULT_SIGNING_DATABASE: /data/signing.db
    volumes:
      - ./vault-data:/data
    ports:
      - "8080:8080"
    secrets:
      - brand_key

  db:
    image: postgres:14
    environment:
      POSTGRES_DB: serialvault
      POSTGRES_USER: vault
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password

secrets:
  brand_key:
    file: ./brand-key.gpg
EOF

docker-compose up -d
```

### Device-Side Serial Request

During Ubuntu Core first boot, `snapd` generates a device key and requests a serial:

```bash
# This happens automatically; for debugging:
journalctl -u snapd | grep -i serial

# Manual inspection of serial assertion after provisioning
snap known serial

# Output:
# type: serial
# authority-id: your-brand-id
# brand-id: your-brand-id
# model: phyboard-pollux-imx8mp-v1
# serial: SN-2024-001234
# device-key: AcbDTQRWhcGAARAA...
# timestamp: 2024-01-15T10:05:23Z
```

---

## Gadget Snap for i.MX8MP: Detailed Specification

### Directory Structure

```
phyboard-pollux-gadget/
├── snap/
│   └── snapcraft.yaml          # snap metadata
├── gadget.yaml                 # partition layout + bootloader config
├── meta/
│   └── snap.yaml               # (generated by snapcraft)
├── grub/
│   └── grub.cfg                # if using UEFI path
├── imx-boot-phyboard-pollux-imx8mp.bin  # HABv4-signed boot binary
├── boot.scr                    # U-Boot boot script (non-UEFI path)
└── configs/
    └── cmdline.extra           # additional kernel command line args
```

### snapcraft.yaml for Gadget

```yaml
name: phyboard-pollux-imx8mp-gadget
version: "22.04.1"
summary: Ubuntu Core gadget for PHYTEC phyBOARD-Pollux i.MX8MP
description: |
  Gadget snap providing the partition layout, U-Boot bootloader,
  and imx-boot firmware for PHYTEC phyBOARD-Pollux i.MX8MP hardware.
type: gadget
architectures:
  - arm64

parts:
  imx-boot:
    # Build imx-boot from source or fetch pre-built HABv4-signed binary
    plugin: nil
    source: .
    override-build: |
      # Copy pre-built HABv4-signed binary (must be signed offline)
      cp imx-boot-phyboard-pollux-imx8mp.bin $CRAFT_PART_INSTALL/

  gadget-files:
    plugin: dump
    source: .
    organize:
      gadget.yaml: gadget.yaml
      boot.scr: boot.scr
      configs/cmdline.extra: configs/cmdline.extra
```

### gadget.yaml for i.MX8MP (non-UEFI FIT path)

```yaml
volumes:
  imx8mp-emmc:
    schema: gpt
    bootloader: u-boot

    structure:
      # imx-boot: HABv4-signed binary at fixed offset required by ROM
      - name: imx-boot
        type: bare                  # no filesystem — raw binary
        size: 4M
        offset: 16896               # 33 * 512 = 0x4200 (eMMC boot offset for i.MX8MP)
        content:
          - image: imx-boot-phyboard-pollux-imx8mp.bin

      # U-Boot environment (if using writable env)
      # For production, use CONFIG_ENV_IS_NOWHERE or make this read-only
      - name: uboot-env
        type: bare
        size: 128K
        content:
          - image: uboot-env.bin    # default environment

      # ubuntu-seed: first partition snapd looks for, contains recovery system
      - name: ubuntu-seed
        role: system-seed
        filesystem: vfat
        type: EF,C12A7328-F81F-11D2-BA4B-00A0C93EC93B
        size: 1G
        content:
          # Grub config for UEFI path (optional if using pure FIT)
          - source: grub/grub.cfg
            target: EFI/ubuntu/grub.cfg

      - name: ubuntu-boot
        role: system-boot
        filesystem: ext4
        type: 83,0FC63DAF-8483-4772-8E79-3D69D8477DE4
        size: 750M

      - name: ubuntu-save
        role: system-save
        filesystem: ext4
        type: 83,0FC63DAF-8483-4772-8E79-3D69D8477DE4
        size: 32M

      - name: ubuntu-data
        role: system-data
        filesystem: ext4
        type: 83,0FC63DAF-8483-4772-8E79-3D69D8477DE4
        size: 0         # Fill remaining space
```

### U-Boot Environment for Ubuntu Core

Ubuntu Core's `snapd` manages U-Boot boot variables via `fw_setenv`/`fw_printenv`. The variables it uses:

```bash
# Ubuntu Core boot variables set by snapd:
snap_mode=""                # or "try" during update
snap_core="core22_1.snap"   # current base snap
snap_try_core=""            # new base snap during update
snap_kernel="kernel_1.snap" # current kernel snap
snap_try_kernel=""          # new kernel snap during update
snap_rootfs=""              # rootfs path

# These variables must be writable by snapd from userspace
# Requires U-Boot's fw_env.config pointing to uboot-env partition:
cat /etc/fw_env.config
# /dev/mmcblk2    0x200000    0x20000    # offset 2MB, size 128KB
```

---

## Kernel Snap for i.MX8MP

### Kernel Snap Structure

A kernel snap, once extracted from its SquashFS, has this structure:

```
/snap/phyboard-pollux-imx8mp-kernel/current/
├── Image.gz                    # ARM64 kernel
├── dtbs/
│   └── freescale/
│       └── imx8mp-phyboard-pollux-rdk.dtb
├── initrd.img                  # Ubuntu Core initramfs
├── modules/
│   └── 6.6.0-phytec-1/         # kernel modules
├── firmware/                   # firmware blobs (wifi, BT, etc.)
└── meta/
    └── kernel.yaml             # kernel snap metadata
```

### kernel.yaml

```yaml
# /snap/<kernel>/current/meta/kernel.yaml
assets:
  snappy-initrd:
    update: false
    content:
      - initrd.img
  kernel:
    update: true             # snapd manages kernel updates
    content:
      - Image.gz
      - dtbs/
```

### Building the Kernel Snap

```bash
# Install snapcraft with core22 build base
sudo snap install snapcraft --classic

cat > snapcraft.yaml << 'EOF'
name: phyboard-pollux-imx8mp-kernel
version: "6.6.0-phytec.1"
summary: Linux kernel for phyBOARD-Pollux i.MX8MP
type: kernel
architectures: [arm64]
base: core22

parts:
  kernel:
    plugin: kernel
    source: https://github.com/phytec/linux-phytec-imx.git
    source-branch: v6.6.3_2.0.0-phy
    source-depth: 1

    # Cross-compilation settings
    kernel-arch: arm64
    kernel-compiler: aarch64-linux-gnu-
    kernel-build-efi-image: false     # no EFI stub for i.MX8MP
    kernel-image-target:
      arm64: Image.gz

    # Device tree to include in kernel snap
    kernel-device-trees:
      - freescale/imx8mp-phyboard-pollux-rdk.dtb
      - freescale/imx8mp-phyboard-pollux-rdk-rpmsg.dtb

    # Kernel config
    kconfigfile: configs/phyboard-imx8mp-ubuntu-core-defconfig

    # Enable Ubuntu Core required features
    kconfigflavour: ubuntu

    build-packages:
      - gcc-aarch64-linux-gnu
      - libssl-dev
      - bc
      - flex
      - bison
      - libelf-dev
EOF

# Build (requires snapcraft with LXD or docker provider)
snapcraft --use-lxd

# The output is phyboard-pollux-imx8mp-kernel_6.6.0-phytec.1_arm64.snap
```

---

## Custom Signing Server

For enterprises needing to sign snaps without Snap Store connectivity, a custom signing server provides:

1. Assertion generation and signing
2. Key protection (HSM-backed)
3. Audit logging
4. Revocation capability

### Minimal Custom Signing Server (Python + SoftHSM)

```python
#!/usr/bin/env python3
"""
Minimal snap assertion signing server.
Production: replace SoftHSM with PKCS#11 HSM.
"""

import hashlib
import base64
import json
import datetime
import gnupg
from flask import Flask, request, jsonify
from functools import wraps

app = Flask(__name__)
gpg = gnupg.GPG(gnupghome='/etc/snap-signer/gnupg')

BRAND_ID = "your-brand-id"
SIGNING_KEY_FP = "YOUR-GPG-KEY-FINGERPRINT"

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = request.headers.get('X-Signing-Token')
        if not verify_token(token):
            return jsonify({"error": "unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

def compute_snap_hash(snap_bytes: bytes) -> str:
    """Compute SHA3-384 hash of snap, base64url-encoded (snap store format)."""
    digest = hashlib.sha3_384(snap_bytes).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip('=')

def create_snap_revision_assertion(
    snap_id: str,
    snap_hash: str,
    snap_size: int,
    revision: int,
    developer_id: str
) -> str:
    """Create and sign a snap-revision assertion."""
    timestamp = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

    header = (
        f"type: snap-revision\n"
        f"authority-id: {BRAND_ID}\n"
        f"snap-sha3-384: {snap_hash}\n"
        f"snap-id: {snap_id}\n"
        f"snap-revision: {revision}\n"
        f"snap-size: {snap_size}\n"
        f"developer-id: {developer_id}\n"
        f"timestamp: {timestamp}\n"
    )

    # Sign with brand GPG key
    signed = gpg.sign(
        header,
        keyid=SIGNING_KEY_FP,
        clearsign=False,
        detach=True
    )

    # Format as assertion
    sig_b64 = base64.b64encode(signed.data).decode()
    return f"{header}\n{sig_b64}"

@app.route('/api/v1/sign-snap', methods=['POST'])
@require_auth
def sign_snap():
    """
    Sign a snap file and return the assertion.
    Request: multipart/form-data with 'snap' file field + metadata
    """
    if 'snap' not in request.files:
        return jsonify({"error": "no snap file"}), 400

    snap_file = request.files['snap']
    snap_bytes = snap_file.read()
    snap_hash = compute_snap_hash(snap_bytes)

    snap_id = request.form.get('snap_id')
    developer_id = request.form.get('developer_id', BRAND_ID)
    revision = int(request.form.get('revision', 1))

    if not snap_id:
        return jsonify({"error": "snap_id required"}), 400

    assertion = create_snap_revision_assertion(
        snap_id=snap_id,
        snap_hash=snap_hash,
        snap_size=len(snap_bytes),
        revision=revision,
        developer_id=developer_id
    )

    # Audit log
    log_signing_event(snap_id, snap_hash, revision, request.remote_addr)

    return jsonify({
        "snap_hash": snap_hash,
        "assertion": assertion,
        "revision": revision
    })

@app.route('/api/v1/sign-model', methods=['POST'])
@require_auth
def sign_model():
    """Sign a model assertion."""
    model_data = request.json
    if not model_data:
        return jsonify({"error": "no model data"}), 400

    # Validate required fields
    required = ['model', 'architecture', 'base', 'snaps']
    for field in required:
        if field not in model_data:
            return jsonify({"error": f"missing field: {field}"}), 400

    timestamp = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')
    model_data['type'] = 'model'
    model_data['authority-id'] = BRAND_ID
    model_data['brand-id'] = BRAND_ID
    model_data['timestamp'] = timestamp

    # Serialize model header (order matters for snap assertions)
    header_lines = []
    for key in ['type', 'authority-id', 'brand-id', 'model', 'architecture',
                'base', 'grade', 'timestamp']:
        if key in model_data:
            header_lines.append(f"{key}: {model_data[key]}")

    # Add snaps section
    header_lines.append("snaps:")
    for snap in model_data.get('snaps', []):
        header_lines.append(f"  - name: {snap['name']}")
        if 'id' in snap:
            header_lines.append(f"    id: {snap['id']}")
        header_lines.append(f"    type: {snap['type']}")
        if 'default-channel' in snap:
            header_lines.append(f"    default-channel: {snap['default-channel']}")

    header = "\n".join(header_lines) + "\n"

    signed = gpg.sign(header, keyid=SIGNING_KEY_FP, clearsign=False, detach=True)
    sig_b64 = base64.b64encode(signed.data).decode()
    assertion = f"{header}\n{sig_b64}"

    return jsonify({"assertion": assertion, "timestamp": timestamp})

def log_signing_event(snap_id, snap_hash, revision, remote_addr):
    """Append to immutable audit log."""
    import time
    entry = {
        "ts": time.time(),
        "snap_id": snap_id,
        "snap_hash": snap_hash,
        "revision": revision,
        "client": remote_addr
    }
    with open('/var/log/snap-signer/audit.log', 'a') as f:
        f.write(json.dumps(entry) + '\n')

def verify_token(token: str) -> bool:
    """Verify signing token (replace with proper JWT verification)."""
    if not token:
        return False
    # TODO: implement JWT verification with key stored in HSM
    return token == "REPLACE_WITH_JWT_VERIFICATION"

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8443, ssl_context='adhoc')
```

### Integrating with Snapcraft

```bash
# snapcraft.yaml: specify custom snap store endpoint
# In ~/.config/snapcraft/snapcraft.yaml (developer workstation):
store_endpoint: https://signing-server.example.com

# Or in CI/CD environment:
export SNAPCRAFT_STORE_CREDENTIALS=$(cat credentials.json)
export SNAPCRAFT_STORE_API_URL=https://signing-server.example.com/api/v1
```

---

## Testing and Validation

### Testing Assertion Chain Without a Device

```bash
# Install snap-confine and snapd on development VM
sudo apt install snapd

# Import your brand's account-key assertion
snap ack your-brand-account-key.assert

# Import model assertion
snap ack model.assert

# Try to install a snap with custom assertion
snap ack myapp_1.0_arm64.snap.assert
snap install myapp_1.0_arm64.snap --dangerous  # --dangerous bypasses store, uses local assert

# Verify snap is installed and assertion is valid
snap list myapp
snap known snap-revision snap-id=$(snap list --json myapp | python3 -c "import sys,json; print(json.load(sys.stdin)['snaps'][0]['id'])")
```

### Simulating an Ubuntu Core Installation

```bash
# Use ubuntu-image to build a flashable Ubuntu Core image
sudo snap install ubuntu-image --classic

# Build Ubuntu Core image from model assertion
ubuntu-image snap --output-dir ./output model.assert

# Output: output/pc.img (or your-device.img)
# Flash to SD card:
sudo dd if=output/phyboard-pollux-imx8mp.img of=/dev/sdX bs=4M status=progress
```
