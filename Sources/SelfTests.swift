import Foundation
import Darwin

func selfTests() throws {
    var count = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw MufusError(message) }; count += 1; print("PASS \(message)")
    }
    func rejects(_ title: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; print("PASS \(title)"); return }
        throw MufusError("Did not reject: " + title)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mufus-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.img"), target = root.appendingPathComponent("target.img")
    // Exercise multiple read blocks, a final non-sector-aligned block, and exact byte verification.
    var bytes = Data((0..<65536).map { UInt8($0 % 251) })
    for _ in 0..<7 { bytes.append(bytes) }
    bytes.append(Data([23, 42, 99]))
    try bytes.write(to: source)
    let (src, size) = try regularSource(source.path)
    defer { close(src) }
    let dst = open(target.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
    guard dst >= 0 else { throw MufusError("test output open") }; defer { close(dst) }
    try copyAndVerify(source: src, destination: dst, length: size, sector: 4096) { _, _ in }
    let copied = try Data(contentsOf: target)
    try expect(copied.prefix(bytes.count) == bytes, "raw write preserves all image bytes")
    try expect(copied.count % 4096 == 0 && copied.suffix(copied.count - bytes.count).allSatisfy { $0 == 0 }, "final block padding is aligned and zero-filled")
    let before = try hashFD(dst, length: size)
    _ = lseek(dst, 100, SEEK_SET); try writeAll(dst, Data([255]))
    let after = try hashFD(dst, length: size)
    try expect(before != after, "readback detects corrupted destination")
    let tail = root.appendingPathComponent("old-partition.img")
    let tailFD = open(tail.path, O_RDWR | O_CREAT | O_EXCL, 0o600); defer { if tailFD >= 0 { close(tailFD) } }
    guard tailFD >= 0 else { throw MufusError("Cannot open partition-tail fixture") }
    try writeAll(tailFD, Data(repeating: 0x77, count: 2 * 1024 * 1024))
    try clearStalePartitionTail(tailFD, imageLength: 1536 * 1024, capacity: 2 * 1024 * 1024, sector: 512)
    _ = lseek(tailFD, 1536 * 1024 - 512, SEEK_SET)
    try expect(try readChunk(tailFD, 512).allSatisfy { $0 == 0x77 }, "tail cleanup preserves image region")
    try expect(try readChunk(tailFD, 512 * 1024).allSatisfy { $0 == 0 }, "old backup partition metadata cleared beyond image")
    try rejects("empty source blocked") {
        let empty = root.appendingPathComponent("empty"); try Data().write(to: empty)
        let (fd, _) = try regularSource(empty.path); close(fd)
    }
    try rejects("symlink source blocked") {
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let (fd, _) = try regularSource(link.path); close(fd)
    }
    var good: [String: Any] = ["DeviceIdentifier":"disk9", "WholeDisk":true, "Internal":false, "Writable":true, "VirtualOrPhysical":"Physical", "BusProtocol":"USB", "TotalSize":Int64(16_000_000_000), "MediaName":"TEST", "DeviceTreePath":"test/path"]
    try expect(try admitDisk(good).id == "disk9", "physical external USB admitted")
    for (key, value) in [("Internal", true as Any), ("WholeDisk", false as Any), ("Writable", false as Any), ("VirtualOrPhysical", "Virtual" as Any), ("BusProtocol", "PCI-Express" as Any), ("DeviceIdentifier", "disk9s1" as Any), ("DeviceIdentifier", "disk9;touch /tmp/x" as Any)] {
        var bad = good; bad[key] = value
        try rejects("unsafe disk rejected: \(key)=\(value)") { _ = try admitDisk(bad) }
    }
    let original = try admitDisk(good).fingerprint
    good["DeviceTreePath"] = "different/path"
    try expect(original != admitDisk(good).fingerprint, "replacement disk changes identity")
    try rejects("shell characters blocked in volume label") { try validateLabel("$(touch x)") }
    try rejects("long FAT label blocked") { try validateLabel("LONGERTHANELEVEN") }
    try validateLabel("MUFUS_USB")
    try expect(shellQuote("a'b") == "'a'\\''b'", "shell paths quoted safely")
    let sample = root.appendingPathComponent("abc.img")
    try Data("abc".utf8).write(to: sample)
    try expect(try hashFile(sample.path) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 matches standard known answer")
    let commandResult = try plist("/bin/sh", ["-c", "printf 'diagnostic warning\\n' >&2; printf '%s' '<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>ok</key><true/></dict></plist>'"])
    try expect(commandResult["ok"] as? Bool == true, "stderr warnings do not corrupt plist output")
    let largeError = try run("/bin/sh", ["-c", "dd if=/dev/zero bs=65536 count=32 >&2 2>/dev/null; printf done"])
    try expect(String(decoding: largeError, as: UTF8.self) == "done", "large stderr drains without deadlock")
    let changed = root.appendingPathComponent("changed.img")
    try bytes.write(to: changed)
    let (changedFD, changedSize) = try regularSource(changed.path); defer { close(changedFD) }
    try rejects("source growth during transfer detected") {
        var appended = false
        try copyAndVerify(source: changedFD, destination: dst, length: changedSize) { phase, _ in
            if !appended && phase == "Image schrijven" {
                let append = open(changed.path, O_WRONLY | O_APPEND)
                if append >= 0 { _ = Darwin.write(append, [UInt8(1)], 1); close(append) }
                appended = true
            }
        }
    }
    let iso = root.appendingPathComponent("test.iso")
    var isoBytes = Data(repeating: 0, count: 1024)
    try isoBytes.write(to: iso)
    let (isoFD, _) = try regularSource(iso.path); defer { close(isoFD) }
    try rejects("non-hybrid optical ISO blocked") { try validateRawImage(isoFD, path: iso.path) }
    isoBytes[510] = 0x55; isoBytes[511] = 0xaa; isoBytes[450] = 0x83; isoBytes[458] = 1
    try isoBytes.write(to: iso)
    let (hybridFD, _) = try regularSource(iso.path); defer { close(hybridFD) }
    try validateRawImage(hybridFD, path: iso.path)
    try expect(lseek(hybridFD, 0, SEEK_CUR) == 0, "hybrid ISO accepted and source rewound")
    try rejects("missing ISO directory fails closed") { _ = try windowsInventory(root.appendingPathComponent("missing")) }
    let win = root.appendingPathComponent("windows")
    for file in ["efi/boot/bootx64.efi", "sources/boot.wim", "sources/install.wim"] {
        let url = win.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: url)
    }
    try expect(try windowsInventory(win).count == 3, "Windows UEFI layout recognized")
    let link = win.appendingPathComponent("link-to-file")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: win.appendingPathComponent("sources/install.wim"))
    try rejects("ISO symbolic links rejected") { _ = try windowsInventory(win) }
    try FileManager.default.removeItem(at: link)
    try FileManager.default.removeItem(at: win.appendingPathComponent("efi/boot/bootx64.efi"))
    try rejects("non-UEFI image blocked before erase") { _ = try windowsInventory(win) }
    let huge = win.appendingPathComponent("too-large.esd")
    FileManager.default.createFile(atPath: huge.path, contents: nil)
    let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: 4_294_967_296); try handle.close()
    try rejects("unsupported >4GB file blocked before erase") { _ = try windowsInventory(win) }
    try FileManager.default.removeItem(at: huge)
    let wim = try FileHandle(forWritingTo: win.appendingPathComponent("sources/install.wim"))
    try wim.truncate(atOffset: 4_294_967_296); try wim.close()
    try Data([1]).write(to: win.appendingPathComponent("sources/install.swm"))
    try rejects("existing SWM files cannot collide with WIM split output") { _ = try windowsInventory(win) }
    print("\(count) checks passed. No physical disks written.")
}
