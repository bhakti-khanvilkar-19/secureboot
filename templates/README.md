# Templates

## Available Templates

| Template | Purpose | Section |
|----------|---------|---------|
| [csf/spl-uboot-csf.cfg.template](csf/spl-uboot-csf.cfg.template) | HABv4 CSF for imx-boot signing | §10, §12 |
| [its/fitimage-template.its](its/fitimage-template.its) | FIT image source file | §09 |
| [yocto/local.conf.secure-boot.template](yocto/local.conf.secure-boot.template) | Yocto local.conf for secure boot | §14 |

## Using Templates

Templates use `@@VARIABLE@@` placeholders that must be replaced before use:

```bash
# Replace placeholders in a template:
sed \
    -e 's|@@KEY_DIR@@|/path/to/keys|g' \
    -e 's|@@FLASH_BIN@@|imx-boot.bin|g' \
    -e 's|@@SPL_LOAD_ADDR@@|0x7E1000|g' \
    -e 's|@@PADDED_SIZE@@|0x100000|g' \
    csf/spl-uboot-csf.cfg.template > imxboot_csf.cfg
```

## Cross-References

- [../10-image-signing/01-signing-workflows.md](../10-image-signing/01-signing-workflows.md) — CSF template usage
- [../09-fit-images/01-its-file-format.md](../09-fit-images/01-its-file-format.md) — ITS format reference
- [../14-yocto-secure-boot/01-yocto-layer-configuration.md](../14-yocto-secure-boot/01-yocto-layer-configuration.md) — Yocto configuration
