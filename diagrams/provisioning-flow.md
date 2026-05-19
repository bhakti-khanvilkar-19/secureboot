# Provisioning Flow Diagram

## Factory Provisioning Sequence

```mermaid
sequenceDiagram
    participant BOARD as Target Board
    participant STATION as Factory Station
    participant HSM as HSM / Key Material
    participant MES as Factory MES

    Note over BOARD: Blank board, no firmware

    STATION->>MES: Request authorization for serial# XXXX
    MES->>STATION: Authorization granted (token)

    STATION->>BOARD: Set BOOT_MODE=USB (Recovery)
    STATION->>BOARD: Flash provisioning image via UUU
    Note over BOARD: Boots provisioning Linux image

    BOARD->>BOARD: Read OCOTP UID (device serial)
    BOARD->>MES: Register device serial
    MES->>BOARD: OK

    BOARD->>BOARD: Check HAB status (must be OPEN)
    BOARD->>BOARD: Check SRK fuses (must be clear)

    BOARD->>STATION: Request SRK fuse values
    STATION->>HSM: Fetch SRK fuse values (SRK_1_2_3_4_fuse.bin)
    HSM->>STATION: SRK fuse data (32 bytes)
    STATION->>BOARD: Transfer SRK fuse data

    BOARD->>BOARD: Program SRK fuses via nvmem
    BOARD->>BOARD: Verify SRK fuses written correctly
    
    alt Fuse verification passed
        BOARD->>STATION: Fuse programming OK
    else Fuse verification failed
        BOARD->>STATION: ERROR: Fuse mismatch
        STATION->>MES: Report failure, mark device FAILED
        Note over BOARD: Set aside for engineering review
    end

    STATION->>BOARD: Transfer production firmware (signed imx-boot + fitImage + rootfs)
    BOARD->>BOARD: Write production firmware to eMMC

    BOARD->>BOARD: Set SEC_CONFIG fuse (CLOSE device)
    Note over BOARD: IRREVERSIBLE STEP

    BOARD->>BOARD: Reboot into production firmware
    BOARD->>BOARD: Verify HAB Configuration: 0x02
    BOARD->>BOARD: Verify No HAB Events Found
    BOARD->>BOARD: Verify dm-verity active
    BOARD->>BOARD: Run QA test suite

    alt All tests passed
        BOARD->>MES: Report provisioning SUCCESS
        MES->>STATION: Issue shipping label
        STATION->>BOARD: Apply security seal + ship
    else Tests failed
        BOARD->>MES: Report FAILURE
        Note over BOARD: Mark as defective, do not ship
    end
```

## Provisioning State Machine

```
RECEIVED ──► AUTHORIZED ──► PROVISIONING_IMAGE_FLASHED
                                │
                                ▼
                          SRK_FUSES_PROGRAMMED
                                │
                         ┌──────┴──────┐
                         │             │
                      (pass)        (fail)
                         │             │
                         ▼             ▼
                  FIRMWARE_FLASHED  FAILED:FUSE_ERROR
                         │
                         ▼
                    DEVICE_CLOSED
                         │
                         ▼
                     QA_TESTING
                         │
                  ┌──────┴──────┐
                  │             │
               (pass)        (fail)
                  │             │
                  ▼             ▼
              SHIPPED      FAILED:QA
```
