# FIT Image Structure Diagram

## Binary Layout

```
FIT Image (fitImage):
┌──────────────────────────────────────────────────────────┐
│ FDT Header (8 bytes)                                     │
│   magic:      0xD00DFEED                                 │
│   totalsize:  <total bytes>                              │
│   off_dt_struct: offset to structure block               │
│   off_dt_strings: offset to strings block                │
│   off_mem_rsvmap: offset to memory reservation map       │
│   version:    17                                         │
│   last_comp_version: 16                                  │
│   boot_cpuid_phys: 0                                     │
│   size_dt_strings: <string block size>                   │
│   size_dt_struct: <struct block size>                    │
├──────────────────────────────────────────────────────────┤
│ Memory Reservation Map                                   │
│   (usually empty for FIT images)                         │
├──────────────────────────────────────────────────────────┤
│ Structure Block (FDT nodes):                             │
│                                                          │
│  / {                                                     │
│    description = "...";                                  │
│    timestamp = <unix_time>;                              │
│    #address-cells = <1>;                                 │
│                                                          │
│    images {                                              │
│      kernel@1 {                                          │
│        description = "Linux Kernel";                     │
│        type = "kernel";                                  │
│        arch = "arm64";                                   │
│        os = "linux";                                     │
│        compression = "none";                             │
│        load = <0x40480000>;                              │
│        entry = <0x40480000>;                             │
│        data-size = <kernel_size>;                        │
│        data-position = <offset_to_data>;  ← external    │
│        hash@1 {                                          │
│          algo = "sha256";                                │
│          value = <32-byte-hash>;          ← computed     │
│        };                                                │
│        signature@1 {                                     │
│          algo = "sha256,rsa2048";                        │
│          key-name-hint = "phytec-fit-key";               │
│          value = <256-byte-sig>;          ← RSA sig      │
│          timestamp = <signing_time>;                     │
│          signer-name = "mkimage";                        │
│        };                                                │
│      };                                                  │
│                                                          │
│      fdt@1 { ... };       ← same structure               │
│      ramdisk@1 { ... };   ← same structure               │
│    };                                                    │
│                                                          │
│    configurations {                                      │
│      default = "conf@1";                                 │
│      conf@1 {                                            │
│        description = "Production Boot Config";           │
│        kernel = "kernel@1";                              │
│        fdt = "fdt@1";                                    │
│        ramdisk = "ramdisk@1";                            │
│        bootargs = "console=... verity=...";              │
│        signature@1 {                                     │
│          algo = "sha256,rsa2048";                        │
│          key-name-hint = "phytec-fit-key";               │
│          value = <256-byte-sig>;    ← signs over conf    │
│          hashed-nodes = "/configurations/conf@1",        │
│                         "/images/kernel@1/hash@1",       │
│                         "/images/fdt@1/hash@1",          │
│                         "/images/ramdisk@1/hash@1";      │
│        };                                                │
│      };                                                  │
│    };                                                    │
│  }                                                       │
├──────────────────────────────────────────────────────────┤
│ Strings Block                                            │
│   (FDT property name strings: "description\0", etc.)    │
├──────────────────────────────────────────────────────────┤
│ Image Data (External Data Mode):                         │
│   [kernel binary: ~20MB]                                 │
│   [DTB binary: ~64KB]                                    │
│   [ramdisk binary: ~5MB]                                 │
│   (Offsets referenced from data-position properties)     │
└──────────────────────────────────────────────────────────┘
```

## Verification Flow in U-Boot

```
bootm <fit_addr>
  │
  ├─ Select default configuration (conf@1)
  │
  ├─ Find embedded public key in U-Boot DTB:
  │    /signature/key-phytec-fit-key
  │
  ├─ Verify configuration signature:
  │    RSA-verify(conf_sig, hashed_content, pubkey)
  │    hashed_content = sha256(
  │      conf@1/bootargs +
  │      kernel@1/hash@1/value +
  │      fdt@1/hash@1/value +
  │      ramdisk@1/hash@1/value
  │    )
  │
  ├─ For each referenced image:
  │    sha256(image_data) == hash@1/value ?
  │    ↑ This is what the config signature covers
  │
  └─ Load verified images to memory addresses
       kernel → 0x40480000
       fdt    → 0x43000000
       ramdisk → 0x44000000
```

## What Is and Isn't Covered by the Signature

```
COVERED by conf signature (attacker cannot tamper):
  ✓ kernel binary content (via hash)
  ✓ DTB content (via hash)
  ✓ ramdisk content (via hash)
  ✓ bootargs string (directly signed)
  ✓ Load addresses (in hash@1 nodes)

NOT directly covered (but derived from the above):
  ~ Description strings (informational only)
  ~ Timestamp (informational only)
  ~ key-name-hint (used for lookup, not security-critical)
```
