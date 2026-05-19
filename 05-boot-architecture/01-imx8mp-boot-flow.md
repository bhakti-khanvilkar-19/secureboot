# i.MX8MP Detailed Boot Flow Reference

## Stage Timing Reference

| Stage | Start | Duration | Cumulative |
|-------|-------|---------|-----------|
| ROM | 0ms | ~5ms | 5ms |
| SPL early init | 5ms | ~50ms | 55ms |
| DDR training | 55ms | ~500ms | 555ms |
| SPL load imx-boot | 555ms | ~100ms | 655ms |
| TF-A BL31 + OP-TEE | 655ms | ~50ms | 705ms |
| U-Boot init | 705ms | ~1000ms | 1705ms |
| U-Boot FIT load+verify | 1705ms | ~500ms | 2205ms |
| Kernel startup | 2205ms | ~5000ms | 7205ms |
| systemd + services | 7205ms | ~3000ms | ~10s |

---

## ROM Stage Detail

### Reset Vector
```
Cortex-A53 power-on reset vector: 0x00000000
(Aliased to ROM code in OCRAM)
All 4 cores reset; Core 0 executes, cores 1-3 wait in WFE
```

### ROM HABv4 Authentication Call

```c
/* Simplified ROM authentication flow */
void rom_boot_authenticate(void)
{
    hab_rvt_t *rvt = (hab_rvt_t *)HAB_RVT_BASE; /* 0x980 */

    /* HABv4 entry */
    hab_status_t status = rvt->entry();

    /* Authenticate boot image */
    void *start = (void *)SPL_LOAD_ADDR; /* 0x7E1000 */
    size_t size = boot_image_size;
    status = rvt->authenticate_image(
        HAB_CID_ROM,    /* Caller ID */
        IVT_OFFSET,     /* IVT offset in image */
        &start,         /* Image start */
        &size,          /* Image size */
        csf_ptr         /* CSF pointer from IVT */
    );

    if (status != HAB_SUCCESS) {
        if (hab_config == HAB_CFG_CLOSED) {
            /* HALT — closed mode, auth failure is fatal */
            while(1) { /* Infinite loop */ }
        }
        /* Open mode: log warning, continue */
    }

    rvt->exit();
    jump_to_spl(start); /* Jump to authenticated SPL */
}
```

### eMMC Access During ROM Stage

ROM reads eMMC in boot0 partition (default):
```
1. Send CMD0 (GO_IDLE_STATE)
2. Send CMD1 (SEND_OP_COND) for MMC
3. Send CMD2 (ALL_SEND_CID) — get card ID
4. Send CMD3 (SET_RELATIVE_ADDR)
5. Send CMD9 (SEND_CSD) — get card specific data
6. Send CMD7 (SELECT_CARD)
7. Send CMD6 (SWITCH) — switch to boot0 partition
8. Read 512-byte sectors from offset 0 (IVT at first sector)
9. Parse IVT, determine image size
10. Read complete SPL image
```

---

## SPL Stage UART Output

Expected SPL output for phyCORE-i.MX8MP:
```
U-Boot SPL 2023.04+gitAUTOINC+abc123 (Jan 16 2024 - 10:23:45 +0000)
DDRINFO: start DRAM init
DDRINFO:ddrphy calibration start
DDRINFO: ddrphy calibration done
DDRINFO: ddrmix config start
Normal Boot
Trying to boot from MMC1 Boot Partition 1
## Checking hash(es) for config conf@1 ... sha256+ OK
## Checking hash(es) for Image uboot@1 ... sha256+ OK
## Checking hash(es) for Image atf@1 ... sha256+ OK
## Checking hash(es) for Image tee@1 ... sha256+ OK
```

If SPL FIT signature verification enabled, you'll see the "Checking hash" lines.

---

## TF-A Boot Output

TF-A BL31 console output (if PLAT_LOG_LEVEL >= LOG_LEVEL_INFO):
```
NOTICE:  BL31: v2.8(release):v2.8.0-dirty
NOTICE:  BL31: Built : 10:23:45, Jan 16 2024
NOTICE:  BL31: Detected i.MX 8MP, SILICON revision = 1.1
INFO:    GICv3 with legacy support detected.
INFO:    ARM GICv3 driver initialized in EL3
INFO:    Maximum SPI INTID supported: 991
INFO:    BL31: Initializing runtime services
INFO:    BL31: Preparing for EL3 exit to normal world
INFO:    Entry point address = 0x40200000
INFO:    SPSR = 0x3c9
```

---

## U-Boot Boot Output

Expected U-Boot secure boot output:
```
U-Boot 2023.04+gitAUTOINC+abc123 (Jan 16 2024 - 10:23:45 +0000)

CPU:   Freescale i.MX8MP rev1.1 1600 MHz (running at 1200 MHz)
CPU:   Industrial temperature grade (-40C to 85C) at 42C
Reset cause: POR
Model: PHYTEC phyBOARD-Pollux i.MX8MP
Board: PHYTEC phyBOARD-Pollux i.MX8MP
DRAM:  2 GiB
Core:  170 devices, 21 uclasses, devicetree: separate
WDT:   Started watchdog@30280000 with servicing (60s timeout)
PMIC:  ROHM BD71847
MMC:   FSL_SDHC: 0, FSL_SDHC: 2
Loading Environment from MMC... OK

HAB Configuration: 0xf0 HAB State: 0xf0
No HAB Events Found!

In:    serial@30890000
Out:   serial@30890000
Err:   serial@30890000
Net:   FEC: 0x30be0000, FEC: 0x30bf0000
Hit any key to stop autoboot:  0
switch to partitions #0, OK
mmc2 is current device
Scanning mmc 2:1...
Found U-Boot script /boot.scr
## Executing script at 40400000
Loading Kernel Image
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ... sha256+ OK
   Verified OK, SIGNATURE sha256,rsa2048:fit-signing-key (1)
## Loading ramdisk from FIT Image at 40400000 ...
   Verifying Hash Integrity ... sha256+ OK
## Loading fdt from FIT Image at 40400000 ...
   Verifying Hash Integrity ... sha256+ OK
   Booting using the fdt blob at 0x43f24da0
Working FDT set to 43f24da0
   Loading Ramdisk to 7ae60000, end 7b3200a0 ... OK
   Loading Device Tree to 000000007ae4c000, end 000000007ae5eba7 ... OK

Starting kernel ...
```

---

## Kernel Boot Output

```
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd034]
[    0.000000] Linux version 6.6.0 (build@host) (aarch64-linux-gnu-gcc 12.2.0)
[    0.000000] KASLR disabled due to lack of seed
[    0.000000] Machine model: PHYTEC phyBOARD-Pollux i.MX8MP
[    0.000000] earlycon: ec_imx6q0 at MMIO32 0x0000000030890000 (options '115200n8')
...
[    2.543210] mmc2: new HS200 MMC card at address 0001
[    2.612345] mmcblk2: mmc2:0001 XXXXXX 7.28 GiB
[    2.634567] mmcblk2boot0: mmc2:0001 XXXXXX partition 1 4.00 MiB
...
[    4.123456] device-mapper: verity: sha256 using implementation "sha256-ce"
[    4.234567] device-mapper: verity: 8:18: created verified target
[    4.345678] EXT4-fs (dm-0): mounted filesystem with ordered data mode
...
[    7.890123] systemd[1]: systemd 252 running in system mode
```

---

## Boot Debug: What to Check at Each Stage

### Stage 1: No UART output at all
```bash
# Check:
# 1. UART baud rate: 115200 8N1
# 2. UART port: UART2 (ttymxc1) → X9 connector on phyBOARD-Pollux
# 3. Power LED on?
# 4. Boot mode pins: BOOT_MODE[1:0] = 10 for internal boot
# 5. eMMC has valid imx-boot at offset 0?
```

### Stage 2: SPL starts but stops
```bash
# Common messages and causes:
# "DDRINFO: ddrphy calibration failed" → DDR timing issue
# Silent stop after "DDRINFO" → DDR training hang
# "Trying to boot from MMC1 Boot Partition 1" stops → FIT not found
# "Bad magic number" → SPL FIT corrupted
```

### Stage 3: U-Boot starts, FIT verification fails
```bash
# Check hab_status for HAB events (from U-Boot prompt)
=> hab_status
# If events: see 25-debugging-and-recovery/01-hab-debugging.md

# Check FIT signature:
# "Verified OK, SIGNATURE sha256,rsa2048:fit-signing-key" = success
# "ERROR: Failed to validate required signature" = wrong key
```
