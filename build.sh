#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/Mufus.app/Contents/MacOS build/Mufus.app/Contents/Resources/Licenses
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target "$arch-apple-macos12.0" Sources/Core.swift Sources/App.swift Sources/SelfTests.swift -o "build/Mufus-$arch"
done
lipo -create build/Mufus-arm64 build/Mufus-x86_64 -output build/Mufus.app/Contents/MacOS/Mufus
cp Resources/Info.plist build/Mufus.app/Contents/Info.plist
cp Resources/Mufus.icns build/Mufus.app/Contents/Resources/
cp Resources/Mufus.png build/Mufus.app/Contents/Resources/
cp Resources/wimlib-imagex build/Mufus.app/Contents/Resources/
cp Resources/Licenses/* build/Mufus.app/Contents/Resources/Licenses/
codesign --force --sign - build/Mufus.app/Contents/Resources/wimlib-imagex
codesign --force --sign - build/Mufus.app
build/Mufus.app/Contents/MacOS/Mufus --self-test
echo 'Built build/Mufus.app (Apple Silicon + Intel, macOS 12+)'
