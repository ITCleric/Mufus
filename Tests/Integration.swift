import Foundation
import Darwin

@main struct Integration {
    static func main() {
        setbuf(stdout, nil)
        do { try test() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func test() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Mufus-integration-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try ensureSourceNotOnTarget("/", "disk999999")
        print("PASS source-volume traversal on boot APFS container")
        let image = root.appendingPathComponent("scratch.sparseimage")
        _ = try run("/usr/bin/hdiutil", ["create", "-size", "800m", "-type", "SPARSE", "-layout", "NONE", image.path])
        let policy = TargetPolicy.disposableImage(image.path)
        var attachedDevice: String?
        defer { if let device = attachedDevice { _ = try? run("/usr/bin/hdiutil", ["detach", device]) } }

        func attach() throws -> Disk {
            let attached = try plist("/usr/bin/hdiutil", ["attach", "-nomount", "-plist", image.path])
            guard let entities = attached["system-entities"] as? [[String: Any]],
                  let device = entities.compactMap({ $0["dev-entry"] as? String }).first(where: { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil }),
                  device.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil else { throw MufusError("No test disk image: \(attached)") }
            attachedDevice = device
            let info = try diskInfo(device)
            guard info["BusProtocol"] as? String == "Disk Image" else { throw MufusError("Not a disposable disk image") }
            do { _ = try admitDisk(info); throw MufusError("Image admitted as physical USB") }
            catch let error as MufusError { guard error.message.contains("Alleen") else { throw error } }
            return try policy.inspect(String(device.dropFirst(5)))
        }
        func job(_ disk: Disk, mode: JobMode, source: String = "", fs: String = "FAT32", scheme: String = "MBRFormat") -> Job {
            Job(disk: disk.id, fingerprint: disk.fingerprint, source: source, mode: mode.rawValue, filesystem: fs, partition: scheme, label: "MUFUSTEST")
        }
        func execute(_ job: Job) throws {
            var finished = false
            try executeJob(job, policy: policy) { phase, fraction in
                if fraction == 1 { finished = true; print(phase) }
            }
            guard finished else { throw MufusError("Missing successful completion") }
            attachedDevice = nil
        }

        for scheme in ["MBRFormat", "GPTFormat"] {
            for fs in ["FAT32", "ExFAT", "JHFS+"] {
                let disk = try attach()
                try execute(job(disk, mode: .format, fs: fs, scheme: scheme))
                let reopened = try attach()
                _ = try run("/usr/sbin/diskutil", ["mountDisk", "/dev/" + reopened.id])
                let volume = try volumeForDisk(reopened.id)
                let info = try diskInfo(volume.path)
                guard info["VolumeName"] as? String == "MUFUSTEST" else { throw MufusError("Wrong format label") }
                let file = volume.appendingPathComponent("verify.txt")
                let payload = Data("Mufus disposable virtual-disk integration test".utf8)
                try payload.write(to: file)
                guard try Data(contentsOf: file) == payload else { throw MufusError("Copy mismatch") }
                _ = try run("/usr/bin/hdiutil", ["detach", "/dev/" + reopened.id]); attachedDevice = nil
                print("PASS complete format job, remount, file write/read: \(fs) \(scheme)")
            }
        }

        // Raw transfer uses the same production writer, verifier, unmount and eject path.
        let raw = root.appendingPathComponent("fixture.img")
        var bytes = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) }); bytes.append(contentsOf: [1,2,3])
        try bytes.write(to: raw)
        let rawDisk = try attach()
        try execute(job(rawDisk, mode: .raw, source: raw.path))
        print("PASS complete raw image job and SHA-256 readback")

        // Use a real, small WIM archive in an actual mounted ISO. EFI/boot files
        // are fixtures, so this deliberately does not claim bootability.
        guard let wimtool = ProcessInfo.processInfo.environment["MUFUS_TEST_WIMLIB"] else { throw MufusError("Set MUFUS_TEST_WIMLIB") }
        let windows = root.appendingPathComponent("windows")
        for name in ["efi/boot/bootx64.efi", "sources/boot.wim", "boot/bcd", "setup.exe"] {
            let file = windows.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture-\(name)".utf8).write(to: file)
        }
        let wimInput = root.appendingPathComponent("wim-input")
        try fm.createDirectory(at: wimInput, withIntermediateDirectories: true)
        for i in 0..<4 { try bytes.write(to: wimInput.appendingPathComponent("payload-\(i).bin")) }
        _ = try run(wimtool, ["capture", wimInput.path, windows.appendingPathComponent("sources/install.wim").path, "--compress=none", "--check"])
        let iso = root.appendingPathComponent("windows.iso")
        _ = try run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", iso.path, windows.path])
        for split in [false, true] {
            if split {
                setenv("MUFUS_TEST_FAT32_LIMIT", "1048576", 1)
                setenv("MUFUS_TEST_WIM_PART_MB", "1", 1)
            }
            let disk = try attach()
            try execute(job(disk, mode: .windows, source: iso.path))
            let reopened = try attach()
            _ = try run("/usr/sbin/diskutil", ["mountDisk", "/dev/" + reopened.id])
            let volume = try volumeForDisk(reopened.id)
            guard fm.fileExists(atPath: volume.appendingPathComponent("efi/boot/bootx64.efi").path) else { throw MufusError("Missing EFI copy") }
            if split {
                guard fm.fileExists(atPath: volume.appendingPathComponent("sources/install.swm").path),
                      !fm.fileExists(atPath: volume.appendingPathComponent("sources/install.wim").path) else { throw MufusError("Split WIM output not used") }
                _ = try run(wimtool, ["verify", volume.appendingPathComponent("sources/install.swm").path, "--ref=" + volume.appendingPathComponent("sources/install*.swm").path])
            } else {
                guard try hashFile(volume.appendingPathComponent("sources/install.wim").path) == hashFile(windows.appendingPathComponent("sources/install.wim").path) else { throw MufusError("WIM copy mismatch") }
            }
            _ = try run("/usr/bin/hdiutil", ["detach", "/dev/" + reopened.id]); attachedDevice = nil
            print("PASS complete Windows ISO job, remount and verification; WIM split=\(split)")
        }
        print("Integration complete. Only the newly created temporary disk image was formatted.")
    }
}
