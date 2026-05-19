# Incident Response Procedures

## Severity Classification

| Severity | Examples | Response Time | Escalation |
|----------|---------|--------------|-----------|
| Critical | Signing key compromise, mass device compromise | Immediate (< 1 hour) | CEO, Legal, Board |
| High | Active exploit of device vulnerability, unauthorized OTA | < 4 hours | CISO, Engineering VP |
| Medium | Suspected compromise, anomalous device behavior | < 24 hours | Security team, Engineering |
| Low | Vulnerability discovered (not yet exploited), patch needed | < 7 days | Security team |

---

## Critical: Signing Key Compromise

### Immediate Actions (First Hour)

```
1. SUSPEND all signing operations immediately
   → Disable signing service access
   → Revoke CI/CD pipeline signing credentials
   → Contact all signing custodians (key ceremony participants)

2. ASSESS scope
   → When was the key last known secure?
   → How many devices received firmware signed with this key?
   → Is the key still in the HSM, or was it exfiltrated?

3. PRESERVE evidence
   → Do NOT restart or shutdown the signing server
   → Capture forensic image if host compromise suspected
   → Preserve HSM audit logs (copy to offline storage immediately)
   → Preserve all signing logs

4. NOTIFY
   → Internal: CISO, Legal, Engineering VP
   → External: Determined case-by-case (regulatory requirements vary)
```

### Containment (Hours 2-24)

```
5. KEY ROTATION
   → Generate new signing keys (full key ceremony required)
   → New key generation requires: air-gapped workstation, fresh HSM,
     2+ witnesses, ceremony documentation
   → For HABv4 SRK: new SRK key means new SRK hash, which means
     existing devices CANNOT be updated with new key without reflash

6. DEVICE ASSESSMENT
   For each device with potentially compromised firmware:
   
   Option A (OTA capable): Push signed firmware indicating "firmware compromised,
     please return for service" — if OTA signing key also compromised, this fails
   
   Option B (Physical access): Reflash in CLOSED mode using SDP with correct SRK key
   
   Option C (FIT key compromised but SRK intact): Push new FIT signed with
     new FIT key — CLOSED mode will only accept FIT if it's signed, so
     this requires a FIT re-signing with the new key

7. SRK REVOCATION (if SRK key compromised)
   → Program OCOTP_SRK_REVOKE fuse on affected devices (requires physical access)
   → Sign future firmware using backup SRK slot
   → If all SRK slots used: device cannot be updated (destroyed)
```

### Recovery

```
8. Root cause analysis:
   → How was the key accessed?
   → HSM audit log analysis
   → Access log review (who had physical access to HSM)
   → Network forensics (was signing service compromised?)

9. Process improvements:
   → Implement identified gaps
   → Update threat model
   → Third-party security audit of key management infrastructure

10. Documentation:
    → Post-incident report (internal)
    → Customer notification (if required by contract or regulation)
    → Regulatory reporting (if required: GDPR, NIS2, IEC 62443)
```

---

## High: Active Device Exploit

```
Situation: Attacker has active shell on production device(s)

1. ISOLATE affected devices
   → If internet-connected: block device IP at firewall
   → If local network: physically disconnect
   → Do NOT power off (preserve memory forensics if possible)

2. DETERMINE scope
   → How many devices affected?
   → Is this a targeted attack or mass exploitation?
   → What data/systems does the attacker have access to?

3. FORENSICS
   → Capture memory image from affected device (if possible)
   → Capture logs: /var/log/, audit logs, dmesg
   → Identify CVE being exploited

4. PATCH
   → Develop fix for exploited vulnerability
   → Security review of patch (2-person review minimum)
   → Test patch on unaffected device first
   → Deploy via OTA as emergency update

5. CVE COORDINATION
   → If vulnerability is in open-source component: coordinate with upstream
   → Request CVE ID from MITRE (if not already assigned)
   → Embargo period for customer notification (standard: 90 days or until patch available)
```

---

## Medium: Anomalous Device Behavior

```
Signs of possible compromise:
  - Unexpected network connections
  - Rootfs modification detected (dm-verity error)
  - OP-TEE secure storage access from unknown application
  - Boot failures after previously working

1. COLLECT logs from device
   → dmesg, syslog, audit log
   → Network connection log

2. VERIFY integrity
   → dm-verity status (should show no errors)
   → IMA log (if enabled)
   → Compare installed package checksums against known-good

3. DETERMINE cause
   → Hardware fault or attack?
   → Reproducible on other devices?

4. RESPOND based on determination
   → If hardware fault: warranty/replacement process
   → If software bug: patch and update
   → If attack: escalate to High severity
```

---

## Incident Response Contacts

```
Fill this in before deployment — have contacts ready before you need them:

Internal:
  CISO:                  ___________________________  _______________
  Engineering VP:        ___________________________  _______________
  Security Lead:         ___________________________  _______________
  Legal Counsel:         ___________________________  _______________
  PR/Communications:     ___________________________  _______________

External:
  NXP Security Team:     security@nxp.com
  CERT/CC:               cert@cert.org
  Forensics Firm:        ___________________________  _______________
  HSM Vendor Support:    ___________________________  _______________

Regulatory (if applicable):
  Data Protection Officer: _________________________  _______________
  Industry CERT:          ___________________________  _______________
```

---

## Cross-References

- [../11-key-management/README.md](../11-key-management/README.md) — Key rotation procedures
- [../25-debugging-and-recovery/03-recovery-procedures.md](../25-debugging-and-recovery/03-recovery-procedures.md) — Device recovery
- [../26-threat-modeling/01-attack-scenarios.md](../26-threat-modeling/01-attack-scenarios.md) — Attack scenarios
- [../20-secure-updates/README.md](../20-secure-updates/README.md) — Emergency OTA update
