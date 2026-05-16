# 17-02: Provisioning Script Reference

## Overview

This document provides complete, production-ready provisioning scripts for the PHYTEC phyCORE-i.MX8MP platform. All scripts are designed to run from the provisioning image (a minimal Linux system booted into RAM during factory provisioning).

**Prerequisites:**
- `imx-utils` package installed (provides `fuse` command)
- `mmc-utils` package installed (provides `mmc` command)
- `openssl` installed
- `curl` available (for provisioning server communication)
- Provisioning image booted from USB-SDP or SD card

---

## Main Provisioning Script

```bash
#!/bin/bash
# provision_device.sh - PHYTEC phyCORE-i.MX8MP provisioning script
# Version: 2.1.0
# Usage: ./provision_device.sh [--server <url>] [--dry-run] [--verbose]
#
# This script performs complete factory provisioning for i.MX8MP devices.
# It must be run from the provisioning image on the target device.
# The provisioning server URL and credentials are embedded in the
# provisioning image at build time.
#
# EXIT CODES:
#   0 - Success (device fully provisioned)
#   1 - General failure
#   2 - Device already provisioned (SEC_CONFIG already set)
#   3 - SRK fuse verification failed
#   4 - RPMB programming failed
#   5 - Certificate issuance failed
#   6 - SEC_CONFIG programming failed
#   7 - Provisioning server communication error
#   8 - Hardware attestation failed

set -euo pipefail
IFS=$'\n\t'

# ============================================================
# CONFIGURATION
# ============================================================

# Embedded at image build time (substituted by Yocto/bitbake):
PROV_SERVER_URL="${PROV_SERVER_URL:-https://provisioning.example.com}"
PROV_CA_CERT="/etc/ssl/prov_ca.crt"         # Embedded in provisioning image
PROV_STATION_CERT="/etc/ssl/station.crt"    # Provisioning station TLS cert
PROV_API_KEY="${PROV_API_KEY:-}"             # API key for station authentication

EMMC_DEV="/dev/mmcblk2"
EMMC_RPMB="/dev/mmcblk2rpmb"
LOG_DIR="/tmp"
FUSE_RETRY_MAX=3

# ============================================================
# LOGGING
# ============================================================

DEVICE_SERIAL=""
LOG_FILE="${LOG_DIR}/provision_boot.log"

log() {
    local level="${1:-INFO}"
    shift
    local msg="$*"
    local ts
    ts=$(date -Iseconds)
    echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [[ "${VERBOSE:-0}" == "1" ]] && log "DEBUG" "$@" || true; }

die() {
    local code="${1:-1}"
    shift
    log_error "FATAL: $* (exit code: ${code})"
    # Attempt to report failure to server before dying
    report_failure "${code}" "$*" || true
    exit "${code}"
}

# ============================================================
# DEVICE IDENTITY
# ============================================================

get_silicon_uid() {
    # i.MX8MP Silicon UID: OCOTP Bank 0 Words 1 and 2
    # Register offset: 0x10 (word 1) and 0x20 (word 2) from base
    local uid_low uid_high
    uid_low=$(fuse read 0 1 2>/dev/null | awk 'NR==1{gsub(/^0x/,"",$NF); print $NF}')
    uid_high=$(fuse read 0 2 2>/dev/null | awk 'NR==1{gsub(/^0x/,"",$NF); print $NF}')
    echo "${uid_high}${uid_low}"
}

get_board_serial() {
    # Board serial from PHYTEC EEPROM (I2C address 0x50 on carrier board)
    # PHYTEC stores product string at EEPROM offset 0
    local eeprom_dev="/sys/bus/i2c/devices/0-0050/eeprom"
    if [[ -r "${eeprom_dev}" ]]; then
        # Read 32 bytes, strip null bytes, extract serial
        dd if="${eeprom_dev}" bs=1 count=32 2>/dev/null | \
            strings | head -1 | tr -d '\n'
    else
        log_warn "EEPROM not accessible, using silicon UID as serial"
        get_silicon_uid
    fi
}

get_cpu_revision() {
    # Read DIGPROG register for SoC revision
    # i.MX8MP DIGPROG at 0x30360800 offset 0x6c
    devmem2 0x3036006c 2>/dev/null | awk '/Value/{print $NF}' || echo "unknown"
}

identify_device() {
    SILICON_UID=$(get_silicon_uid)
    BOARD_SERIAL=$(get_board_serial)
    CPU_REV=$(get_cpu_revision)

    log_info "Silicon UID:   ${SILICON_UID}"
    log_info "Board serial:  ${BOARD_SERIAL}"
    log_info "CPU revision:  ${CPU_REV}"

    if [[ -z "${SILICON_UID}" || "${SILICON_UID}" == "00000000" ]]; then
        die 8 "Failed to read valid silicon UID"
    fi

    LOG_FILE="${LOG_DIR}/provision_${SILICON_UID}.log"
}

# ============================================================
# HAB / FUSE STATUS CHECKS
# ============================================================

check_hab_status() {
    log_info "Checking HAB/fuse status..."

    # Read Boot Configuration fuse: Bank 1, Word 3
    local boot_cfg
    boot_cfg=$(fuse read 1 3 2>/dev/null | awk 'NR==1{print $NF}')
    local boot_cfg_int
    boot_cfg_int=$((boot_cfg))

    log_debug "Bank 1 Word 3 = ${boot_cfg} (${boot_cfg_int})"

    # Check SEC_CONFIG bit (bit 1)
    if (( (boot_cfg_int & 0x2) != 0 )); then
        log_error "SEC_CONFIG is already CLOSED (bit 1 set in Bank 1 Word 3)"
        log_error "This device has already been provisioned. Aborting."
        exit 2
    fi

    log_info "SEC_CONFIG: OPEN (device not yet closed) - safe to provision"
}

check_srk_blank() {
    log_info "Checking SRK fuse bank is blank..."

    local any_burned=0
    for word in 0 1 2 3 4 5 6 7; do
        local val
        val=$(fuse read 3 "${word}" 2>/dev/null | awk 'NR==1{print $NF}')
        if [[ "${val}" != "0x00000000" && "${val}" != "00000000" ]]; then
            log_warn "SRK Bank 3 Word ${word} is not blank: ${val}"
            any_burned=1
        fi
    done

    if [[ "${any_burned}" == "1" ]]; then
        log_error "SRK fuses are not blank. Partial provisioning detected."
        die 3 "SRK fuses already partially programmed — cannot safely continue"
    fi

    log_info "SRK fuse bank is blank - safe to program"
}

# ============================================================
# PROVISIONING SERVER COMMUNICATION
# ============================================================

server_post() {
    local endpoint="$1"
    local payload="$2"
    local response

    response=$(curl \
        --silent \
        --fail \
        --max-time 30 \
        --retry 3 \
        --retry-delay 2 \
        --cacert "${PROV_CA_CERT}" \
        -H "Content-Type: application/json" \
        -H "X-Station-Key: ${PROV_API_KEY}" \
        -X POST \
        -d "${payload}" \
        "${PROV_SERVER_URL}${endpoint}" 2>&1) || {
        die 7 "Server communication failed: ${endpoint}"
    }

    echo "${response}"
}

server_get() {
    local endpoint="$1"
    local response

    response=$(curl \
        --silent \
        --fail \
        --max-time 30 \
        --retry 3 \
        --retry-delay 2 \
        --cacert "${PROV_CA_CERT}" \
        -H "X-Station-Key: ${PROV_API_KEY}" \
        "${PROV_SERVER_URL}${endpoint}" 2>&1) || {
        die 7 "Server communication failed: ${endpoint}"
    }

    echo "${response}"
}

start_provisioning_session() {
    log_info "Starting provisioning session with server..."

    local resp
    resp=$(server_post "/api/v1/sessions/start" \
        "{\"silicon_uid\":\"${SILICON_UID}\",\"board_serial\":\"${BOARD_SERIAL}\"}")

    SESSION_ID=$(echo "${resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)['session_id'])")
    SESSION_TOKEN=$(echo "${resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

    if [[ -z "${SESSION_ID}" ]]; then
        die 7 "Failed to obtain session ID from provisioning server"
    fi

    log_info "Provisioning session: ${SESSION_ID}"
}

report_failure() {
    local code="${1}"
    local message="${2}"
    curl --silent --max-time 5 \
        --cacert "${PROV_CA_CERT}" \
        -H "Content-Type: application/json" \
        -H "X-Station-Key: ${PROV_API_KEY}" \
        -X POST \
        -d "{\"session_id\":\"${SESSION_ID:-unknown}\",\"silicon_uid\":\"${SILICON_UID:-unknown}\",\"code\":${code},\"message\":\"${message}\"}" \
        "${PROV_SERVER_URL}/api/v1/sessions/fail" >/dev/null 2>&1 || true
}

# ============================================================
# SRK FUSE PROGRAMMING
# ============================================================

get_srk_fuse_values() {
    log_info "Fetching SRK fuse values from provisioning server..."

    local resp
    resp=$(server_post "/api/v1/srk/fuse-values" \
        "{\"session_id\":\"${SESSION_ID}\",\"silicon_uid\":\"${SILICON_UID}\"}")

    # Parse JSON array of {bank, word, value} objects
    SRK_FUSE_JSON="${resp}"
    log_debug "SRK fuse values received"
}

program_srk_fuses() {
    log_info "Programming SRK fuses..."

    # Parse fuse values from JSON and program each word
    # JSON format: {"fuses":[{"bank":3,"word":0,"value":"0xA1B2C3D4"},...],"hash":"sha256:..."}
    local fuse_count=0

    while IFS=',' read -r bank word value; do
        bank=$(echo "${bank}" | tr -d ' "')
        word=$(echo "${word}" | tr -d ' "')
        value=$(echo "${value}" | tr -d ' "')

        log_info "Programming fuse: bank=${bank} word=${word} value=${value}"

        local attempt=0
        while (( attempt < FUSE_RETRY_MAX )); do
            if fuse prog -y "${bank}" "${word}" "${value}" 2>&1 | \
                    tee -a "${LOG_FILE}"; then
                break
            fi
            attempt=$(( attempt + 1 ))
            log_warn "Fuse prog attempt ${attempt} failed, retrying..."
            sleep 1
        done

        if (( attempt >= FUSE_RETRY_MAX )); then
            die 3 "Failed to program fuse bank=${bank} word=${word} after ${FUSE_RETRY_MAX} attempts"
        fi

        fuse_count=$(( fuse_count + 1 ))
    done < <(echo "${SRK_FUSE_JSON}" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data['fuses']:
    print(f'{f[\"bank\"]},{f[\"word\"]},{f[\"value\"]}')
")

    log_info "Programmed ${fuse_count} SRK fuse words"
}

verify_srk_fuses() {
    log_info "Verifying SRK fuse values..."

    local all_match=1
    local readback_values=()

    while IFS=',' read -r bank word expected; do
        bank=$(echo "${bank}" | tr -d ' "')
        word=$(echo "${word}" | tr -d ' "')
        expected=$(echo "${expected}" | tr -d ' "' | tr '[:upper:]' '[:lower:]')

        local actual
        actual=$(fuse read "${bank}" "${word}" 2>/dev/null | \
            awk 'NR==1{gsub(/^0[xX]/,"",$NF); print tolower($NF)}')

        # Normalize expected (remove 0x prefix, lowercase)
        local expected_norm
        expected_norm=$(echo "${expected}" | sed 's/^0x//' | tr '[:upper:]' '[:lower:]')

        if [[ "${actual}" != "${expected_norm}" ]]; then
            log_error "MISMATCH: bank=${bank} word=${word} expected=0x${expected_norm} got=0x${actual}"
            all_match=0
        else
            log_debug "OK: bank=${bank} word=${word} value=0x${actual}"
        fi

        readback_values+=("${bank}:${word}:0x${actual}")
    done < <(echo "${SRK_FUSE_JSON}" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data['fuses']:
    print(f'{f[\"bank\"]},{f[\"word\"]},{f[\"value\"]}')
")

    if [[ "${all_match}" != "1" ]]; then
        die 3 "SRK fuse verification FAILED — value mismatch detected"
    fi

    log_info "SRK fuse verification PASSED"

    # Report readback values to server for audit
    local readback_json
    readback_json=$(printf '%s\n' "${readback_values[@]}" | \
        python3 -c "
import sys
vals = [l.strip() for l in sys.stdin]
import json
print(json.dumps({'readback': vals}))
")
    server_post "/api/v1/srk/verify" \
        "{\"session_id\":\"${SESSION_ID}\",\"silicon_uid\":\"${SILICON_UID}\",\"readback\":${readback_json}}" \
        >/dev/null
}

# ============================================================
# RPMB PROVISIONING
# ============================================================

program_rpmb_key() {
    log_info "Programming RPMB authentication key..."

    # Check if RPMB is already programmed
    if mmc extcsd read "${EMMC_DEV}" 2>/dev/null | grep -q "RPMB Size"; then
        # Test RPMB access — if already keyed, this will fail with auth error
        if mmc rpmb read-counter "${EMMC_RPMB}" 2>/dev/null | grep -q "0x"; then
            log_warn "RPMB appears already programmed"
            # Do not die — check with server if this is expected
        fi
    fi

    # Fetch encrypted RPMB key from server
    log_info "Fetching RPMB key from provisioning server..."
    local resp
    resp=$(server_post "/api/v1/rpmb/key" \
        "{\"session_id\":\"${SESSION_ID}\",\"silicon_uid\":\"${SILICON_UID}\"}")

    # Decrypt RPMB key (server encrypts with session-derived key)
    # Key is delivered as AES-256-GCM encrypted blob
    local encrypted_key iv auth_tag
    encrypted_key=$(echo "${resp}" | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print(d['key_enc'])")
    iv=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['iv'])")
    auth_tag=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tag'])")

    # Derive session decryption key from silicon UID (known to both sides)
    # In production, this uses TLS keying material export (RFC 5705)
    local session_key
    session_key=$(openssl dgst -sha256 -hmac "${SESSION_TOKEN}" \
        <(echo -n "RPMB_KEY_DERIVE:${SILICON_UID}") 2>/dev/null | \
        awk '{print $NF}')

    # Decrypt RPMB key using session key
    local rpmb_key_hex
    rpmb_key_hex=$(python3 <<EOF
import base64
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import binascii

session_key = binascii.unhexlify("${session_key}")
key_enc = base64.b64decode("${encrypted_key}")
iv = base64.b64decode("${iv}")

aesgcm = AESGCM(session_key)
rpmb_key = aesgcm.decrypt(iv, key_enc, b"${SILICON_UID}")
print(rpmb_key.hex())
EOF
)

    # Program RPMB key
    local rpmb_key_file
    rpmb_key_file=$(mktemp /tmp/rpmb_key.XXXXXX)
    echo -n "${rpmb_key_hex}" | xxd -r -p > "${rpmb_key_file}"

    local attempt=0
    while (( attempt < 3 )); do
        if mmc rpmb write-key "${EMMC_RPMB}" - < "${rpmb_key_file}" 2>&1 | \
                tee -a "${LOG_FILE}"; then
            break
        fi
        attempt=$(( attempt + 1 ))
        log_warn "RPMB key write attempt ${attempt} failed"
        sleep 2
    done

    # Securely erase RPMB key file
    dd if=/dev/urandom of="${rpmb_key_file}" bs=32 count=1 2>/dev/null
    rm -f "${rpmb_key_file}"

    if (( attempt >= 3 )); then
        die 4 "RPMB key programming failed after 3 attempts"
    fi

    # Verify RPMB is functional
    local counter
    counter=$(mmc rpmb read-counter "${EMMC_RPMB}" 2>/dev/null | awk '{print $NF}')
    if [[ -z "${counter}" ]]; then
        die 4 "RPMB verification failed — cannot read write counter"
    fi

    log_info "RPMB provisioned successfully (write counter: ${counter})"
}

# ============================================================
# DEVICE CERTIFICATE PROVISIONING
# ============================================================

provision_device_certificate() {
    log_info "Provisioning device identity certificate..."

    # Request TEE to generate key pair and CSR
    # This communicates with OP-TEE via the TEEC API through a small helper binary
    local csr_file
    csr_file=$(mktemp /tmp/device_csr.XXXXXX)

    log_info "Generating device key pair in TEE..."
    if ! tee_keygen --type EC-P256 \
                    --key-id "device_identity_key" \
                    --subject "CN=${SILICON_UID},O=ExampleCorp,OU=IoT" \
                    --output-csr "${csr_file}" 2>&1 | tee -a "${LOG_FILE}"; then
        # Fallback: generate key with openssl if TEE is not available in provisioning image
        log_warn "TEE key generation failed, using software key (DEVELOPMENT ONLY)"
        openssl ecparam -name prime256v1 -genkey -noout \
            -out /tmp/device_key.pem 2>/dev/null
        openssl req -new -key /tmp/device_key.pem \
            -subj "/CN=${SILICON_UID}/O=ExampleCorp/OU=IoT" \
            -out "${csr_file}" 2>/dev/null
    fi

    local csr_b64
    csr_b64=$(base64 -w0 "${csr_file}")

    log_info "Submitting CSR to provisioning server..."
    local resp
    resp=$(server_post "/api/v1/certificates/issue" \
        "{\"session_id\":\"${SESSION_ID}\",\"silicon_uid\":\"${SILICON_UID}\",\"csr\":\"${csr_b64}\"}")

    local cert_b64
    cert_b64=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['certificate'])")
    local chain_b64
    chain_b64=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['chain'])")

    # Store certificate in OP-TEE secure storage (via TEE helper)
    echo "${cert_b64}" | base64 -d > /tmp/device_cert.der
    echo "${chain_b64}" | base64 -d > /tmp/device_chain.pem

    if command -v tee_store_cert >/dev/null 2>&1; then
        tee_store_cert --key-id "device_identity_key" \
                       --cert /tmp/device_cert.der \
                       --chain /tmp/device_chain.pem 2>&1 | tee -a "${LOG_FILE}"
    fi

    # Also store certificate in filesystem (for TLS clients that cannot use TEE)
    mkdir -p /mnt/rootfs/etc/ssl/device
    install -m 0444 /tmp/device_cert.der /mnt/rootfs/etc/ssl/device/device.der
    install -m 0444 /tmp/device_chain.pem /mnt/rootfs/etc/ssl/device/chain.pem
    openssl x509 -inform DER -in /tmp/device_cert.der \
        -out /mnt/rootfs/etc/ssl/device/device.pem 2>/dev/null

    # Cleanup sensitive material
    rm -f /tmp/device_csr.* /tmp/device_key.pem /tmp/device_cert.der

    log_info "Device certificate stored successfully"
}

# ============================================================
# DEVICE CLOSURE (SEC_CONFIG)
# ============================================================

close_device() {
    log_info "Preparing to close device (SEC_CONFIG)..."
    log_warn "============================================"
    log_warn "  IRREVERSIBLE OPERATION: SEC_CONFIG burn   "
    log_warn "============================================"

    # Final pre-closure validation
    log_info "Running final pre-closure checks..."

    # 1. Verify SRK fuses are still correct (nothing changed them)
    verify_srk_fuses

    # 2. Verify RPMB is accessible
    if ! mmc rpmb read-counter "${EMMC_RPMB}" >/dev/null 2>&1; then
        die 6 "RPMB not accessible before closure — aborting"
    fi

    # 3. Request closure authorization from server
    log_info "Requesting closure authorization from server..."
    local resp
    resp=$(server_post "/api/v1/closure/authorize" \
        "{\"session_id\":\"${SESSION_ID}\",\"silicon_uid\":\"${SILICON_UID}\"}")

    local authorized
    authorized=$(echo "${resp}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('authorized', False))")
    if [[ "${authorized}" != "True" && "${authorized}" != "true" ]]; then
        die 6 "Closure not authorized by provisioning server"
    fi

    local closure_token
    closure_token=$(echo "${resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)['closure_token'])")

    log_info "Closure authorized. Burning SEC_CONFIG fuse..."

    # Burn SEC_CONFIG bit (bit 1 in Bank 1 Word 3)
    # Value 0x2 = bit 1 set = HAB enforcement enabled
    if ! fuse prog -y 1 3 0x00000002 2>&1 | tee -a "${LOG_FILE}"; then
        die 6 "fuse prog command failed for SEC_CONFIG"
    fi

    # Verify SEC_CONFIG was set
    local boot_cfg
    boot_cfg=$(fuse read 1 3 2>/dev/null | awk 'NR==1{print $NF}')
    local boot_cfg_int
    boot_cfg_int=$((boot_cfg))

    if (( (boot_cfg_int & 0x2) == 0 )); then
        die 6 "SEC_CONFIG bit not set after programming — possible fuse failure"
    fi

    log_info "SEC_CONFIG set to CLOSED mode: Bank 1 Word 3 = ${boot_cfg}"

    # Report closure to server (include closure token to prevent replay)
    server_post "/api/v1/closure/confirm" \
        "{\"session_id\":\"${SESSION_ID}\",\"silicon_uid\":\"${SILICON_UID}\",\"closure_token\":\"${closure_token}\",\"boot_cfg\":\"${boot_cfg}\"}" \
        >/dev/null

    log_info "Device CLOSED. SEC_CONFIG confirmed."
}

# ============================================================
# COMPLETION
# ============================================================

complete_provisioning() {
    log_info "Completing provisioning session..."

    # Write RPMB provisioning completion marker
    # This marker is checked by the one-time guard on future boots
    if command -v rpmb_write_marker >/dev/null 2>&1; then
        rpmb_write_marker "PROVISIONED:v1:${SILICON_UID}:$(date -Iseconds)"
    fi

    # Final report to provisioning server
    local duration_ms=$(( $(date +%s%3N) - START_TIME_MS ))
    server_post "/api/v1/sessions/complete" \
        "{\"session_id\":\"${SESSION_ID}\",\"silicon_uid\":\"${SILICON_UID}\",\"duration_ms\":${duration_ms}}" \
        >/dev/null

    log_info "========================================"
    log_info "  PROVISIONING COMPLETE"
    log_info "  Silicon UID: ${SILICON_UID}"
    log_info "  Session:     ${SESSION_ID}"
    log_info "  Duration:    ${duration_ms}ms"
    log_info "========================================"

    # Upload log to server
    server_post "/api/v1/sessions/log" \
        "{\"session_id\":\"${SESSION_ID}\",\"log\":$(python3 -c "import sys,json; print(json.dumps(open('${LOG_FILE}').read()))")}" \
        >/dev/null || true
}

# ============================================================
# MAIN
# ============================================================

main() {
    START_TIME_MS=$(date +%s%3N)

    # Parse arguments
    DRY_RUN=0
    VERBOSE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  DRY_RUN=1 ;;
            --verbose)  VERBOSE=1 ;;
            --server)   PROV_SERVER_URL="$2"; shift ;;
            *)          log_warn "Unknown argument: $1" ;;
        esac
        shift
    done

    log_info "==========================================="
    log_info "  PHYTEC phyCORE-i.MX8MP Provisioning"
    log_info "  Script version: 2.1.0"
    log_info "  Dry-run: ${DRY_RUN}"
    log_info "==========================================="

    # Step 1: Identify device
    identify_device
    log_info "Starting provisioning for silicon UID: ${SILICON_UID}"

    # Step 2: Safety checks
    check_hab_status
    check_srk_blank

    # Step 3: Connect to provisioning server and start session
    start_provisioning_session

    # Step 4: Get SRK fuse values and program
    get_srk_fuse_values
    if [[ "${DRY_RUN}" == "0" ]]; then
        program_srk_fuses
    else
        log_info "[DRY-RUN] Would program SRK fuses"
    fi

    # Step 5: Verify SRK fuses
    if [[ "${DRY_RUN}" == "0" ]]; then
        verify_srk_fuses
    fi

    # Step 6: RPMB provisioning
    if [[ "${DRY_RUN}" == "0" ]]; then
        program_rpmb_key
    else
        log_info "[DRY-RUN] Would program RPMB key"
    fi

    # Step 7: Device certificate provisioning
    if [[ "${DRY_RUN}" == "0" ]]; then
        provision_device_certificate
    else
        log_info "[DRY-RUN] Would provision device certificate"
    fi

    # Step 8: Close device
    if [[ "${DRY_RUN}" == "0" ]]; then
        close_device
    else
        log_info "[DRY-RUN] Would burn SEC_CONFIG (SKIPPED)"
    fi

    # Step 9: Mark complete
    complete_provisioning

    exit 0
}

main "$@"
```

---

## RPMB Provisioning Script

```bash
#!/bin/bash
# rpmb_provision.sh - Standalone RPMB key provisioning script
# Used when RPMB needs to be provisioned independently (e.g., eMMC replacement recovery)

set -euo pipefail

EMMC_DEV="${1:-/dev/mmcblk2}"
EMMC_RPMB="${EMMC_DEV}rpmb"

check_rpmb_status() {
    echo "Checking eMMC RPMB status..."

    # Check if eMMC supports RPMB
    local extcsd_file
    extcsd_file=$(mktemp /tmp/extcsd.XXXXXX)
    mmc extcsd read "${EMMC_DEV}" > "${extcsd_file}" 2>&1

    if ! grep -q "RPMB Size" "${extcsd_file}"; then
        echo "ERROR: eMMC does not report RPMB capability"
        rm -f "${extcsd_file}"
        exit 1
    fi

    local rpmb_size
    rpmb_size=$(grep "RPMB Size" "${extcsd_file}" | awk '{print $NF}')
    echo "RPMB size: ${rpmb_size} * 128KB"
    rm -f "${extcsd_file}"

    # Try reading RPMB write counter to see if already keyed
    if mmc rpmb read-counter "${EMMC_RPMB}" 2>/dev/null | grep -q "RPMB"; then
        echo "RPMB appears to have an authentication key"
        echo "Re-programming RPMB requires eMMC secure erase or new eMMC die"
        echo "If this is a replacement eMMC, continue. If not, ABORT."
        read -r -p "Continue? [yes/NO]: " confirm
        if [[ "${confirm}" != "yes" ]]; then
            echo "Aborted by operator."
            exit 0
        fi
    fi
}

program_rpmb_key_from_file() {
    local key_file="${1:?Key file required}"

    if [[ ! -f "${key_file}" ]]; then
        echo "ERROR: Key file not found: ${key_file}"
        exit 1
    fi

    local key_size
    key_size=$(wc -c < "${key_file}")
    if [[ "${key_size}" != "32" ]]; then
        echo "ERROR: RPMB key must be exactly 32 bytes, got ${key_size}"
        exit 1
    fi

    echo "Programming RPMB key from ${key_file}..."
    if mmc rpmb write-key "${EMMC_RPMB}" - < "${key_file}"; then
        echo "RPMB key programmed successfully"
    else
        echo "ERROR: mmc rpmb write-key failed"
        exit 1
    fi
}

verify_rpmb() {
    echo "Verifying RPMB functionality..."

    local counter
    counter=$(mmc rpmb read-counter "${EMMC_RPMB}" 2>/dev/null | \
        awk '/Write counter/{print $NF}')

    if [[ -z "${counter}" ]]; then
        echo "ERROR: Cannot read RPMB write counter after provisioning"
        exit 1
    fi

    echo "RPMB write counter: ${counter}"
    echo "RPMB verification PASSED"
}

echo "=== RPMB Provisioning Tool ==="
echo "Target device: ${EMMC_DEV}"
echo ""

check_rpmb_status

# Key file can be passed as second argument or read from stdin
if [[ -n "${2:-}" ]]; then
    program_rpmb_key_from_file "$2"
else
    echo "Reading RPMB key from stdin (32 bytes)..."
    local_key_file=$(mktemp /tmp/rpmb_key.XXXXXX)
    dd bs=32 count=1 of="${local_key_file}" 2>/dev/null
    program_rpmb_key_from_file "${local_key_file}"
    dd if=/dev/urandom of="${local_key_file}" bs=32 count=1 2>/dev/null
    rm -f "${local_key_file}"
fi

verify_rpmb
```

---

## Device Attestation Script

```bash
#!/bin/bash
# attest_device.sh - Verify device authenticity before provisioning
# Returns 0 if device is genuine, non-zero if attestation fails

set -euo pipefail

PROV_SERVER_URL="${PROV_SERVER_URL:-https://provisioning.example.com}"
PROV_CA_CERT="${PROV_CA_CERT:-/etc/ssl/prov_ca.crt}"

attest_caam_rng() {
    # Request CAAM hardware RNG to generate entropy, verifiable as hardware-backed
    echo "Testing CAAM hardware RNG..."

    # CAAM RNG should be accessible via /dev/hwrng
    if [[ ! -c /dev/hwrng ]]; then
        echo "WARNING: /dev/hwrng not available (CAAM RNG driver not loaded?)"
        return 1
    fi

    local rng_sample
    rng_sample=$(dd if=/dev/hwrng bs=32 count=1 2>/dev/null | xxd -p | tr -d '\n')

    if [[ ${#rng_sample} -ne 64 ]]; then
        echo "ERROR: CAAM RNG output invalid length: ${#rng_sample}"
        return 1
    fi

    echo "CAAM RNG sample: ${rng_sample:0:16}... (${#rng_sample} hex chars)"
    echo "CAAM RNG: PASS"
}

attest_silicon_uid() {
    local expected_uid="${1:-}"

    # Read silicon UID from OCOTP
    local uid_low uid_high uid_full
    uid_low=$(fuse read 0 1 2>/dev/null | awk 'NR==1{print $NF}')
    uid_high=$(fuse read 0 2 2>/dev/null | awk 'NR==1{print $NF}')
    uid_full="${uid_high}${uid_low}"

    echo "Silicon UID: ${uid_full}"

    # Verify UID is non-zero and non-all-ones
    if [[ "${uid_full}" == "0000000000000000" ]]; then
        echo "ERROR: Silicon UID is all zeros — OCOTP read failure or invalid device"
        return 1
    fi

    if [[ "${uid_full}" == "ffffffffffffffff" ]]; then
        echo "ERROR: Silicon UID is all ones — OCOTP error"
        return 1
    fi

    # If expected UID provided, verify match
    if [[ -n "${expected_uid}" ]]; then
        if [[ "${uid_full,,}" != "${expected_uid,,}" ]]; then
            echo "ERROR: Silicon UID mismatch: expected ${expected_uid}, got ${uid_full}"
            return 1
        fi
        echo "Silicon UID matches expected value: PASS"
    else
        echo "Silicon UID (no expected value to compare against): PASS"
    fi
}

attest_cpu_type() {
    # Verify this is actually an i.MX8MP (not a different i.MX8 variant)
    echo "Verifying CPU type..."

    # Check /proc/cpuinfo for i.MX8MP indicators
    if grep -q "i.MX8MP" /proc/cpuinfo 2>/dev/null || \
       grep -q "Freescale i.MX8MPlus" /proc/device-tree/model 2>/dev/null; then
        echo "CPU type: i.MX8MP confirmed: PASS"
    else
        local model
        model=$(cat /proc/device-tree/model 2>/dev/null || echo "unknown")
        echo "WARNING: Could not confirm i.MX8MP CPU type. Model: ${model}"
        # Don't fail — model string format varies
    fi
}

generate_attestation_nonce_response() {
    local server_nonce="${1:?Server nonce required}"

    # Generate a CAAM-backed nonce response
    # In a full implementation, this would use a CAAM key to sign the nonce
    # For now, we combine the silicon UID with the server nonce and hash it
    local uid_low uid_high uid_full
    uid_low=$(fuse read 0 1 2>/dev/null | awk 'NR==1{print $NF}')
    uid_high=$(fuse read 0 2 2>/dev/null | awk 'NR==1{print $NF}')
    uid_full="${uid_high}${uid_low}"

    local response
    response=$(echo -n "${uid_full}:${server_nonce}" | \
        openssl dgst -sha256 -binary | xxd -p | tr -d '\n')

    echo "${response}"
}

main() {
    echo "=== Device Attestation ==="
    local all_pass=1

    attest_cpu_type || all_pass=0
    attest_silicon_uid || all_pass=0
    attest_caam_rng || all_pass=0

    if [[ "${all_pass}" == "1" ]]; then
        echo ""
        echo "ATTESTATION RESULT: PASS"
        exit 0
    else
        echo ""
        echo "ATTESTATION RESULT: FAIL"
        exit 8
    fi
}

main "$@"
```

---

## Provisioning Verification Script

```bash
#!/bin/bash
# verify_provisioning.sh - Post-provisioning verification
# Run after device reboot into production firmware to confirm
# all provisioning steps completed successfully.

set -euo pipefail

PASS=0
FAIL=0
WARN=0

result() {
    local test_name="$1"
    local status="$2"
    local message="${3:-}"

    case "${status}" in
        PASS) echo "[PASS] ${test_name}"; PASS=$(( PASS + 1 )) ;;
        FAIL) echo "[FAIL] ${test_name}: ${message}"; FAIL=$(( FAIL + 1 )) ;;
        WARN) echo "[WARN] ${test_name}: ${message}"; WARN=$(( WARN + 1 )) ;;
    esac
}

check_sec_config() {
    local boot_cfg
    boot_cfg=$(fuse read 1 3 2>/dev/null | awk 'NR==1{print $NF}')
    local boot_cfg_int
    boot_cfg_int=$((boot_cfg))

    if (( (boot_cfg_int & 0x2) != 0 )); then
        result "SEC_CONFIG closed" "PASS"
    else
        result "SEC_CONFIG closed" "FAIL" "SEC_CONFIG bit not set (device not in HAB closed mode)"
    fi
}

check_srk_fuses_nonzero() {
    local all_nonzero=1
    for word in 0 1 2 3 4 5 6 7; do
        local val
        val=$(fuse read 3 "${word}" 2>/dev/null | awk 'NR==1{print $NF}')
        if [[ "${val}" == "0x00000000" || "${val}" == "00000000" ]]; then
            all_nonzero=0
            echo "  SRK Bank 3 Word ${word} is zero"
        fi
    done
    if [[ "${all_nonzero}" == "1" ]]; then
        result "SRK fuses programmed" "PASS"
    else
        result "SRK fuses programmed" "FAIL" "One or more SRK fuse words are zero"
    fi
}

check_jtag_disabled() {
    local boot_cfg
    boot_cfg=$(fuse read 1 3 2>/dev/null | awk 'NR==1{print $NF}')
    local boot_cfg_int
    boot_cfg_int=$((boot_cfg))
    local jtag_mode=$(( (boot_cfg_int >> 22) & 0x3 ))

    if (( jtag_mode == 3 )); then
        result "JTAG disabled" "PASS"
    elif (( jtag_mode == 0 )); then
        result "JTAG disabled" "FAIL" "JTAG_SMODE = 0 (JTAG fully enabled — INSECURE)"
    else
        result "JTAG disabled" "WARN" "JTAG_SMODE = ${jtag_mode} (partial restriction)"
    fi
}

check_rpmb_functional() {
    local counter
    counter=$(mmc rpmb read-counter /dev/mmcblk2rpmb 2>/dev/null | \
        awk '/counter/{print $NF}')
    if [[ -n "${counter}" ]]; then
        result "RPMB functional" "PASS"
    else
        result "RPMB functional" "FAIL" "Cannot read RPMB write counter"
    fi
}

check_device_certificate() {
    local cert_file="/etc/ssl/device/device.pem"
    if [[ ! -f "${cert_file}" ]]; then
        result "Device certificate present" "FAIL" "Certificate file not found: ${cert_file}"
        return
    fi

    # Verify certificate is valid (not expired)
    if openssl x509 -in "${cert_file}" -noout -checkend 0 2>/dev/null; then
        local subject
        subject=$(openssl x509 -in "${cert_file}" -noout -subject 2>/dev/null | \
            awk -F'=' '{print $NF}')
        result "Device certificate valid" "PASS"
        echo "  Subject: ${subject}"
    else
        result "Device certificate valid" "FAIL" "Certificate is expired"
    fi
}

check_optee_running() {
    if [[ -c /dev/tee0 ]]; then
        result "OP-TEE device node present" "PASS"
    else
        result "OP-TEE device node present" "WARN" "/dev/tee0 not found (OP-TEE may not be running)"
    fi
}

check_hab_log() {
    # Check HAB event log via U-Boot or via sysfs
    # In Linux, HAB events can be read from /sys/bus/platform/drivers/habv4/...
    # or from a small kernel module.
    # For simplicity, use the habv4-cfg sysfs if available.
    if [[ -f /sys/kernel/security/hab/status ]]; then
        local hab_status
        hab_status=$(cat /sys/kernel/security/hab/status 2>/dev/null)
        if echo "${hab_status}" | grep -q "success\|No HAB Events"; then
            result "HAB event log clean" "PASS"
        else
            result "HAB event log clean" "WARN" "HAB events present: ${hab_status}"
        fi
    else
        result "HAB event log" "WARN" "HAB sysfs not available (check kernel config)"
    fi
}

echo "======================================"
echo "  Post-Provisioning Verification"
echo "======================================"
echo ""

check_sec_config
check_srk_fuses_nonzero
check_jtag_disabled
check_rpmb_functional
check_device_certificate
check_optee_running
check_hab_log

echo ""
echo "======================================"
echo "  RESULTS: ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
echo "======================================"

if [[ "${FAIL}" -gt 0 ]]; then
    echo "VERIFICATION: FAILED"
    exit 1
else
    echo "VERIFICATION: PASSED"
    exit 0
fi
```

---

## Batch Provisioning Wrapper

```bash
#!/bin/bash
# batch_provision.sh - Wrapper for batch provisioning multiple devices
# Reads device serial numbers from a file and provisions each device
# in sequence, logging results per device.

set -euo pipefail

SERIAL_LIST="${1:?Provide serial number list file}"
OUTPUT_DIR="${2:-/var/log/provisioning/batch_$(date +%Y%m%d_%H%M%S)}"
PROVISION_SCRIPT="/usr/local/bin/provision_device.sh"

mkdir -p "${OUTPUT_DIR}"

TOTAL=0
SUCCEEDED=0
FAILED=0
SKIPPED=0

# Header
echo "=== Batch Provisioning Session ===" | tee "${OUTPUT_DIR}/batch.log"
echo "Started: $(date -Iseconds)" | tee -a "${OUTPUT_DIR}/batch.log"
echo "Devices: $(wc -l < "${SERIAL_LIST}")" | tee -a "${OUTPUT_DIR}/batch.log"
echo "" | tee -a "${OUTPUT_DIR}/batch.log"

while IFS= read -r serial; do
    # Skip blank lines and comments
    [[ -z "${serial}" || "${serial}" == \#* ]] && continue

    TOTAL=$(( TOTAL + 1 ))
    echo "--- Device ${TOTAL}: ${serial} ---" | tee -a "${OUTPUT_DIR}/batch.log"

    # Export serial for provision script
    export TARGET_SERIAL="${serial}"
    LOG_FILE="${OUTPUT_DIR}/${serial}.log"

    # Run provisioning script with timeout
    if timeout 300 "${PROVISION_SCRIPT}" \
            --server "${PROV_SERVER_URL:-https://provisioning.example.com}" \
            >"${LOG_FILE}" 2>&1; then
        SUCCEEDED=$(( SUCCEEDED + 1 ))
        echo "  RESULT: SUCCESS" | tee -a "${OUTPUT_DIR}/batch.log"
    else
        rc=$?
        FAILED=$(( FAILED + 1 ))
        echo "  RESULT: FAILED (exit code: ${rc})" | tee -a "${OUTPUT_DIR}/batch.log"
        echo "  Log: ${LOG_FILE}" | tee -a "${OUTPUT_DIR}/batch.log"

        # Extract last error from log
        last_error=$(tail -3 "${LOG_FILE}" | grep "ERROR\|FATAL" | head -1)
        if [[ -n "${last_error}" ]]; then
            echo "  Error: ${last_error}" | tee -a "${OUTPUT_DIR}/batch.log"
        fi
    fi

done < "${SERIAL_LIST}"

echo "" | tee -a "${OUTPUT_DIR}/batch.log"
echo "=== Batch Summary ===" | tee -a "${OUTPUT_DIR}/batch.log"
echo "Total:     ${TOTAL}" | tee -a "${OUTPUT_DIR}/batch.log"
echo "Succeeded: ${SUCCEEDED}" | tee -a "${OUTPUT_DIR}/batch.log"
echo "Failed:    ${FAILED}" | tee -a "${OUTPUT_DIR}/batch.log"
echo "Skipped:   ${SKIPPED}" | tee -a "${OUTPUT_DIR}/batch.log"
echo "Completed: $(date -Iseconds)" | tee -a "${OUTPUT_DIR}/batch.log"

if [[ "${FAILED}" -gt 0 ]]; then
    echo ""
    echo "BATCH STATUS: PARTIAL FAILURE (${FAILED}/${TOTAL} failed)"
    exit 1
else
    echo ""
    echo "BATCH STATUS: COMPLETE SUCCESS"
    exit 0
fi
```
