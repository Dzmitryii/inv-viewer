# Release process

1. Review the source tree from a clean checkout. Keep private scans, generated reports, study-note and patient-library JSON, recent-file bookmarks, screenshots from clinical studies, local configuration and build products outside commits and public issue reports. The authorized clinical demo at `docs/assets/demo-study.inv` is the sole scan included in the source package. Audit it with `python3 scripts/prepare-demo.py docs/assets/demo-study.inv --verify` before release. Synthetic fixtures remain available to the test suite.
2. Run `bash scripts/bootstrap-openjpeg.sh` followed by `bash build.sh --verify` on macOS. Confirm the Apple Silicon and Intel CI jobs for the release commit. Check opening the demo, switching between Russian and English, opening the automatic panorama on a new study, editing and restoring the suggested arch, navigating MPR, saving a ruler with a note, restoring the last view after restart, and exporting PNG with and without a ruler. Check exact brightness/window inputs and persistent presets. With synthetic files outside the app bundle, verify two studies in one patient record, reopen a study after relaunch, and check that removing a record does not delete the files.
3. Publish the reviewed source and its MIT license. For a downloadable app, sign with a Developer ID Application identity, notarize and staple the app, then test the downloaded archive on a separate Mac. Follow [Apple's distribution instructions](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
4. State the supported `.inv` layout, macOS requirement, actual tested architectures and clinical validation limits in the release notes. Attach SHA-256 checksums for downloadable archives.

The default build's ad-hoc signature is for local development and testing. Use the separate Developer ID process for distribution.

For the 3D window, require a successful Metal rendering test on a physical Mac. A headless runner without a Metal device skips that part of the suite. Open the bundled demo, rotate and zoom, select both presets, move and reverse the clipping plane, then switch studies and verify that the 3D window closes. Verify Intel GPU support separately if distributing an Intel build.

For MCP, use an isolated copy with its own bundle identifier and the bundled demo. Enable **Tools → Local MCP**, then run `python3 Tests/MCPAcceptance.py "/path/to/Test.app" /path/to/qa-bookmark-id.txt`. The test saves a bookmark in that copy's study store. Close the viewer and run the same command with `--disconnected`. Reopen the app and demo, then run it with `--reopen` to check the saved ruler.

## 1.14 regression acceptance

Run `bash build.sh --verify`. The audit fixtures cover one-file DICOM identity and legacy notes, divergent curves and rulers, >64 KiB discovery headers, MONOCHROME1 parity, cancelled tasks, backup integrity/conflicts, and journal recovery after partial writes. Do not substitute these for native acceptance.

In an isolated bundle/profile, repeat: paste/select-all in bookmark fields; export a rotated active 3D view and inspect the saved PNG; cancel loading with an existing study and verify it stays unchanged after the worker finishes; close and quit with complete/incomplete arches, exercise Save/Don't Save/Cancel; export/import backup, restart and reopen bookmarks; add/relink a synthetic library record. Keep private scan/reference paths and native artifacts outside source control. Close older builds during import. Run the existing live and disconnected MCP acceptance only in an explicitly opted-in isolated profile; it is not part of the headless suite. Record exact build/version and actual hardware in the acceptance report.

## Demonstration/package checks

Run `python3 Tests/CaptureDemo.py` to check that media capture rejects a different app version/build before creating output or launching it. Confirm the packaged `Info.plist` is 1.14.0 (21), verify the demo header, inspect the media terms and README links, and exclude `.build`, `__pycache__`, local evidence and patient data from the source archive. Check the videos in a browser before publication.

Before packaging, confirm that image file extensions match their formats and inspect image and video metadata for identifying information.

## Public documentation and demo site

GitHub Pages serves `docs/` from `main` at https://dzmitryii.github.io/inv-viewer/. The `.nojekyll` file keeps the existing HTML, CSS and JavaScript unchanged during publication. README video links target `#product` and `#mcp` on that page, where native video controls provide playback. Keep the repository About website set to the same URL.

After updating documentation, check both videos on the deployed page, the 375 px layout, navigation to installation/MCP/release downloads, and the Pages deployment. Build CI remains required. Documentation fixes can be published on `main` without moving an existing release tag or replacing its archives. Link release notes to the current installation and MCP guides, and describe the tagged archives as the original release snapshot.
