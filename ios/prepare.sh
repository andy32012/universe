#!/bin/sh
# Copies the website into the app (ios/Web) and makes the 1024 px App Store icon.
# Run on macOS before `xcodegen generate`.
set -eu
cd "$(dirname "$0")/.."
rm -rf ios/Web
mkdir -p ios/Web
cp -R index.html manifest.json icon-180.png icon-192.png icon-512.png assets ios/Web/
sips -z 1024 1024 icon-512.png --out ios/Universe/Assets.xcassets/AppIcon.appiconset/AppIcon.png >/dev/null
