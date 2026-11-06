#!/bin/zsh
# Builds "Wülfe Labeller.app" (universal: Apple Silicon + Intel) and a shareable zip.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Wülfe Labeller.app"
rm -rf "$APP" build/obj && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos14.0 \
    -o build/obj/WulfeLabeller-$arch Sources/*.swift
done
lipo -create build/obj/WulfeLabeller-* -output "$APP/Contents/MacOS/WulfeLabeller"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon
swift Tools/MakeIcon.swift build/icon-1024.png >/dev/null
ICONSET=build/obj/AppIcon.iconset; mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
rm -f "build/Wulfe-Labeller.zip"
ditto -c -k --keepParent "$APP" "build/Wulfe-Labeller.zip"
echo "Built: $APP"
