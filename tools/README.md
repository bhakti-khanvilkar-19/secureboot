# Tools Reference

## Tool Inventory

| Tool | Version | Purpose | Source |
|------|---------|---------|--------|
| NXP CST | 3.4.0+ | HABv4 CSF generation and signing | NXP registration required |
| mkimage | 2023.04+ | FIT image creation and signing | `apt install u-boot-tools` |
| dumpimage | 2023.04+ | FIT image inspection | Same package as mkimage |
| srktool | bundled with CST | SRK table + fuse value generation | NXP CST |
| openssl | 3.0+ | Key generation, signing, verification | `apt install openssl` |
| uuu | 1.4.182+ | Universal Update Utility (SDP flashing) | GitHub: nxp-imx/mfgtools |
| veritysetup | 2.4.3+ | dm-verity hash tree generation | `apt install cryptsetup` |
| tpm2-tools | 5.0+ | TPM 2.0 key management and PCR reading | `apt install tpm2-tools` |
| dtc | 1.6+ | Device tree compiler | `apt install device-tree-compiler` |
| fdtdump | 1.6+ | Device tree dump (inspect DTB) | Same package as dtc |

## Cross-References

- [tool-versions.md](tool-versions.md) — Verified compatible versions
- [../scripts/README.md](../scripts/README.md) — Scripts using these tools
