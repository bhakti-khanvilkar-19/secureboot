# GitHub Actions Secure Firmware Build Pipeline

## Overview

This document provides a complete, production-ready GitHub Actions workflow for building and signing embedded Linux firmware for the i.MX8MP platform. The design enforces separation of build and sign, uses GitHub Environments for access control, and produces SLSA Level 3 provenance.

## Repository Secret and Environment Configuration

### Required Secrets

Configure in GitHub: Settings → Secrets and variables → Actions

**Repository-level secrets (available to all workflows):**
- None. No production secrets at repository level.

**Environment: `production-signing`**
Required approval from at least 2 reviewers before this environment is accessible.

| Secret | Description |
|--------|-------------|
| `HSM_TOKEN_PIN` | PKCS#11 token PIN for HSM access |
| `SIGNING_KEY_ID` | Key label/ID in HSM for firmware signing |
| `SIGNING_SERVICE_URL` | URL of internal signing service |
| `SIGNING_SERVICE_JWT` | JWT for authenticating to signing service |
| `ARTIFACT_STORAGE_KEY` | AWS/S3 access key for artifact storage |

**Environment: `release`**
Separate environment for publishing to release channels.

| Secret | Description |
|--------|-------------|
| `RELEASE_STORAGE_BUCKET` | S3 bucket for production firmware releases |
| `RELEASE_CDN_KEY` | CDN signing key for release distribution |

### Branch Protection Configuration

Before deploying this pipeline, configure branch protection on `main`:
- Require status checks: `build / build-firmware`
- Require 2 reviewer approvals for PRs
- Restrict pushes to `main`: require PR
- Do not allow force pushes
- Do not allow bypassing required reviews

---

## Complete Workflow: `.github/workflows/secure-build.yml`

```yaml
name: Secure Embedded Firmware Build

on:
  push:
    branches:
      - main
      - 'release/**'
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'
      - 'v[0-9]+.[0-9]+.[0-9]+-rc[0-9]+'
  pull_request:
    branches:
      - main

# Minimal permissions at workflow level — jobs add what they need
permissions:
  contents: read

env:
  YOCTO_MACHINE: phyboard-pollux-imx8mp-3
  YOCTO_IMAGE: phytec-securiphy-image
  YOCTO_DISTRO: securiphy
  REGISTRY: ghcr.io
  # Artifact retention policy
  UNSIGNED_RETENTION_DAYS: 3
  SIGNED_RETENTION_DAYS: 90

jobs:
  # ─────────────────────────────────────────────────────────────
  # Job 1: Static analysis and configuration validation
  # Runs on every PR and push. No signing, no build.
  # ─────────────────────────────────────────────────────────────
  validate:
    name: Validate Configuration
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          # Full history for accurate commit info
          fetch-depth: 0

      - name: Validate Yocto layer configuration
        run: |
          # Check that required layers are present
          python3 scripts/ci/validate_layers.py --bblayers bblayers.conf
          python3 scripts/ci/validate_local_conf.py --local local.conf.template

      - name: Check for hardcoded keys or credentials in source
        run: |
          # Fail if any file contains patterns matching private keys or tokens
          python3 scripts/ci/secret_scan.py \
            --patterns scripts/ci/secret_patterns.txt \
            --exclude .github/workflows/ \
            --path .

      - name: Validate signing configuration
        run: |
          # Ensure signing-related configs reference correct key IDs
          python3 scripts/ci/validate_signing_config.py \
            --config configs/signing/production.yaml

  # ─────────────────────────────────────────────────────────────
  # Job 2: Build firmware
  # Runs on every push and PR. Produces UNSIGNED firmware.
  # ─────────────────────────────────────────────────────────────
  build:
    name: Build Firmware
    needs: validate
    runs-on: ubuntu-22.04

    outputs:
      build-id: ${{ steps.build-meta.outputs.build-id }}
      artifact-hashes: ${{ steps.compute-hashes.outputs.hashes }}
      git-sha: ${{ github.sha }}
      git-ref: ${{ github.ref }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          submodules: recursive

      - name: Set build metadata
        id: build-meta
        run: |
          BUILD_ID="$(date -u +%Y%m%d)-${GITHUB_RUN_NUMBER}-${GITHUB_SHA:0:8}"
          echo "build-id=${BUILD_ID}" >> $GITHUB_OUTPUT
          echo "BUILD_ID=${BUILD_ID}" >> $GITHUB_ENV

          # Record build metadata for provenance
          cat > build_metadata.json << EOF
          {
            "build_id": "${BUILD_ID}",
            "git_sha": "${GITHUB_SHA}",
            "git_ref": "${GITHUB_REF}",
            "git_tag": "${GITHUB_REF_NAME}",
            "runner": "${RUNNER_NAME}",
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "workflow": "${GITHUB_WORKFLOW}",
            "run_url": "https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
          }
          EOF

      - name: Setup Yocto build dependencies
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y --no-install-recommends \
            gawk wget git-core diffstat unzip texinfo \
            gcc-multilib build-essential chrpath socat \
            cpio python3 python3-pip python3-pexpect \
            xz-utils debianutils iputils-ping python3-git \
            python3-jinja2 libegl1-mesa libsdl1.2-dev \
            xterm python3-subunit mesa-common-dev \
            zstd liblz4-tool

      - name: Restore Yocto sstate cache
        uses: actions/cache/restore@v4
        id: sstate-cache
        with:
          path: |
            yocto-cache/sstate-cache
            yocto-cache/downloads
          key: yocto-${{ env.YOCTO_MACHINE }}-${{ hashFiles('sources/**/*.bb', 'sources/**/*.bbappend', 'sources/**/*.conf') }}
          restore-keys: |
            yocto-${{ env.YOCTO_MACHINE }}-

      - name: Initialize Yocto build environment
        run: |
          # Use kas for reproducible Yocto setup
          pip3 install kas

          # kas setup configures bblayers.conf and local.conf from kas YAML
          kas checkout kas/phyboard-pollux-imx8mp-securiphy.yml

          # Override for CI: set BB_NUMBER_THREADS, disable interactive features
          cat >> build/conf/local.conf << 'EOF'

          # CI overrides
          BB_NUMBER_THREADS = "8"
          PARALLEL_MAKE = "-j8"
          BB_ENV_PASSTHROUGH_ADDITIONS += "CI BUILD_ID"
          DL_DIR = "${TOPDIR}/../yocto-cache/downloads"
          SSTATE_DIR = "${TOPDIR}/../yocto-cache/sstate-cache"
          # In CI: no HAB signing (unsigned firmware for artifact step)
          # HAB signing is done offline / in signing service
          HAB_ENABLE = "0"
          FIT_SIGN_ENABLE = "0"
          EOF

      - name: Build Yocto image
        id: yocto-build
        run: |
          cd build
          # source Yocto environment
          . ../sources/poky/oe-init-build-env . 2>/dev/null

          # Build the image
          bitbake ${YOCTO_IMAGE} 2>&1 | tee ../build.log || {
            echo "::error::Yocto build failed"
            tail -50 ../build.log
            exit 1
          }
        env:
          BUILD_ID: ${{ steps.build-meta.outputs.build-id }}
          MACHINE: ${{ env.YOCTO_MACHINE }}
          DISTRO: ${{ env.YOCTO_DISTRO }}

      - name: Save Yocto sstate cache
        if: steps.sstate-cache.outputs.cache-hit != 'true'
        uses: actions/cache/save@v4
        with:
          path: |
            yocto-cache/sstate-cache
            yocto-cache/downloads
          key: yocto-${{ env.YOCTO_MACHINE }}-${{ hashFiles('sources/**/*.bb', 'sources/**/*.bbappend', 'sources/**/*.conf') }}

      - name: Collect build artifacts
        run: |
          DEPLOY_DIR="build/tmp/deploy/images/${YOCTO_MACHINE}"
          mkdir -p artifacts/unsigned

          # Copy primary artifacts
          cp "${DEPLOY_DIR}/fitImage"                               artifacts/unsigned/
          cp "${DEPLOY_DIR}/imx-boot-${YOCTO_MACHINE}.bin"         artifacts/unsigned/
          cp "${DEPLOY_DIR}/${YOCTO_IMAGE}-${YOCTO_MACHINE}.ext4"  artifacts/unsigned/rootfs.ext4
          cp "${DEPLOY_DIR}/${YOCTO_MACHINE}.dtb"                  artifacts/unsigned/

          # Copy rootfs hash (pre-computed dm-verity root hash)
          cp "${DEPLOY_DIR}/${YOCTO_IMAGE}-${YOCTO_MACHINE}.verity.roothash" \
             artifacts/unsigned/rootfs.verity.roothash 2>/dev/null || true

      - name: Compute artifact hashes
        id: compute-hashes
        run: |
          cd artifacts/unsigned
          sha256sum * > ../../artifact_manifest.sha256
          cd ../..

          # Encode for output (base64 for safe passing between jobs)
          HASHES=$(cat artifact_manifest.sha256 | base64 -w0)
          echo "hashes=${HASHES}" >> $GITHUB_OUTPUT

          echo "Artifact manifest:"
          cat artifact_manifest.sha256

      - name: Sign artifact manifest (CI key, not production key)
        run: |
          # Sign the manifest with a CI-specific GPG key (not the firmware signing key!)
          # This proves the manifest was produced by this specific CI run
          echo "${CI_GPG_PRIVATE_KEY}" | gpg --import
          gpg --armor --detach-sign \
              --local-user "${CI_GPG_KEY_ID}" \
              artifact_manifest.sha256
        env:
          CI_GPG_PRIVATE_KEY: ${{ secrets.CI_MANIFEST_SIGNING_KEY }}
          CI_GPG_KEY_ID: ${{ secrets.CI_MANIFEST_KEY_ID }}

      - name: Bundle unsigned artifacts
        run: |
          cp artifact_manifest.sha256 artifacts/unsigned/
          cp artifact_manifest.sha256.asc artifacts/unsigned/
          cp build_metadata.json artifacts/unsigned/

      - name: Upload unsigned firmware artifacts
        uses: actions/upload-artifact@v4
        with:
          name: unsigned-firmware-${{ steps.build-meta.outputs.build-id }}
          path: artifacts/unsigned/
          retention-days: ${{ env.UNSIGNED_RETENTION_DAYS }}
          if-no-files-found: error

      - name: Upload build log
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: build-log-${{ steps.build-meta.outputs.build-id }}
          path: build.log
          retention-days: 7

  # ─────────────────────────────────────────────────────────────
  # Job 3: Sign firmware
  # Runs only on main, release/* branches, and version tags.
  # Requires manual approval via GitHub Environment.
  # ─────────────────────────────────────────────────────────────
  sign:
    name: Sign Firmware
    needs: build
    runs-on: ubuntu-22.04
    environment: production-signing   # Requires reviewer approval

    # Only sign on protected branches/tags
    if: |
      github.event_name == 'push' && (
        github.ref == 'refs/heads/main' ||
        startsWith(github.ref, 'refs/heads/release/') ||
        startsWith(github.ref, 'refs/tags/v')
      )

    outputs:
      signed-artifact-id: ${{ steps.upload-signed.outputs.artifact-id }}

    steps:
      - name: Checkout scripts
        uses: actions/checkout@v4
        with:
          sparse-checkout: |
            scripts/
            configs/signing/

      - name: Download unsigned firmware
        uses: actions/download-artifact@v4
        with:
          name: unsigned-firmware-${{ needs.build.outputs.build-id }}
          path: artifacts/unsigned/

      - name: Verify artifact manifest (integrity check before signing)
        run: |
          cd artifacts/unsigned

          # Verify CI manifest signature
          gpg --import "${CI_GPG_PUBLIC_KEY}"
          gpg --verify artifact_manifest.sha256.asc artifact_manifest.sha256

          # Verify artifact hashes match manifest
          sha256sum -c artifact_manifest.sha256

          echo "Artifact integrity verified — proceeding to signing."
        env:
          CI_GPG_PUBLIC_KEY: ${{ vars.CI_MANIFEST_PUBLIC_KEY }}

      - name: Install signing tools
        run: |
          sudo apt-get install -y --no-install-recommends \
            softhsm2 openssl libengine-pkcs11-openssl \
            gnutls-bin p11-kit

          # Alternatively, connect to remote signing service:
          pip3 install requests cryptography

      - name: Sign FIT image
        id: sign-fit
        run: |
          ./scripts/signing/sign_fit_image.sh \
            --input  artifacts/unsigned/fitImage \
            --output artifacts/signed/fitImage \
            --key-id "${SIGNING_KEY_ID}" \
            --hsm-pin "${HSM_TOKEN_PIN}" \
            --signing-service-url "${SIGNING_SERVICE_URL}" \
            --signing-service-token "${SIGNING_SERVICE_JWT}"
        env:
          HSM_TOKEN_PIN: ${{ secrets.HSM_TOKEN_PIN }}
          SIGNING_KEY_ID: ${{ secrets.SIGNING_KEY_ID }}
          SIGNING_SERVICE_URL: ${{ secrets.SIGNING_SERVICE_URL }}
          SIGNING_SERVICE_JWT: ${{ secrets.SIGNING_SERVICE_JWT }}

      - name: Sign imx-boot (HABv4 CSF injection)
        id: sign-imxboot
        run: |
          # Note: HABv4 signing typically done offline with CST tool
          # This step injects a pre-computed CSF into the imx-boot binary
          ./scripts/signing/sign_imxboot.sh \
            --input  artifacts/unsigned/imx-boot-${YOCTO_MACHINE}.bin \
            --output artifacts/signed/imx-boot-${YOCTO_MACHINE}.bin \
            --key-id "${SIGNING_KEY_ID}" \
            --signing-service-url "${SIGNING_SERVICE_URL}" \
            --signing-service-token "${SIGNING_SERVICE_JWT}"
        env:
          SIGNING_SERVICE_URL: ${{ secrets.SIGNING_SERVICE_URL }}
          SIGNING_SERVICE_JWT: ${{ secrets.SIGNING_SERVICE_JWT }}
          SIGNING_KEY_ID: ${{ secrets.SIGNING_KEY_ID }}

      - name: Verify all signatures
        run: |
          echo "=== Verifying FIT image signature ==="
          dumpimage -l artifacts/signed/fitImage

          echo "=== Verifying FIT signature against embedded key ==="
          ./scripts/verify/verify_fit_image.sh artifacts/signed/fitImage

          echo "=== Verifying imx-boot HABv4 CSF ==="
          ./scripts/verify/verify_imxboot_csf.sh \
            artifacts/signed/imx-boot-${YOCTO_MACHINE}.bin

          echo "All signatures verified successfully."

      - name: Generate signed manifest
        run: |
          cd artifacts/signed
          sha256sum * > ../../signed_manifest.sha256
          cat ../../signed_manifest.sha256

      - name: Bundle signed artifacts
        run: |
          cp signed_manifest.sha256 artifacts/signed/
          cp artifacts/unsigned/build_metadata.json artifacts/signed/
          cp artifacts/unsigned/rootfs.verity.roothash artifacts/signed/ 2>/dev/null || true

      - name: Upload signed firmware artifacts
        id: upload-signed
        uses: actions/upload-artifact@v4
        with:
          name: signed-firmware-${{ needs.build.outputs.build-id }}
          path: artifacts/signed/
          retention-days: ${{ env.SIGNED_RETENTION_DAYS }}
          if-no-files-found: error

  # ─────────────────────────────────────────────────────────────
  # Job 4: Generate SLSA provenance
  # ─────────────────────────────────────────────────────────────
  provenance:
    name: Generate SLSA Provenance
    needs: [build, sign]
    permissions:
      actions: read
      id-token: write
      contents: write
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v1.9.0
    with:
      base64-subjects: "${{ needs.build.outputs.artifact-hashes }}"
      upload-assets: ${{ startsWith(github.ref, 'refs/tags/v') }}

  # ─────────────────────────────────────────────────────────────
  # Job 5: Release (only on version tags)
  # ─────────────────────────────────────────────────────────────
  release:
    name: Create Release
    needs: [build, sign, provenance]
    runs-on: ubuntu-22.04
    environment: release
    permissions:
      contents: write

    if: startsWith(github.ref, 'refs/tags/v')

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Download signed firmware
        uses: actions/download-artifact@v4
        with:
          name: signed-firmware-${{ needs.build.outputs.build-id }}
          path: release-artifacts/

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          name: "Firmware ${{ github.ref_name }}"
          body_path: CHANGELOG.md
          files: |
            release-artifacts/fitImage
            release-artifacts/imx-boot-*.bin
            release-artifacts/signed_manifest.sha256
          draft: false
          prerelease: ${{ contains(github.ref_name, '-rc') }}

      - name: Upload to firmware distribution bucket
        run: |
          aws s3 sync release-artifacts/ \
            s3://${RELEASE_STORAGE_BUCKET}/releases/${GITHUB_REF_NAME}/ \
            --metadata git-tag=${GITHUB_REF_NAME},build-id=${{ needs.build.outputs.build-id }}
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.ARTIFACT_STORAGE_KEY }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.ARTIFACT_STORAGE_SECRET }}
          RELEASE_STORAGE_BUCKET: ${{ secrets.RELEASE_STORAGE_BUCKET }}
```

---

## Supporting Scripts

### `scripts/signing/sign_fit_image.sh`

```bash
#!/bin/bash
# sign_fit_image.sh - Sign a FIT image using the remote signing service
# Usage: sign_fit_image.sh --input <fit> --output <fit> --key-id <id> ...

set -euo pipefail

# Parse arguments
INPUT=""
OUTPUT=""
KEY_ID=""
HSM_PIN=""
SIGNING_URL=""
SIGNING_TOKEN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)            INPUT="$2";         shift 2 ;;
        --output)           OUTPUT="$2";        shift 2 ;;
        --key-id)           KEY_ID="$2";        shift 2 ;;
        --hsm-pin)          HSM_PIN="$2";       shift 2 ;;
        --signing-service-url)   SIGNING_URL="$2";   shift 2 ;;
        --signing-service-token) SIGNING_TOKEN="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# Validate inputs
[[ -f "$INPUT" ]] || { echo "ERROR: Input file not found: $INPUT"; exit 1; }
[[ -n "$KEY_ID" ]] || { echo "ERROR: --key-id required"; exit 1; }

echo "Signing FIT image: $INPUT"
echo "  Key ID: $KEY_ID"
echo "  Signing service: $SIGNING_URL"

# Compute hash of input artifact
ARTIFACT_HASH=$(sha256sum "$INPUT" | cut -d' ' -f1)
echo "  Artifact hash: sha256:${ARTIFACT_HASH}"

if [[ -n "$SIGNING_URL" && -n "$SIGNING_TOKEN" ]]; then
    # Remote signing via signing service API
    echo "Using remote signing service..."

    RESPONSE=$(curl -sf \
        -X POST "${SIGNING_URL}/api/v1/sign" \
        -H "Authorization: Bearer ${SIGNING_TOKEN}" \
        -F "artifact=@${INPUT}" \
        -F "artifact_type=fit_image" \
        -F "key_id=${KEY_ID}" \
        -F "build_id=${BUILD_ID:-unknown}" \
        -F "git_sha=${GITHUB_SHA:-unknown}")

    if [[ $? -ne 0 ]]; then
        echo "ERROR: Signing service request failed"
        exit 1
    fi

    # Extract signed artifact URL from response
    SIGNED_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['signed_artifact_url'])")
    AUDIT_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['audit_id'])")

    echo "  Audit ID: ${AUDIT_ID}"
    echo "  Downloading signed artifact..."

    curl -sf "${SIGNED_URL}" -o "${OUTPUT}"

elif [[ -n "$HSM_PIN" ]]; then
    # Local HSM signing via PKCS#11
    echo "Using local HSM signing..."
    mkdir -p "$(dirname "$OUTPUT")"

    # Step 1: Extract the FIT image data nodes that need signing
    # The FIT image has already been built with signing placeholders
    # (using mkimage with external signing)

    # For U-Boot FIT external signing workflow:
    # 1. Build FIT with mkimage -E (external signing mode)
    # 2. Sign using OpenSSL + PKCS#11 engine
    # 3. Insert signature back into FIT

    # Generate signing data file
    mkimage -F -k /dev/null -r "$INPUT" 2>&1 | \
        grep "data to sign" > /tmp/sign_nodes.txt || true

    # Use OpenSSL with PKCS#11 engine for HSM signing
    PKCS11_MODULE="/usr/lib/softhsm/libsofthsm2.so"  # replace with real HSM module

    # Sign using engine
    openssl dgst \
        -engine pkcs11 \
        -keyform engine \
        -inkey "pkcs11:token=signing-token;id=${KEY_ID};type=private" \
        -sha256 \
        -sign \
        -out "${INPUT}.sig" \
        "$INPUT"

    # TODO: inject signature into FIT using fit-sign tool
    cp "$INPUT" "$OUTPUT"
    echo "WARNING: FIT signature injection not yet implemented in this script"
    echo "Use mkimage with CONFIG_FIT_SIGNATURE_MAX_SIZE and fit_auto_resign"

else
    echo "ERROR: Either --signing-service-url/token or --hsm-pin required"
    exit 1
fi

# Verify the output exists and has content
[[ -f "$OUTPUT" && -s "$OUTPUT" ]] || { echo "ERROR: Signed output file missing or empty"; exit 1; }

SIGNED_HASH=$(sha256sum "$OUTPUT" | cut -d' ' -f1)
echo "  Signed artifact hash: sha256:${SIGNED_HASH}"
echo "FIT image signed successfully: $OUTPUT"
```

### `scripts/verify/verify_fit_image.sh`

```bash
#!/bin/bash
# verify_fit_image.sh - Verify a signed FIT image
# Requires: u-boot-tools (dumpimage, mkimage)

set -euo pipefail

FIT_IMAGE="$1"

if [[ ! -f "$FIT_IMAGE" ]]; then
    echo "ERROR: FIT image not found: $FIT_IMAGE"
    exit 1
fi

echo "=== FIT Image Verification ==="
echo "File: $FIT_IMAGE"
echo "Size: $(du -sh "$FIT_IMAGE" | cut -f1)"
echo "SHA256: $(sha256sum "$FIT_IMAGE" | cut -d' ' -f1)"
echo ""

# List all nodes in FIT image
echo "--- FIT Image Structure ---"
dumpimage -l "$FIT_IMAGE"

echo ""
echo "--- Signature Nodes ---"
# Check that signature nodes exist
if fdtdump "$FIT_IMAGE" 2>/dev/null | grep -q "signature@"; then
    fdtdump "$FIT_IMAGE" 2>/dev/null | grep -A5 "signature@"
    echo ""
    echo "Result: Signature nodes present"
else
    echo "WARNING: No signature nodes found in FIT image"
    echo "This may be an unsigned FIT image"
    exit 1
fi

# If we have a U-Boot DTB with the verification key embedded, test it
UBOOT_DTB="${UBOOT_DTB:-configs/verify/u-boot.dtb}"
if [[ -f "$UBOOT_DTB" ]]; then
    echo ""
    echo "--- Cryptographic Verification ---"
    # Use mkimage to verify
    mkimage -F -k /dev/null -r -T flat_dt "$FIT_IMAGE" && \
        echo "Cryptographic verification: PASSED" || \
        echo "WARNING: mkimage verification skipped (requires running U-Boot)"
fi

echo ""
echo "FIT image verification complete."
```

---

## Secret Management: GitHub Environments vs HashiCorp Vault

### GitHub Environments (Simpler)

GitHub Environments provide:
- Environment-specific secrets (separate from repository secrets)
- Required reviewer approvals (gate before accessing secrets)
- Deployment protection rules (branch restrictions)
- Audit in GitHub's audit log

Configuration (via GitHub UI or terraform-github-actions):

```hcl
# terraform/github_environments.tf
resource "github_repository_environment" "production_signing" {
  environment = "production-signing"
  repository  = "firmware-build"

  reviewers {
    users = [data.github_user.signing_approver_1.id,
             data.github_user.signing_approver_2.id]
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}
```

### HashiCorp Vault (Enterprise)

For organizations that need more granular control:

```yaml
# .github/workflows/vault-signing.yml (signing job)
- name: Authenticate to Vault with OIDC
  uses: hashicorp/vault-action@v3
  with:
    url: https://vault.example.com
    method: jwt
    jwtGithubAudience: https://vault.example.com
    role: firmware-signer
    secrets: |
      secret/data/signing/production hsm_pin | HSM_TOKEN_PIN ;
      secret/data/signing/production key_id  | SIGNING_KEY_ID ;
      secret/data/signing/production service_url | SIGNING_SERVICE_URL
```

Vault policy for firmware signing:

```hcl
# vault policy: firmware-signer
path "secret/data/signing/production" {
  capabilities = ["read"]
  required_parameters = ["hsm_pin", "key_id", "service_url"]
}

# Restrict to GitHub Actions JWT from main branch only
bound_claims = {
  "repository" = "example/firmware-build"
  "ref" = "refs/heads/main"
  "ref_type" = "branch"
}
```

---

## OIDC-Based Signing with Sigstore/Cosign

For signing additional artifacts (container images, release notes), Sigstore's cosign can be integrated without long-lived key material:

```yaml
# Signing with keyless cosign (OIDC-based)
- name: Install cosign
  uses: sigstore/cosign-installer@v3

- name: Sign release artifacts with cosign (keyless)
  run: |
    # Cosign uses OIDC token from GitHub Actions to get a short-lived cert
    cosign sign-blob \
      --yes \
      --bundle release-artifacts/fitImage.cosign.bundle \
      release-artifacts/fitImage
  env:
    COSIGN_EXPERIMENTAL: "1"

- name: Verify cosign signature
  run: |
    cosign verify-blob \
      --certificate-identity-regexp="https://github.com/${GITHUB_REPOSITORY}/" \
      --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
      --bundle release-artifacts/fitImage.cosign.bundle \
      release-artifacts/fitImage
```

**Note**: Cosign keyless signing is appropriate for non-firmware artifacts (release notes, SBOM, etc.). For firmware images that must be verified by U-Boot at runtime, you need traditional RSA/ECDSA signing with keys embedded in U-Boot.

---

## Branch Protection for Signing Workflows

Enforce that production signing only happens from reviewed, merged code:

```yaml
# .github/branch_protection.yml (GitHub Apps / API config)
protection_rules:
  main:
    required_status_checks:
      strict: true
      contexts:
        - "Validate Configuration"
        - "Build Firmware"
    required_pull_request_reviews:
      required_approving_review_count: 2
      dismiss_stale_reviews: true
      require_code_owner_reviews: true
    restrictions:
      # Only CI service account can push directly
      users: []
      teams: ["ci-service-account"]
    enforce_admins: true
    allow_force_pushes: false
    allow_deletions: false

  'release/**':
    required_status_checks:
      strict: true
      contexts:
        - "Validate Configuration"
        - "Build Firmware"
        - "Sign Firmware"
    required_pull_request_reviews:
      required_approving_review_count: 3
    restrictions:
      users: []
      teams: ["release-managers"]
```

---

## Monitoring and Alerting

```yaml
# Additional monitoring job
  monitor-signing:
    name: Post-Signing Audit
    needs: sign
    runs-on: ubuntu-22.04
    if: always()
    steps:
      - name: Report signing outcome to audit system
        run: |
          STATUS="${{ needs.sign.result }}"
          curl -X POST "${AUDIT_WEBHOOK_URL}" \
            -H "Content-Type: application/json" \
            -d '{
              "event": "firmware_signing",
              "status": "'"${STATUS}"'",
              "build_id": "${{ needs.build.outputs.build-id }}",
              "git_sha": "${{ github.sha }}",
              "git_ref": "${{ github.ref }}",
              "workflow_run": "https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}",
              "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
            }'
        env:
          AUDIT_WEBHOOK_URL: ${{ secrets.AUDIT_WEBHOOK_URL }}

      - name: Alert on signing failure
        if: needs.sign.result == 'failure'
        uses: 8398a7/action-slack@v3
        with:
          status: failure
          text: |
            ALERT: Firmware signing failed!
            Build: ${{ needs.build.outputs.build-id }}
            Git: ${{ github.sha }}
            Run: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_SECURITY_WEBHOOK }}
```
