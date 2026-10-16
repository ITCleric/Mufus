#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
version=1.0.1
stage="dist/release-$version"
mkdir -p "$stage"
codesign --verify --deep --strict build/Mufus.app
ditto build/Mufus.app "$stage/Mufus.app"
cp README.md LEESMIJ.txt "$stage/"
cp docs/VALIDATION.md "$stage/VALIDATION.md"
if [ ! -L "$stage/Applications" ]; then ln -s /Applications "$stage/Applications"; fi
git archive --format=zip --prefix=Mufus/ --output="dist/Mufus-$version-source.zip" HEAD
cp "dist/Mufus-$version-source.zip" "$stage/"
hdiutil create -volname Mufus -srcfolder "$stage" -format UDZO -ov "dist/Mufus-$version-universal.dmg"
hdiutil verify "dist/Mufus-$version-universal.dmg"
(cd dist && shasum -a 256 "Mufus-$version-universal.dmg" "Mufus-$version-source.zip" > SHA256SUMS.txt)
