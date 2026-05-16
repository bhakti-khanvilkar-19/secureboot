# 24 — CI/CD Signing Pipelines for Embedded Firmware

## The Security Challenge in Automated Signing

Automated build systems create an inherent tension: you want reproducible, fast builds with minimal human intervention, but signing requires protecting private keys that, if compromised, allow an attacker to create arbitrarily trusted firmware. Every CI/CD signing integration is a question of how you manage this tension.

The naive approach — put the private key in a CI/CD secret variable — is widely practiced and widely wrong. It works until it doesn't: until the secret is logged, leaked through a build artifact, exfiltrated by a compromised dependency, or exposed in a forked repository's PR run. For firmware signing, a compromised key means attackers can produce firmware that boots on every device you have ever shipped.

This chapter establishes the architecture, threat model, and implementation patterns for CI/CD signing pipelines that provide real security — not security theater.

---

## Threat Model for CI/CD

Before designing any CI/CD security control, you must enumerate what you are protecting against. The threats are different from production system threats.

### Assets

| Asset | Value | Loss Impact |
|-------|-------|-------------|
| Production firmware signing key | Enables signing any firmware for all shipped devices | Catastrophic: all shipped devices potentially compromised |
| Build system access | Enables code injection, artifact tampering | High: injected code becomes signed firmware |
| Signing history / audit log | Legal and forensic accountability | Medium: loss of accountability |
| Build artifacts (unsigned) | Pre-signing source of truth | Medium: tampering before signing |

### Threats

**T1: Compromised Build Runner (High Probability)**

An attacker who compromises the build server (via vulnerable build dependencies, malicious test code, compromised developer credentials) can:
- Access environment variables (signing keys stored as CI secrets)
- Modify build artifacts before they reach the signing step
- Exfiltrate keys that persist on the runner

Mitigation: Keys never on the build runner. Signing service is network-separated. Build runners are ephemeral.

**T2: Malicious Code Injection via Dependency Supply Chain**

Compromised npm package, Python package, or build tool that runs during build can:
- Exfiltrate secrets from the build environment
- Modify compiled artifacts before they are archived

Mitigation: Dependency pinning with hash verification. Hermetic builds. Artifact hash verification before signing.

**T3: Pipeline Configuration Injection (YAML Injection)**

In GitHub Actions, user-controlled input in workflow YAML can execute arbitrary commands. A malicious pull request could modify the pipeline to exfiltrate signing credentials.

Mitigation: Never run production signing on PR branches. Separate signing workflows require environment approvals. No user-controlled input in signing steps.

**T4: Artifact Tampering Between Build and Sign**

An attacker with access to the artifact storage (e.g., S3 bucket) can swap unsigned artifacts before the signing step processes them.

Mitigation: Artifact hash locked at build completion, verified before signing. Artifact storage with write-once semantics (S3 Object Lock) or content-addressed storage.

**T5: Signing Key Exfiltration from Signing Service**

An attacker who compromises the signing service itself can extract the signing key.

Mitigation: HSM-backed keys that cannot be extracted. Signing service runs in isolated network segment. Physical HSM requires physical compromise.

**T6: Insider Threat (Authorized User Misuse)**

A malicious or coerced engineer with legitimate access signs unauthorized firmware.

Mitigation: Mandatory two-person review for production builds. Audit logging of all signing operations. Rate limiting and anomaly detection.

**T7: Unauthorized Branch / Tag Signing**

Production signing triggered on development branches or from unreviewed code.

Mitigation: Signing restricted to specific branch patterns (`main`, `release/*`, version tags). Branch protection rules require review. Signing environment requires human approval (GitHub Environments).

---

## Secure CI/CD Architecture Principles

### Principle 1: Separate Build from Sign

Build runners have broad access to the codebase, network, and dependencies. They should never have signing key access. The signing function should be isolated as a separate service:

```
Developer ──push──▶ Git Repository
                           │
                    ┌──────▼──────┐
                    │ Build Runner│  (ephemeral, untrusted)
                    │ (no keys)   │
                    └──────┬──────┘
                           │ upload unsigned artifact + hash
                    ┌──────▼──────┐
                    │  Artifact   │  (content-addressed, immutable)
                    │  Storage    │
                    └──────┬──────┘
                           │ hash verification
                    ┌──────▼──────┐
                    │   Signing   │  (isolated network, HSM-backed)
                    │   Service   │
                    └──────┬──────┘
                           │ signed artifact
                    ┌──────▼──────┐
                    │  Release    │  (immutable, hash-pinned)
                    │  Storage    │
                    └─────────────┘
```

### Principle 2: Ephemeral Build Environments

Build runners should:
- Start fresh for every build (no persistent state that could be poisoned)
- Have minimal permissions (read source, write to artifact storage only)
- Be destroyed after the build completes
- Not persist secrets between runs

GitHub Actions' hosted runners are ephemeral by design. Self-hosted runners should use Docker or VM snapshots.

### Principle 3: Artifact Integrity Lock

As soon as build artifacts are produced, compute and record their cryptographic hashes. All downstream steps verify against these hashes:

```bash
# At build completion:
sha256sum \
  build/deploy/images/phyboard-pollux-imx8mp-3/fitImage \
  build/deploy/images/phyboard-pollux-imx8mp-3/imx-boot-phyboard-pollux-imx8mp-3.bin \
  > build_manifest_${BUILD_ID}.sha256

# Sign the manifest itself (with a CI-specific key, not the production key):
gpg --armor --detach-sign build_manifest_${BUILD_ID}.sha256

# At signing step (separate runner):
gpg --verify build_manifest_${BUILD_ID}.sha256.asc
sha256sum -c build_manifest_${BUILD_ID}.sha256
```

### Principle 4: Immutable Audit Log

Every signing operation must be recorded in an append-only, tamper-evident log:

```json
{
  "event": "sign",
  "timestamp": "2024-01-15T10:30:00Z",
  "artifact_type": "fit_image",
  "artifact_hash": "sha256:abc123...",
  "artifact_path": "s3://firmware-releases/phyboard/20240115-1234/fitImage",
  "requestor": "github-actions/release-build@main",
  "build_id": "github-run-123456789",
  "git_sha": "a1b2c3d4...",
  "git_tag": "v2.1.0",
  "signed_artifact_hash": "sha256:def456...",
  "signing_key_id": "production-rsa4096-2024",
  "audit_id": "sign-20240115-0842"
}
```

Append-only storage options: AWS CloudTrail, Azure Monitor Logs, custom append-only S3 bucket (Object Lock compliance mode), append-only PostgreSQL table with triggers.

### Principle 5: Secret Management

Signing service credentials (HSM PIN, service account token) must be managed by a secrets manager, not stored in CI/CD variables:

- **HashiCorp Vault**: Dynamic secrets, audit log, policy-based access
- **AWS Secrets Manager**: IAM-based access, rotation support
- **GitHub Environments**: Built-in to GitHub Actions, environment-level secrets with required approvals
- **Azure Key Vault**: Managed HSM with FIPS 140-2 Level 3

### Principle 6: SLSA Framework Compliance

SLSA (Supply-chain Levels for Software Artifacts) provides a framework for measuring supply chain integrity:

| SLSA Level | Requirements | Applicability |
|-----------|-------------|---------------|
| L0 | None | No controls |
| L1 | Signed provenance | Build produces provenance document |
| L2 | Signed provenance + hosted build | Build on hosted platform (GitHub Actions) |
| L3 | Hardened builds + non-forgeable provenance | Ephemeral build, non-falsifiable provenance |
| L4 | Two-party review + hermetic builds | Full hermetic build, mandatory review |

For firmware signing, aim for **SLSA Level 3**:
- Builds run on GitHub Actions (or equivalent hosted CI) with ephemeral runners: L2
- Build scripts are version-controlled and protected by branch policies
- Build produces a signed SLSA provenance document
- Build is declared in a protected pipeline file, not in user-controlled code

**SLSA L3 provenance document for firmware:**

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/provenance/v0.2",
  "subject": [
    {
      "name": "fitImage",
      "digest": {
        "sha256": "a1b2c3d4e5f6..."
      }
    }
  ],
  "predicate": {
    "builder": {
      "id": "https://github.com/actions/runner/releases/tag/v2.311.0"
    },
    "buildType": "https://github.com/slsa-framework/slsa-github-generator/tree/main/internal/builders/generic@v1",
    "invocation": {
      "configSource": {
        "uri": "git+https://github.com/example/firmware@refs/heads/main",
        "digest": {"sha1": "a1b2c3d4..."},
        "entryPoint": ".github/workflows/secure-build.yml"
      }
    },
    "materials": [
      {
        "uri": "git+https://github.com/example/firmware",
        "digest": {"sha1": "a1b2c3d4..."}
      }
    ]
  }
}
```

---

## Signing Proxy Pattern

The signing proxy decouples the signing capability from the build infrastructure. CI runners build and submit artifacts for signing; they cannot sign themselves.

```
┌─────────────────────────────────────────────────────────────────┐
│                     CI Network (untrusted)                      │
│                                                                 │
│  ┌─────────────┐         ┌────────────────────────────────┐     │
│  │ Build Runner│────────▶│     Signing Proxy (API)        │     │
│  │             │  HTTPS  │  - Validates artifact hash     │     │
│  │  No keys    │  mTLS   │  - Checks build authorization  │     │
│  └─────────────┘         │  - Writes to audit log         │     │
│                           └──────────────┬─────────────────┘     │
└──────────────────────────────────────────┼──────────────────────┘
                                           │ PKCS#11
                         ┌─────────────────▼──────────────────────┐
                         │      Signing Network (isolated)        │
                         │                                        │
                         │  ┌──────────────┐  ┌───────────────┐   │
                         │  │  Signing     │  │  HSM          │   │
                         │  │  Service     │◀─│  (private key)│   │
                         │  │  (PKCS#11)   │  │               │   │
                         │  └──────────────┘  └───────────────┘   │
                         └────────────────────────────────────────┘
```

The signing proxy:
1. Receives signing requests with artifact hash + metadata
2. Validates: Is the requestor authorized? Is the artifact within expected size/type bounds?
3. Fetches artifact from content-addressed storage and re-verifies hash
4. Calls signing service via PKCS#11 (key never leaves HSM)
5. Returns signature + signed artifact URL
6. Writes immutable audit record

---

## Jenkins Signing Pipeline

For organizations using Jenkins, the signing pipeline pattern with a separate signing node:

```groovy
// Jenkinsfile
pipeline {
    agent none

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
    }

    stages {
        stage('Build') {
            agent {
                docker {
                    image 'crops/poky:latest'
                    label 'build-worker'
                    args '--privileged -v /build-cache:/build-cache'
                }
            }
            steps {
                sh '''
                    source oe-init-build-env build
                    bitbake phytec-securiphy-image
                '''
                // Archive artifacts with hash
                sh 'sha256sum build/deploy/images/**/*.{bin,fitImage} > build_manifest.sha256'
                archiveArtifacts artifacts: 'build/deploy/images/**/*'
                archiveArtifacts artifacts: 'build_manifest.sha256'
                stash name: 'artifacts', includes: 'build/deploy/images/**/*,build_manifest.sha256'
            }
        }

        stage('Sign') {
            // Signing agent: network-isolated, HSM-connected
            agent { label 'hsm-signing-node' }
            environment {
                HSM_PIN = credentials('hsm-production-pin')
                SIGNING_KEY_ID = credentials('production-key-id')
            }
            when {
                anyOf {
                    branch 'main'
                    branch 'release/*'
                    tag pattern: /v\d+\.\d+\.\d+/, comparator: "REGEXP"
                }
            }
            steps {
                unstash 'artifacts'

                // Verify artifact integrity before signing
                sh 'sha256sum -c build_manifest.sha256'

                // Sign using PKCS#11 HSM
                sh '''
                    pkcs11-tool \
                        --module /usr/lib/softhsm/libsofthsm2.so \
                        --login --pin "${HSM_PIN}" \
                        --sign --mechanism SHA256-RSA-PKCS \
                        --id "${SIGNING_KEY_ID}" \
                        --input-file build/deploy/images/phyboard-pollux-imx8mp-3/fitImage.unsigned \
                        --output-file fitImage.sig

                    # Embed signature in FIT image
                    ./scripts/embed_fit_signature.sh \
                        build/deploy/images/phyboard-pollux-imx8mp-3/fitImage.unsigned \
                        fitImage.sig \
                        fitImage.signed
                '''

                // Verify signature before archiving
                sh './scripts/verify_fit_signature.sh fitImage.signed'

                archiveArtifacts artifacts: 'fitImage.signed'
            }
        }

        stage('Publish') {
            agent { label 'hsm-signing-node' }
            when {
                tag pattern: /v\d+\.\d+\.\d+/, comparator: "REGEXP"
            }
            steps {
                // Upload to release storage
                sh '''
                    aws s3 cp fitImage.signed \
                        s3://firmware-releases/${BUILD_TAG}/fitImage \
                        --metadata build-id=${BUILD_NUMBER},git-tag=${TAG_NAME}
                '''
            }
        }
    }

    post {
        always {
            // Clean workspace (remove any credential artifacts)
            cleanWs()
        }
    }
}
```

---

## Key Rotation Without Pipeline Changes

Key rotation — replacing the production signing key with a new one — must be possible without modifying pipeline code. The signing service provides this abstraction:

```
Pipeline calls:  POST /api/v1/sign?artifact_type=fit_image
Signing service internally resolves: "fit_image" → current-active-key → HSM slot

Key rotation:
  1. Generate new key in HSM (offline ceremony)
  2. Update signing service config: active_key = new_key_id
  3. Old key remains available for verification of old artifacts
  4. Pipeline code does NOT change
  5. Devices must be updated with new verification key (firmware update)

Transition period:
  - Old devices: verify with old key
  - New devices: verify with new key
  - Transition firmware signed by BOTH keys (FIT supports multiple signatures)
```

### Key ID Abstraction in Signing Service

```yaml
# /etc/signing-service/keys.yaml
keys:
  fit-image-signing:
    current: fit-signing-rsa4096-2024
    previous: fit-signing-rsa4096-2022
    algorithm: RSA-4096
    digest: SHA-256

  spl-signing:
    current: hab-srk1-2024
    previous: null
    algorithm: RSA-2048
    digest: SHA-256

key-slots:
  fit-signing-rsa4096-2024:
    hsm_slot: 1
    hsm_label: "fit-signing-2024"
    pkcs11_module: /usr/lib/libCryptoki2_64.so

  fit-signing-rsa4096-2022:
    hsm_slot: 2
    hsm_label: "fit-signing-2022"
    pkcs11_module: /usr/lib/libCryptoki2_64.so
```

---

## SLSA Level 3 for Embedded Firmware

Achieving SLSA L3 for embedded firmware requires:

1. **Non-forgeable provenance**: The build system (not the developer) generates the provenance document. In GitHub Actions, this is provided by the `slsa-framework/slsa-github-generator` action.

2. **Isolated build**: Build runs in a fresh environment, cannot modify pipeline configuration.

3. **Source revision tracked**: Every build artifact is linked to a specific git commit hash.

4. **No persistent credential access**: Build runners have no access to signing keys.

Implementation for firmware:

```yaml
# .github/workflows/slsa-firmware.yml
name: SLSA Firmware Build

on:
  push:
    tags: ['v*']

permissions:
  id-token: write    # Required for OIDC
  contents: read
  actions: read

jobs:
  build:
    outputs:
      hashes: ${{ steps.hash.outputs.hashes }}
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4

      - name: Build firmware
        run: |
          # Your Yocto build or equivalent
          make firmware

      - name: Generate hash
        id: hash
        run: |
          sha256sum fitImage imx-boot.bin > hashes.txt
          echo "hashes=$(cat hashes.txt | base64 -w0)" >> $GITHUB_OUTPUT

      - uses: actions/upload-artifact@v4
        with:
          name: firmware
          path: |
            fitImage
            imx-boot.bin
            hashes.txt

  provenance:
    needs: [build]
    permissions:
      actions: read
      id-token: write
      contents: write
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v1.9.0
    with:
      base64-subjects: "${{ needs.build.outputs.hashes }}"
      upload-assets: true  # Upload provenance to release

  sign:
    needs: [build, provenance]
    runs-on: ubuntu-22.04
    environment: production-signing
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: firmware

      - name: Sign with HSM
        run: |
          # Sign artifacts — keys managed by signing service, not in this runner
          curl -X POST https://signing-service.example.com/api/v1/sign \
            -H "Authorization: Bearer ${SIGNING_JWT}" \
            -F "artifact=@fitImage" \
            -F "artifact_type=fit_image" \
            -F "build_id=${GITHUB_RUN_ID}" \
            -F "git_sha=${GITHUB_SHA}" \
            > signed_fitImage
        env:
          SIGNING_JWT: ${{ secrets.SIGNING_SERVICE_JWT }}
```

---

## Further Reading

- [01-github-actions-pipeline.md](./01-github-actions-pipeline.md) — Complete GitHub Actions secure build workflow
- [02-signing-service-design.md](./02-signing-service-design.md) — Signing microservice architecture and API
- SLSA framework: https://slsa.dev
- Sigstore project: https://sigstore.dev (primarily software, applicable patterns)
- NIST SP 800-204D: Strategies for the Integration of Software Supply Chain Security in DevSecOps CI/CD Pipelines
