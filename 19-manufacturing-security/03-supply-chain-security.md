# Supply Chain Security

## Overview

Supply chain attacks on embedded systems occur when adversaries compromise the hardware, firmware, software, or processes upstream of the final product. A secure boot chain only protects what happens after ROM; supply chain security protects the integrity of the chain itself.

---

## Threat Model: Supply Chain Attack Vectors

```
┌─────────────────────────────────────────────────────────────┐
│                  SUPPLY CHAIN ATTACK SURFACE                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Semiconductor  → Counterfeit SoC, hardware trojans         │
│  PCB Fab        → Layout modification, signal implants      │
│  Board Assembly → Rogue component substitution              │
│  Firmware Dev   → Compromised build tools, backdoored deps  │
│  Code Repo      → Dependency confusion, typosquatting       │
│  Build System   → Compromised CI/CD, poisoned sstate        │
│  Key Management → Unauthorized key access, key theft        │
│  Signing Infra  → Compromised signing service               │
│  Firmware Dist  → Image substitution during transit         │
│  Factory Flash  → Rogue firmware at contract manufacturer   │
│  Logistics      → Physical tampering during shipping        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Hardware Supply Chain Controls

### Sourcing

```
Policy: Only source NXP i.MX8MP from:
  1. NXP directly (NXP.com authorized distributor)
  2. Arrow, Avnet, Mouser, Digi-Key (authorized distributors)
  NEVER from: eBay, Alibaba, unverified gray market suppliers

Verification:
  □ Verify distributor authorization on NXP's Authorized Distributor List
  □ Request Certificate of Conformance (CoC) with each shipment
  □ Inspect date codes and lot numbers against expected production run
  □ Perform incoming inspection (10% sample rate minimum)
```

### Counterfeit Detection

```bash
# Hardware markers to verify:
# 1. NXP part marking (laser engraving, not ink)
# 2. Date code matches purchase order
# 3. Package geometry matches datasheet
# 4. Die mark under microscope (sample destructive test)

# Electrical verification:
# - Power consumption profile during boot matches known-good reference
# - JTAG IDCODE matches expected value:
openocd -f interface/ftdi/olimex-arm-usb-tiny-h.cfg \
        -f target/imx8mp.cfg \
        -c "init; irscan imx8mp.cpu 0x0E; drscan imx8mp.cpu 32 0x0; exit"
# Expected IDCODE: 0x??????01 (verify against NXP datasheet Table 3-1)
```

### PCB Security Features

```
Physical tamper evidence:
  □ Security labels on enclosure seams (voiding on removal)
  □ Potting compound over sensitive components (HSM, key storage)
  □ PCB tamper mesh traces connected to SNVS tamper detect
  □ Active tamper detection to clear SNVS keys on intrusion

i.MX8MP SNVS tamper detection:
  - SNVS_LPTGFCR: Tamper glitch filter
  - SNVS_LPTDCR: Tamper detect control
  - On tamper: ZMK (Zone Master Key) zeroized
```

---

## Software Supply Chain Controls

### Dependency Management

```bash
# Lock all build dependencies:

# Yocto: pin layer commits
# In conf/bblayers.conf or kas configuration:

# kas/imx8mp-securiphy.yml
header:
  version: 14

machine: phyboard-pollux-imx8mp-3
distro: ampliphy-headless

repos:
  poky:
    url: https://git.yoctoproject.org/poky
    commit: abc123def456  # EXACT commit hash
    branch: kirkstone

  meta-imx:
    url: https://github.com/nxp-imx/meta-imx
    commit: def789abc012  # EXACT commit hash

  meta-phytec:
    url: https://github.com/phytec/meta-phytec
    commit: 111222333444  # EXACT commit hash

# Never use floating 'branch' references in production builds
```

### Build Reproducibility

```bash
# Enable reproducible builds in local.conf:
BB_SIGNATURE_HANDLER = "OEEquivHash"
BB_HASHSERVE = "auto"

# Record build manifest:
bitbake phytec-securiphy-image -g  # Generate task dependency graph
bitbake-layers show-recipes > build-manifest.txt
bitbake -e phytec-securiphy-image | grep "^SRCREV" > srcrev-manifest.txt

# Verify build is reproducible:
# Build twice and diff the resulting images:
sha256sum tmp/deploy/images/phyboard-pollux-imx8mp-3/*.ext4
# Should be identical across builds (given same SOURCE_DATE_EPOCH)

# Set SOURCE_DATE_EPOCH for reproducibility:
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
```

### Software Bill of Materials (SBOM)

```bash
# Generate SBOM using Yocto:
# In local.conf:
INHERIT += "create-spdx"
SPDX_PRETTY = "1"

# After build, SBOM at:
ls tmp/deploy/spdx/phyboard-pollux-imx8mp-3/

# Verify SBOM with cyclonedx-cli or Syft:
syft packages phytec-securiphy-image-phyboard-pollux-imx8mp-3.wic.gz \
    -o cyclonedx-json > sbom.json

# Check for known vulnerabilities:
grype sbom:sbom.json
```

---

## Code Repository Security

```
Source repository controls:
  □ Require signed commits (git commit -S / GPG)
  □ Require signed tags for release artifacts
  □ Branch protection: main/release requires 2 reviews + CI pass
  □ No force-push to protected branches
  □ Dependency updates via PR with security review
  □ Secret scanning enabled (no keys/passwords in repo)
  □ Audit log retention minimum 12 months

Signing verification in CI:
```

```yaml
# .github/workflows/verify-commits.yml
name: Verify Commit Signatures

on: [push, pull_request]

jobs:
  verify-signatures:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Import allowed signing keys
        run: |
          gpg --import .github/allowed-signing-keys.asc

      - name: Verify all commits are signed
        run: |
          git log origin/main..HEAD --format="%H" | while read COMMIT; do
            if ! git verify-commit "$COMMIT" 2>/dev/null; then
              echo "ERROR: Unsigned commit $COMMIT"
              exit 1
            fi
          done
```

---

## Build System Security

```
CI/CD server security controls:
  □ Dedicated build servers (not shared with development)
  □ Network isolation: build servers cannot access internet directly
  □ All downloads through verified mirror/proxy
  □ Build server OS hardened and patched monthly
  □ Build artifacts signed by build server key (SLSA provenance)
  □ sstate-cache cryptographically verified before use
  □ Build output archived with hash + build log for 5 years

Signing service isolation:
  □ Air-gapped signing server (no internet)
  □ Physical access control (badge + PIN required)
  □ HSM for all private key operations
  □ Signing service code reviewed quarterly
  □ All signing operations logged to external syslog server
```

---

## Signing Infrastructure Provenance

```python
# Generate SLSA provenance for signed artifacts
# slsa-provenance.py

import json, hashlib, datetime, subprocess

def generate_provenance(artifact_path, signing_key_id, build_id):
    """Generate SLSA Level 2 provenance record."""
    
    with open(artifact_path, 'rb') as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    
    git_commit = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD']
    ).decode().strip()
    
    provenance = {
        "_type": "https://in-toto.io/Statement/v0.1",
        "subject": [
            {
                "name": artifact_path,
                "digest": {"sha256": digest}
            }
        ],
        "predicateType": "https://slsa.dev/provenance/v0.2",
        "predicate": {
            "builder": {"id": "https://ci.example.com/builder"},
            "buildType": "https://example.com/build-types/yocto@v1",
            "invocation": {
                "configSource": {
                    "uri": "git+https://github.com/example/firmware",
                    "digest": {"sha1": git_commit}
                }
            },
            "metadata": {
                "buildStartedOn": datetime.datetime.utcnow().isoformat(),
                "completeness": {"parameters": True, "environment": True}
            },
            "materials": [
                {"uri": "pkg:yocto/poky@kirkstone", "digest": {"sha1": "abc123"}}
                # ... more materials
            ]
        }
    }
    
    return provenance
```

---

## Factory Security Controls

### Contract Manufacturer (CM) Controls

```
If using contract manufacturing:

Before engagement:
  □ CM security audit (SOC 2 Type II or ISO 27001 required)
  □ NDA with IP protection clauses
  □ Right-to-audit provisions in contract

Key management with CM:
  NEVER give CM your production private keys.
  
  Instead:
  Option A (Preferred): You flash firmware directly at CM site
    - Your engineer on-site or remote session to your signing station
    - CM provides mechanical services (board assembly, test fixtures)
    - Signing happens in your infrastructure
    
  Option B: Provision at CM with derived keys
    - CM gets batch-specific derived keys (not master keys)
    - Each batch key valid for specific serial number range only
    - Keys revoked after batch completion

  Option C: Delayed activation
    - CM flashes unsigned/development firmware
    - Final activation and signing at your site or via OTA

Audit at CM:
  □ Install cameras at flashing stations
  □ Review CM's production logs vs your signing server logs
  □ Random sampling: pull 1% of boards for re-test at your site
```

### Shipping and Logistics

```bash
# Anti-tamper package sealing:
# Use security tape with serial number visible in photo before shipping
# Photo evidence at pack, photo required at receive

# Firmware version verification at receive:
# Boards should arrive in HAB OPEN state (not yet closed)
# Close device at your facility, not at CM

# Physical label verification:
# Each board labeled with SOM serial, matching CM packing list
# Verify 100% of serial numbers against authorized list
```

---

## Incident Response: Supply Chain Compromise

```
If you suspect supply chain compromise:

Immediate:
  1. Quarantine affected batch (serial number range)
  2. Suspend signing operations
  3. Notify security team and legal
  4. Do NOT disclose publicly yet (allow investigation)

Investigation:
  5. Compare binary artifacts against known-good hashes
  6. Check signing server logs for unauthorized operations
  7. Audit key ceremony logs (who had access, when)
  8. Engage external forensics if HSM or signing infra suspected

Containment:
  9. Revoke affected signing keys (if compromised)
  10. Issue new keys (full key ceremony required)
  11. Re-sign and re-provision affected batch (or recall)
  12. Notify customers per contract/regulatory requirements

Recovery:
  13. Root cause analysis
  14. Updated threat model
  15. Enhanced controls implementation
  16. Third-party security audit
```

---

## Cross-References

- [01-manufacturing-pipeline.md](01-manufacturing-pipeline.md) — Factory pipeline
- [02-secure-manufacturing-tools.md](02-secure-manufacturing-tools.md) — Tooling
- [../11-key-management/README.md](../11-key-management/README.md) — Key management
- [../24-ci-cd-signing-pipelines/02-signing-service-design.md](../24-ci-cd-signing-pipelines/02-signing-service-design.md) — Signing infrastructure
- [../26-threat-modeling/01-attack-scenarios.md](../26-threat-modeling/01-attack-scenarios.md) — Supply chain attack scenarios
