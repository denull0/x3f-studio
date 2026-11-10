#!/bin/bash
# Build X3F Studio: the engine server (sppqd), the SwiftUI app, and the .app bundle.
# Needs the Command Line Tools (no Xcode licence required) and SIGMA Photo Pro 6 at run time.
set -eo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK=$DEVELOPER_DIR/SDKs/MacOSX.sdk
mkdir -p build

echo "• engine server"
clang -O2 -isysroot "$SDK" -Iengine/x3f -Wno-deprecated-declarations -o build/sppqd \
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
codesign -fs - --deep "$APP" >/dev/null 2>&1 || true
echo "built $APP"
