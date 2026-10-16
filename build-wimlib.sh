#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p tools
tar -xzf tools/wimlib-1.14.5.tar.gz -C tools
cd tools/wimlib-1.14.5
./configure --disable-shared --enable-static --without-ntfs-3g --without-fuse \
  CFLAGS='-O2 -arch arm64 -arch x86_64 -mmacosx-version-min=12.0' \
  LDFLAGS='-arch arm64 -arch x86_64 -mmacosx-version-min=12.0'
make -j4
cp wimlib-imagex ../../Resources/wimlib-imagex
