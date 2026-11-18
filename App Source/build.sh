#!/bin/zsh
# Builds "DCBT Reader.app" next to the "Source texts" and "SLR files" folders.
set -e
cd "$(dirname "$0")"
APP="../DCBT Reader.app"
BUILD="${TMPDIR:-/tmp}/dcbreader-build"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/DCBReader" Sources/*.swift
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/DCBReader" "$APP/Contents/MacOS/DCBT Reader"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
