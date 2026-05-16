# Contributing to the Secure Boot Engineering Reference

This guide defines the standards for contributing to this repository. The high standards are intentional: security documentation that is vague, incorrect, or incomplete causes real harm when engineers implement based on it.

---

## Core Contribution Principles

**Test before documenting.** Every command sequence, configuration snippet, and procedural step must have been executed on real hardware (or a documented virtual equivalent). If you cannot test a command, mark it explicitly:

```markdown
<!-- UNTESTED: This command sequence is derived from NXP AN12108 but has not been
     validated on phyCORE-i.MX8MP hardware. Do not follow without independent verification. -->
```

**Claim precision.** Never write "this is secure" without specifying against what attacker and under what conditions. Security properties must be stated in this form:

> "HABv4 with closed configuration prevents execution of unsigned bootloader images by an attacker with physical access to the SD card interface, assuming the SRK_HASH fuse value is correct and the HAB keys are not compromised."

**Acknowledge limitations.** Every mechanism has limitations. Documenting what a mechanism does *not* protect against is as important as documenting what it does protect against.

---

## Documentation Standards

### Required Sections for Every Chapter README

Every chapter `README.md` must contain the following sections in this order:

```markdown
# Chapter Title

## Learning Objectives
<!-- 3-7 specific, measurable objectives using action verbs:
     "After reading this chapter, you will be able to..." -->

## Overview
<!-- 2-4 paragraphs introducing the concept, its role in secure boot,
     and what problems it solves -->

## Prerequisites
<!-- Link to prerequisite chapters, specific knowledge assumed -->

## Relationship to Other Chapters
<!-- What chapters this builds on, what chapters build on this -->

## [Main Content Sections]
<!-- Chapter-specific technical content -->

## Summary
<!-- Key takeaways, 5-10 bullet points -->

## Further Reading
<!-- External references: NXP Application Notes, ARM documentation,
     academic papers with full citations -->
```

### Required Sections for Implementation Documents

Every implementation document (`NN-chapter-name/MM-topic.md`) must contain:

```markdown
# Topic Title

## Version Matrix
<!-- Table: Tool/Software | Version | Status (Tested/Untested/Deprecated) -->

## Overview
<!-- What this procedure accomplishes, why it is needed -->

## Prerequisites
<!-- Required tools, hardware, files, prior steps -->

## Procedure
<!-- Step-by-step commands, each with expected output -->

## Verification
<!-- How to confirm the procedure succeeded -->

## Failure Modes
<!-- Common failures, their causes, and remediation -->

## Security Considerations
<!-- What security properties this procedure establishes or affects -->
```

---

## Diagram Requirements

Diagrams in this repository serve one of three purposes: structural (showing relationships), flow (showing sequences), or informational (showing data layouts). Each has a format requirement.

### ASCII Diagrams

ASCII diagrams are preferred over image files for structural and flow diagrams. They are:
- Diff-friendly (changes are visible in code review)
- Accessible (readable without image rendering)
- Portable (work in all Markdown renderers)

**Required quality level:**

```
Good ASCII diagram (clear, aligned, labeled):

┌─────────────────┐         ┌──────────────────┐
│   Boot ROM      │──HAB──▶│   SPL            │
│   (Trust Anchor)│         │   (Authenticated)│
└─────────────────┘         └────────┬─────────┘
                                      │ Loads+Verifies
                                      ▼
                             ┌──────────────────┐
                             │   TF-A BL31      │
                             │   (Secure World) │
                             └──────────────────┘

Bad ASCII diagram (unclear, inconsistent):

[ROM] -> [SPL] -> [TF-A]
```

Use Unicode box-drawing characters (`┌ ┐ └ ┘ ─ │ ┬ ┴ ├ ┤ ┼ ▶ ◀ ▲ ▼`) for all new diagrams.

### Image Diagrams

Complex diagrams that cannot be adequately expressed in ASCII (e.g., detailed PKI hierarchy trees, memory map graphics) may use PNG images. Requirements:
- Source file (draw.io XML, PlantUML, or Mermaid) must be committed alongside the PNG
- Maximum width: 1200px
- Background: white or transparent
- Font: monospace or sans-serif, minimum 12pt
- File location: `diagrams/` subdirectory within the chapter
- Referenced in Markdown as: `![Diagram Title](diagrams/diagram-name.png)`

---

## Code and Command Formatting Standards

### Command Blocks

All commands use fenced code blocks with language specifiers:

```bash
# Generate 4096-bit RSA private key
openssl genrsa -out srk1-private.pem 4096
```

**Required for every command block:**
- Language specifier (`bash`, `c`, `python`, `yaml`, `ini`, etc.)
- Comment explaining what the command does
- Expected output shown in a separate block labeled with `# Expected output:`

```bash
# Verify HAB status in U-Boot
hab_status
```

```
# Expected output (closed board, no failures):
HAB Configuration: 0xf0 - HAB enabled - Secure Boot
HAB State: 0x66 - Trusted State
```

### Variable Substitution

Commands that require user-supplied values use uppercase placeholder variables with angle brackets:

```bash
# Sign the SPL image
cst --o hab4_spl.bin --i <PATH_TO_CSF_FILE> --hab4
```

Where `<PATH_TO_CSF_FILE>` must be replaced by the actual path. Placeholder names must be descriptive, not generic (`<FILE>` is unacceptable; `<PATH_TO_UNSIGNED_SPL>` is correct).

### File Contents

Configuration files and source code are shown in full, not truncated:

```yaml
# hab4-csf-spl.yaml
# HABv4 Code Signing Framework file for SPL authentication
# Tested against NXP CST 3.3.1
Header:
    Version: 4.4
    Hash Algorithm: sha256
    Engine Configuration: 0
    Certificate Format: X509
    Signature Format: CMS
```

If a file is too long to show in full, the document must:
1. Show the critical sections with comments explaining what the omitted sections contain
2. Reference the full file in `29-reference-builds/`

---

## Security Review Requirements

All contributions touching the following topics require a security review before merge:

- Key management procedures
- Fuse programming procedures
- HAB/AHAB configuration
- PKI hierarchy design
- Manufacturing pipeline procedures
- Key ceremony procedures
- Cryptographic algorithm selection

**Security review process:**

1. Contributor opens a PR and applies the `security-review-required` label
2. Contributor completes the Security Review Checklist (below) in the PR description
3. A second contributor with embedded security experience reviews the PR
4. Reviewer verifies claims against NXP documentation and applicable standards
5. Both contributor and reviewer sign off before merge

---

## PR Checklist

All pull requests must include this checklist in the PR description, with each item explicitly checked or marked N/A:

```markdown
## PR Checklist

### Content Quality
- [ ] All commands have been tested on hardware or marked UNTESTED
- [ ] Expected outputs are shown for all commands
- [ ] Version matrix is complete and accurate
- [ ] No placeholder text remains ("TODO", "TBD", "coming soon")
- [ ] Cross-references use relative links with correct anchors

### Security Accuracy
- [ ] Security properties are precisely stated (what, against what attacker, under what conditions)
- [ ] Limitations are documented (what this mechanism does NOT protect against)
- [ ] No security theater: every mechanism has a documented threat it addresses
- [ ] Key material in examples is clearly labeled TEST-ONLY
- [ ] No production key material, device serial numbers, or fuse values committed

### Documentation Standards
- [ ] Required sections are present (see CONTRIBUTING.md)
- [ ] ASCII diagrams use Unicode box-drawing characters
- [ ] Code blocks have language specifiers
- [ ] Heading hierarchy is correct (one H1, logical H2/H3/H4)
- [ ] External references include full URLs and document titles

### Security Review (check if applicable)
- [ ] N/A - Does not touch key management, fuse programming, HAB/AHAB config, or manufacturing
- [ ] Security review completed by: @reviewer_handle
- [ ] Claims verified against NXP Application Notes: AN____
- [ ] No known vulnerabilities introduced

### Platform Validation
- [ ] Platform scope is clearly stated (which SoCs, which BSP version)
- [ ] PHYTEC-specific content is separated from general i.MX8MP content
- [ ] Ubuntu Core content is separated from Yocto content
- [ ] Version dependencies are documented in the Version Matrix

### Reviewer Confirmation
- [ ] I have read the changed content in full
- [ ] I have verified the technical accuracy of security claims
- [ ] I would be comfortable implementing a production system based on this content
```

---

## Style Guide

### Technical Terminology

Use precise terminology consistently. The following terms have specific meanings in this repository:

| Term | Meaning | Do Not Confuse With |
|------|---------|---------------------|
| Secure Boot | The general concept of cryptographic boot authentication | HABv4 (a specific implementation) |
| HABv4 | NXP High Assurance Boot v4, used on i.MX6/7/8M | AHAB (used on i.MX8QM/8X/93) |
| AHAB | NXP Advanced HAB, container-based format for newer SoCs | HABv4 |
| SRK | Super Root Key: the RSA/ECDSA key whose hash is burned in fuses | The key used to sign individual images |
| CSF | Code Signing Framework: NXP's signing descriptor format | The signing tool itself |
| CoT | Chain of Trust | Certificate chain |
| RoT | Root of Trust | CoT |
| TF-A | Trusted Firmware-A (formerly ARM Trusted Firmware) | OP-TEE |
| OP-TEE | Open Portable Trusted Execution Environment (the Secure OS) | TF-A |
| BL31 | TF-A Secure Monitor (EL3, runs forever as the secure monitor) | BL32 |
| BL32 | OP-TEE (Secure OS, S-EL1) | BL31 |
| BL33 | U-Boot (Normal World bootloader, EL2/EL1) | U-Boot SPL |

### Writing Voice

- Use present tense for descriptions: "The ROM code validates the IVT" not "The ROM code will validate the IVT"
- Use active voice: "U-Boot loads the kernel FIT image" not "The kernel FIT image is loaded by U-Boot"
- Use second person for instructions: "Run `make` to build" not "One should run `make`"
- Avoid marketing language: do not write "robust", "seamless", "cutting-edge", "state-of-the-art"

### Security Language

- Do not write "this is secure" without qualification
- Do not write "this prevents attacks" without specifying which attacks
- Acceptable: "This configuration prevents an attacker with physical access to the boot media from replacing the bootloader with an unsigned image"
- Unacceptable: "This secures the boot process"
