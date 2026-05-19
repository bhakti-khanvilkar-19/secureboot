# Tool Versions

## Verified Compatible Versions

The following tool versions have been verified for use with i.MX8MP HABv4 secure boot:

| Tool | Minimum Version | Recommended | Notes |
|------|----------------|-------------|-------|
| NXP CST | 3.3.1 | 3.4.0 | Required for HABv4 CSF generation |
| openssl | 1.1.1 | 3.0.x | 3.0+ preferred; 1.1.1 still works |
| mkimage | 2022.01 | 2023.04 | Earlier versions may lack FIT signing features |
| uuu | 1.4.43 | 1.4.182 | Required for USB SDP flashing |
| veritysetup | 2.3.6 | 2.4.3+ | Part of cryptsetup package |
| tpm2-tools | 4.0 | 5.2 | TPM 2.0 management |
| dtc | 1.6.0 | 1.7.0 | Device tree compiler |
| Python | 3.8 | 3.10+ | For provisioning and analysis scripts |

## Installation (Ubuntu 22.04)

```bash
# Core tools:
sudo apt-get install -y \
    openssl \
    u-boot-tools \
    device-tree-compiler \
    cryptsetup \
    tpm2-tools \
    python3 \
    python3-cryptography

# uuu (Universal Update Utility):
# Download from: https://github.com/nxp-imx/mfgtools/releases
wget https://github.com/nxp-imx/mfgtools/releases/download/uuu_1.4.182/uuu
chmod +x uuu
sudo mv uuu /usr/local/bin/

# NXP CST: Download from NXP (requires account)
# https://www.nxp.com/webapp/sps/download/license.jsp?colCode=IMX_CST_TOOL_NEW
# Install to /opt/cst/:
tar xf cst-*.tar.bz2
sudo mv cst /opt/cst
sudo chmod +x /opt/cst/linux64/bin/*
echo 'export PATH=$PATH:/opt/cst/linux64/bin' >> ~/.bashrc
```

## Version Checking

```bash
# Verify all tools:
echo "=== Tool Version Check ==="
openssl version
mkimage --version 2>&1 | head -1
uuu --version 2>&1 | head -1
veritysetup --version 2>&1 | head -1
tpm2_getcap --version 2>&1 | head -1
dtc --version
python3 --version

# CST:
/opt/cst/linux64/bin/cst --version 2>&1 | head -1
/opt/cst/linux64/bin/srktool --version 2>&1 | head -1
```
