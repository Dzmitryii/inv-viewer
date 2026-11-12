# Installation

INV Viewer 1.14.0 runs on macOS 14 or later. Building from source also requires Xcode Command Line Tools and CMake. The build targets the architecture of your Mac. Apple Silicon has been tested; Intel still needs release testing.

## Build from source

Download the source archive or clone the repository, then run these commands from its root:

```sh
bash scripts/bootstrap-openjpeg.sh
bash build.sh --verify
open ".build/INV Viewer.app"
```

The first command downloads the pinned OpenJPEG source. The second builds the app and runs its tests. Subsequent builds use the local dependency checkout.

Choose **Open demo** on the welcome screen. You can browse both dental arches, open MPR, and rotate the 3D volume. To use your own scan, choose **Open scan…** or drag a supported file or DICOM series folder into the window.

English and Russian are available in **Язык / Language**. Changing language restarts the app.

## Prebuilt app

A notarized download is not available yet. The local build and the `INV-Viewer-1.14.0-macOS-arm64-developer.zip` archive use an ad-hoc signature for development. For now, build from source using the commands above.

The [release process](../RELEASING.md) covers Developer ID signing, notarization and testing on another Mac.

## Preview the demo site

The site contains videos and screenshots. To serve it locally from the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory docs
```

Open `http://127.0.0.1:8765/` for the English page. The site does not decode scans; use the Mac app to explore the volume.
