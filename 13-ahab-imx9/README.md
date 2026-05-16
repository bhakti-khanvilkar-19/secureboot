# AHAB on i.MX9: Advanced High Assurance Boot Reference

```
Tested Against:
  - NXP CST: 3.4.0 (with AHAB support)
  - U-Boot: 2024.01 (NXP lf-6.6.3-1.0.0)
  - Linux Kernel: 6.6.3 (NXP lf-6.6.3-1.0.0)
  - NXP SPSDK: 2.3.0
  - imx-mkimage: lf-6.6.3-1.0.0
Last Validated: 2024-Q4
Platform: NXP i.MX93 (phyCORE-i.MX93), i.MX95
```

---

## Overview

AHAB (Advanced High Assurance Boot) is NXP's next-generation secure boot architecture, introduced with the i.MX8ULP and deployed as the primary boot security mechanism across the entire i.MX9 family (i.MX91, i.MX93, i.MX95). AHAB is not an incremental revision of HABv4 — it is a complete architectural redesign driven by two requirements that HABv4 could not cleanly satisfy: support for multiple authenticatable images in a single boot container, and delegation of all cryptographic operations to an isolated security processor.

This chapter covers AHAB from the architectural level through production deployment, including comparison with HABv4, the EdgeLock Enclave subsystem, signed container binary format, SRK key management with ECC support, lifecycle state transitions, and the CST/imx-mkimage workflow for i.MX93.

---

## AHAB vs HABv4: Architectural Differences

Understanding the differences is essential when migrating designs from i.MX8M to i.MX9, or when evaluating which platform to choose for a new design.

### Authentication Model

**HABv4 model (i.MX8M and earlier):**

The Boot ROM parses a fixed-format structure called the Image Vector Table (IVT), which sits at a known offset in the boot image. The IVT points to two things: the actual image data, and a Command Sequence File (CSF) that contains all authentication commands and the RSA signature. The ROM executes HAB library calls to process the CSF, authenticate the image, and report success or failure via an event log.

The critical consequence of this model is that the CSF is a separate structure from the image it authenticates. The signing workflow involves generating the image, computing its hash, and producing the CSF as a separate artifact that gets appended to the image binary. The CSF references the image data by address range and length — this tight coupling to memory layout makes the workflow sensitive to image size changes.

**AHAB model (i.MX9):**

The Boot ROM does not parse an IVT. Instead, it parses an **AHAB Signed Container Header**, a self-describing structure at a fixed boot media offset. The container header enumerates all images that should be authenticated (TF-A BL31, OP-TEE, U-Boot SPL, U-Boot proper), provides their load addresses and hashes, and references a Signature Block that contains the SRK table and the cryptographic signature over the entire container header and image array.

The ROM loads each image listed in the container to its specified load address, verifies the hash of each image against the hash stored in the container header, and then verifies the container header's signature using the SRK. If any step fails, the ROM halts (in CLOSED lifecycle) or logs an event (in OPEN lifecycle).

### Key Structural Differences

| Property | HABv4 | AHAB |
|----------|-------|------|
| ROM parsing target | IVT at fixed offset | Container header at fixed offset |
| Separate CSF file | Yes — appended to image | No — signature block embedded in container |
| Multi-image authentication | No — one image per CSF | Yes — up to 8 images per container |
| Cryptographic engine | CAAM (Cortex-A controlled) | EdgeLock Enclave (dedicated M33 security processor) |
| Key algorithm support | RSA-2048, RSA-4096 | RSA-2048, RSA-4096, ECDSA P-256, ECDSA P-521 |
| SRK hash fused location | OTP bank 3–6 | OTP fuse field (ELE-controlled) |
| Key revocation | Per-SRK slot fuse | Per-SRK slot via ELE API |
| Anti-rollback | Not natively enforced | SW version field in container header |
| Attestation | Not available | ELE provides attestation tokens |
| Lifecycle control | HAB API in ROM | ELE firmware commands |

### CSF File vs Container: Signing Workflow Difference

HABv4 requires generating a CSF text file that references specific byte ranges in the image, compiling it with CST, and re-embedding the result. This creates a circular dependency (the CSF modifies the image, but the CSF was signed based on the image before modification), resolved by a two-pass signing process with padded CSF regions.

AHAB eliminates this problem. The container header lists each image's hash independently. The signer computes the SHA-256/384/512 digest of each image binary, places those digests in the image entry array, then signs the container header (which includes the image entries). There is no circular dependency. Adding an image to the container does not require re-signing other images — only the container header signature is updated.

### No Separate CSF File in AHAB

A frequent confusion when migrating from HABv4: **AHAB has no CSF file**. The equivalent of the CSF commands is embedded in the container structure itself. The `CST` tool, when invoked for AHAB, generates a complete signed container binary rather than a CSF appendage. The imx-mkimage tool then combines these containers with the raw image binaries to produce the final `flash.bin`.

---

## EdgeLock Enclave (ELE) Subsystem

The most significant architectural change in i.MX9 relative to i.MX8M is the introduction of the EdgeLock Enclave (ELE). ELE is a dedicated security subsystem implemented as a Cortex-M33 processor running NXP-signed firmware, isolated from the application processors by hardware access controls.

### ELE Purpose and Scope

In HABv4 systems, cryptographic operations during boot run on the same Cortex-A cores that will later run Linux. The HAB library in ROM executes on the Cortex-A before Linux boots, but the cryptographic accelerator (CAAM) is a shared peripheral accessible from Cortex-A normal world. This means that a compromised bootloader could potentially interfere with the cryptographic verification of subsequent stages.

ELE resolves this by moving all security-critical operations to a separate processor that the Cortex-A cannot directly control:

- All cryptographic operations during boot authentication run inside ELE
- ELE has exclusive access to the OTP fuse values for SRK hash comparison
- ELE manages device lifecycle state transitions
- ELE provides secure key storage and wrapping for application use
- ELE generates attestation tokens upon request
- ELE controls CAAM resource ownership after Linux boots

The Cortex-A communicates with ELE via a Message Unit (MU) interface — a hardware mailbox. ELE validates each message and performs the requested operation internally, returning only the result. The Cortex-A never has direct access to the raw cryptographic keys or fuse values.

### ELE Firmware

ELE runs NXP-signed firmware stored in the boot image. This firmware is authenticated by a ROM-internal public key whose hash is embedded in the chip at fabrication (separate from the user-controllable SRK fuses). The ELE firmware version is also subject to anti-rollback protection enforced by ELE itself.

ELE firmware provides these services via MU messages:

```
ELE Services (partial list):
├── Lifecycle management
│   ├── ELE_OEM_CNTN_AUTH: Authenticate OEM AHAB container
│   ├── ELE_VERIFY_IMAGE: Verify individual image within container
│   ├── ELE_FORWARD_LIFECYCLE: Advance lifecycle state
│   └── ELE_READ_FUSE: Read OTP fuse value (ELE-controlled)
├── Cryptographic services
│   ├── ELE_GENERATE_KEY: Generate key in secure storage
│   ├── ELE_IMPORT_KEY: Import wrapped key
│   ├── ELE_SIGN: Sign data with stored key
│   ├── ELE_VERIFY: Verify signature
│   ├── ELE_ENCRYPT: Encrypt data (AES-GCM, AES-CBC)
│   └── ELE_DECRYPT: Decrypt data
├── Secure storage
│   ├── ELE_OPEN_DATA_STORAGE: Open secure storage session
│   ├── ELE_CREATE_DATA_STORAGE: Create secure storage chunk
│   └── ELE_GET_DATA_STORAGE: Retrieve data from secure storage
└── Attestation
    ├── ELE_ATTEST: Generate attestation token
    └── ELE_GET_INFO: Get device/firmware information
```

### ELE Boot Role

During ROM execution on i.MX93, the boot sequence is:

1. Cortex-A55 reset vector executes ROM code
2. ROM copies ELE firmware to ELE SRAM and releases ELE reset
3. ELE authenticates its own firmware using ROM public key
4. ELE signals ROM via MU that it is ready
5. ROM requests ELE to authenticate the AHAB container
6. ELE verifies container header signature against SRK hash in OTP
7. ELE verifies each image hash against values in image entry array
8. ELE returns authentication result to ROM
9. ROM transfers control to first image (SPL or BL31 depending on configuration)

Steps 5–8 all execute inside ELE. The Cortex-A ROM code never handles raw signature data or key material — it only receives a pass/fail result from ELE.

---

## AHAB Architecture Components

### Signed Container Header

The signed container header is the root structure that AHAB uses to describe a boot payload. It begins at a fixed offset on the boot medium (determined by the boot device type) and has a fixed 128-byte header followed by variable-length image entry array and a signature block.

The header tag byte `0x87` identifies the structure as an AHAB container header. Tooling that needs to locate a container in a binary image searches for this tag at 4-byte-aligned offsets.

Key fields in the container header:

- `version` (1 byte): Format version, currently `0x00`
- `length` (2 bytes little-endian): Total container size including signature block
- `tag` (1 byte): Must be `0x87`
- `flags` (4 bytes): Image type flags (primary, recovery, secondary)
- `sw_version` (2 bytes): Anti-rollback software version counter
- `fuse_version` (1 byte): Expected minimum fuse version for this image
- `num_images` (1 byte): Number of image entries following the header
- `sig_blk_offset` (2 bytes): Byte offset from container start to signature block

### Image Entry Array

Each image entry is 128 bytes and describes one image in the container. Entries follow the container header contiguously. The ROM uses these entries to load images to memory and verify their integrity.

Image entry fields:

- `image_offset` (4 bytes): Offset from container start to raw image data
- `load_address` (8 bytes): Target physical address for loading
- `image_size` (4 bytes): Size in bytes of image data
- `hab_flags` (4 bytes): Image type (`0x03`=ELE, `0x04`=V2X primary, `0x07`=executable), target core (`0x01`=Cortex-A55, `0x06`=Cortex-M33), hash type (`0x00`=SHA256, `0x01`=SHA384, `0x02`=SHA512)
- `image_hash` (64 bytes): SHA-256/384/512 digest of the raw image data
- `meta` (4 bytes): Compression type (0=none), encryption flag

### Signature Block

The signature block begins at `sig_blk_offset` from the container start. It contains:

- `version` (1 byte): `0x00`
- `length` (2 bytes): Size of signature block
- `tag` (1 byte): Must be `0x90`
- SRK table: 4 SRK public keys (RSA or ECDSA), each as X.509 certificate
- SRK record array: identifies which SRK was used to sign
- Signature: RSA-PSS or ECDSA signature over the container header bytes

The signed region covers: all bytes of the container header + all image entry bytes. The signature block itself is not signed — it is the container that is signed.

### Multi-Container Layout

i.MX9 boot images contain two containers:

- **Container 1** (ELE container): Contains ELE firmware image, signed by NXP. The ROM authenticates this container using the NXP-internal public key. Users cannot modify this container.
- **Container 2** (OEM container): Contains all OEM images (TF-A BL31, OP-TEE, U-Boot SPL, U-Boot proper). The ROM authenticates this container using the SRK hash from OEM-programmed OTP fuses.

Both containers are combined into the final `flash.bin` by imx-mkimage.

---

## Lifecycle States in AHAB

AHAB defines lifecycle states that control ROM behavior and ELE access permissions. Unlike HABv4 where lifecycle was controlled purely by fuse values read by ROM, AHAB lifecycle state is managed by ELE firmware using OTP fuses plus ELE internal state.

### State Definitions

**NXP Provisioned**

Factory default state. The chip has left NXP with only NXP-internal keys provisioned. OEM SRK fuses are blank (all zeros). AHAB authentication in ROM is effectively disabled because there is no OEM SRK hash to compare against — all container authentications succeed regardless of signature content.

This state is equivalent to HABv4 FAB state. No OEM key material is present.

**OEM Open**

The OEM has programmed SRK fuse values. ELE will authenticate AHAB containers against the programmed SRK hash. Authentication failures are **logged** but do not halt boot. The system boots even if signature verification fails.

This state is intended for development and debug. It allows testing the signing workflow with the production keys before closing the device. HAB event logs can be inspected from U-Boot or Linux to confirm clean authentication.

Equivalent to HABv4 OPEN lifecycle state.

**OEM Closed**

The lifecycle has been advanced past OEM Open. ELE enforces authentication: a container that fails signature verification causes ELE to halt the ROM, preventing boot of unauthenticated images.

This transition is irreversible. Once a device enters OEM Closed, it cannot return to OEM Open.

Equivalent to HABv4 CLOSED lifecycle state.

**OEM Field Return**

A special state that re-enables some debug access for devices returned from the field. Transitioning to this state requires using an NXP-signed Field Return Authorization (FRA) certificate. The OEM must request FRA generation from NXP for specific device serial numbers.

In Field Return state, JTAG debug access is re-enabled but AHAB authentication remains enforced. The state can be advanced to OEM Closed again after repair.

**OEM Locked**

An OEM Closed variant where key revocation is also disabled. An OEM can choose to advance to OEM Locked after closing if the product does not require the ability to revoke individual SRK slots during its lifetime.

This eliminates the attack surface of SRK revocation commands being accepted by ELE. The tradeoff is that if an SRK private key is compromised, the device cannot be updated to reject signatures from that key.

### State Transition Diagram

```
NXP Provisioned
      │
      │ Program OEM SRK fuses
      ▼
  OEM Open  ◄────────────────────┐
      │                          │ (Field Return workflow
      │ ELE_FORWARD_LIFECYCLE    │  re-opens from Closed)
      ▼                          │
 OEM Closed ───────────────────►─┘
      │
      │ ELE_FORWARD_LIFECYCLE
      │ (optional, to disable key revocation)
      ▼
 OEM Locked
```

### Checking Current Lifecycle State

From U-Boot (i.MX93):

```bash
# ELE provides lifecycle info via ahab_status command
=> ahab_status

ELE Status
----------
ELE firmware version: 0.1.1-2fb4b48
ELE Lifecycle: 0x0008        # OEM Open = 0x0010, OEM Closed = 0x0080

# Lifecycle encoding:
# 0x0001 = NXP Provisioned
# 0x0002 = NXP Provisioned (OEM empty)
# 0x0008 = OEM Open
# 0x0010 = OEM Open (Keys programmed)
# 0x0080 = OEM Closed
# 0x0100 = OEM Field Return
# 0x0200 = OEM Locked
```

From Linux via ELE kernel driver:

```bash
# Read lifecycle via sysfs (if ele driver loaded)
cat /sys/bus/platform/drivers/ele-mu/*/lifecycle

# Or via devmem (ELE MU base address on i.MX93: 0x47520000)
# Not recommended for production — use ELE API

# Check dmesg for ELE authentication events
dmesg | grep -i "ele\|ahab"
```

---

## Migration from i.MX8M to i.MX9

### Workflow Changes Summary

When migrating a product design from i.MX8MP (HABv4) to i.MX93 (AHAB), the following workflow elements change:

**Key generation:** The PKI tree structure is similar (SRK table with 4 slots), but the key generation script changes from `hab4_pki_tree.sh` to `ahab_pki_tree.sh`. ECC keys (P-256, P-521) are now an option in addition to RSA. The SRK table binary format differs between HABv4 and AHAB.

**CSF files:** Eliminated entirely. The AHAB container is generated by CST with a JSON/YAML configuration file (SPSDK format) or with a BD (Binary Description) file, depending on which NXP toolchain version you use. There are no `[Header]`, `[Install SRK]`, `[Authenticate Data]` sections to write.

**SRK hash:** The fuse addresses for the SRK hash differ between i.MX8MP (OTP bank 3-6) and i.MX93 (ELE-managed OTP range). The `srktool` output format is the same (32 bytes), but the fuse programming commands change.

**imx-mkimage targets:** HABv4 used `flash_evk` with post-build signing. AHAB integrates signing into the imx-mkimage build flow via AHAB-specific make targets.

**Boot image structure:** HABv4 produced: DDR firmware + SPL (with appended CSF) + U-Boot proper (with appended CSF). AHAB produces: ELE firmware container (NXP-signed) + OEM container (SPL + BL31 + OP-TEE + U-Boot proper, all authenticated by one container header).

**U-Boot verification:** HABv4 used `hab_auth_img` U-Boot commands. AHAB uses `ahab_auth_img` and the verification behavior changes because ELE performs the actual verification on behalf of U-Boot.

**FIT signing:** Unchanged. FIT image signing (for kernel + DTB + initramfs) uses the same U-Boot `verified-boot` mechanism on both platforms. The HABv4/AHAB boundary is below U-Boot; FIT verification happens within U-Boot and is independent of the boot ROM authentication mechanism.

### Side-by-Side Comparison

| Workflow Step | i.MX8MP (HABv4) | i.MX93 (AHAB) |
|---------------|-----------------|----------------|
| Key generation script | `hab4_pki_tree.sh` | `ahab_pki_tree.sh` |
| Key algorithm | RSA-2048, RSA-4096 | RSA or ECDSA P-256/P-521 |
| Signing artifact | CSF file (binary) | AHAB container binary |
| Signing tool | CST `cst --o` | CST with BD/YAML or SPSDK |
| Image combining | imx-mkimage + post-sign | imx-mkimage AHAB targets |
| SRK fuse bank | OTP bank 3 (words 0–7) | ELE OTP (chip-specific) |
| SRK programming | `fuse prog 3 0 0x...` | `fuse prog` with ELE addresses |
| Lifecycle close | `fuse prog 1 3 0x2` | ELE forward lifecycle command |
| Authentication check | `hab_status` | `ahab_status` |
| Authentication events | HAB event log (RVT API) | ELE event log (MU API) |

---

## CST Tool Support for AHAB

NXP Code Signing Tool (CST) version 3.4.0 and later supports AHAB container generation. The tool interface differs from HABv4 CSF generation.

### CST AHAB Invocation

CST accepts a Binary Description (BD) file that specifies container parameters:

```
# ahab_container.bd
sources {
    ELE = "mx93a0-ahab-container.img";  # NXP ELE firmware (downloaded from NXP)
    BL31 = "bl31.bin";
    OPTEE = "tee.bin";
    SPL = "u-boot-spl.bin";
    UBOOT = "u-boot-nodtb.bin";
    UBDTB = "u-boot.dtb";
}

section (id = AHAB_CONTAINER) {
    Soc = i.MX93;
    sw_version = 0;
    fuse_version = 0;
    images {
        ELE(type = ELE, core = ELE, hash = sha384) { ... };
        BL31(type = executable, core = cortex-a55, 
             load_addr = 0xBB000000, hash = sha256) { ... };
        OPTEE(type = executable, core = cortex-a55,
              load_addr = 0x56000000, hash = sha256) { ... };
        SPL(type = executable, core = cortex-a55,
            load_addr = 0x2049A000, hash = sha256) { ... };
    };
    SRK_table = "SRK_1_2_3_4_table.bin";
    SRK_index = 0;
    RSA_key = "SRK1_sha256_2048_65537_v3_usr_key.pem";
    # or for ECC:
    ECDSA_key = "SRK1_p256_v3_usr_key.pem";
};
```

Invoke CST:

```bash
cst --i ahab_container.bd --o flash.bin
```

### SPSDK Alternative

NXP's SPSDK (Secure Provisioning SDK) provides a Python-based alternative to CST for AHAB container generation, with YAML-based configuration:

```bash
# Install SPSDK
pip install spsdk

# Generate AHAB container with SPSDK
nxpimage ahab export --config ahab_config.yaml --output flash.bin

# Verify generated container
nxpimage ahab parse --binary flash.bin
```

SPSDK is actively developed and recommended for new designs targeting i.MX9.

---

## imx-mkimage AHAB Targets

For i.MX93, imx-mkimage provides AHAB-specific make targets that integrate with CST or SPSDK output:

```bash
# Clone imx-mkimage (NXP fork, lf-6.6.x branch)
git clone https://github.com/nxp-imx/imx-mkimage.git
cd imx-mkimage
git checkout lf-6.6.3-1.0.0

# Required binaries in iMX9/ directory:
ls iMX9/
# bl31.bin          - TF-A BL31
# tee.bin           - OP-TEE
# u-boot-spl.bin    - U-Boot SPL
# u-boot-nodtb.bin  - U-Boot without DTB
# u-boot.dtb        - U-Boot DTB (with FIT signing public key)
# lpddr4_*.bin      - DDR PHY firmware (from NXP)
# mx93a0-ahab-container.img  - ELE firmware container (from NXP)

# Build signed combined image (AHAB signing done externally by CST)
make SOC=iMX9 flash_singleboot

# Output: iMX9/flash.bin
# This is the bootable image combining ELE container + OEM container

# For SPI NOR (FlexSPI) boot:
make SOC=iMX9 flash_singleboot_flexspi

# Inspect output:
ls -la iMX9/flash.bin
# The offset of each component is printed during make
```

The `flash_singleboot` target positions images at the offsets expected by the i.MX93 ROM for SD card / eMMC boot. The exact offsets are:

- Offset `0x0`: Not used (MBR area)
- Offset `0x8000` (32 KB): AHAB container 1 (ELE firmware, NXP-signed)
- Offset `0x9000` or dynamically calculated: AHAB container 2 (OEM content)
- Image data: follows OEM container header

---

## SRK Key Generation for AHAB

### Using the ahab_pki_tree.sh Script (CST)

CST provides a shell script equivalent to `hab4_pki_tree.sh` for AHAB key generation:

```bash
cd /opt/cst-3.4.0/keys/

# Run interactive key generation
./ahab_pki_tree.sh

# Script prompts:
# Do you want to use an existing CA key (y/n)? n
# Enter key name prefix: SRK
# Enter number of SRK keys [1–4]: 4
# Enter key algorithm (rsa/ecdsa): ecdsa
# Enter ECDSA curve (P-256/P-521): P-256
# Enter certificate validity (days): 3650

# Output files:
# SRK1_sha256_secp256r1_v3_usr_key.pem  - SRK1 private key
# SRK1_sha256_secp256r1_v3_usr_cert.pem - SRK1 certificate
# SRK2_sha256_secp256r1_v3_usr_key.pem
# SRK2_sha256_secp256r1_v3_usr_cert.pem
# SRK3_sha256_secp256r1_v3_usr_key.pem
# SRK3_sha256_secp256r1_v3_usr_cert.pem
# SRK4_sha256_secp256r1_v3_usr_key.pem
# SRK4_sha256_secp256r1_v3_usr_cert.pem
```

### Manual ECC Key Generation with OpenSSL

If you prefer direct OpenSSL control (for HSM integration or audit purposes):

```bash
# Generate 4 SRK key pairs using ECDSA P-256
for i in 1 2 3 4; do
    # Generate private key
    openssl ecparam -name prime256v1 -genkey -noout \
        -out SRK${i}-ec256-key.pem

    # Generate self-signed certificate (10-year validity)
    openssl req -new -x509 \
        -key SRK${i}-ec256-key.pem \
        -out SRK${i}-ec256-cert.pem \
        -days 3650 \
        -subj "/C=DE/O=OEM Name/CN=SRK${i} AHAB Signing Key"

    # Verify
    openssl x509 -in SRK${i}-ec256-cert.pem -noout -text | \
        grep -E "Subject:|Not After"
done

# Generate SRK table binary (used for fuse hash computation)
# CST srktool handles AHAB SRK table format
srktool --hab_ver 4.5 \
        --certs SRK1-ec256-cert.pem,SRK2-ec256-cert.pem,SRK3-ec256-cert.pem,SRK4-ec256-cert.pem \
        --table SRK_1_2_3_4_table.bin \
        --efuses SRK_1_2_3_4_fuse.bin \
        --digest sha256

# Verify SRK table was generated
ls -la SRK_1_2_3_4_table.bin SRK_1_2_3_4_fuse.bin
# SRK_1_2_3_4_table.bin: embedded in AHAB container signature block
# SRK_1_2_3_4_fuse.bin:  32 bytes; SHA-256 of SRK table, program to OTP
```

### Programming SRK Fuses on i.MX93

The SRK fuse addresses differ from i.MX8MP. Refer to the i.MX93 Security Reference Manual for precise fuse locations. General process from U-Boot:

```bash
# Display current SRK fuse content
=> fuse read 16 0 8    # Banks and words differ per chip - verify in SRM

# Program SRK hash (32 bytes = 8 x 32-bit words)
# Values come from SRK_1_2_3_4_fuse.bin
=> fuse prog -y 16 0 0xAABBCCDD  # word 0
=> fuse prog -y 16 1 0xEEFF0011  # word 1
# ... repeat for words 2–7

# Advance lifecycle to OEM Open (fuses programmed, verification enabled)
# This is done via ELE command, not direct fuse write
=> ahab_close

# Verify authentication status
=> ahab_status
```

---

## Further Reading

- `01-ahab-container-format.md`: Binary container format deep dive, inspection tools, imx-mkimage AHAB targets
- NXP i.MX93 Security Reference Manual (document IMX93SRM)
- NXP Application Note AN13195: AHAB Guide for i.MX9 Series
- NXP AHAB CST User Guide (included with CST 3.4.0+)
- SPSDK documentation: https://spsdk.readthedocs.io
