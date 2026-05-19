# ITS (Image Tree Source) File Format

## Complete Annotated ITS Example

```dts
/dts-v1/;

/ {
    /* Description shown by dumpimage -l */
    description = "phyCORE-i.MX8MP Production Secure Boot Image";

    /* Must be <1> for 32-bit addresses */
    #address-cells = <1>;

    images {

        /* ─────────────────────────────────────────────────── */
        /* KERNEL IMAGE NODE                                   */
        /* ─────────────────────────────────────────────────── */
        kernel@1 {
            description = "Linux Kernel 6.6.0";

            /* Include binary file at build time */
            data = /incbin/("Image");

            /* Image type — determines how U-Boot handles it */
            type = kernel;

            /* CPU architecture */
            arch = arm64;

            /* Operating system */
            os = linux;

            /* Compression: none recommended for kernel (faster boot) */
            compression = none;

            /* Load address: where kernel is placed in RAM */
            /* i.MX8MP: DRAM starts at 0x40000000, kernel at +0x480000 */
            load = <0x40480000>;

            /* Entry point: where execution begins (same as load for arm64) */
            entry = <0x40480000>;

            /* Hash node: mkimage fills 'value' at build time */
            hash@1 {
                algo = "sha256";
                /* value = <...> added by mkimage */
            };
        };

        /* ─────────────────────────────────────────────────── */
        /* DEVICE TREE NODE                                    */
        /* ─────────────────────────────────────────────────── */
        fdt@1 {
            description = "phyCORE-i.MX8MP Device Tree (SOM)";

            data = /incbin/("imx8mp-phycore-som-pd22.1.0.dtb");

            /* flat_dt = Flattened Device Tree */
            type = flat_dt;
            arch = arm64;
            compression = none;

            /* DTB load address: U-Boot places it here before bootm */
            load = <0x43000000>;

            hash@1 {
                algo = "sha256";
            };
        };

        /* Second DTB for kit variant */
        fdt@2 {
            description = "phyBOARD-Pollux Kit Device Tree";
            data = /incbin/("imx8mp-phyboard-pollux-rdk-pd22.1.0.dtb");
            type = flat_dt;
            arch = arm64;
            compression = none;
            load = <0x43000000>;
            hash@1 {
                algo = "sha256";
            };
        };

        /* ─────────────────────────────────────────────────── */
        /* INITRAMFS NODE                                      */
        /* ─────────────────────────────────────────────────── */
        ramdisk@1 {
            description = "phytec-securiphy initramfs";

            /* Compressed initramfs cpio archive */
            data = /incbin/("phytec-securiphy-image.cpio.gz");

            type = ramdisk;
            arch = arm64;
            os = linux;

            /* gzip compression (already gzipped by Yocto) */
            compression = gzip;

            /* Ramdisk: U-Boot places anywhere, kernel locates via ATAGs */
            /* load/entry not needed for ramdisk */

            hash@1 {
                algo = "sha256";
            };
        };

    }; /* end images */

    configurations {

        /* Default configuration selected at boot */
        default = "conf@1";

        /* ─────────────────────────────────────────────────── */
        /* PRIMARY CONFIGURATION (SOM + SOM DTB)              */
        /* ─────────────────────────────────────────────────── */
        conf@1 {
            description = "phyCORE-i.MX8MP Secure Boot (SOM)";
            kernel    = "kernel@1";
            fdt       = "fdt@1";
            ramdisk   = "ramdisk@1";

            /* Signature node: RSA signature over this configuration */
            signature@1 {
                /* Algorithm: hash_algorithm,signature_algorithm */
                algo = "sha256,rsa2048";

                /* Must match filename (without extension) in key directory */
                key-name-hint = "fit-signing-key";

                /* Which images are included in this signature */
                /* The signature covers: hash(kernel) + hash(fdt) + hash(ramdisk) */
                sign-images = "kernel", "fdt", "ramdisk";

                /* value = <...> added by mkimage -F -r */
            };
        };

        /* ─────────────────────────────────────────────────── */
        /* SECONDARY CONFIGURATION (Kit + Kit DTB)            */
        /* ─────────────────────────────────────────────────── */
        conf@2 {
            description = "phyCORE-i.MX8MP Secure Boot (Kit)";
            kernel = "kernel@1";
            fdt    = "fdt@2";        /* Different DTB */
            ramdisk = "ramdisk@1";

            signature@1 {
                algo = "sha256,rsa2048";
                key-name-hint = "fit-signing-key";
                sign-images = "kernel", "fdt", "ramdisk";
            };
        };

    }; /* end configurations */
};
```

---

## Load Address Calculations (i.MX8MP)

```
DRAM base:        0x40000000
Kernel load:      0x40480000  (base + 0x480000 = +4.5MB)
DTB load:         0x43000000  (base + 3MB, after kernel)
Ramdisk load:     0x44000000  (or wherever U-Boot fits it)
FIT image load:   0x40400000  (before kernel, U-Boot loads FIT here first)

Memory layout during FIT load:
0x40400000: FIT image (22MB) → kernel, dtb, ramdisk extracted from here
0x40480000: kernel Image (extracted from FIT)
0x43000000: DTB (extracted from FIT)
0x7AE60000: ramdisk (placed at top of RAM by U-Boot)
```

---

## Valid Values Reference

### type
| Value | Description |
|-------|-------------|
| `kernel` | Linux kernel |
| `flat_dt` | Device Tree Blob |
| `ramdisk` | Initial RAM filesystem |
| `firmware` | Firmware blob (TF-A, OP-TEE) |
| `standalone` | Standalone program |
| `script` | U-Boot script |
| `fpga` | FPGA bitstream |
| `loadable` | Loadable binary |
| `vbmeta` | Android Verified Boot metadata |

### compression
| Value | Description |
|-------|-------------|
| `none` | No compression |
| `gzip` | GNU zip |
| `bzip2` | Bzip2 |
| `lzma` | LZMA |
| `lzo` | LZO |
| `lz4` | LZ4 |
| `zstd` | Zstandard |

### algo (signature)
| Value | Security Level |
|-------|---------------|
| `sha256,rsa2048` | 112-bit (minimum for HABv4) |
| `sha256,rsa4096` | 140-bit |
| `sha384,rsa4096` | 140-bit (stronger hash) |
| `sha256,ecdsa256` | 128-bit (P-256) |
| `sha384,ecdsa384` | 192-bit (P-384) |

---

## ITS for External Data (Large Images)

For large images, use external data to avoid bloating the ITS:

```dts
/* External data mode: data stored separately, referenced by offset */
kernel@1 {
    data-size = <0x01400000>;    /* 20MB */
    data-position = <0x00001000>; /* Offset in combined image */
    type = kernel;
    ...
};
```

Build with: `mkimage -E -f fitimage.its fitimage.bin`  
External data is appended after the FDT structure.
