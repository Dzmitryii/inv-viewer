# Using INV Viewer

## Start viewing

1. Open INV Viewer, choose **Open scan…**, and select a file or DICOM series folder. You can also drag the file or folder in. Choose **Open demo** on the welcome screen or in the **File** menu to explore without a scan.
2. The viewer proposes upper and lower dental arches from the scan and opens the panorama when it finds both. Check the line on the axial slice. Choose **Edit arch**, drag its control points, and choose **Done** to save your edit. Use **Settings → Restore automatic arch** to return to the suggestion. When there is too little evidence for a pair of arches, the study opens in MPR and you can use **Draw arch** in Panorama.
3. Click the panorama to select an area. Double-click a cross-section to enlarge it. Scroll to browse neighboring sections and use **Back to panorama** or Esc to return to the same area. Use **Settings** to show the panorama controls.
4. Choose **Open in MPR** to move the selected point to the three linked planes. Click in a plane to move the crosshair, scroll to step through slices and double-click to enlarge a plane. Choose **Tilt** and drag around the crosshair or use the ±5° buttons.
5. Use **Ruler** to measure between two points on an MPR slice or on an enlarged cross-section. **Bookmarks** or ⌘D saves the viewing position. Arch edits and bookmarks persist locally and follow identical copies of the same file.

The automatic fit checks neighboring axial slices and traces the two posterior ends independently. For the lower arch it also checks for a consistent contour around each terminal point. With sufficient evidence, it guides the curve through the tooth center to its estimated posterior edge. Previously generated suggestions refresh when a study reopens. Saved manual curves and bookmarks retain their original geometry.

The **View** menu lists ⌘1, ⌘2, and ⌘3 for slices, panorama, and MPR. **Reopen last scan** on the welcome screen restores the most recent file and its last saved view.

## 3D volume

After opening a scan, choose **3D** or press ⌘4. A separate window lets you keep MPR or the panorama visible while inspecting the volume. Use the **Rotate** buttons above the volume to turn it by 15° per click. You can also drag the volume or use the arrow keys. Scroll to zoom. Choose **Bone** or **Soft Tissue** and adjust the density threshold and opacity. To cut into the volume, select a clipping plane, move the slider and use **Opposite Side** to switch the visible side.

3D viewing uses the Mac's Metal GPU and the voxel spacing of the loaded volume. Presets visualize intensity ranges. Their appearance varies with the scan and acquisition settings. InVivo case layers such as implant plans, nerve traces, models and simulations are outside the supported file layout.

## DICOM

Choose a `.dcm`, `.dicom`, or `.ima` file, or select the entire CT export folder. The viewer looks inside nested folders and offers a choice when it finds multiple compatible CT series. Files inside the export may be extensionless. The viewer opens both single-file Enhanced CT volumes and classic CT stacks in patient position order. You can add either to a patient record.

Supported DICOM files use the Part 10 file wrapper, uncompressed Explicit or Implicit VR Little Endian, and monochrome 8-bit or 16-bit pixel containers with regular, axis-aligned patient geometry. Compressed transfer syntaxes and oblique or irregular acquisitions require a compatible export. This is an offline viewer for local files.

## Compatibility and scope

- macOS 14 or newer. The build targets the current Mac architecture. The repository contains CI jobs for Apple Silicon and Intel.
- The supported layout is `INVFile 2.0`, little endian, one unsigned 16-bit volume, with raw JPEG 2000 blocks. Other layouts may be rejected. The viewer does not need DICOM conversion.
- Anatomical labels are displayed for the recognized orientation metadata. Otherwise, planes are identified by volume axes. The ruler uses spacing from the file. Scanner calibration and equivalence to commercial InVivo have not been validated.
- The demo contains the original clinical image blocks and the geometry required by the viewer. The project is an independent viewer for local review and demonstration and has not been clinically validated for primary diagnosis.

## Organize and export scans

Open **Patients** (⇧⌘L), create a record using a name or ID, then add one or more INV or DICOM files or DICOM series folders. Give each study a title and date. Search the patient list and double-click a study to open it. The library stays in the app container on this Mac. If macOS loses the link to a scan, choose **Relink scan…** and select a byte-for-byte copy. Removing a record leaves the original files, bookmarks, and measurements on disk.

Use **Save measurement…** after placing both ruler points in MPR or an enlarged cross-section. Add an optional note. Pick the saved item from **Bookmarks** to restore the plane and ruler line, or use **Edit bookmark…** to revise its name or note. The last view of a real scan is saved on close or when switching studies. **File → Export PNG…** (⇧⌘E) saves the current image with physical proportions and known orientation labels. If a ruler is active, the save dialog lets you include its line and distance. File names, notes, and patient metadata are excluded; the image still contains patient anatomy. **File → Recent scans** remembers up to 12 directly opened studies. Demo and patient-library openings stay out of this list, and you can clear it from the menu.

Enter numeric brightness and window width below the image. Option-drag horizontally to adjust window width and vertically to adjust brightness. Use **Presets** to reuse your values on other scans.

## Reliability and backups (1.14)

**Cancel loading** or ⌘. stops opening a study or fitting its arches; the previous study stays open. Cancellation is cooperative: a running JPEG 2000 block may finish before its memory is released. Late results never replace the current study. Finish an arch before opening another study. Closing or quitting during an edit offers Save, Don't Save and Cancel; an incomplete curve cannot be saved.

The **Edit** menu supplies standard text shortcuts, including ⌘V and ⌘A. **Export PNG…** captures the active 3D window when it is in front; otherwise it exports the selected 2D view.

Opening a single-file DICOM directly or through its series folder uses the same notes. Existing notes from older folder identities are merged automatically. Divergent curves and viewing positions appear as recovered bookmarks; original note files remain intact. If preserving everything would exceed the bookmark limit, opening reports a migration error instead of dropping records.

**File → Create backup… / Restore backup…** transfers patient records, arches, bookmarks and measurements as a validated JSON file. **Scan pixels are not included**: copy the original scans separately and use **Relink scan…** on another Mac. Identical records are accepted and new records are added. Conflicting records abort the import without replacement; this is a merge, not a rollback to an older version. Close older viewer versions before importing. Prepared imports resume before subsequent store access after interruption. If recovery detects an intervening conflicting edit, it stops and preserves both the journal and existing files for recovery; do not delete them.

See [the compatibility notes](compatibility.md) for tested samples and remaining device checks.

