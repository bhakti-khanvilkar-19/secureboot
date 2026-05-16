# Prerequisites: Skills and Environment Setup

## Overview

This document defines the technical prerequisites for working through this repository, provides self-assessment questions to verify readiness, and gives step-by-step instructions for setting up the required development environment.

The prerequisites fall into five skill domains and one environment setup. Complete the environment setup before starting Chapter 01.

---

## Skill Domain 1: Linux Command Line Proficiency

### Required Level

You should be comfortable spending an entire working day in a Linux terminal without reaching for a GUI. This includes file operations, text processing, process management, and network tools.

### Self-Assessment Questions

Answer these without Google. If more than two are unclear, review the remediation resources below.

1. What does `chmod 4755 /usr/bin/sudo` do, and why is it significant?
2. Write a one-liner to find all files modified in the last 24 hours in `/etc` and show their sizes.
3. What is the difference between `>`, `>>`, `2>`, `2>&1`, and `|&`?
4. How do you send a signal to a process by name without knowing its PID?
5. What does `strace -e trace=openat ls` show you?
6. What is the output of `echo $((16#FF))` and what does the `$((16#...))` syntax do?
7. How do you extract bytes 512 through 1023 from a binary file using `dd`?
8. What does `/proc/cmdline` contain and how does it get set?

### Remediation Resources

- *The Linux Command Line* by William Shotts (free at https://linuxcommand.org/tlcl.php)
- Linux Foundation's "Introduction to Linux" (free at edX)
- Specific focus: `dd`, `xxd`, `hexdump`, `objdump`, `strings`, `file`, `ldd`

---

## Skill Domain 2: C Programming Basics

### Required Level

You do not need to be a C expert. You need to read and understand C code at the level of:
- Data structures (structs, pointers, arrays)
- Bitwise operations (critical for register programming)
- Compile, link, and basic Makefile usage
- Reading function signatures and header files

### Self-Assessment Questions

1. What is the value of `(0x1234 >> 4) & 0xFF`?
2. What does `__attribute__((packed))` do to a struct and why is it used in bootloaders?
3. Write a struct definition for a 4-byte-aligned structure containing a uint32_t magic number at offset 0, a uint32_t length at offset 4, and a uint8_t[8] hash at offset 8.
4. What does `volatile uint32_t *reg = (volatile uint32_t *)0x30360000;` do?
5. What is the difference between `static` and `extern` for a function defined in one C file and used in another?
6. What does `#pragma pack(1)` do and when would you use it in bootloader code?

### Remediation Resources

- *The C Programming Language* (K&R) - focus on chapters 2, 5, 6
- Bootloader-specific: NXP's U-Boot source code `arch/arm/mach-imx/` is well-commented

---

## Skill Domain 3: Embedded Systems Fundamentals

### Required Level

You need to understand the boot process of an ARM-based system at a conceptual level before diving into the security overlay.

### Self-Assessment Questions

1. What is the purpose of a bootloader and what does it do before jumping to the kernel?
2. What is a device tree and why does the Linux kernel need it?
3. What is the difference between eMMC and SD card boot, and why does it matter for secure boot?
4. What is DRAM initialization and why must it happen before most code can run?
5. What is the difference between NOR flash and NAND flash, and how does it affect bootloader placement?
6. What is the purpose of the `BOOT_MODE` pins on an NXP i.MX processor?
7. What does "exception level" mean on an ARM Cortex-A processor?

### Recommended Knowledge (not required but helpful)

- How U-Boot's `board_init_f()` / `board_init_r()` split works
- What `CONFIG_SPL_BUILD` does in U-Boot's build system
- What a Yocto `machine` configuration controls

### Remediation Resources

- *Embedded Linux Development using Yocto Projects* (Packt)
- NXP i.MX8MP Data Sheet: "Chapter 3: System Boot"
- PHYTEC BSP Manual: Yocto i.MX8MP (`https://www.phytec.de/bsp-software/`)
- U-Boot documentation: `doc/README.SPL`

---

## Skill Domain 4: Basic Cryptography Awareness

### Required Level

You need to understand the concepts well enough to use OpenSSL correctly and evaluate key management decisions. You do not need to implement cryptographic algorithms.

### Self-Assessment Questions

1. What is the difference between a hash function and a MAC (Message Authentication Code)?
2. If you have a file's SHA-256 hash, what can you verify and what can you NOT verify?
3. What is the relationship between a private key and a public key in RSA?
4. What does "signing" a message mean cryptographically? What does "verifying" a signature verify?
5. What is a certificate and how is it different from a public key?
6. What is a certificate chain? Why are intermediate CAs used?
7. What is the difference between encryption and authentication?
8. Why is `openssl rand -hex 32` preferable to `date | sha256sum` for generating a random key?

### Remediation Resources

- *Real-World Cryptography* by David Wong: chapters 1–6
- Computerphile YouTube channel: public key cryptography videos
- OpenSSL Cookbook (free at https://www.feistyduck.com/library/openssl-cookbook/)

---

## Skill Domain 5: Yocto/OpenEmbedded Basics

### Required Level

You need to be able to build a Yocto image, add a recipe to the build, and understand how `MACHINE`, `DISTRO`, and `LAYER` configurations interact.

### Self-Assessment Questions

1. What is the difference between a Yocto `MACHINE` and a Yocto `DISTRO`?
2. What does `bitbake -c devshell u-boot` give you access to?
3. What is the purpose of `IMAGE_INSTALL` vs `CORE_IMAGE_EXTRA_INSTALL`?
4. Where does `SRC_URI` with a `git://` prefix fetch source from and how does the build system cache it?
5. What is the purpose of `PREFERRED_VERSION_u-boot` in `local.conf`?
6. What does `do_deploy` task typically do in a U-Boot recipe?
7. How do you add a kernel configuration fragment from a layer (not by modifying the upstream `defconfig`)?

### Remediation Resources

- *Embedded Linux Development with Yocto* (Packt) - chapters 1–6
- Yocto Project Quick Build guide: https://docs.yoctoproject.org/brief-yoctoprojectqs/
- PHYTEC Yocto BSP documentation for i.MX8MP

---

## Required Tools

### Host System Requirements

Minimum host system for development:
- **OS:** Ubuntu 22.04 LTS (preferred) or Debian 12 Bookworm
- **RAM:** 16 GB minimum; 32 GB recommended for parallel Yocto builds
- **Disk:** 200 GB free (Yocto build directories are large)
- **CPU:** 8+ cores recommended for reasonable build times

### Core Toolchain Installation

```bash
# Update package lists
sudo apt-get update

# Essential build tools
sudo apt-get install -y \
    build-essential \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    gdb-multiarch

# OpenSSL and cryptographic tools
sudo apt-get install -y \
    openssl \
    libssl-dev \
    libengine-pkcs11-openssl \
    softhsm2 \
    p11-kit \
    pkcs11-dump

# Yocto host dependencies
sudo apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping python3-git python3-jinja2 \
    python3-subunit zstd liblz4-tool file locales libacl1

# NXP-specific tools dependencies
sudo apt-get install -y \
    python3-crypto \
    python3-cryptography \
    cmake \
    ninja-build \
    srecord \
    mtools

# Serial communication
sudo apt-get install -y \
    minicom \
    picocom \
    screen
```

### NXP Code Signing Tool (CST)

CST is required for generating HABv4-compliant signed images. It requires an NXP account to download.

```bash
# Download from NXP website (requires free account):
# https://www.nxp.com/webapp/sps/download/license.jsp?colCode=IMX_CST_TOOL_NEW

# After download:
mkdir -p ~/tools/cst
tar -xzf cst-3.3.1.tar.gz -C ~/tools/cst
cd ~/tools/cst/cst-3.3.1

# Build the CST tool
cd code/back_end/src
make

# Add to PATH
echo 'export PATH="$HOME/tools/cst/cst-3.3.1/release/linux64/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Verify installation
cst --version
# Expected output:
# HAB Code Signing Tool (CST) version 3.3.1
```

### NXP SPSDK (Secure Provisioning SDK)

SPSDK is NXP's Python-based replacement/complement for CST, providing a unified workflow for HABv4 and AHAB.

```bash
# Install Python 3.10+ (Ubuntu 22.04 includes this)
python3 --version
# Expected: Python 3.10.x or later

# Create virtual environment (recommended)
python3 -m venv ~/tools/spsdk-env
source ~/tools/spsdk-env/bin/activate

# Install SPSDK
pip install spsdk

# Verify installation
nxpimage --version
# Expected: spsdk, version 2.x.x

pfr --version
shadowregs --version

# Install additional NXP tools in the same environment
pip install nxp-spsdk[all]
```

### SoftHSM2 (HSM Simulation for Development)

```bash
# Install SoftHSM2
sudo apt-get install -y softhsm2

# Initialize a token for development use
softhsm2-util --init-token --slot 0 --label "secureboot-dev" \
    --pin 1234 --so-pin 12345678

# Verify token is visible
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so --list-slots
# Expected output:
# Available slots:
# Slot 0 (0x3b5dba04): secureboot-dev
#   token label        : secureboot-dev
#   token manufacturer : SoftHSM project
#   token model        : SoftHSM v2
#   token flags        : login required, rng, token initialized, PIN initialized
```

### U-Boot and TF-A Build Dependencies

```bash
# Device tree compiler
sudo apt-get install -y device-tree-compiler

# Python tools for U-Boot mkimage
pip3 install pyelftools

# Verify mkimage is available after U-Boot build
# (will be in u-boot/tools/mkimage after build)
```

### Minicom Configuration for PHYTEC UART

```bash
# Add user to dialout group for UART access
sudo usermod -aG dialout $USER
# Log out and back in for this to take effect

# Configure minicom for PHYTEC phyBOARD-Pollux
# Default: 115200 8N1, no hardware flow control
sudo minicom -s
# Navigate to: Serial port setup
# Set: A - Serial Device: /dev/ttyUSB0 (or ttyACM0)
# Set: E - Bps/Par/Bits: 115200 8N1
# Set: F - Hardware Flow Control: No
# Set: G - Software Flow Control: No
# Save as default

# Alternative: picocom (simpler)
picocom -b 115200 --flow none /dev/ttyUSB0
```

---

## Hardware Setup Requirements

### Minimum Hardware for Labs

| Item | Purpose | Notes |
|------|---------|-------|
| PHYTEC phyCORE-i.MX8MP SoM | Primary target platform | Rev 1452.1 or later |
| PHYTEC phyBOARD-Pollux carrier | Provides UART, SD, USB | |
| USB-to-UART adapter (CP210x or FTDI) | Console access | Must support 3.3V TTL |
| SD card, 16GB+, Class 10 | Boot media for testing | Use a dedicated test card |
| USB-A to USB-C cable | USB Serial Download mode | |
| 5V/3A USB-C power supply | Board power | Check PHYTEC spec |
| PC/laptop with USB 3.0 | Host | Linux only for this workflow |

### Optional Hardware (Recommended for Phase 3+)

| Item | Purpose |
|------|---------|
| Second phyCORE-i.MX8MP + phyBOARD-Pollux | Dedicated fuse-burning test board |
| JTAG debugger (Segger J-Link Pro or ARM DSTREAM) | Debug early boot failures |
| USB Hub (powered) | Multiple USB peripherals |
| eMMC adapter | Direct eMMC access for provisioning |

### Hardware Configuration for UART Access

The phyBOARD-Pollux provides UART access via the X8 connector (USB Micro-B). However, the debug UART is also accessible as a 3.3V TTL on J25 header:

```
J25 Pin Layout (phyBOARD-Pollux):
┌────────────────────────────────┐
│ Pin 1: VCC (3.3V - do not use)│
│ Pin 2: UART_RXD (connect TX)  │
│ Pin 3: UART_TXD (connect RX)  │
│ Pin 4: GND                    │
└────────────────────────────────┘

USB-to-UART wiring:
  UART adapter RX ──────▶ Board TX (J25 pin 3)
  UART adapter TX ──────▶ Board RX (J25 pin 2)
  UART adapter GND ─────▶ Board GND (J25 pin 4)
```

**CRITICAL:** Do NOT connect VCC from the UART adapter to the board. The board has its own power supply.

---

## Development Environment Setup

### Step 1: Clone and Prepare Repository

```bash
# Clone this repository
git clone https://github.com/example/secureboot ~/secureboot
cd ~/secureboot

# Set up pre-commit hooks (validates documentation quality)
pip3 install pre-commit
pre-commit install
```

### Step 2: Fetch PHYTEC BSP

```bash
# Install repo tool
mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Create BSP workspace
mkdir -p ~/bsp/phytec-imx8mp
cd ~/bsp/phytec-imx8mp

# Initialize BSP (Kirkstone release)
repo init -u https://github.com/phytec/qorvo-manifest -b kirkstone \
    -m phytec-nxp-kirkstone.xml

# Sync (this downloads several GB)
repo sync
```

### Step 3: Set Up Yocto Build Environment

```bash
cd ~/bsp/phytec-imx8mp

# Source Yocto environment
source sources/poky/oe-init-build-env build

# Configure build for phyCORE-i.MX8MP
# Edit conf/local.conf:
```

Add to `build/conf/local.conf`:

```bash
# Machine configuration
MACHINE = "phyboard-pollux-imx8mp-3"

# Parallel build settings (adjust to your CPU count)
BB_NUMBER_THREADS = "8"
PARALLEL_MAKE = "-j8"

# Enable security features
DISTRO_FEATURES:append = " security"
IMAGE_FEATURES:append = " read-only-rootfs"

# Secure boot signing keys location (TEST KEYS ONLY)
HAB_SRK_TABLE = "${TOPDIR}/../secureboot/29-reference-builds/test-keys/srk_table.bin"
HAB_CSF_KEY = "${TOPDIR}/../secureboot/29-reference-builds/test-keys/csf-private.pem"
HAB_IMG_KEY = "${TOPDIR}/../secureboot/29-reference-builds/test-keys/img-private.pem"
```

### Step 4: Verify Toolchain

```bash
# Verify cross-compiler
aarch64-linux-gnu-gcc --version
# Expected: aarch64-linux-gnu-gcc (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0

# Verify OpenSSL
openssl version
# Expected: OpenSSL 3.0.x (or later)

# Verify CST
cst --version
# Expected: HAB Code Signing Tool (CST) version 3.3.1

# Verify SPSDK
source ~/tools/spsdk-env/bin/activate
nxpimage --version
# Expected: spsdk, version 2.x.x

# Verify device tree compiler
dtc --version
# Expected: Version: DTC 1.6.x

# Verify mkimage (build U-Boot first or install u-boot-tools)
sudo apt-get install -y u-boot-tools
mkimage -V
# Expected: mkimage version 2023.01 (or later)
```

### Step 5: Configure OpenSSL for PKCS#11 (SoftHSM2)

```bash
# Create OpenSSL configuration for PKCS#11 engine
cat > ~/.config/openssl-pkcs11.cnf << 'EOF'
openssl_conf = openssl_init

[openssl_init]
engines = engine_section

[engine_section]
pkcs11 = pkcs11_section

[pkcs11_section]
engine_id = pkcs11
dynamic_path = /usr/lib/x86_64-linux-gnu/engines-3/pkcs11.so
MODULE_PATH = /usr/lib/softhsm/libsofthsm2.so
init = 0
EOF

# Test PKCS#11 access to SoftHSM2
OPENSSL_CONF=~/.config/openssl-pkcs11.cnf \
    openssl engine pkcs11 -t
# Expected: (pkcs11) pkcs11 engine
#           [ available ]
```

### Step 6: Test UART Connection

```bash
# Connect UART adapter to phyBOARD-Pollux
# Power on the board

# Open console
picocom -b 115200 --flow none /dev/ttyUSB0

# Expected: You should see U-Boot output within 3 seconds of power-on
# If nothing appears: check wiring (TX/RX swap is the most common mistake)

# At U-Boot prompt, run:
# U-Boot> version
# Expected: U-Boot 2023.04-gc... (NXP version string)
```

### Step 7: Verify HAB Status (Baseline)

```bash
# At U-Boot prompt on an un-configured board:
U-Boot> hab_status

# Expected output on an unconfigured board:
# HAB Configuration: 0xf0 - HAB enabled - Open Configuration
# HAB State: 0x66 - Trusted State

# This confirms HABv4 is present but not yet closed.
# The "Open Configuration" means signatures are checked but not enforced.
```

---

## Environment Verification Checklist

Complete this checklist before starting Chapter 01:

**Tools:**
- [ ] `openssl version` shows 3.0.x or later
- [ ] `aarch64-linux-gnu-gcc --version` shows working cross-compiler
- [ ] `cst --version` shows CST 3.3.1 or later
- [ ] `nxpimage --version` shows SPSDK 2.x
- [ ] `dtc --version` shows DTC 1.6.x or later
- [ ] `mkimage -V` shows functional mkimage
- [ ] SoftHSM2 has an initialized token visible via `pkcs11-tool`

**Hardware:**
- [ ] UART connection established; see U-Boot prompt
- [ ] `hab_status` command returns "Open Configuration"
- [ ] SD card with PHYTEC BSP image boots successfully

**Build Environment:**
- [ ] Yocto build directory initialized for `phyboard-pollux-imx8mp-3`
- [ ] `bitbake core-image-minimal` completes without errors (run this first; it takes 2-4 hours)
- [ ] Repository cloned and pre-commit hooks installed

If any item fails, resolve it before proceeding. Many later labs depend on all tools being functional.
