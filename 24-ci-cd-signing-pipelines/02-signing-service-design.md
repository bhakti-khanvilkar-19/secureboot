# Signing Service Architecture

## Design Principles

1. **Separation**: Build infrastructure never touches private keys
2. **Authentication**: Every signing request is authenticated and authorized
3. **Audit**: Every signing operation is logged with full metadata
4. **HSM-backed**: Private keys stored in Hardware Security Module
5. **Rate-limited**: Prevents key abuse
6. **Async**: Large firmware signing is asynchronous

## Architecture Overview

```
CI/CD Pipeline                    Signing Service
     │                                  │
     │  1. Build unsigned artifacts      │
     │  2. Compute artifact hash         │
     │  3. Request signature via API ──▶ │
     │                                  │ 4. Verify requester identity (JWT/mTLS)
     │                                  │ 5. Check authorization (artifact type, branch)
     │                                  │ 6. Log request to audit trail
     │                                  │ 7. Send to HSM for signing
     │                                  │ 8. Receive signature from HSM
     │  9. Receive signature     ◀────  │ 9. Log completion
     │  10. Embed signature in artifact  │
     │  11. Upload to artifact store     │
```

## REST API Design

Base URL: `https://signing.internal.company.com/api/v1`

### POST /sign/fit-image

Signs a FIT image by fetching it from the artifact store, computing its hash,
delegating to the HSM backend, and returning the signature along with a signed
artifact URL.

Request:
```json
{
  "artifact_type": "fit_image",
  "artifact_hash": "sha256:abc123def456...",
  "artifact_url": "s3://internal-builds/job-1234/fitImage",
  "requestor": {
    "ci_job_id": "github-actions-1234",
    "git_commit": "abc123",
    "git_branch": "release/2.0",
    "build_timestamp": "2024-01-16T10:23:45Z"
  },
  "signing_key_id": "fit-production-key-2024",
  "target_platform": "phyboard-pollux-imx8mp-3"
}
```

Response:
```json
{
  "status": "success",
  "audit_id": "sign-2024-0116-001234",
  "signature": {
    "algorithm": "sha256,rsa2048",
    "value": "<base64-encoded-signature>",
    "certificate": "<PEM certificate>",
    "timestamp": "2024-01-16T10:23:47Z"
  },
  "signed_artifact_url": "s3://internal-builds/job-1234/fitImage-signed",
  "artifact_hash_after": "sha256:fedcba987654..."
}
```

### POST /sign/hab-csf

For HABv4 CSF generation and signing.

Request:
```json
{
  "artifact_type": "hab_csf",
  "artifact_url": "s3://internal-builds/job-1234/flash.bin",
  "artifact_hash": "sha256:deadbeef...",
  "requestor": {
    "ci_job_id": "github-actions-1234",
    "git_commit": "abc123",
    "git_branch": "release/2.0",
    "build_timestamp": "2024-01-16T10:23:45Z"
  },
  "signing_key_id": "srk-production-2024",
  "csf_template": "s3://csf-templates/imx8mp-spl.csf",
  "target_platform": "phyboard-pollux-imx8mp-3",
  "load_address": "0x7E1000",
  "ivt_offset": "0x400"
}
```

Response:
```json
{
  "status": "success",
  "audit_id": "sign-2024-0116-001235",
  "csf_binary_url": "s3://internal-builds/job-1234/flash.csf",
  "signed_artifact_url": "s3://internal-builds/job-1234/flash-signed.bin",
  "artifact_hash_after": "sha256:aabbccdd..."
}
```

### POST /sign/swupdate

Signs a SWUpdate `.swu` package using a CMS (PKCS#7) signature.

Request:
```json
{
  "artifact_type": "swupdate",
  "artifact_url": "s3://internal-builds/job-1234/update.swu",
  "artifact_hash": "sha256:11223344...",
  "requestor": {
    "ci_job_id": "github-actions-1234",
    "git_commit": "abc123",
    "git_branch": "release/2.0",
    "build_timestamp": "2024-01-16T10:23:45Z"
  },
  "signing_key_id": "swupdate-production-2024",
  "sw_version": "2.0.1",
  "min_version": "1.5.0"
}
```

### GET /sign/{job_id}/status

Poll for async signing job status. Used when the artifact is large (>500 MB)
and signing is performed asynchronously.

```json
{
  "job_id": "async-sign-2024-0116-001236",
  "status": "pending|running|complete|failed",
  "progress_pct": 75,
  "audit_id": "sign-2024-0116-001236",
  "result_url": "s3://internal-builds/job-1234/fitImage-signed"
}
```

### GET /audit/{audit_id}

Retrieve the full audit record for a completed signing operation.

```json
{
  "audit_id": "sign-2024-0116-001234",
  "timestamp": "2024-01-16T10:23:47Z",
  "artifact_type": "fit_image",
  "artifact_hash_before": "sha256:abc123...",
  "artifact_hash_after": "sha256:fedcba...",
  "signing_key_id": "fit-production-key-2024",
  "requestor": {
    "ci_job_id": "github-actions-1234",
    "git_commit": "abc123",
    "git_branch": "release/2.0",
    "identity": "repo:acme/firmware:ref:refs/heads/release/2.0"
  },
  "authorization_decision": "allowed",
  "authorization_policy": "release-branch-fit-production",
  "hsm_slot": "slot-0",
  "duration_ms": 342,
  "status": "success"
}
```

### GET /keys

List available signing keys (no private key material returned):

```json
{
  "keys": [
    {
      "key_id": "fit-production-key-2024",
      "algorithm": "rsa2048",
      "purpose": "fit_image",
      "created": "2024-01-01T00:00:00Z",
      "expires": "2026-01-01T00:00:00Z",
      "allowed_branches": ["release/*", "main"],
      "certificate_fingerprint": "SHA256:abc123..."
    },
    {
      "key_id": "srk-production-2024",
      "algorithm": "rsa4096",
      "purpose": "hab_csf",
      "created": "2024-01-01T00:00:00Z",
      "expires": "2034-01-01T00:00:00Z",
      "allowed_branches": ["release/*"],
      "certificate_fingerprint": "SHA256:def456..."
    }
  ]
}
```

## Authentication

### Option 1: OIDC + JWT (GitHub Actions native)

GitHub Actions provides a short-lived OIDC token for each job. The token
includes the repository name, branch, and workflow identity. The signing
service validates the token against GitHub's OIDC endpoint.

```yaml
# .github/workflows/build-and-sign.yml
jobs:
  sign:
    permissions:
      id-token: write   # Required for OIDC token issuance
      contents: read

    steps:
      - name: Get OIDC signing token
        uses: actions/github-script@v7
        with:
          script: |
            const token = await core.getIDToken('signing.internal.company.com')
            core.setSecret(token)
            core.exportVariable('SIGNING_JWT', token)

      - name: Compute artifact hash
        run: |
          HASH=$(sha256sum build/fitImage | awk '{print $1}')
          echo "ARTIFACT_HASH=sha256:${HASH}" >> $GITHUB_ENV

      - name: Upload artifact for signing
        run: |
          aws s3 cp build/fitImage s3://internal-builds/${GITHUB_RUN_ID}/fitImage

      - name: Request signature
        run: |
          cat > signing-request.json <<EOF
          {
            "artifact_type": "fit_image",
            "artifact_hash": "${ARTIFACT_HASH}",
            "artifact_url": "s3://internal-builds/${GITHUB_RUN_ID}/fitImage",
            "requestor": {
              "ci_job_id": "${GITHUB_RUN_ID}",
              "git_commit": "${GITHUB_SHA}",
              "git_branch": "${GITHUB_REF_NAME}",
              "build_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            },
            "signing_key_id": "fit-production-key-2024",
            "target_platform": "phyboard-pollux-imx8mp-3"
          }
          EOF

          RESPONSE=$(curl -s -X POST \
            https://signing.internal.company.com/api/v1/sign/fit-image \
            -H "Authorization: Bearer ${SIGNING_JWT}" \
            -H "Content-Type: application/json" \
            -d @signing-request.json)

          echo "${RESPONSE}" | jq .
          SIGNED_URL=$(echo "${RESPONSE}" | jq -r '.signed_artifact_url')
          echo "SIGNED_ARTIFACT_URL=${SIGNED_URL}" >> $GITHUB_ENV

      - name: Download signed artifact
        run: |
          aws s3 cp "${SIGNED_ARTIFACT_URL}" build/fitImage-signed
```

JWT claims checked by signing service:
```python
# signing_service/auth/oidc_validator.py
import jwt
import requests

GITHUB_JWKS_URL = "https://token.actions.githubusercontent.com/.well-known/jwks"
ALLOWED_REPOSITORIES = ["acme/firmware", "acme/bsp"]

def validate_github_oidc(token: str, audience: str) -> dict:
    """Validate a GitHub Actions OIDC JWT token."""
    # Fetch GitHub's public keys
    jwks = requests.get(GITHUB_JWKS_URL).json()

    # Decode and validate
    claims = jwt.decode(
        token,
        jwks,
        algorithms=["RS256"],
        audience=audience,
        options={"verify_exp": True}
    )

    # Check repository allowlist
    repo = claims.get("repository")
    if repo not in ALLOWED_REPOSITORIES:
        raise ValueError(f"Repository {repo} not allowed to sign")

    return claims
```

### Option 2: mTLS (mutual TLS)

Each CI worker gets a client certificate from internal PKI.
Signing service verifies client certificate against internal CA.
Useful for self-hosted runners or on-premise Jenkins environments.

```bash
# Generate CI worker client certificate
openssl genrsa -out ci-worker-01.key 2048
openssl req -new -key ci-worker-01.key \
  -subj "/CN=ci-worker-01/OU=CI/O=Acme" \
  -out ci-worker-01.csr

# Sign with internal CA
openssl x509 -req -in ci-worker-01.csr \
  -CA internal-ca.crt -CAkey internal-ca.key \
  -CAcreateserial \
  -days 365 \
  -out ci-worker-01.crt

# Use in curl
curl -X POST https://signing.internal.company.com/api/v1/sign/fit-image \
  --cert ci-worker-01.crt \
  --key ci-worker-01.key \
  --cacert internal-ca.crt \
  -H "Content-Type: application/json" \
  -d @signing-request.json
```

Nginx mTLS configuration for signing service:
```nginx
server {
    listen 443 ssl;
    server_name signing.internal.company.com;

    ssl_certificate     /etc/ssl/server.crt;
    ssl_certificate_key /etc/ssl/server.key;

    # Require client certificates from internal CA
    ssl_client_certificate /etc/ssl/internal-ca.crt;
    ssl_verify_client      on;
    ssl_verify_depth       2;

    # Pass client cert DN to upstream
    proxy_set_header X-Client-Cert-Subject $ssl_client_s_dn;
    proxy_set_header X-Client-Cert-Issuer  $ssl_client_i_dn;
    proxy_set_header X-Client-Verify       $ssl_client_verify;

    location /api/ {
        proxy_pass http://signing-service-backend:8080;
    }
}
```

## Authorization Policy

Authorization is checked after authentication. Policies are stored as YAML
and loaded at startup.

```yaml
# signing_service/policies/production.yaml
policies:
  - name: release-branch-fit-production
    description: "Release branches can sign FIT images with production key"
    artifact_types:
      - fit_image
    key_ids:
      - fit-production-key-2024
    conditions:
      git_branch:
        pattern: "^release/.*$"
      repository:
        allowlist:
          - "acme/firmware"
          - "acme/bsp"
    rate_limit:
      requests_per_hour: 50
      requests_per_day: 200

  - name: main-branch-fit-staging
    description: "Main branch can sign FIT images with staging key only"
    artifact_types:
      - fit_image
    key_ids:
      - fit-staging-key-2024
    conditions:
      git_branch:
        exact: "main"
      repository:
        allowlist:
          - "acme/firmware"
    rate_limit:
      requests_per_hour: 100
      requests_per_day: 500

  - name: hab-csf-release-only
    description: "HAB CSF signing restricted to release branches"
    artifact_types:
      - hab_csf
    key_ids:
      - srk-production-2024
    conditions:
      git_branch:
        pattern: "^release/.*$"
      repository:
        allowlist:
          - "acme/firmware"
    rate_limit:
      requests_per_hour: 10
      requests_per_day: 50
```

Policy enforcement in Python:
```python
# signing_service/auth/policy_engine.py
import re
import yaml
from dataclasses import dataclass
from typing import Optional

@dataclass
class SigningRequest:
    artifact_type: str
    signing_key_id: str
    git_branch: str
    repository: str
    requestor_identity: str

class PolicyEngine:
    def __init__(self, policy_file: str):
        with open(policy_file) as f:
            data = yaml.safe_load(f)
        self.policies = data["policies"]

    def evaluate(self, request: SigningRequest) -> tuple[bool, Optional[str]]:
        """Returns (allowed, policy_name_matched)."""
        for policy in self.policies:
            if self._matches(policy, request):
                return True, policy["name"]
        return False, None

    def _matches(self, policy: dict, request: SigningRequest) -> bool:
        # Check artifact type
        if request.artifact_type not in policy["artifact_types"]:
            return False

        # Check key ID
        if request.signing_key_id not in policy["key_ids"]:
            return False

        conditions = policy.get("conditions", {})

        # Check branch
        branch_cond = conditions.get("git_branch", {})
        if "exact" in branch_cond:
            if request.git_branch != branch_cond["exact"]:
                return False
        if "pattern" in branch_cond:
            if not re.match(branch_cond["pattern"], request.git_branch):
                return False

        # Check repository
        repo_cond = conditions.get("repository", {})
        if "allowlist" in repo_cond:
            if request.repository not in repo_cond["allowlist"]:
                return False

        return True
```

## HSM Integration

Using PKCS#11 for HSM-agnostic signing. Tested with:
- Thales Luna Network HSM
- AWS CloudHSM
- SoftHSM2 (for development/testing)
- Nitrokey HSM (for small deployments)

```python
# signing_service/hsm_backend.py
import pkcs11
import pkcs11.util.rsa
from pkcs11 import Mechanism, KeyType, Attribute, ObjectClass
import hashlib
import logging

logger = logging.getLogger(__name__)

class HSMSigner:
    """PKCS#11-based HSM signing backend."""

    def __init__(self, hsm_lib: str, token_label: str, pin: str):
        """
        Initialize HSM connection.

        Args:
            hsm_lib: Path to PKCS#11 shared library
                     e.g. /usr/lib/softhsm/libsofthsm2.so
                          /usr/lib/libCryptoki2_64.so  (Luna HSM)
                          /opt/cloudhsm/lib/libcloudhsm_pkcs11.so
            token_label: HSM token label (matches configured token)
            pin: HSM user PIN (loaded from secrets manager at runtime)
        """
        self.lib = pkcs11.lib(hsm_lib)
        self.token = self.lib.get_token(token_label=token_label)
        self.session = self.token.open(
            rw=False,       # Read-only session (signing doesn't need write)
            user_pin=pin
        )
        logger.info(f"HSM session opened: token={token_label}")

    def sign_rsa_sha256(self, key_label: str, data: bytes) -> bytes:
        """
        Sign data using RSA PKCS#1 v1.5 with SHA-256.

        Args:
            key_label: PKCS#11 label of the private key to use
            data: Raw data to sign (NOT a pre-computed hash;
                  the HSM computes SHA-256 internally)

        Returns:
            Raw signature bytes
        """
        try:
            # Find private key by label
            privkey = next(self.session.get_objects({
                Attribute.CLASS: ObjectClass.PRIVATE_KEY,
                Attribute.KEY_TYPE: KeyType.RSA,
                Attribute.LABEL: key_label,
            }))
        except StopIteration:
            raise KeyError(f"Private key '{key_label}' not found in HSM")

        logger.info(f"Signing with key: {key_label}")

        # Sign with RSA PKCS1 v1.5 + SHA256
        # Mechanism handles hashing internally
        signature = privkey.sign(
            data,
            mechanism=Mechanism.SHA256_RSA_PKCS
        )

        logger.info(f"Signature generated: {len(signature)} bytes")
        return bytes(signature)

    def sign_rsa_pss_sha256(self, key_label: str, data: bytes) -> bytes:
        """
        Sign data using RSA-PSS with SHA-256 (recommended for new deployments).
        """
        try:
            privkey = next(self.session.get_objects({
                Attribute.CLASS: ObjectClass.PRIVATE_KEY,
                Attribute.KEY_TYPE: KeyType.RSA,
                Attribute.LABEL: key_label,
            }))
        except StopIteration:
            raise KeyError(f"Private key '{key_label}' not found in HSM")

        # RSA-PSS with SHA-256 and MGF1-SHA256
        params = pkcs11.util.rsa.PSS(
            hash_alg=Mechanism.SHA256,
            mgf=pkcs11.MGF.SHA256,
            salt_length=32,
        )
        signature = privkey.sign(
            data,
            mechanism=Mechanism.SHA256_RSA_PKCS_PSS,
            mechanism_param=params
        )
        return bytes(signature)

    def get_certificate(self, cert_label: str) -> bytes:
        """Retrieve certificate from HSM by label (DER-encoded)."""
        try:
            cert_obj = next(self.session.get_objects({
                Attribute.CLASS: ObjectClass.CERTIFICATE,
                Attribute.LABEL: cert_label,
            }))
        except StopIteration:
            raise KeyError(f"Certificate '{cert_label}' not found in HSM")

        return bytes(cert_obj[Attribute.VALUE])

    def list_keys(self) -> list[dict]:
        """List all available signing keys (no private key material)."""
        keys = []
        for obj in self.session.get_objects({
            Attribute.CLASS: ObjectClass.PRIVATE_KEY,
        }):
            keys.append({
                "label": obj[Attribute.LABEL],
                "key_type": str(obj[Attribute.KEY_TYPE]),
                "modulus_bits": obj.get(Attribute.MODULUS_BITS, None),
                "id": obj[Attribute.ID].hex(),
            })
        return keys

    def close(self):
        """Close HSM session cleanly."""
        if self.session:
            self.session.close()
            logger.info("HSM session closed")

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
```

HSM key import (performed offline during key ceremony):
```bash
# Import RSA key pair into SoftHSM2 (development)
# In production: key generated ON HSM, never extracted

softhsm2-util --init-token --slot 0 \
  --label "signing-service-production" \
  --pin "${HSM_PIN}" \
  --so-pin "${HSM_SO_PIN}"

# Import existing key (dev/test only — in prod, generate in HSM)
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login --pin "${HSM_PIN}" \
  --write-object fit-signing-key.pem \
  --type privkey \
  --label "fit-production-key-2024" \
  --id 01

# Import corresponding certificate
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login --pin "${HSM_PIN}" \
  --write-object fit-signing-key.crt \
  --type cert \
  --label "fit-production-key-2024-cert" \
  --id 01

# List objects to verify
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login --pin "${HSM_PIN}" \
  --list-objects
```

AWS CloudHSM-specific configuration:
```python
# For AWS CloudHSM, configure the PKCS#11 client
import os

# CloudHSM PKCS#11 library path
HSM_LIB = "/opt/cloudhsm/lib/libcloudhsm_pkcs11.so"

# CloudHSM authenticates via environment variables
# Set before initializing library:
os.environ["HSM_PARTITION"] = "hsm-cluster-id"

# Credentials stored in AWS Secrets Manager
import boto3
sm = boto3.client("secretsmanager")
secret = sm.get_secret_value(SecretId="signing-service/hsm-pin")
HSM_PIN = secret["SecretString"]

signer = HSMSigner(
    hsm_lib=HSM_LIB,
    token_label="signing-cluster",
    pin=HSM_PIN
)
```

## Complete Service Implementation

```python
# signing_service/app.py
from fastapi import FastAPI, HTTPException, Depends, Header
from pydantic import BaseModel
import boto3
import hashlib
import secrets
import time
from datetime import datetime, timezone

from .hsm_backend import HSMSigner
from .auth.oidc_validator import validate_github_oidc
from .auth.policy_engine import PolicyEngine, SigningRequest
from .audit import AuditLogger

app = FastAPI(title="Firmware Signing Service", version="1.0.0")

# Initialize singletons (in production: use dependency injection)
hsm = HSMSigner(
    hsm_lib=os.environ["HSM_LIB_PATH"],
    token_label=os.environ["HSM_TOKEN_LABEL"],
    pin=get_hsm_pin_from_secrets_manager()
)
policy_engine = PolicyEngine("policies/production.yaml")
audit_logger = AuditLogger(os.environ["DATABASE_URL"])
s3 = boto3.client("s3")

class FITSigningRequest(BaseModel):
    artifact_type: str
    artifact_hash: str
    artifact_url: str
    requestor: dict
    signing_key_id: str
    target_platform: str

@app.post("/api/v1/sign/fit-image")
async def sign_fit_image(
    request: FITSigningRequest,
    authorization: str = Header(...)
):
    start_time = time.time()

    # 1. Authenticate
    try:
        token = authorization.removeprefix("Bearer ")
        claims = validate_github_oidc(
            token,
            audience="signing.internal.company.com"
        )
    except Exception as e:
        raise HTTPException(status_code=401, detail=f"Authentication failed: {e}")

    # 2. Build signing request for policy check
    sign_req = SigningRequest(
        artifact_type=request.artifact_type,
        signing_key_id=request.signing_key_id,
        git_branch=request.requestor.get("git_branch", ""),
        repository=claims.get("repository", ""),
        requestor_identity=claims.get("sub", "")
    )

    # 3. Authorize
    allowed, policy_name = policy_engine.evaluate(sign_req)
    if not allowed:
        audit_logger.log_denied(request, claims, "no matching policy")
        raise HTTPException(
            status_code=403,
            detail="No policy allows this signing request"
        )

    # 4. Fetch artifact from S3 and verify hash
    bucket, key = parse_s3_url(request.artifact_url)
    artifact_data = s3.get_object(Bucket=bucket, Key=key)["Body"].read()

    actual_hash = "sha256:" + hashlib.sha256(artifact_data).hexdigest()
    if actual_hash != request.artifact_hash:
        raise HTTPException(
            status_code=400,
            detail=f"Hash mismatch: expected {request.artifact_hash}, got {actual_hash}"
        )

    # 5. Sign via HSM
    try:
        signature = hsm.sign_rsa_sha256(request.signing_key_id, artifact_data)
        certificate_der = hsm.get_certificate(f"{request.signing_key_id}-cert")
    except Exception as e:
        audit_logger.log_error(request, claims, str(e))
        raise HTTPException(status_code=500, detail=f"HSM signing failed: {e}")

    # 6. Generate audit ID and log success
    audit_id = f"sign-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(4)}"
    duration_ms = int((time.time() - start_time) * 1000)

    audit_logger.log_success(
        audit_id=audit_id,
        request=request,
        claims=claims,
        policy_name=policy_name,
        signature=signature,
        duration_ms=duration_ms
    )

    # 7. Return signature
    import base64
    from cryptography import x509
    cert = x509.load_der_x509_certificate(certificate_der)
    cert_pem = cert.public_bytes(encoding=serialization.Encoding.PEM).decode()

    return {
        "status": "success",
        "audit_id": audit_id,
        "signature": {
            "algorithm": "sha256,rsa2048",
            "value": base64.b64encode(signature).decode(),
            "certificate": cert_pem,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    }
```

## Audit Log Schema

```sql
-- PostgreSQL schema for signing audit trail

CREATE TABLE signing_audit (
    id              SERIAL PRIMARY KEY,
    audit_id        VARCHAR(50)  UNIQUE NOT NULL,
    timestamp       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    -- Request info
    artifact_type   VARCHAR(50)  NOT NULL,
    artifact_hash   VARCHAR(100) NOT NULL,
    artifact_url    VARCHAR(500),
    signing_key_id  VARCHAR(100) NOT NULL,
    target_platform VARCHAR(100),

    -- Requestor identity (from JWT claims)
    ci_job_id           VARCHAR(200),
    git_commit          VARCHAR(50),
    git_branch          VARCHAR(200),
    git_repository      VARCHAR(200),
    requestor_identity  VARCHAR(500),   -- JWT 'sub' claim
    requestor_ip        INET,
    requestor_cert_dn   TEXT,           -- mTLS client cert DN

    -- Authorization
    authorization_decision  VARCHAR(20) NOT NULL, -- allowed, denied
    authorization_policy    VARCHAR(100),

    -- Result
    status          VARCHAR(20)  NOT NULL, -- success, denied, error
    signature_hash  VARCHAR(100),          -- SHA-256 of the signature
    error_message   TEXT,

    -- Timing
    duration_ms     INTEGER,

    -- Metadata
    service_version VARCHAR(20),
    hsm_slot        VARCHAR(50)
);

-- Indexes for common queries
CREATE INDEX idx_signing_audit_timestamp   ON signing_audit(timestamp);
CREATE INDEX idx_signing_audit_git_commit  ON signing_audit(git_commit);
CREATE INDEX idx_signing_audit_key_id      ON signing_audit(signing_key_id);
CREATE INDEX idx_signing_audit_status      ON signing_audit(status);
CREATE INDEX idx_signing_audit_repository  ON signing_audit(git_repository);

-- Audit trail is append-only; enforce with row-level security
ALTER TABLE signing_audit ENABLE ROW LEVEL SECURITY;

-- Allow inserts from service role, no updates/deletes
CREATE POLICY audit_insert_only ON signing_audit
    FOR INSERT TO signing_service_role WITH CHECK (true);

-- Read access for audit reviewers
CREATE POLICY audit_read ON signing_audit
    FOR SELECT TO audit_reviewer_role USING (true);

-- Useful views for reporting
CREATE VIEW daily_signing_summary AS
SELECT
    DATE_TRUNC('day', timestamp) AS day,
    signing_key_id,
    artifact_type,
    COUNT(*) FILTER (WHERE status = 'success') AS successful,
    COUNT(*) FILTER (WHERE status = 'denied')  AS denied,
    COUNT(*) FILTER (WHERE status = 'error')   AS errors,
    AVG(duration_ms) FILTER (WHERE status = 'success') AS avg_duration_ms
FROM signing_audit
GROUP BY 1, 2, 3
ORDER BY 1 DESC;
```

## Rate Limiting Implementation

```python
# signing_service/rate_limiter.py
import redis
import time
from datetime import timedelta

class RateLimiter:
    """Redis-backed sliding window rate limiter."""

    def __init__(self, redis_url: str):
        self.redis = redis.from_url(redis_url)

    def check_and_increment(
        self,
        identity: str,
        key_id: str,
        requests_per_hour: int,
        requests_per_day: int
    ) -> tuple[bool, dict]:
        """
        Check rate limits and increment counters if within limits.

        Returns:
            (allowed, info_dict)
        """
        now = int(time.time())
        hour_window = now - 3600
        day_window  = now - 86400

        pipe = self.redis.pipeline()

        # Keys for rate limiting
        hourly_key = f"ratelimit:{identity}:{key_id}:hourly"
        daily_key  = f"ratelimit:{identity}:{key_id}:daily"

        # Use sorted sets for sliding window
        pipe.zremrangebyscore(hourly_key, 0, hour_window)
        pipe.zremrangebyscore(daily_key,  0, day_window)
        pipe.zcard(hourly_key)
        pipe.zcard(daily_key)
        results = pipe.execute()

        hourly_count = results[2]
        daily_count  = results[3]

        if hourly_count >= requests_per_hour:
            return False, {
                "reason": "hourly_rate_limit_exceeded",
                "current": hourly_count,
                "limit": requests_per_hour
            }

        if daily_count >= requests_per_day:
            return False, {
                "reason": "daily_rate_limit_exceeded",
                "current": daily_count,
                "limit": requests_per_day
            }

        # Add current request
        unique_id = f"{now}-{id(object())}"
        pipe2 = self.redis.pipeline()
        pipe2.zadd(hourly_key, {unique_id: now})
        pipe2.zadd(daily_key,  {unique_id: now})
        pipe2.expire(hourly_key, 3601)
        pipe2.expire(daily_key,  86401)
        pipe2.execute()

        return True, {
            "hourly_remaining": requests_per_hour - hourly_count - 1,
            "daily_remaining":  requests_per_day  - daily_count  - 1
        }
```

## Deployment Architecture

```
                              ┌─────────────────────┐
                              │   Load Balancer      │
                              │   (TLS termination)  │
                              └──────────┬──────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    │                    │                    │
           ┌────────▼──────┐   ┌────────▼──────┐   ┌────────▼──────┐
           │  Signing Svc  │   │  Signing Svc  │   │  Signing Svc  │
           │  Instance 1   │   │  Instance 2   │   │  Instance 3   │
           └────────┬──────┘   └────────┬──────┘   └────────┬──────┘
                    │                    │                    │
           ┌────────▼────────────────────▼────────────────────▼──────┐
           │                 PKCS#11 HSM Network Interface            │
           └─────────────────────────┬──────────────────────────────┘
                                     │
                            ┌────────▼────────┐
                            │   HSM Cluster    │
                            │  (Active/Active) │
                            │  Thales Luna /   │
                            │  AWS CloudHSM    │
                            └─────────────────┘

           ┌──────────────┐      ┌──────────────┐     ┌──────────────┐
           │  PostgreSQL  │      │    Redis      │     │   S3 /       │
           │  Audit DB    │      │  Rate Limiter │     │   MinIO      │
           │  (primary +  │      │  (cluster)    │     │  Artifact    │
           │   replica)   │      │               │     │  Store       │
           └──────────────┘      └──────────────┘     └──────────────┘
```

Kubernetes deployment:
```yaml
# k8s/signing-service-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signing-service
  namespace: security
spec:
  replicas: 3
  selector:
    matchLabels:
      app: signing-service
  template:
    metadata:
      labels:
        app: signing-service
    spec:
      serviceAccountName: signing-service-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000

      containers:
        - name: signing-service
          image: registry.internal.company.com/signing-service:1.0.0
          ports:
            - containerPort: 8080

          env:
            - name: HSM_LIB_PATH
              value: /usr/lib/softhsm/libsofthsm2.so  # Replace with real HSM lib
            - name: HSM_TOKEN_LABEL
              valueFrom:
                secretKeyRef:
                  name: hsm-config
                  key: token-label
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: signing-db-creds
                  key: url
            - name: REDIS_URL
              valueFrom:
                secretKeyRef:
                  name: redis-creds
                  key: url

          # HSM PIN from Vault or AWS Secrets Manager (external secrets operator)
          envFrom:
            - secretRef:
                name: hsm-pin

          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "1000m"

          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5

          # Mount PKCS#11 library (if HSM client is not in container image)
          volumeMounts:
            - name: hsm-client-lib
              mountPath: /usr/lib/hsm-client
              readOnly: true

      volumes:
        - name: hsm-client-lib
          hostPath:
            path: /usr/lib/cloudhsm    # HSM client installed on nodes
            type: Directory
```

## Security Considerations

### Key Material Protection
- Private keys NEVER leave the HSM
- HSM PINs stored in Vault or AWS Secrets Manager (not in environment files)
- HSM PIN split between two people (m-of-n control)
- HSM audit log correlated with signing service audit log

### Network Security
- Signing service deployed in isolated network segment
- Only CI/CD infrastructure has network access to signing service
- All traffic over TLS 1.3 minimum
- Internal DNS for service discovery (no public exposure)

### Audit and Alerting

Alert triggers:
```yaml
# prometheus/signing-alerts.yaml
groups:
  - name: signing_service
    rules:
      - alert: SigningRateSpikeDetected
        expr: rate(signing_requests_total[5m]) > 10
        for: 2m
        annotations:
          summary: "Unusual signing request rate"

      - alert: SigningAuthFailureSpike
        expr: rate(signing_auth_failures_total[5m]) > 5
        for: 1m
        annotations:
          summary: "Multiple authentication failures - possible attack"

      - alert: HSMConnectionLost
        expr: hsm_connected == 0
        for: 30s
        annotations:
          summary: "HSM connection lost - signing unavailable"
          severity: critical

      - alert: UnexpectedBranchSigning
        expr: signing_requests_by_branch{branch!~"^(release/.*|main)$"} > 0
        annotations:
          summary: "Signing request from unexpected branch"
```
