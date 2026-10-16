# Contributing to Mufus

Run `bash test.sh` before proposing a change. Disk writes belong in `Sources/Core.swift`; UI changes belong in `Sources/App.swift`. Preserve the production physical-USB restriction and fail before erasing a target when validation is inconclusive.

Please describe the problem, expected behavior, actual behavior, macOS version, processor, and workflow in bug reports. Never post credentials or unredacted personal logs.

Hardware compatibility reports are particularly useful. Specify the image's official source and checksum, target computer, USB model, and whether booting actually succeeded. Use only media you explicitly intend to erase.

Do not describe a successful file-copy test as a successful boot test. Test-only disk admission must remain behind `MUFUS_INTEGRATION_TESTS` and must not be enabled in a distributed app.
