# Manufacturing Flow Diagram

## Factory Station Flow

```mermaid
flowchart TD
    START([Board Received]) --> S1

    S1[Station 1:\nIncoming Inspection]
    S1 --> |Scan serial| MES1{MES: Authorized?}
    MES1 --> |No| REJECT1([Reject / Return])
    MES1 --> |Yes| INSPECT{Visual Inspection}
    INSPECT --> |Fail| REJECT2([Reject])
    INSPECT --> |Pass| S2

    S2[Station 2:\nFlash Provisioning Image]
    S2 --> UUU[uuu: Flash provisioning\nimage to eMMC\nUSB SDP mode]
    UUU --> S3

    S3[Station 3:\nSecure Provisioning]
    S3 --> BOOT[Boot provisioning image]
    BOOT --> HAB_CHECK{HAB: OPEN?\nFuses: CLEAR?}
    HAB_CHECK --> |No| FAIL1([FAIL: Already provisioned\nor wrong state])
    HAB_CHECK --> |Yes| AUTH[Request MES authorization]
    AUTH --> PROG[Program SRK fuses\n32 bytes from HSM]
    PROG --> VERIFY{Fuse verification\npassed?}
    VERIFY --> |No| FAIL2([FAIL: Fuse programming\nerror])
    VERIFY --> |Yes| FLASH[Flash production\nfirmware]
    FLASH --> CLOSE[Close device\nSEC_CONFIG fuse]
    CLOSE --> REBOOT[Reboot → production\nfirmware]
    REBOOT --> S4

    S4[Station 4:\nQuality Assurance]
    S4 --> QA1{HAB Configuration\n= 0x02?}
    QA1 --> |No| FAIL3([FAIL: Device not closed])
    QA1 --> |Yes| QA2{No HAB Events\nFound?}
    QA2 --> |No| FAIL4([FAIL: HAB events present])
    QA2 --> |Yes| QA3{dm-verity active?\nRootfs read-only?}
    QA3 --> |No| FAIL5([FAIL: Verity not active])
    QA3 --> |Yes| QA4[Application\nfunctional tests]
    QA4 --> PASS{All tests\npass?}
    PASS --> |No| FAIL6([FAIL: Functional test])
    PASS --> |Yes| S5

    S5[Station 5:\nPackaging and Shipping]
    S5 --> LABEL[Print + apply\nsecurity label]
    LABEL --> SEAL[Apply anti-tamper\nenclosure seal]
    SEAL --> MES_FINAL[Report SHIPPED to MES]
    MES_FINAL --> DONE([Device Shipped ✓])

    style DONE fill:#2e7d32,color:#fff
    style FAIL1 fill:#c62828,color:#fff
    style FAIL2 fill:#c62828,color:#fff
    style FAIL3 fill:#c62828,color:#fff
    style FAIL4 fill:#c62828,color:#fff
    style FAIL5 fill:#c62828,color:#fff
    style FAIL6 fill:#c62828,color:#fff
    style REJECT1 fill:#e65100,color:#fff
    style REJECT2 fill:#e65100,color:#fff
```

## Parallel Station Throughput

```
Typical station times:
  Station 1 (Incoming):    1 min/board
  Station 2 (Flash prov):  3 min/board
  Station 3 (Provision):   8 min/board  ← bottleneck
  Station 4 (QA):          5 min/board
  Station 5 (Pack):        1 min/board

For 500 boards/day:
  Station 3 needed: 500 × 8min = 4000 min = 67 hours
  With 8-hour shift: 67/8 = 9 parallel Station 3 setups required

Throughput optimization:
  - Parallel USB hubs (8 ports per workstation)
  - Pipeline: Board in S2 while S1 inspecting next
  - Optimize provisioning script (parallel fuse programming)
```
