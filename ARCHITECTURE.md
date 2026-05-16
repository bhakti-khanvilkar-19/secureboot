# Repository Architecture

## Design Principles

This repository is structured around three core design principles: modularity, layering, and precision.

**Modularity:** Each chapter is self-contained. A reader working through `06-nxp-hab/` can understand that chapter without reading every prior chapter, provided they have the foundational knowledge described in the prerequisites. Cross-references use relative links and explicitly state what knowledge is assumed. This allows engineers with different backgrounds to enter the repository at appropriate levels.

**Layering:** Content is organized from abstract to concrete. Foundational security concepts precede hardware-specific implementation. Conceptual architecture precedes step-by-step commands. Validation precedes production deployment. This layering prevents the "cookbook anti-pattern" where engineers follow commands without understanding what those commands do or why they are correct.

**Precision:** Security documentation must be precise. Vague claims about what is "secure" or "protected" are worse than no documentation, because they create false confidence. Every security property statement in this repository is scoped: *what* is protected, *against what attacker*, *under what assumptions*, and *with what residual risks*.

---

## Documentation Taxonomy

Each document in this repository falls into one of six categories. Understanding the category tells you what kind of content to expect.

### Category T: Theory
**Purpose:** Explain the underlying security concept, mechanism, or protocol.
**Contains:** Definitions, formal properties, threat models, trust assumptions.
**Does not contain:** Platform-specific commands, version-specific behavior.
**Examples:** `01-security-foundations/README.md`, `02-embedded-cryptography/README.md`
**Audience:** Anyone needing to understand *why*.

### Category A: Architecture
**Purpose:** Describe the system design at a structural level.
**Contains:** Block diagrams, component relationships, information flows, trust boundaries.
**Does not contain:** Implementation commands, debugging procedures.
**Examples:** `04-chain-of-trust/README.md`, `05-boot-architecture/README.md`
**Audience:** Architects, senior engineers, security reviewers.

### Category I: Implementation
**Purpose:** Provide step-by-step implementation guidance.
**Contains:** Configuration files, build commands, signing workflows, tested command sequences.
**Does not contain:** Conceptual background (references to Theory documents instead).
**Examples:** `06-nxp-hab/02-signing-workflow.md`, `17-fuse-programming/01-burn-procedure.md`
**Audience:** Implementation engineers following a defined process.

### Category V: Validation
**Purpose:** Describe how to verify that an implementation is correct.
**Contains:** Test procedures, expected outputs, failure indicators, automated test scripts.
**Does not contain:** Implementation steps (validates the output of Implementation docs).
**Examples:** `21-testing-validation/README.md`, `21-testing-validation/02-hab-event-analysis.md`
**Audience:** QA engineers, security auditors, implementers verifying their own work.

### Category D: Debugging
**Purpose:** Diagnose and resolve failures.
**Contains:** Failure mode taxonomy, diagnostic command sequences, error code tables, UART trace analysis.
**Does not contain:** Implementation steps (assumes a broken implementation exists).
**Examples:** `22-debugging/README.md`, `22-debugging/01-hab-failure-codes.md`
**Audience:** Engineers facing a failing system.

### Category M: Manufacturing
**Purpose:** Define repeatable production processes.
**Contains:** Batch signing workflows, provisioning pipeline definitions, tooling requirements, audit trail requirements.
**Does not contain:** Conceptual background, debugging guidance.
**Examples:** `23-manufacturing/README.md`, `24-key-ceremony/README.md`
**Audience:** Manufacturing engineers, production security managers.

---

## Chapter Dependency Graph

The following ASCII diagram shows the dependency relationships between repository chapters. An arrow from A → B means "B depends on A" (A should be understood before B).

```
  [00-learning-path]
         │
         ▼
  [01-security-foundations] ──────────────────────────┐
         │                                             │
         ▼                                             │
  [02-embedded-cryptography] ────────┐                │
         │                           │                │
         ▼                           │                │
  [03-root-of-trust] ───────────┐    │                │
         │                      │    │                │
         ▼                      │    │                │
  [04-chain-of-trust] ──────────┤    │                │
         │                      │    │                │
         ▼                      │    │                │
  [05-boot-architecture] ───────┤    │                │
         │                      │    │                │
    ┌────┴────┐                  │    │                │
    ▼         ▼                  │    │                │
[06-nxp-hab] [07-nxp-ahab]       │    │                │
    │         │                  │    │                │
    └────┬────┘                  │    │                │
         │                       │    │                │
         ▼                       │    │                │
  [08-uboot-verified-boot]◄──────┘    │                │
         │                            │                │
         ▼                            │                │
  [09-trusted-firmware-a] ◄───────────┘                │
         │                                             │
         ▼                                             │
  [10-optee] ◄────────────────────────────────────────┘
         │
    ┌────┴───────────────────────────────┐
    ▼                                    ▼
[11-linux-kernel-security]         [14-secure-storage]
    │                                    │
    ▼                                    │
[12-dm-verity]                           │
    │                                    │
    ▼                                    │
[13-dm-crypt] ◄──────────────────────────┘
         │
         ▼
  [15-key-management]
         │
    ┌────┴──────────────────┐
    ▼                       ▼
[16-certificate-management] [17-fuse-programming]
         │                       │
         └──────────┬────────────┘
                    │
                    ▼
             [18-yocto-integration]
                    │
               ┌────┴────────────┐
               ▼                 ▼
        [19-phytec-specifics] [20-ubuntu-core]
               │
               ▼
        [21-testing-validation]
               │
               ▼
          [22-debugging]
               │
          ┌────┴────┐
          ▼         ▼
  [23-manufacturing] [24-key-ceremony]
          │
          ▼
     [25-compliance]
          │
     ┌────┴──────────────┐
     ▼                   ▼
[26-runtime-security] [27-supply-chain]
                          │
                          ▼
                  [28-incident-response]
```

**Critical path for i.MX8MP Secure Boot deployment:**
```
01 → 02 → 03 → 04 → 05 → 06 → 08 → 09 → 17 → 23
```

**Critical path for full production hardening:**
```
01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 →
11 → 12 → 13 → 14 → 15 → 16 → 17 → 18 → 19 → 21 →
22 → 23 → 24 → 25 → 26 → 27 → 28
```

---

## Cross-Referencing Strategy

References between documents use relative Markdown links. Links always point to the most specific relevant anchor, not just the top of a document.

**Format for cross-references:**

```markdown
For the HABv4 fuse layout, see [OCOTP Fuse Map](../03-root-of-trust/01-hardware-security-features-imx8mp.md#ocotp-fuse-map).
```

**Forward references** (referencing a concept that will be explained later) are written as:

```markdown
The SRK hash is burned into fuses at production time
(see [Fuse Programming](../17-fuse-programming/README.md) for the procedure).
```

**Back references** (reminding the reader of an established concept) are written as:

```markdown
As established in [Threat Modeling](../01-security-foundations/01-threat-modeling.md#physical-attacker),
physical attackers with sufficient time and equipment can extract DRAM contents.
```

**External references** use full URLs with a description of what the document is. They are placed at the end of sections, not inline, to reduce link rot disruption:

```markdown
Reference: NXP Application Note AN4581 "Secure Boot on i.MX50, i.MX53, and i.MX 6 Series using HABv4"
https://www.nxp.com/docs/en/application-note/AN4581.pdf
```

---

## Naming Conventions

### Directory Names
- Lowercase with hyphens, prefixed with two-digit chapter number
- Example: `06-nxp-hab/`, `17-fuse-programming/`

### File Names
- Lowercase with hyphens, prefixed with two-digit section number within chapter
- Example: `01-signing-workflow.md`, `02-hab-configuration.md`
- Chapter README files: `README.md` (no prefix)

### Asset Names
- Diagrams: `diagrams/boot-flow-overview.png`
- Scripts: `scripts/generate-srk.sh`
- Configurations: `configs/hab-config-imx8mp.json`
- Reference builds: `builds/phycore-imx8mp-secureboot/`

### Heading Hierarchy
```
# Chapter Title (H1, one per file)
## Major Section (H2)
### Subsection (H3)
#### Detail (H4, use sparingly)
```

---

## Artifact Management Strategy

### Signing Key Artifacts
Key material referenced in this repository is **always** example/test material. Production key material must never be committed to any repository, including private repositories.

Test key artifacts (in `29-reference-builds/test-keys/`) are:
- 2048-bit RSA keys labeled `TEST-ONLY`
- Generated with a known, documented seed for reproducibility
- Explicitly excluded from any production signing workflow
- Accompanied by a `WARNING.md` explaining they are not for production use

### Build Artifacts
Build artifacts (binary images, signed bootloaders) are not committed to the repository. The `29-reference-builds/` directory contains build scripts and configuration, not binary outputs.

Binary artifacts, where provided, are:
- Hosted as tagged GitHub Releases
- Accompanied by SHA-256 checksums in a `CHECKSUMS.sha256` file
- Signed with the repository's release signing key (public key in `30-appendices/release-signing.pub`)

### Configuration Artifacts
Platform-specific configuration files (device trees, U-Boot configurations, Yocto `local.conf`) are committed and versioned. They are annotated with:
- The software version they apply to (e.g., `# Tested with U-Boot 2023.04`)
- The hardware revision they apply to (e.g., `# For PHYTEC phyCORE-i.MX8MP PCB rev. 1452.1`)
- Any deviations from upstream defaults

---

## Security Warning Strategy

Security warnings appear in four severity levels, consistently formatted throughout the repository.

### CRITICAL: Irreversible or catastrophic actions
Used for fuse burning, key destruction, operations that can permanently brick hardware or expose production key material.

```
> **⚠️ CRITICAL:** Burning the SEC_CONFIG[1] fuse closes HAB. This is irreversible.
> If SRK_HASH is incorrect or keys are lost, the device is permanently bricked.
> Triple-verify the hash before burning. Test on a non-production board first.
```

### WARNING: Security-impacting decisions
Used for configuration choices that weaken security guarantees, common mistakes that create vulnerabilities, or operations requiring careful verification.

```
> **⚠️ WARNING:** Using a 2048-bit RSA key is the minimum for HABv4 but is no longer
> considered adequate for long-lived deployments. Use 4096-bit RSA or ECC P-384
> for new designs with device lifetimes beyond 2030.
```

### NOTE: Important operational consideration
Used for non-obvious behavior, platform-specific deviations, or context that prevents common mistakes.

```
> **📝 NOTE:** The HAB event log is cleared after reading. If you need to inspect
> HAB events, do not reset the board before capturing the log. U-Boot's
> `hab_status` command reads and clears the event buffer.
```

### TIP: Efficiency or best practice
Used for time-saving approaches, recommended tooling, or process improvements.

```
> **💡 TIP:** Use the NXP SPSDK `nxpimage` tool rather than the legacy CST for new
> projects. SPSDK provides better error messages and supports both HABv4 and AHAB
> in a unified workflow.
```

---

## Maintenance Strategy

### Versioning
This repository uses semantic versioning for the overall content: `MAJOR.MINOR.PATCH`.

- `MAJOR`: Architectural reorganization that changes chapter numbers or fundamental approach
- `MINOR`: New chapter additions or significant content updates
- `PATCH`: Corrections, clarifications, updated commands for new tool versions

The current content version is tracked in `30-appendices/VERSIONS.md`.

### Software Version Tracking
Commands and configurations are version-sensitive. Each implementation document tracks:

```yaml
# At the top of each implementation document
Tested Against:
  - U-Boot: 2023.04 (NXP lf-6.1.55-2.2.0 branch)
  - TF-A: 2.9 (NXP lf-6.1.55-2.2.0 branch)
  - OP-TEE: 3.22.0
  - Linux Kernel: 6.1.55
  - NXP CST: 3.3.1
  - NXP SPSDK: 2.1.0
  - Yocto: kirkstone (4.0.x)
Last Validated: 2024-Q1
```

### Review Schedule
- Security-sensitive content (key management, fuse programming, manufacturing): reviewed at every major NXP SDK release
- Conceptual content (theory, architecture): reviewed annually
- Platform-specific content: reviewed when BSP changes affect the described behavior

### Issue Tracking
Known inaccuracies, version-dependent caveats, and "TODO" items are tracked as GitHub Issues with the label `content-accuracy`. The issue number is referenced in the document:

```markdown
<!-- TODO: Update for SPSDK 2.2 workflow changes - see issue #47 -->
```
