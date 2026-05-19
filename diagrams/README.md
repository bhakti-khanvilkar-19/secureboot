# Diagrams

## Overview

Architecture diagrams for the secure boot system. All diagrams are in Markdown format using ASCII art and Mermaid syntax, ensuring they render in any documentation viewer without external dependencies.

## Available Diagrams

| Diagram | Description |
|---------|-------------|
| [boot-flow-imx8mp.md](boot-flow-imx8mp.md) | Complete i.MX8MP boot sequence with timing |
| [chain-of-trust.md](chain-of-trust.md) | Trust chain from ROM to application |
| [fit-image-structure.md](fit-image-structure.md) | FIT image binary layout |
| [key-hierarchy.md](key-hierarchy.md) | Complete key management hierarchy |
| [signing-pipeline.md](signing-pipeline.md) | CI/CD signing pipeline flow |
| [provisioning-flow.md](provisioning-flow.md) | Factory provisioning sequence |
| [manufacturing-flow.md](manufacturing-flow.md) | Manufacturing station workflow |
| [ota-update-flow.md](ota-update-flow.md) | OTA update with A/B partitions |
| [fuse-map-imx8mp.md](fuse-map-imx8mp.md) | OCOTP fuse register map |
| [memory-layout.md](memory-layout.md) | RAM and eMMC memory layout |
| [attack-surface.md](attack-surface.md) | Attack surface diagram |

## Viewing Mermaid Diagrams

Mermaid diagrams render in:
- GitHub (native support)
- GitLab (native support)
- VS Code (with Markdown Preview Mermaid Support extension)
- Any documentation site using Mermaid.js

For pure ASCII diagrams: viewable in any terminal or text editor.
