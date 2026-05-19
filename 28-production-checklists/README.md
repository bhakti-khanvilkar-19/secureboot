# Production Checklists

## Overview

Production checklists are the operational backbone of secure boot deployment. They convert security architecture requirements into verifiable, auditable steps that every engineer follows consistently.

## Philosophy

- **Checklists prevent omissions, not mistakes** — they assume competent engineers, not careless ones
- **Every step is verifiable** — "configure secure boot" is not a checklist item; "verify `hab_status` shows `No HAB Events Found!`" is
- **Two-person rules** for irreversible operations (fuse programming, device closure)
- **Evidence collection** — checklists produce artifacts (logs, screenshots, sign-offs) that prove what was done

## Checklist Categories

| Checklist | When Used | Audience |
|-----------|----------|----------|
| Pre-Provisioning | Before factory run | Manufacturing engineer + security officer |
| Security Review | Before shipping new firmware | Security engineer + product manager |
| Incident Response | When security issue detected | Security team + management |
| Key Ceremony | When generating new keys | Key custodians + security officer |

## Cross-References

- [01-pre-provisioning-checklist.md](01-pre-provisioning-checklist.md) — Factory provisioning checklist
- [02-security-review-checklist.md](02-security-review-checklist.md) — Firmware security review
- [03-incident-response.md](03-incident-response.md) — Security incident response
- [../16-phytec-securiphy/02-securiphy-provisioning.md](../16-phytec-securiphy/02-securiphy-provisioning.md) — PHYTEC provisioning workflow
- [../11-key-management/02-srk-fuse-programming.md](../11-key-management/02-srk-fuse-programming.md) — Key ceremony records
