# Compatibility and testing

Test record for version 1.14.0 (build 21), dated 2026-11-12.

## Build and renderer

`bash build.sh --verify` passed from a clean source tree on macOS 27.2.1 / arm64: **17 PASS lines, one headless Metal SKIP**, 323 English/Russian interface strings, valid ad-hoc code signature. The run used the bundled demo and synthetic fixtures.

The headless process had no Metal device. Metal rendering was tested separately in the running app through MCP. [The capture transcript](assets/mcp-transcript.json) records view/slice changes, rotation and clipping. Other GPU configurations still need testing.

| Capability | Evidence / scope |
|---|---|
| INVFile 2.0, little-endian unsigned 16-bit volume with raw JPEG 2000 blocks | Bundled 400×400×300 clinical demo, decoder validation, synthetic multi-block lossless round trip |
| Explicit/Implicit VR Little Endian DICOM, 8/16-bit monochrome, regular axis-aligned geometry | Synthetic fixtures: nested series, selection, geometry, incomplete/truncated rejection |
| Single-file CT opened as file or folder | Identity and lossless legacy-note migration fixtures |
| Large DICOM header and MONOCHROME1 | Discovery and normalized-arch regression fixtures |
| Panorama, both arches, sections, linked MPR | Geometry/interpolation/physical-spacing fixtures and actual demo capture |
| Persistence and metadata backup | Isolation, duplicate/stale-write rejection, schema/checksum/conflict checks, interrupted journal recovery |
| Cancellation | Cancelled load/arch work does not publish results |
| Local MCP capture | Actual stdio requests, returned images and state transitions on Apple Silicon |
| Apple Silicon source build | Verified locally |
| Intel CI / public GitHub CI | Workflow included; not run on GitHub in this preparation |
| Developer ID, notarization, another Mac download, execution on minimum macOS 14 | Not completed; release gates remain |
| Clinical accuracy / scanner calibration | Not validated |

## Additional checks

Earlier checks of the same version covered MCP reconnect/disconnect behavior, saved-ruler reopening, patient creation, DICOM attachment, rejection of a different replacement file, exact-copy relinking and persistence after restart. They also included per-voxel comparisons for one INV study and one classic DICOM study against private reference volumes. Those private inputs are not distributed. These checks were not repeated during the documentation revision.

## Format limits

Compressed DICOM transfer syntaxes, oblique/irregular acquisitions, non-Part-10 files, and proprietary implant plans, nerve traces, models or simulations are not supported. Other INV layouts may be rejected. An anatomical orientation label requires recognized metadata; otherwise the viewer uses volume axes.

Before a release, repeat the native checks and both architecture CI jobs described in [RELEASING.md](../RELEASING.md). Report compatible exports using the issue template without sharing patient data.
