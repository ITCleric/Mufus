#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
swiftc -swift-version 5 -D MUFUS_INTEGRATION_TESTS Sources/Core.swift Tests/Integration.swift -o Tests/integration-test
MUFUS_TEST_WIMLIB="$PWD/Resources/wimlib-imagex" Tests/integration-test
python3 - <<'PY'
from pathlib import Path
binary = Path('build/Mufus.app/Contents/MacOS/Mufus').read_bytes()
for marker in [b'MUFUS_TEST_FAT32_LIMIT', b'MUFUS_TEST_WIM_PART_MB', b'MUFUS_TEST_WIMLIB', b'Integration host refuses']:
    assert marker not in binary, f'Test-only capability leaked into production app: {marker!r}'
print('PASS test-only admission and threshold overrides excluded from production executable')
PY
codesign --verify --deep --strict --verbose=2 build/Mufus.app
