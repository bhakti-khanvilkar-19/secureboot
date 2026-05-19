# Labs and Exercises

## Overview

Hands-on labs for learning secure boot concepts. Labs progress from software-only exercises (usable on any Linux machine) to hardware-required exercises (i.MX8MP target board needed).

## Lab Tracks

### Track A: Software-Only (No Hardware Required)

| Lab | Topic | Prerequisite | Time |
|-----|-------|-------------|------|
| [lab-01-cryptography-basics](lab-01-cryptography-basics/README.md) | OpenSSL: keys, certs, signing | None | 1 hour |
| [lab-02-fit-image-signing](lab-02-fit-image-signing/README.md) | FIT image creation and signing | Lab 01 | 2 hours |
| [lab-03-uboot-qemu](lab-03-uboot-qemu/README.md) | U-Boot FIT verification in QEMU | Lab 02 | 3 hours |

### Track B: Simulation and Analysis

| Lab | Topic | Prerequisite | Time |
|-----|-------|-------------|------|
| [lab-04-hab-simulation](lab-04-hab-simulation/README.md) | HAB event parsing and analysis | Lab 01 | 2 hours |

### Track C: Hardware Required (i.MX8MP / PHYTEC)

| Lab | Topic | Prerequisite | Time |
|-----|-------|-------------|------|
| [lab-08-dmverity](lab-08-dmverity/README.md) | dm-verity on real hardware | Labs 01-03 | 4 hours |
| [lab-10-phytec-production](lab-10-phytec-production/README.md) | Full PHYTEC provisioning flow | All above | 8 hours |

## Equipment Required for Track C

```
Hardware:
  - phyCORE-i.MX8MP SOM (phyBOARD-Pollux carrier)
  - USB-to-UART adapter (PL2303 or FTDI)
  - USB-A to USB-micro cable (for UUU)
  - MicroSD card (8GB+) or eMMC-equipped SOM
  - Linux workstation (Ubuntu 22.04 recommended)

Software:
  - u-boot-tools (mkimage, dumpimage)
  - openssl 3.0+
  - QEMU (for Track A/B)
  - uuu (Universal Update Utility)
  - NXP CST (requires NXP registration for Track C)
  - Yocto build environment (for lab-10)
```

## Learning Objectives by Lab

Each lab has specific, testable learning objectives. You have completed the lab when you can:

- **Lab 01**: Generate RSA keys, sign data, verify signatures, create X.509 certificates
- **Lab 02**: Create a signed FIT image from scratch, verify with mkimage
- **Lab 03**: Boot a signed FIT in QEMU U-Boot, observe verification output
- **Lab 04**: Decode HAB events from hex byte sequences without reference tables
- **Lab 08**: Set up dm-verity on a real partition, verify it blocks tampering
- **Lab 10**: Complete end-to-end PHYTEC securiPHY provisioning

## Cross-References

- [../00-learning-path/README.md](../00-learning-path/README.md) — Which lab to do next
- [../02-embedded-cryptography/README.md](../02-embedded-cryptography/README.md) — Theory before Lab 01
- [../09-fit-images/README.md](../09-fit-images/README.md) — Theory before Lab 02
