# Install on Mac

INV Viewer 1.14.0 requires **macOS 14 or later**. Choose Apple menu → **About This Mac** to check your macOS version and whether your Mac has an Apple chip or an Intel processor.

[Watch the demos](https://dzmitryii.github.io/inv-viewer/) · [Release 1.14.0 and downloads](https://github.com/Dzmitryii/inv-viewer/releases/tag/v1.14.0) · [Connect MCP](mcp.md)

The source build works on both architectures. Build and test CI passed on Apple Silicon and Intel; manual app checks were performed on Apple Silicon. Installation on a separate Intel Mac is not yet verified.

## Build from source

This is the recommended way to run the current release. You need Terminal, Apple's Command Line Tools and CMake. You do not need the full Xcode app.

### 1. Install the build tools

Open **Terminal** from Applications → Utilities. Run:

```sh
xcode-select --install
```

Complete Apple's installation dialog before continuing. If Terminal says the tools are already installed, continue to CMake. [Apple's installation instructions](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools) cover installation problems.

If you already use Homebrew, install CMake with:

```sh
brew install cmake
```

Otherwise, download the stable **macOS universal DMG** from [CMake](https://cmake.org/download/), open it, and drag **CMake.app** to **Applications**. Then make its command-line tools available in this Terminal window:

```sh
export PATH="/Applications/CMake.app/Contents/bin:$PATH"
```

Check that both tools are available:

```sh
xcrun --find swift-frontend
cmake --version
```

The first command prints a path; the second prints the CMake version. If either reports an error, finish that tool's installation before building. If you open a new Terminal window after using the DMG, repeat the `export PATH` command there.

### 2. Download and build

Run these commands in a folder where you want to keep the project:

```sh
git clone https://github.com/Dzmitryii/inv-viewer.git
cd inv-viewer
bash scripts/bootstrap-openjpeg.sh
bash build.sh --verify
open ".build/INV Viewer.app"
```

Cloning creates an `inv-viewer` folder. The bootstrap command downloads a pinned OpenJPEG revision; the build command runs the tests and creates an ad-hoc signed app for your Mac's architecture. Leave Terminal open until it reports `Built …/INV Viewer.app`. Subsequent builds reuse the local dependency checkout.

If you already downloaded the source ZIP from the release, unzip it in Finder. In Terminal, type `cd ` (including the space), drag the extracted folder containing `build.sh` into Terminal, and press Return. Run the last three commands above; you do not need to clone again.

Keep the app in `.build` when following the MCP instructions below, so the executable path stays consistent.

### 3. Open a study

Choose **Open demo** on the welcome screen. You should see a dental panorama; switch to **MPR** or open **3D** to explore other views. The demo is included, so no patient file is needed for this check.

To use your own scan, choose **Open scan…** or drag a supported file or DICOM series folder into the window. See the [user guide](usage.md) for viewing controls and supported workflows.

English and Russian are available in **Язык / Language**. Changing language restarts the app.

To control the running app from Codex or another local client, continue with [MCP setup](mcp.md).

## Prebuilt developer app

The [1.14.0 release](https://github.com/Dzmitryii/inv-viewer/releases/tag/v1.14.0) includes an [Apple Silicon developer ZIP](https://github.com/Dzmitryii/inv-viewer/releases/download/v1.14.0/INV-Viewer-1.14.0-macOS-arm64-developer.zip). It is **arm64 only**, ad-hoc signed and **not notarized**. It is provided for development and testing; a standard notarized installer is not available yet.

On an Apple Silicon Mac, download and unzip the archive in Finder to find `INV Viewer.app`. macOS may block a downloaded ad-hoc app. If it does, use the source-build steps above. Intel users should build from source.

To check the download, save [SHA256SUMS.txt](https://github.com/Dzmitryii/inv-viewer/releases/download/v1.14.0/SHA256SUMS.txt) beside the ZIP. From that folder, run:

```sh
shasum -a 256 INV-Viewer-1.14.0-macOS-arm64-developer.zip
```

Compare the printed hash with the line for that filename in `SHA256SUMS.txt`.

The [release process](../RELEASING.md) covers Developer ID signing, notarization and testing on another Mac.

## Watch or preview the demo site

[Watch the product and MCP videos in your browser](https://dzmitryii.github.io/inv-viewer/). No installation is needed to watch. This page shows recordings and screenshots; it does not open scans.

For a local preview from the repository root, if Python 3 is installed:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory docs
```

Open `http://127.0.0.1:8765/`. Press Control-C in Terminal to stop the preview server.
