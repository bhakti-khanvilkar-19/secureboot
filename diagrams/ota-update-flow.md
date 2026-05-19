# OTA Update Flow Diagram

## A/B Update Flow with SWUpdate

```mermaid
sequenceDiagram
    participant DEVICE as Device (Running Slot A)
    participant SWUPDATE as SWUpdate Service
    participant SERVER as Update Server (Hawkbit)
    participant SIGNING as Signing Station

    Note over SIGNING: Pre-production: Build + sign OTA package
    SIGNING->>SERVER: Upload signed update.swu (version 2.1.0)

    DEVICE->>SERVER: Poll for updates (every 45s)
    SERVER->>DEVICE: Update available: version 2.1.0
    
    DEVICE->>SERVER: Download update.swu
    Note over DEVICE: Verify package signature before processing

    DEVICE->>DEVICE: verifyCSMS(sw-description.sig, sw-description, signing-cert)
    
    alt Signature valid
        DEVICE->>DEVICE: Parse sw-description (version, artifacts, SHA256s)
        
        Note over DEVICE: Anti-rollback check
        DEVICE->>DEVICE: current_version(2.0.0) ≤ update_version(2.1.0)? ✓
        
        Note over DEVICE: Write to INACTIVE slot (B)
        DEVICE->>DEVICE: Write fitImage → /dev/mmcblk2p2 (boot-b)
        DEVICE->>DEVICE: Write rootfs.ext4.gz → /dev/mmcblk2p4 (rootfs-b)
        DEVICE->>DEVICE: Generate dm-verity hash tree for rootfs-b
        DEVICE->>DEVICE: Run post-install.sh (update bootenv: BOOT_ORDER=B A)
        
        DEVICE->>SERVER: Update complete (pending reboot)
        DEVICE->>DEVICE: Reboot
        
        Note over DEVICE: U-Boot reads BOOT_ORDER=B A, BOOT_B_LEFT=3
        Note over DEVICE: Boots from slot B
        
        DEVICE->>DEVICE: HABv4 verify imx-boot ✓
        DEVICE->>DEVICE: FIT verify fitImage ✓ (slot B)
        DEVICE->>DEVICE: dm-verity activate (slot B rootfs)
        DEVICE->>DEVICE: systemd starts successfully
        
        DEVICE->>SWUPDATE: Update success detected (watchdog not triggered)
        SWUPDATE->>DEVICE: Mark B as good (BOOT_B_LEFT=3, BOOT_ORDER=B A confirmed)
        DEVICE->>SERVER: Report: version 2.1.0 active
        
    else Signature invalid or version downgrade
        DEVICE->>SERVER: Report: update rejected
        Note over DEVICE: Continue running version 2.0.0 on slot A
    end
```

## Rollback Flow (Boot Failure After Update)

```
U-Boot boot attempt with BOOT_ORDER=B A:

  Attempt 1: BOOT_B_LEFT=3 → boot B (decrements to 2)
    → Kernel panic (bad update) → REBOOT
  
  Attempt 2: BOOT_B_LEFT=2 → boot B (decrements to 1)
    → Kernel panic → REBOOT
  
  Attempt 3: BOOT_B_LEFT=1 → boot B (decrements to 0)
    → Kernel panic → REBOOT
  
  Attempt 4: BOOT_B_LEFT=0 → skip B, try A
    BOOT_A_LEFT=3 → boot A (decrements to 2)
    → Boot succeeds!
  
  SWUpdate (on A) detects boot from A after B failure:
    → Reports failure to update server
    → Server can re-try or hold current version
    → BOOT_A_LEFT restored to 3
```

## Partition Switching

```
Before update (Active = A):
  BOOT_ORDER = A B
  BOOT_A_LEFT = 3 (good)
  BOOT_B_LEFT = 3 (good)
  Active data: boot-a, rootfs-a

After install + reboot (Testing B):
  BOOT_ORDER = B A
  BOOT_A_LEFT = 3 (still good)
  BOOT_B_LEFT = 3 → 2 → 1 → 0 (each boot attempt)

After confirmed good (B active):
  BOOT_ORDER = B A
  BOOT_B_LEFT = 3 (reset to good by rauc/swupdate)
  Active data: boot-b, rootfs-b
```
