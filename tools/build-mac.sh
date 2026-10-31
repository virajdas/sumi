#!/bin/bash
# Builds Sumi.app (Apple silicon and Intel) and packs it into dist/Sumi.dmg. Run on a Mac with Xcode's command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."

out=dist/mac
app="$out/Sumi.app"
rm -rf "$out" dist/Sumi.dmg
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

for arch in arm64 x86_64; do
  xcrun swiftc -O -whole-module-optimization -swift-version 5 -target "$arch-apple-macos11" \
    src/Mac/*.swift -o "$out/Sumi-$arch"
done
xcrun lipo -create "$out/Sumi-arm64" "$out/Sumi-x86_64" -output "$app/Contents/MacOS/Sumi"
xcrun strip -x "$app/Contents/MacOS/Sumi"
rm "$out"/Sumi-arm64 "$out"/Sumi-x86_64

cp src/Mac/Info.plist "$app/Contents/"
mkdir "$app/Contents/Resources/fonts"
cp src/Sumi/web/*.woff2 "$app/Contents/Resources/fonts/"
cp src/Sumi/web/icon.png "$app/Contents/Resources/"

iconset="$out/Sumi.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/sumi-1024.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/sumi-1024.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Sumi.icns"
rm -rf "$iconset"

# Apple silicon requires a signature; this ad-hoc one is not a Developer ID.
codesign --force --sign - "$app"

stage="$out/dmg"
mkdir "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname Sumi -srcfolder "$stage" -format ULMO -ov dist/Sumi.dmg
rm -rf "$stage"

du -sh "$app" dist/Sumi.dmg
