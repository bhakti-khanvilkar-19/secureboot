# NXP Documents and Resources

## Official NXP Documentation

### i.MX8MP Reference Manual

- **Document**: IMXMX8MPRM
- **Key Chapters**:
  - Chapter 6: Boot — Boot modes, IVT, DCD
  - Chapter 12: OCOTP — Fuse map, programming
  - Chapter 14: CAAM — Hardware cryptography
  - Chapter 15: SNVS — Secure non-volatile storage
  - Chapter 16: HABv4 — High Assurance Boot

### HABv4 API Reference Manual

- **Document**: IMXHABAPIRM
- **Contents**: Complete HABv4 API, status/reason/context/engine codes, event format
- **Location**: Available via NXP registration at nxp.com

### Application Notes

| Document | Title | Relevance |
|----------|-------|-----------|
| AN12079 | i.MX Secure Boot using HABv4 on i.MX 8 series | Primary HABv4 guide |
| AN4581 | i.MX6 and i.MX 7 Boot process with HABv4 | Background (older SoC) |
| AN12838 | Secure Boot on i.MX RT | Context for HABv4 variants |

### Yocto / BSP

| Resource | URL/Location |
|----------|-------------|
| meta-imx | github.com/nxp-imx/meta-imx |
| imx-mkimage | github.com/nxp-imx/imx-mkimage |
| imx-atf (TF-A) | github.com/nxp-imx/imx-atf |
| imx-optee-os | github.com/nxp-imx/imx-optee-os |
| uuu (mfgtools) | github.com/nxp-imx/mfgtools |

## PHYTEC Documentation

| Document | Description |
|----------|-------------|
| phyCORE-i.MX8MP Product Page | Hardware specifications, schematics |
| PHYTEC Yocto BSP Guide | BSP setup, layer configuration |
| securiPHY Application Note | PHYTEC secure boot implementation guide |

**PHYTEC Support**: phytec.com/support

## Accessing NXP Documents

Most NXP security documents require registration at nxp.com:
1. Create account at nxp.com
2. Navigate to i.MX8MP product page
3. Select "Documentation" tab
4. Search for document number (e.g., IMXMX8MPRM)

Some documents (application notes) are publicly accessible via:
- nxp.com/docs/en/application-note/AN12079.pdf
