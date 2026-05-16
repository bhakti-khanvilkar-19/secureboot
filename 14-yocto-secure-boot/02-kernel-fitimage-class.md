# kernel-fitimage.bbclass: Detailed Analysis

```
Source file: openembedded-core/meta/classes/kernel-fitimage.bbclass
Applies to: Yocto Scarthgap (5.0.x); class evolved significantly since Kirkstone
Primary function: FIT image assembly and signing during kernel build
```

---

## Overview

`kernel-fitimage.bbclass` is the Yocto class that transforms a compiled Linux kernel into a FIT (Flattened Image Tree) image suitable for authenticated boot with U-Boot. The class adds tasks to the kernel recipe's task graph, generates an ITS (Image Tree Source) file programmatically, and invokes `mkimage` to assemble and optionally sign the FIT.

Understanding this class is essential for:
- Debugging signing failures
- Adding custom FIT nodes (ramdisk, extra DTBs, overlays)
- Understanding why a FIT image was built with particular hashes or configurations
- Extending the ITS generation for non-standard platforms

---

## Class Inheritance Chain

```
linux-imx.bb (kernel recipe)
  └── inherits: kernel
        └── kernel.bbclass
              └── inherits: kernel-base
              └── KERNEL_CLASSES += "kernel-fitimage"
                    └── kernel-fitimage.bbclass
                          └── inherits: kernel-arch
                          └── inherits: uboot-sign  ← key embedding
```

`kernel-fitimage.bbclass` is not inherited directly by recipes. Instead, the `kernel.bbclass` dynamically inherits whatever class names are listed in `KERNEL_CLASSES`. Setting `KERNEL_CLASSES = "kernel-fitimage"` in `local.conf` causes `kernel.bbclass` to `inherit kernel-fitimage` during parsing.

---

## Tasks Added by the Class

### do_assemble_fitimage

Creates the unsigned FIT image from compiled kernel and device trees.

**Inputs:**
- `${KERNEL_IMAGETYPE}` (= "Image" for arm64) — raw kernel binary
- All DTB files matching `*.dtb` in `${B}/arch/${ARCH}/boot/dts/`
- Initramfs (if `INITRAMFS_IMAGE` is set and built)

**Outputs:**
- `${WORKDIR}/fitImage-its-${KERNEL_VERSION}-${MACHINE}` — the generated ITS source
- `${WORKDIR}/fitImage-${KERNEL_VERSION}-${MACHINE}` — unsigned FIT binary

**When it runs:** After `do_compile` (kernel compilation) and `do_install`.

**Task definition (simplified from source):**

```bitbake
python do_assemble_fitimage() {
    import subprocess
    
    # Call fitimage_assemble() with signing=False
    fitimage_assemble(d, "", False)
}
addtask assemble_fitimage before do_install after do_compile
```

### do_uboot_assemble_fitimage

Signs the FIT image (or creates a signed copy) by invoking `mkimage -F`.

**Inputs:**
- Unsigned FIT from `do_assemble_fitimage`
- `${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.pem` — private key
- `${DEPLOY_DIR_IMAGE}/u-boot.dtb` — U-Boot DTB to embed public key into

**Outputs:**
- `${WORKDIR}/fitImage-${KERNEL_VERSION}-${MACHINE}` — signed FIT image
- Modified `u-boot.dtb` — now contains embedded FIT signing public key

**Dependencies:**
```bitbake
do_uboot_assemble_fitimage[depends] = "u-boot-imx:do_deploy"
# The U-Boot DTB must exist before signing can embed the key into it
```

**When it runs:** After `do_assemble_fitimage`, before `do_install`.

**Effective command (what the class runs):**

```bash
# Sign FIT image and embed public key into U-Boot DTB
mkimage \
  -f fitImage.its \
  -k /path/to/keys/fit \
  -K u-boot.dtb \
  -r \
  -F fitImage

# Parameters:
# -f fitImage.its       Source ITS file
# -k /path/to/keys/fit  Key directory (looks for .key and .crt files)
# -K u-boot.dtb         DTB to embed public key into
# -r                    Mark configurations as 'required' (mandatory verification)
# -F                    Fit image (sign in place)
```

The `-r` flag is critical: it marks FIT configurations as `required = "yes"` in the signed FIT. When U-Boot loads a FIT with a required configuration node, it **mandates** that the configuration passes signature verification before executing. Without `-r`, U-Boot will verify signatures if present but still boot unsigned configurations.

### do_install (modified)

When `KERNEL_IMAGETYPE = "fitImage"` and signing is enabled, `do_install` copies `fitImage` (not raw `Image`) to `${D}/boot/`:

```bitbake
# In kernel-fitimage.bbclass do_install_append:
install -m 0644 ${WORKDIR}/fitImage-* ${D}/boot/
```

### do_deploy (modified)

Copies signed artifacts to `${DEPLOY_DIR_IMAGE}`:

```bitbake
# Copies:
# fitImage → DEPLOY_DIR_IMAGE/fitImage
# fitImage → DEPLOY_DIR_IMAGE/fitImage-${KERNEL_VERSION}-${MACHINE}
# fitImage.its → DEPLOY_DIR_IMAGE/fitImage-its-${KERNEL_VERSION}-${MACHINE}.its
```

---

## Internal Functions

### fitimage_assemble()

The main assembly function. Called with `signing=True` by `do_uboot_assemble_fitimage` and `signing=False` by `do_assemble_fitimage`.

```python
def fitimage_assemble(d, initramfs_req, signing):
    """
    Assembles a FIT image from kernel + DTBs + optional ramdisk.
    
    1. Writes ITS prologue (root node, images node)
    2. Calls fitimage_emit_section_kernel() to add kernel image node
    3. For each DTB: calls fitimage_emit_section_dtb()
    4. If initramfs: calls fitimage_emit_section_ramdisk()
    5. Calls fitimage_emit_section_config() for each DTB
    6. Writes ITS epilogue
    7. Invokes mkimage to compile ITS → FIT binary
    8. If signing: invokes mkimage again with -k flag to sign
    """
```

### fitimage_emit_section_kernel()

Generates the `kernel-1` node in the ITS:

```python
def fitimage_emit_section_kernel(d, f, fitimage_its, kernel_id, its_file):
    """
    Writes to its_file:
    
    kernel-{kernel_id} {
        description = "Linux kernel";
        data = /incbin/("{kernel_binary_path}");
        type = kernel;
        arch = {UBOOT_ARCH};
        os = linux;
        compression = {FIT_KERNEL_COMP_ALG};
        load = <{UBOOT_LOADADDRESS}>;
        entry = <{UBOOT_ENTRYPOINT}>;
        hash-1 {
            algo = "{FIT_HASH_ALG}";
        };
    };
    """
```

### fitimage_emit_section_dtb()

Generates a `fdt-N` node for each device tree:

```python
def fitimage_emit_section_dtb(d, f, fitimage_its, dtb_id, dtbfile):
    """
    Writes to its_file:
    
    fdt-{dtb_id} {
        description = "{dtb_filename}";
        data = /incbin/("{dtb_path}");
        type = flat_dt;
        arch = {UBOOT_ARCH};
        compression = none;
        hash-1 {
            algo = "{FIT_HASH_ALG}";
        };
    };
    """
```

### fitimage_emit_section_ramdisk()

Only called when `INITRAMFS_IMAGE` is set and an initramfs was built. Generates a `ramdisk-1` node:

```python
def fitimage_emit_section_ramdisk(d, f, fitimage_its, image_id, initramfs):
    """
    Writes to its_file:
    
    ramdisk-{image_id} {
        description = "ramdisk";
        data = /incbin/("{initramfs_path}");
        type = ramdisk;
        arch = {UBOOT_ARCH};
        os = linux;
        compression = {FIT_RAMDISK_COMP_ALG};
        hash-1 {
            algo = "{FIT_HASH_ALG}";
        };
    };
    """
```

### fitimage_emit_section_config()

Generates a configuration node that ties kernel + DTB (+ optional ramdisk) together:

```python
def fitimage_emit_section_config(d, f, fitimage_its, kernel_id, dtb_id, 
                                  ramdisk_id, bootscr_id, config_id):
    """
    Writes to its_file:
    
    conf-{config_id} {
        description = "{MACHINE} {dtb_filename}";
        kernel = "kernel-{kernel_id}";
        fdt = "fdt-{dtb_id}";
        ramdisk = "ramdisk-1";  # only if ramdisk present
        hash-1 {
            algo = "{FIT_HASH_ALG}";
        };
        signature-1 {               # only if signing enabled
            algo = "{FIT_SIGN_ALG}:{FIT_HASH_ALG}";
            key-name-hint = "{UBOOT_SIGN_KEYNAME}";
            sign-images = "kernel", "fdt";  # what gets signed
        };
    };
    """
```

### fitimage_generate_keys()

Called only when `FIT_GENERATE_KEYS = "1"`. Generates a key pair during the build:

```python
def fitimage_generate_keys(d):
    """
    Runs:
      openssl genrsa -out ${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.pem ${FIT_SIGN_NUMBITS}
      openssl req -batch -new -x509 \
          -key ${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.pem \
          -out ${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt

    WARNING: Keys generated here are stored in the build tree.
    Never use FIT_GENERATE_KEYS = "1" in production.
    """
```

---

## Generated ITS File

The ITS file generated by the class is saved to `${DEPLOY_DIR_IMAGE}` as `fitImage-its-${KERNEL_VERSION}-${MACHINE}.its`. Examining this file is the best way to understand exactly what structure `mkimage` received as input.

### Example Generated ITS (phyboard-pollux-imx8mp-3)

This is a representative ITS for a build with 2 DTBs, no ramdisk, and RSA-2048 signing:

```dts
/dts-v1/;

/ {
	description = "U-Boot fitImage for linux-imx kernel";
	#address-cells = <1>;

	images {
		kernel-1 {
			description = "Linux kernel";
			data = /incbin/("Image");
			type = "kernel";
			arch = "arm64";
			os = "linux";
			compression = "none";
			load = <0x40480000>;
			entry = <0x40480000>;
			hash-1 {
				algo = "sha256";
			};
		};
		fdt-1 {
			description = "Flattened Device Tree blob - imx8mp-phycore-som-pd22.1.0.dtb";
			data = /incbin/("imx8mp-phycore-som-pd22.1.0.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";
			hash-1 {
				algo = "sha256";
			};
		};
		fdt-2 {
			description = "Flattened Device Tree blob - imx8mp-phyboard-pollux-rdk.dtb";
			data = /incbin/("imx8mp-phyboard-pollux-rdk.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";
			hash-1 {
				algo = "sha256";
			};
		};
	};

	configurations {
		default = "conf-1";
		conf-1 {
			description = "Linux kernel, FDT blob - imx8mp-phycore-som-pd22.1.0.dtb";
			kernel = "kernel-1";
			fdt = "fdt-1";
			hash-1 {
				algo = "sha256";
			};
			signature-1 {
				algo = "sha256,rsa2048";
				key-name-hint = "fit-signing-key";
				sign-images = "kernel", "fdt";
			};
		};
		conf-2 {
			description = "Linux kernel, FDT blob - imx8mp-phyboard-pollux-rdk.dtb";
			kernel = "kernel-1";
			fdt = "fdt-2";
			hash-1 {
				algo = "sha256";
			};
			signature-1 {
				algo = "sha256,rsa2048";
				key-name-hint = "fit-signing-key";
				sign-images = "kernel", "fdt";
			};
		};
	};
};
```

### Post-Signing ITS Changes

After `mkimage -F -k` signs the FIT, the binary FIT node structure is updated. The ITS itself is not changed (it is already compiled to binary), but if you use `dumpimage -l fitImage` you will see the signature nodes now contain actual signature data:

```
# dumpimage -l fitImage output (after signing)
FIT description: U-Boot fitImage for linux-imx kernel
Created:         Fri Dec 20 14:23:01 2024
 Image 0 (kernel-1)
  Description:  Linux kernel
  Created:      Fri Dec 20 14:23:01 2024
  Type:         Kernel Image
  Compression:  uncompressed
  Data Size:    28311552 Bytes = 27648.00 KiB = 27.00 MiB
  Architecture: AArch64
  OS:           Linux
  Load Address: 0x40480000
  Entry Point:  0x40480000
  Hash algo:    sha256
  Hash value:   a3f1e29d...      ← computed by mkimage during assembly

 Image 1 (fdt-1)
  Description:  Flattened Device Tree blob - imx8mp-phycore-som.dtb
  ...
  Hash algo:    sha256
  Hash value:   7b8c2a1f...

 Default Configuration: conf-1
 Configuration 0 (conf-1)
  Description:  Linux kernel, FDT blob - imx8mp-phycore-som.dtb
  Kernel:       kernel-1
  FDT:          fdt-1
  Sign algo:    sha256,rsa2048:fit-signing-key  ← signature present
  Sign value:   4e7a9bc2f8...                   ← actual signature bytes
  Timestamp:    Fri Dec 20 14:23:01 2024
  Required:     yes                              ← -r flag effect
```

---

## Variable Reference

### Complete Variable Table

| Variable | Default | Description |
|----------|---------|-------------|
| `FIT_ADDRESS_CELLS` | `1` | DT address cells count in FIT root; use `2` for 64-bit addresses if load address > 4 GiB |
| `FIT_HASH_ALG` | `sha256` | Hash algorithm applied to each image node |
| `FIT_SIGN_ALG` | `rsa2048` | Signature algorithm for configuration nodes |
| `FIT_SIGN_NUMBITS` | `2048` | Key size in bits (informational; affects HSM key selection) |
| `UBOOT_SIGN_ENABLE` | `0` | Master switch: `"1"` enables signing; `"0"` produces unsigned FIT |
| `UBOOT_SIGN_KEYDIR` | `""` | Absolute path to directory containing signing keys |
| `UBOOT_SIGN_KEYNAME` | `""` | Base filename of key pair (no extension) |
| `FIT_GENERATE_KEYS` | `0` | Auto-generate keys if not present; development only |
| `FIT_SIGN_INDIVIDUAL` | `0` | Sign each image node in addition to configuration node |
| `FIT_KERNEL_COMP_ALG` | `none` | Kernel compression: `none`, `gzip`, `lz4`, `zstd` |
| `FIT_KERNEL_COMP_ALG_EXTENSION` | `.gz` | File extension of compressed kernel |
| `FIT_RAMDISK_COMP_ALG` | `none` | Initramfs compression algorithm |
| `FIT_CONF_PREFIX` | `conf-` | Prefix for configuration node names in ITS |
| `UBOOT_MKIMAGE_DTCOPTS` | `""` | Options passed to `mkimage`'s internal DTC; set `-p NNNN` for padding |
| `UBOOT_ARCH` | arch from `ARCH` | Architecture string for FIT nodes (`arm64`, `arm`, etc.) |
| `UBOOT_LOADADDRESS` | (machine-set) | Kernel load address in FIT image entry |
| `UBOOT_ENTRYPOINT` | (machine-set) | Kernel entry point in FIT image entry |
| `UBOOT_DTB_BINARY` | (machine-set) | U-Boot DTB filename to embed public key into |
| `INITRAMFS_IMAGE` | `""` | Name of initramfs image recipe; if set, adds ramdisk node to FIT |
| `INITRAMFS_IMAGE_BUNDLE` | `0` | Bundle initramfs into kernel binary instead of separate FIT node |
| `FIT_DESC` | (generated) | `description` field in FIT root node |
| `KERNEL_FIT_DESCRIPTION` | `""` | Override for `description` field |

### Machine-Specific Variables for phyboard-pollux-imx8mp-3

These values come from the machine configuration files in `meta-phytec`:

```bitbake
# From meta-phytec/conf/machine/phycore-imx8mp.conf:
UBOOT_LOADADDRESS = "0x40480000"
UBOOT_ENTRYPOINT = "0x40480000"
UBOOT_ARCH = "arm64"
```

---

## Extending the ITS: Adding a Ramdisk

To include an initramfs in the FIT image:

```bitbake
# In local.conf:
INITRAMFS_IMAGE = "my-initramfs-image"
INITRAMFS_IMAGE_BUNDLE = "0"   # Keep as separate FIT node (not bundled into kernel)

# Ensure initramfs is built before fitImage:
do_uboot_assemble_fitimage[depends] += "my-initramfs-image:do_image"
```

With `INITRAMFS_IMAGE` set, the generated ITS gains a `ramdisk-1` node and each configuration references it.

## Extending the ITS: Adding DTB Overlays

Kernel DTB overlays (`.dtbo` files) can be included as additional FIT nodes. This requires a `bbappend` to the kernel recipe:

```bitbake
# In meta-my-layer/recipes-kernel/linux/linux-imx_%.bbappend:

# Add overlay to the FIT
KERNEL_DEVICETREE:append = " overlays/my-overlay.dtbo"

# The class treats .dtbo files as flat_dt type automatically
```

---

## Debugging: Reproducing the FIT Assembly Manually

To reproduce exactly what the class does, examine the generated ITS and run `mkimage` manually:

```bash
# Locate the ITS file in the build tree
DEPLOY=tmp/deploy/images/phyboard-pollux-imx8mp-3
ITS=$(ls ${DEPLOY}/fitImage-its-*.its | head -1)

# The ITS uses relative paths; must run from the kernel build directory
KWORKDIR=$(bitbake -e virtual/kernel | grep "^WORKDIR=" | cut -d'"' -f2)

cd ${KWORKDIR}

# Reproduce unsigned FIT:
mkimage -f ${ITS} -D "-I dts -O dtb -p 2000" /tmp/fitImage-debug

# Reproduce signed FIT (requires keys):
mkimage -f ${ITS} \
    -D "-I dts -O dtb -p 2000" \
    -k /path/to/keys/fit \
    -K /tmp/u-boot-with-key.dtb \
    -r \
    /tmp/fitImage-signed

# Inspect result:
dumpimage -l /tmp/fitImage-signed
```

---

## Interaction with uboot-sign.bbclass

The U-Boot side of signing is handled by `uboot-sign.bbclass`. Understanding the interaction between the two classes is key to understanding why build order matters.

```
Sequence of operations:

1. u-boot-imx: do_compile
   → produces u-boot.dtb (no FIT key yet)

2. u-boot-imx: do_deploy
   → copies u-boot.dtb to ${DEPLOY_DIR_IMAGE}/u-boot.dtb

3. linux-imx: do_assemble_fitimage
   → produces fitImage-unsigned from ITS
   (this step does NOT depend on u-boot.dtb)

4. linux-imx: do_uboot_assemble_fitimage
   [depends on u-boot-imx:do_deploy]
   → reads ${DEPLOY_DIR_IMAGE}/u-boot.dtb
   → runs: mkimage -f fitImage.its -k keydir -K u-boot.dtb -r fitImage
   → mkimage signs fitImage AND embeds public key into u-boot.dtb
   → writes modified u-boot.dtb back to ${WORKDIR}/u-boot.dtb
   
5. u-boot-imx: [uboot-sign.bbclass] do_uboot_sign  
   → copies the key-embedded u-boot.dtb from linux-imx's WORKDIR
     back into u-boot's deploy directory
   (This is the "round-trip" — u-boot.dtb bounces between the two recipes)

6. imx-boot: do_compile
   → picks up key-embedded u-boot.dtb
   → combines into flash.bin
```

The key insight: `u-boot.dtb` in the final `flash.bin` contains the FIT signing public key embedded as an FDT node. If you flash a `flash.bin` that was built with a different FIT signing key than the one used to sign `fitImage`, verified boot will fail with "RSA: key not found" or "FDT signature not matched."
