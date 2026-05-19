# Lab 04: HAB Event Parsing and Analysis

## Learning Objectives

After completing this lab, you can:
1. Decode HAB event bytes without reference tables
2. Identify the root cause of an HABv4 failure from event data
3. Distinguish between the 5 most common HABv4 failure types
4. Propose the correct fix for each failure scenario

## Prerequisites

- Lab 01 completed
- Python 3 installed
- Read [12-habv4-imx8m/03-hab-event-decoding.md](../../12-habv4-imx8m/03-hab-event-decoding.md)

---

## Part 1: Build the HAB Event Decoder (15 min)

```bash
mkdir -p lab04 && cd lab04

cat > hab_decoder.py << 'EOF'
#!/usr/bin/env python3
"""HABv4 Event Decoder - Lab Exercise"""

STATUS_CODES = {
    0xF0: "HAB_SUCCESS",
    0x33: "HAB_FAILURE",
    0x69: "HAB_WARNING",
}

REASON_CODES = {
    0x00: "HAB_RSN_ANY (generic failure)",
    0x05: "HAB_INV_ADDRESS (bad load address)",
    0x08: "HAB_INV_ASSERTION (internal assert)",
    0x18: "HAB_INV_SIGNATURE (signature mismatch)",
    0x1D: "HAB_INV_INDEX (SRK index invalid)",
    0x1E: "HAB_INV_ASSERTION",
    0x2B: "HAB_INV_CERTIFICATE (cert chain broken)",
    0x3B: "HAB_INV_CLAIM (algorithm mismatch)",
    0x3E: "HAB_INV_COMMAND (bad CSF command)",
    0x3F: "HAB_INV_CSF (malformed CSF)",
    0xC2: "HAB_INV_KEY (SRK not installed / hash mismatch)",
    0xCA: "HAB_INV_DATA (data doesn't match signature)",
    0x2B: "HAB_MEM_FAIL (memory/size error)",
}

CONTEXT_CODES = {
    0x00: "HAB_CTX_ANY",
    0x0A: "HAB_CTX_COMMAND (processing CSF command)",
    0x10: "HAB_CTX_AUT_DAT (Authenticate Data)",
    0x20: "HAB_CTX_ASSERT (assertion check)",
    0x22: "HAB_CTX_DCD (Device Configuration Data)",
    0x24: "HAB_CTX_ENTRY (HAB_ENTRY call)",
    0x25: "HAB_CTX_EXIT (HAB_EXIT call)",
    0x41: "HAB_CTX_FAB (certificate fabrication)",
}

ENGINE_CODES = {
    0x00: "HAB_ENG_ANY (any engine)",
    0x1E: "HAB_ENG_CAAM (CAAM crypto engine)",
    0x1F: "HAB_ENG_SNVS (Secure Non-Volatile Storage)",
    0x21: "HAB_ENG_OCOTP (OTP fuses)",
    0x36: "HAB_ENG_ROM (ROM code)",
    0xFF: "HAB_ENG_SW (software)",
}

SUGGESTED_FIXES = {
    0x18: "Re-sign the image with the correct keys. Verify CSF Authenticate Data block size matches padded image size.",
    0xC2: "SRK hash in fuses doesn't match SRK table. Verify SHA-256(SRK_table.bin) matches OCOTP Bank 3 Words 0-7.",
    0x2B: "Certificate chain broken. Verify CSF cert is signed by the same SRK CA. Don't mix keys from different generation runs.",
    0x05: "Image load address in CSF doesn't match SPL_LOAD_ADDR. Check IVT/imx-mkimage output.",
    0x3F: "CSF structure malformed. Regenerate CSF using CST. Check CSF template syntax.",
}

def decode_event(hex_string):
    """Decode a HAB event from space-separated hex bytes."""
    bytes_list = [int(b, 16) for b in hex_string.split()]
    
    if len(bytes_list) < 8:
        print("ERROR: Event too short (need at least 8 bytes)")
        return
    
    header = bytes_list[0]
    length = (bytes_list[1] << 8) | bytes_list[2]
    version = bytes_list[3]
    status = bytes_list[4]
    reason = bytes_list[5]
    context = bytes_list[6]
    engine = bytes_list[7]
    
    print(f"{'='*50}")
    print(f"HAB Event Decoded:")
    print(f"  Header:  0x{header:02X}")
    print(f"  Length:  {length} bytes")
    print(f"  Version: 0x{version:02X} (HABv{version >> 4}.{version & 0xF})")
    print(f"  Status:  {STATUS_CODES.get(status, 'UNKNOWN')} (0x{status:02X})")
    print(f"  Reason:  {REASON_CODES.get(reason, f'UNKNOWN (0x{reason:02X})')}")
    print(f"  Context: {CONTEXT_CODES.get(context, f'UNKNOWN (0x{context:02X})')}")
    print(f"  Engine:  {ENGINE_CODES.get(engine, f'UNKNOWN (0x{engine:02X})')}")
    
    if reason in SUGGESTED_FIXES:
        print(f"\n  Suggested Fix: {SUGGESTED_FIXES[reason]}")
    
    if len(bytes_list) > 8:
        extra = " ".join(f"0x{b:02X}" for b in bytes_list[8:])
        print(f"  Extra Data: {extra}")
    print()

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        decode_event(" ".join(sys.argv[1:]))
    else:
        print("Usage: python3 hab_decoder.py <hex bytes>")
        print("Example: python3 hab_decoder.py 0xdb 0x00 0x24 0x43 0x33 0x18 0x10 0x00")
EOF

chmod +x hab_decoder.py
echo "HAB decoder ready"
```

---

## Part 2: Decode Sample Events (20 min)

Practice decoding these real-world HAB events. For each, identify:
1. What failed
2. What caused it
3. How to fix it

```bash
# Event 1: Common signature failure
python3 hab_decoder.py \
    0xdb 0x00 0x24 0x43 0x33 0x18 0x10 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00

# Event 2: SRK hash mismatch
python3 hab_decoder.py \
    0xdb 0x00 0x24 0x43 0x33 0xC2 0x0A 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00

# Event 3: Certificate chain broken
python3 hab_decoder.py \
    0xdb 0x00 0x24 0x43 0x33 0x2B 0x41 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00

# Write your analysis here:
echo ""
echo "=== Your Analysis ==="
echo "Event 1: Reason _____, Context _____, Cause _____, Fix _____"
echo "Event 2: Reason _____, Context _____, Cause _____, Fix _____"
echo "Event 3: Reason _____, Context _____, Cause _____, Fix _____"
```

---

## Part 3: Scenario Analysis (20 min)

For each scenario, predict what HAB events would be generated:

**Scenario A**: Engineer generated new keys but forgot to update the fuse values in the provisioning script. The old key hash is still in the fuse, but the CSF was generated with the new key.

**Scenario B**: The image was padded to 4096 bytes but the CSF Authenticate Data block specifies size 4097. The image is signed and the signature is valid for the stated size.

**Scenario C**: Two separate key generation runs were done. The SRK was from run 1, but the CSF key was from run 2. The SRK hash from run 1 is burned in fuses.

Write your predicted events:
```bash
cat > analysis.txt << 'EOF'
Scenario A:
  Status:  HAB_FAILURE
  Reason:  HAB_INV_KEY (0xC2) — SRK hash mismatch
  Context: HAB_CTX_COMMAND (processing Install SRK command)
  Fix:     Use matching SRK keys OR re-burn fuses with new SRK hash

Scenario B:
  Status:  HAB_FAILURE
  Reason:  HAB_INV_SIGNATURE (0x18) — data doesn't match
  Context: HAB_CTX_AUT_DAT
  Fix:     Recompute padded size and regenerate CSF

Scenario C:
  Status:  HAB_FAILURE
  Reason:  HAB_INV_CERTIFICATE (0x2B) — CSF cert not from same CA
  Context: HAB_CTX_FAB (certificate processing)
  Fix:     Generate all keys in a single key generation run
EOF

cat analysis.txt
```

---

## Part 4: Write a Complete Event Analyzer (15 min)

```bash
cat > analyze-hab-log.py << 'EOF'
#!/usr/bin/env python3
"""
Parse U-Boot hab_status output and produce a human-readable report.

Usage: echo "U-Boot output..." | python3 analyze-hab-log.py
Or:    python3 analyze-hab-log.py < hab-output.txt
"""

import sys
import re

# Paste in the HAB decoder functions from Part 1...
# (Run: source hab_decoder.py in same session, or copy functions here)

def parse_uboot_hab_output(text):
    """Extract HAB event byte strings from U-Boot hab_status output."""
    events = []
    in_event = False
    current_bytes = []
    
    for line in text.split('\n'):
        if '----- HAB Event' in line:
            in_event = True
            current_bytes = []
        elif in_event and 'event data:' in line:
            continue
        elif in_event and line.strip().startswith('0x'):
            hex_values = re.findall(r'0x[0-9a-fA-F]{2}', line)
            current_bytes.extend(hex_values)
        elif in_event and line.strip().startswith('STS'):
            in_event = False
            if current_bytes:
                events.append(current_bytes)
    
    return events

def main():
    text = sys.stdin.read()
    
    if 'No HAB Events Found' in text:
        print("✓ No HAB events — authentication successful!")
        return
    
    events = parse_uboot_hab_output(text)
    
    if not events:
        print("No parseable HAB events found in input.")
        return
    
    print(f"Found {len(events)} HAB event(s):")
    print()
    
    for i, event in enumerate(events):
        print(f"Event {i+1}:")
        print(f"  Raw: {' '.join(event)}")
        # Decode using hab_decoder functions...

main()
EOF
```

---

## Cleanup

```bash
cd ..
rm -rf lab04/
```

## Answers to Part 2

```
Event 1: HAB_INV_SIGNATURE + HAB_CTX_AUT_DAT
  → Image data doesn't match CSF signature
  → Fix: Re-sign with correct keys, verify image was not modified post-signing

Event 2: HAB_INV_KEY + HAB_CTX_COMMAND
  → SRK not installed — Install SRK command failed
  → Fix: Check SRK table hash matches fuse values

Event 3: HAB_INV_CERTIFICATE + HAB_CTX_FAB
  → Certificate chain invalid
  → Fix: Use certificates signed by same CA as SRK
```

## Next Lab

→ [lab-08-dmverity](../lab-08-dmverity/README.md)
