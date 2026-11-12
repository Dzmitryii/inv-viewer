# Changelog

## 1.14.0 (build 21)

### Added

- Cancel loading or automatic arch fitting without losing the previous study.
- Export and import patient records, arches, bookmarks and measurements as a metadata backup. Imports check for conflicts and can recover after an interrupted write. Scan files are copied separately.
- Standard Edit menu commands, including paste and select all.

### Fixed

- PNG export now captures the active 3D window when it is in front.
- A single DICOM file uses the same notes whether opened directly or through its series folder. Existing notes are merged without dropping divergent arches or rulers.
- DICOM discovery reads headers larger than 64 KiB and rejects truncated elements.
- MONOCHROME1 normalization is consistent during automatic arch fitting.
- Closing or quitting during arch editing offers Save, Don't Save and Cancel. Incomplete curves cannot be saved.
- Results from cancelled loading or arch fitting cannot replace the current study.

### Documentation

Updated the demo videos, MCP examples, installation instructions and contribution guide.

[Compatibility and test results](docs/compatibility.md)
