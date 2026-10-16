# Mufus 1.0.1 validation

Validated locally on 16 October 2026, using macOS 26.4.1 on Apple Silicon.

## Results

| Check | Result |
| --- | --- |
| Universal arm64/x86_64 build, macOS 12 deployment target | Passed |
| 31 self-tests on Apple Silicon | Passed |
| Same self-tests using the Intel executable under Rosetta | Passed |
| Complete FAT32, exFAT and Mac OS Extended format jobs, MBR and GPT | All six passed on a disposable disk image |
| Raw-image write, source check, target SHA-256 readback and ejection | Passed on a disposable disk image |
| Windows ISO mount, inventory, FAT32 copy, per-file verification and ejection | Passed with a fixture ISO |
| Windows WIM split path and wimlib verification | Passed with a real small WIM and reduced test thresholds |
| Test-only disk admission and threshold overrides absent from production executable | Passed |
| Local app code-signature validation | Passed; ad-hoc signature |

The integration runner remounts the output after successful jobs to check filesystem behavior and copied Windows files. Fixture EFI and boot files are placeholders: these tests exercise the pipeline and **do not demonstrate bootability**.

## Issues found and fixed

- Kept stderr separate from stdout so macOS diagnostics cannot corrupt plist/XML parsing. A regression check exercises large stderr output to catch pipe deadlocks.
- Stopped ISO inspection on filesystem enumeration errors instead of accepting an incomplete inventory.
- Rejected ISO symlinks, conflicting FAT32 filenames, and existing split-WIM files that would collide with generated output.
- Selected the whole attached image device independently of hdiutil's output ordering, so cleanup does not depend on the first entity being the whole disk.
- Rewound source and target descriptors, filled short reads, and detected source growth during writing.
- Cleared stale backup partition metadata beyond a shorter raw image while preserving the image region.

## Not established

- Booting a physical computer from a real USB drive.
- Physical USB-controller behavior, disconnection handling under load, and the macOS administrator prompt on every supported OS version.
- Native execution on Intel hardware or macOS releases older than the test host.
- Apple Developer ID signing and notarization.
- Full Rufus feature parity.

There are no known failures in the local automated suite. That is a bounded result, not a claim that the application is issue-free on all hardware.

## Reproduce

Run `bash test.sh`. The test host only admits the exact disk image it creates and will reject other disks. Production builds omit that admission case entirely. Running the suite needs macOS DiskManagement access and should be done in a normal local terminal rather than a filesystem-only sandbox.

The GitHub Actions workflow separately builds the universal app and runs self-tests. Its remote result must be inspected after publication; local results do not certify a remote CI run.
