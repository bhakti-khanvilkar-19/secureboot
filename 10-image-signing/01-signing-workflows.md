# Signing Workflows

## Workflow 1: HABv4 imx-boot Signing

### Prerequisites
- NXP Code Signing Tool (CST) installed at `/opt/cst`
- HABv4 keys generated (see [11-key-management/01-key-generation.md](../11-key-management/01-key-generation.md))
- Unsigned `imx-boot.bin` from Yocto build

### Step 1: Determine Image Parameters

```bash
FLASH_BIN="imx-boot-phyboard-pollux-imx8mp-3-sd.bin-flash_evk"
KEY_DIR="/secure/hab-keys"

# Get image size
FLASH_SIZE=$(wc -c < "$FLASH_BIN")
echo "Flash image size: $FLASH_SIZE bytes ($(printf '0x%x' $FLASH_SIZE))"

# Determine SPL load address (from imx-mkimage output or linker map)
SPL_LOAD_ADDR="0x7E1000"

# Pad to 4KB boundary for CSF alignment
PADDED_SIZE=$(( (FLASH_SIZE + 0xFFF) & ~0xFFF ))
echo "Padded size: $PADDED_SIZE bytes ($(printf '0x%x' $PADDED_SIZE))"
```

### Step 2: Create CSF Configuration

```bash
cat > imxboot_csf.cfg << EOF
[Header]
    Version = 4.3
    Hash Algorithm = sha256
    Engine = CAAM
    Engine Configuration = 0
    Certificate Format = X509
    Signature Format = CMS

[Install SRK]
    File = "${KEY_DIR}/SRK_1_2_3_4_table.bin"
    Source index = 0

[Install CSFK]
    File = "${KEY_DIR}/crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate CSF]

[Install Key]
    Verification index = 0
    Target index = 2
    File = "${KEY_DIR}/crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem"

[Authenticate Data]
    Verification index = 2
    Blocks = ${SPL_LOAD_ADDR} 0x000 ${PADDED_SIZE} "${FLASH_BIN}"
EOF
```

### Step 3: Generate CSF Binary

```bash
export PATH=$PATH:/opt/cst/linux64/bin

cst -o imxboot_csf.bin -i imxboot_csf.cfg

echo "CSF generated: imxboot_csf.bin ($(wc -c < imxboot_csf.bin) bytes)"
```

### Step 4: Combine Image and CSF

```bash
# Pad original image to alignment boundary
dd if="$FLASH_BIN" of="${FLASH_BIN}-padded" bs=1 count="$PADDED_SIZE" conv=sync

# Append CSF
cat "${FLASH_BIN}-padded" imxboot_csf.bin > "${FLASH_BIN}-signed"

echo "Signed image: ${FLASH_BIN}-signed ($(wc -c < "${FLASH_BIN}-signed") bytes)"
```

### Step 5: Verify (in HAB Open Mode)

Flash the signed image and check U-Boot:
```
=> hab_status
HAB Configuration: 0x00 HAB State: 0x00
No HAB Events Found!
```

---

## Workflow 2: FIT Image Signing

### Prerequisites
- FIT signing key generated (see below)
- Unsigned FIT image from Yocto build
- `u-boot-tools` package installed

### Generate FIT Signing Key (one time)

```bash
mkdir -p keys/fit
KEY_NAME="fit-signing-key"

# Generate RSA-2048 private key
openssl genrsa -out "keys/fit/${KEY_NAME}.pem" 2048

# Generate self-signed certificate
openssl req -new -x509 \
    -key "keys/fit/${KEY_NAME}.pem" \
    -out "keys/fit/${KEY_NAME}.crt" \
    -days 3650 \
    -subj "/CN=${KEY_NAME}/O=PHYTEC Messtechnik GmbH/C=DE"

echo "Key fingerprint:"
openssl x509 -in "keys/fit/${KEY_NAME}.crt" -fingerprint -sha256 -noout
```

### Sign FIT Image

```bash
FIT_IMAGE="fitImage"
KEY_DIR="keys/fit"
KEY_NAME="fit-signing-key"
UBOOT_DTB="u-boot.dtb"

# Step 1: Sign FIT and embed public key in U-Boot DTB
mkimage -F "$FIT_IMAGE" \
        -k "$KEY_DIR" \
        -K "$UBOOT_DTB" \
        -r

# Step 2: Verify signature
dumpimage -l "$FIT_IMAGE" | grep -E "Sign algo|Sign value|Verified"
```

### Verify Signing Result

```bash
# Check FIT has signature nodes
dumpimage -l fitImage | grep "Sign algo"
# Should show:
# Sign algo:    sha256,rsa2048:fit-signing-key

# Check U-Boot DTB has embedded key
fdtdump u-boot.dtb | grep -A5 "signature"
# Should show:
# signature {
#   key-fit-signing-key {
#     required = "conf";
#     algo = "sha256,rsa2048";
```

---

## Workflow 3: SWUpdate Package Signing

```bash
SWU_KEY="keys/swupdate-signing-key.pem"
SWU_CERT="keys/swupdate-signing-cert.pem"

# Generate SWUpdate signing key (one time)
openssl genrsa -out "$SWU_KEY" 2048
openssl req -new -x509 -key "$SWU_KEY" -out "$SWU_CERT" -days 3650 \
    -subj "/CN=SWUpdate Signing Key/O=PHYTEC/C=DE"

# Sign sw-description
openssl cms -sign \
    -in sw-description \
    -out sw-description.sig \
    -signer "$SWU_CERT" \
    -inkey "$SWU_KEY" \
    -outform DER \
    -nosmimecap \
    -binary

# Create SWU package
echo sw-description sw-description.sig rootfs.ext4.gz fitImage imx-boot-signed.bin | \
    tr ' ' '\n' | \
    cpio -ovL -H newc > update-v2.0.swu

echo "SWU package: update-v2.0.swu ($(wc -c < update-v2.0.swu) bytes)"
```

---

## Signing Checklist

Before signing any production artifact:

```
[ ] Using production keys (NOT development keys)
[ ] Keys loaded from HSM (not plaintext files on networked system)
[ ] Artifact hash verified before signing
[ ] Correct artifact version / git tag
[ ] Signing log entry created (audit trail)
[ ] Second engineer reviewed artifact
[ ] Signing output verified (dumpimage -l, hab_status)
```
