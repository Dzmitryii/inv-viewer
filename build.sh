#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
source scripts/build-environment.sh

case "${1:-}" in
    --verify) shift ;;
    '') ;;
    *) echo 'Usage: bash build.sh [--verify [--reference /path/to/source.inv /path/to/reference.npy]]' >&2; exit 2 ;;
esac
reference=("$@")
while [[ "$#" -ne 0 ]]; do
    [[ "$#" -ge 3 && ( "$1" == '--reference' || "$1" == '--demo-reference' || "$1" == '--dicom-reference' || "$1" == '--auto-arch-reference' ) ]] ||
        { echo 'Expected --reference, --demo-reference, --dicom-reference or --auto-arch-reference followed by a scan and reference.npy.' >&2; exit 2; }
    shift 3
done
[[ "$(uname -s)" == Darwin ]] || { echo 'This application builds on macOS.' >&2; exit 1; }
architecture="$(uname -m)"
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
command -v cmake >/dev/null || { echo 'CMake is required.' >&2; exit 1; }
[[ ! -L "$source" && -d "$source/.git" && "$(git -C "$source" rev-parse HEAD)" == "$openjpeg_revision" ]] || {
    echo 'The pinned OpenJPEG source is missing. Run bash scripts/bootstrap-openjpeg.sh once.' >&2
    exit 1
}

run="$(mktemp -d "$work/build.XXXXXX")"
trap 'rm -rf -- "$run"' EXIT
mkdir -p "$run/vendor" "$run/tmp" "$run/module-cache"
export TMPDIR="$run/tmp"
# Build the pinned tree from Git objects. The dependency worktree and its untracked files are not executed.
GIT_NO_REPLACE_OBJECTS=1 git -C "$source" archive --format=tar "$openjpeg_revision" | tar -xf - -C "$run/vendor"
vendor="$run/vendor"
cmake -S "$vendor" -B "$run/openjpeg" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$architecture" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CODEC=OFF -DBUILD_JPIP=OFF \
    -DBUILD_VIEWER=OFF -DBUILD_JAVA=OFF -DBUILD_TESTING=OFF
cmake --build "$run/openjpeg" --target openjp2 --parallel 4

sdk="$(xcrun --sdk macosx --show-sdk-path)"
target="$architecture-apple-macos14"
archive="$run/openjpeg/bin/libopenjp2.a"
clang_flags=(-target "$target" -isysroot "$sdk" -O2 -Wall -Wextra -Werror
    -I "$vendor/src/lib/openjp2" -I "$run/openjpeg/src/lib/openjp2")
swift_flags=(-frontend -c -whole-module-optimization -target "$target" -sdk "$sdk"
    -O -warnings-as-errors -module-cache-path "$run/module-cache")
link_flags=(-target "$target" -isysroot "$sdk" -L "$sdk/usr/lib/swift")
core=(Sources/StudyFile.swift Sources/Volume.swift Sources/DICOM.swift Sources/Arch.swift Sources/AutomaticArches.swift Sources/MPRGeometry.swift Sources/StudyNotes.swift Sources/LocalDocument.swift Sources/StoreAccess.swift Sources/LibraryBackup.swift Sources/StudyLibrary.swift Sources/DemoStudy.swift Sources/RulerOverlay.swift Sources/PNGExport.swift Sources/VolumeRendering.swift)
xcrun clang "${clang_flags[@]}" -c Sources/JP2.c -o "$run/JP2.o"
xcrun clang "${clang_flags[@]}" -c Tests/Fixture.c -o "$run/Fixture.o"
xcrun swift-frontend "${swift_flags[@]}" -import-objc-header Tests/Fixture.h -module-name INVVerify \
    "${core[@]}" Tests/Fixture.swift Tests/SyntheticStudy.swift Tests/DICOMFixture.swift Tests/AuditRegression.swift Tests/BackupFixture.swift Tests/VolumeRenderingFixture.swift Tests/Verify.swift -o "$run/Verify.o"
xcrun clang "${link_flags[@]}" "$run/Verify.o" "$run/JP2.o" "$run/Fixture.o" "$archive" -o "$run/Verify"

stage="$run/INV Viewer.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
/usr/bin/python3 scripts/prepare-demo.py docs/assets/demo-study.inv --verify
"$run/Verify" "$run/SyntheticStudy.inv" docs/assets/demo-study.inv Resources/DemoArches.json "${reference[@]+"${reference[@]}"}"
cp docs/assets/demo-study.inv "$stage/Contents/Resources/DemoStudy.inv"
cp Info.plist "$stage/Contents/Info.plist"
cp "$vendor/LICENSE" "$stage/Contents/Resources/OpenJPEG-LICENSE.txt"
cp LICENSE "$stage/Contents/Resources/INV-Viewer-LICENSE.txt"
cp -R Resources/. "$stage/Contents/Resources/"
mkdir "$run/localization"
xcrun swift-frontend "${swift_flags[@]}" -import-objc-header Sources/JP2.h -module-name INVViewer \
    -emit-localized-strings -emit-localized-strings-path "$run/localization" Sources/*.swift -o "$run/Viewer.o"
/usr/bin/python3 scripts/check-localizations.py "$run/localization"
xcrun clang "${link_flags[@]}" "$run/Viewer.o" "$run/JP2.o" "$archive" -o "$stage/Contents/MacOS/INVViewer"
codesign --force --sign - --entitlements Viewer.entitlements --options runtime "$stage"
codesign --verify --strict --verbose=2 "$stage"

output="$work/INV Viewer.app"
previous="$run/Previous.app"
if [[ -e "$output" ]]; then mv "$output" "$previous"; fi
if ! mv "$stage" "$output"; then
    if [[ -e "$previous" ]]; then mv "$previous" "$output"; fi
    exit 1
fi
printf 'Built %s (%s)\n' "$output" "$architecture"
