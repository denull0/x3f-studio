#!/bin/bash
# Build X3F Studio: the engine server (sppqd), the SwiftUI app, and the .app bundle.
# Needs the Command Line Tools (no Xcode licence required) and SIGMA Photo Pro 6 at run time.
set -eo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK=$DEVELOPER_DIR/SDKs/MacOSX.sdk
mkdir -p build

echo "• engine server"
# The deployment target matches the app's (Package.swift, Info.plist); without it clang targets the SDK's macOS.
clang -O2 -isysroot "$SDK" -mmacosx-version-min=14.0 -Iengine/x3f -Wno-deprecated-declarations -o build/sppqd \
  engine/sppqd.c engine/dng.c engine/ljpeg.c engine/x3f/x3f_io.c engine/x3f/x3f_meta.c engine/x3f/x3f_printf.c engine/x3f/x3f_print_meta.c \
  -lz -lm -liconv
codesign -fs - build/sppqd >/dev/null 2>&1

echo "• app"
swift build -c release --product X3FStudio 2>&1 | grep -v "^\[" | grep -v "^$" || true
BIN=$(swift build -c release --show-bin-path)
[ -x "$BIN/X3FStudio" ] || { echo "swift build failed"; exit 1; }

echo "• bundle"
APP="build/X3F Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/X3FStudio" "$APP/Contents/MacOS/X3F Studio"
cp build/sppqd engine/010_params.bin engine/009_lensprofile.bin "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Licence notices of the third-party code compiled in: x3f (BSD) in sppqd, the Swift packages in the app.
{
  echo "X3F Studio includes third-party code under the licences below."
  echo
  echo "== x3f (github.com/Kalpanika/x3f), compiled into sppqd =="
  cat engine/x3f/COPYRIGHT.txt
  for d in .build/checkouts/*; do
    for f in "$d"/LICENSE* "$d"/NOTICE*; do
      [ -f "$f" ] || continue
      echo; echo "== $(basename "$d"): $(basename "$f") =="; cat "$f"
    done
  done
} > "$APP/Contents/Resources/Acknowledgements.txt"
codesign -fs - --deep "$APP" >/dev/null 2>&1 || true
echo "built $APP"
