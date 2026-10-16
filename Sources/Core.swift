import Foundation
import CryptoKit
import Darwin

private final class ErrorCapture: @unchecked Sendable {
    var data = Data()
}

struct MufusError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@discardableResult
func run(_ path: String, _ args: [String]) throws -> Data {
    let p = Process(), out = Pipe(), err = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = out
    p.standardError = err
    p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LC_ALL": "C"]
    try p.run()
    let capture = ErrorCapture(), readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
        capture.data = err.fileHandleForReading.readDataToEndOfFile()
        readers.leave()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    readers.wait()
    guard p.terminationStatus == 0 else {
        let details = capture.data.isEmpty ? data : capture.data
        throw MufusError("\(URL(fileURLWithPath: path).lastPathComponent): \(String(decoding: details.suffix(6000), as: UTF8.self))")
    }
    return data
}

func plist(_ path: String, _ args: [String]) throws -> [String: Any] {
    let d = try run(path, args)
    guard let value = try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else {
        throw MufusError("Onleesbaar schijfantwoord.")
    }
    return value
}

struct Disk: Identifiable, Hashable {
    let id: String
    let name: String
    let size: Int64
    let fingerprint: String
    var title: String { "\(name) — \(ByteCountFormatter.string(fromByteCount: size, countStyle: .decimal)) (\(id))" }
}

func diskInfo(_ id: String) throws -> [String: Any] {
    try plist("/usr/sbin/diskutil", ["info", "-plist", id])
}

func admitDisk(_ info: [String: Any]) throws -> Disk {
    guard let id = info["DeviceIdentifier"] as? String,
          id.range(of: "^disk[0-9]+$", options: .regularExpression) != nil,
          info["WholeDisk"] as? Bool == true,
          info["Internal"] as? Bool == false,
          info["Writable"] as? Bool == true,
          info["VirtualOrPhysical"] as? String == "Physical",
          info["BusProtocol"] as? String == "USB",
          let size = (info["TotalSize"] as? NSNumber)?.int64Value, size > 0 else {
        throw MufusError("Alleen een volledige, fysieke, beschrijfbare externe USB-schijf is toegestaan.")
    }
    return try diskDescriptor(info)
}

private func diskDescriptor(_ info: [String: Any]) throws -> Disk {
    guard let id = info["DeviceIdentifier"] as? String,
          id.range(of: "^disk[0-9]+$", options: .regularExpression) != nil,
          let size = (info["TotalSize"] as? NSNumber)?.int64Value, size > 0 else { throw MufusError("Ongeldige schijfidentiteit.") }
    let name = info["MediaName"] as? String ?? info["IORegistryEntryName"] as? String ?? "USB-schijf"
    let identity = [id, name, String(size), info["DeviceTreePath"] as? String ?? "", info["MediaUUID"] as? String ?? ""].joined(separator: "|")
    return Disk(id: id, name: name, size: size, fingerprint: SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined())
}

// Disposable-image admission exists only in the separately compiled test host.
// It is absent from the shipping app, including its administrator helper.
enum TargetPolicy {
    case physicalUSB
    #if MUFUS_INTEGRATION_TESTS
    case disposableImage(String)
    #endif

    func inspect(_ id: String) throws -> Disk {
        let info = try diskInfo(id)
        switch self {
        case .physicalUSB: return try admitDisk(info)
        #if MUFUS_INTEGRATION_TESTS
        case .disposableImage(let image):
            let inventory = try plist("/usr/bin/hdiutil", ["info", "-plist"])
            let expected = URL(fileURLWithPath: image).resolvingSymlinksInPath().path
            let owned = (inventory["images"] as? [[String: Any]] ?? []).contains { entry in
                guard let path = entry["image-path"] as? String,
                      URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected else { return false }
                return (entry["system-entities"] as? [[String: Any]] ?? []).contains { $0["dev-entry"] as? String == "/dev/" + id }
            }
            guard owned, info["BusProtocol"] as? String == "Disk Image", info["WholeDisk"] as? Bool == true else {
                throw MufusError("Integration host refuses media not backed by its exact disposable image.")
            }
            return try diskDescriptor(info)
        #endif
        }
    }

    func checked(_ id: String, _ fingerprint: String) throws -> Disk {
        let disk = try inspect(id)
        guard disk.fingerprint == fingerprint else { throw MufusError("De USB-schijf is veranderd. Selecteer hem opnieuw.") }
        return disk
    }

    func requirePrivilege() throws {
        switch self {
        case .physicalUSB:
            guard geteuid() == 0 else { throw MufusError("Schrijven vereist macOS-beheerdersrechten.") }
        #if MUFUS_INTEGRATION_TESTS
        case .disposableImage: break
        #endif
        }
    }
}

func externalDisks() throws -> [Disk] {
    let list = try plist("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
    return (list["AllDisksAndPartitions"] as? [[String: Any]] ?? []).compactMap {
        guard let id = $0["DeviceIdentifier"] as? String, let info = try? diskInfo(id) else { return nil }
        return try? admitDisk(info)
    }
}

func checkedDisk(_ id: String, _ fingerprint: String) throws -> Disk {
    try TargetPolicy.physicalUSB.checked(id, fingerprint)
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

enum JobMode: String, CaseIterable, Identifiable {
    case raw, windows, format
    var id: String { rawValue }
    var title: String {
        switch self {
        case .raw: return "Image schrijven (Linux / IMG)"
        case .windows: return "Windows-installatie (UEFI)"
        case .format: return "Alleen formatteren"
        }
    }
}

struct Job: Codable {
    var disk: String
    var fingerprint: String
    var source: String
    var mode: String
    var filesystem: String
    var partition: String
    var label: String
}

func validateLabel(_ label: String) throws {
    guard label.range(of: "^[A-Za-z0-9_ -]{1,11}$", options: .regularExpression) != nil,
          label.trimmingCharacters(in: .whitespaces).isEmpty == false else {
        throw MufusError("Gebruik 1–11 letters, cijfers, spaties, _ of - voor de volumenaam.")
    }
}

func regularSource(_ path: String) throws -> (Int32, Int64) {
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw MufusError("Kan het bronbestand niet openen: \(String(cString: strerror(errno))).") }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else {
        close(fd); throw MufusError("Kies een gewoon, niet-leeg imagebestand.")
    }
    return (fd, st.st_size)
}

func validateRawImage(_ fd: Int32, path: String) throws {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard ["iso", "img", "dd", "bin"].contains(ext) else { throw MufusError("Gebruik een ISO, IMG, DD of BIN. Gecomprimeerde DMG-images worden niet ondersteund.") }
    if ext == "iso" {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw MufusError("Kan het image niet lezen.") }
        let header = [UInt8](try readChunk(fd, 512))
        guard header.count == 512, header[510] == 0x55, header[511] == 0xaa,
              (0..<4).contains(where: { let start = 446 + $0 * 16; return header[start + 4] != 0 && header[(start+12)...(start+15)].contains(where: { $0 != 0 }) }) else {
            throw MufusError("Deze ISO is geen hybride USB-schijfimage. Gebruik voor Windows de optie ‘Windows-installatie (UEFI)’.")
        }
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw MufusError("Kan het image niet terugspoelen.") }
    }
}

func ensureSourceNotOnTarget(_ path: String, _ target: String) throws {
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(forKeys: [.volumeURLKey])
    guard let mount = values.volume else { throw MufusError("Kan het bronvolume niet controleren.") }
    var queue: [[String: Any]] = [try diskInfo(mount.path)]
    var visited = Set<String>()
    while !queue.isEmpty {
        let info = queue.removeFirst()
        let id = info["DeviceIdentifier"] as? String ?? ""
        if visited.contains(id) { continue }; visited.insert(id)
        let parent = info["ParentWholeDisk"] as? String ?? id
        guard id != target && parent != target else { throw MufusError("Het bronbestand, Mufus of macOS staat op de USB-schijf die je wilt wissen.") }
        for key in ["ParentWholeDisk", "APFSContainerReference"] {
            if let next = info[key] as? String, !visited.contains(next) { queue.append(try diskInfo(next)) }
        }
        for store in info["APFSPhysicalStores"] as? [[String: Any]] ?? [] {
            if let next = store["APFSPhysicalStore"] as? String, !visited.contains(next) { queue.append(try diskInfo(next)) }
        }
    }
}

func readChunk(_ fd: Int32, _ limit: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: limit)
    var filled = 0
    try bytes.withUnsafeMutableBytes { buffer in
        while filled < limit {
            let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: filled), limit - filled)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw MufusError("Leesfout: \(String(cString: strerror(errno))).") }
            if n == 0 { break }
            filled += n
        }
    }
    return Data(bytes.prefix(filled))
}

func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { ptr in
        var pos = 0
        while pos < ptr.count {
            let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: pos), ptr.count - pos)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw MufusError("Schrijffout: \(String(cString: strerror(errno))).") }
            pos += n
        }
    }
}

func hashFD(_ fd: Int32, length: Int64, progress: (Double) -> Void = { _ in }) throws -> String {
    guard lseek(fd, 0, SEEK_SET) >= 0 else { throw MufusError("Kan niet naar het begin van de schijf gaan.") }
    var hash = SHA256(), done: Int64 = 0
    while done < length {
        // Raw devices require sector-aligned read lengths, even for an unaligned source file.
        let wanted = Int(min(Int64(4 * 1024 * 1024), ((length - done + 4095) / 4096) * 4096))
        let data = try readChunk(fd, wanted)
        guard !data.isEmpty else { throw MufusError("Onverwacht einde tijdens verificatie.") }
        let used = data.prefix(Int(min(Int64(data.count), length - done)))
        hash.update(data: used); done += Int64(used.count)
        progress(Double(done) / Double(length))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func hashFile(_ path: String) throws -> String {
    let (fd, size) = try regularSource(path)
    defer { close(fd) }
    return try hashFD(fd, length: size)
}

func clearStalePartitionTail(_ fd: Int32, imageLength: Int64, capacity: Int64, sector: Int) throws {
    guard [512, 1024, 2048, 4096].contains(sector), imageLength > 0, capacity >= imageLength,
          capacity % Int64(sector) == 0 else { throw MufusError("Ongeldige schijfgeometrie.") }
    let imageEnd = ((imageLength + Int64(sector) - 1) / Int64(sector)) * Int64(sector)
    let start = max(imageEnd, capacity - min(capacity, 1024 * 1024))
    guard start < capacity else { return }
    guard lseek(fd, start, SEEK_SET) == start else { throw MufusError("Kan oude schijfmetadata niet wissen.") }
    try writeAll(fd, Data(repeating: 0, count: Int(capacity - start)))
}

/// Also used by integration tests with ordinary files; production callers supply a validated raw USB fd.
func copyAndVerify(source: Int32, destination: Int32, length: Int64, sector: Int = 512, progress: (String, Double) -> Void) throws {
    guard [512, 1024, 2048, 4096].contains(sector), length > 0 else { throw MufusError("Ongeldige sectorgrootte of imagegrootte.") }
    var sourceStat = stat()
    guard fstat(source, &sourceStat) == 0, sourceStat.st_size == length,
          lseek(source, 0, SEEK_SET) == 0, lseek(destination, 0, SEEK_SET) == 0 else {
        throw MufusError("Het bronbestand is veranderd of de schijf kan niet worden teruggespoeld.")
    }
    var done: Int64 = 0, hash = SHA256()
    while done < length {
        var data = try readChunk(source, Int(min(Int64(4 * 1024 * 1024), length - done)))
        guard !data.isEmpty else { throw MufusError("Het bronbestand is tijdens het schrijven veranderd.") }
        hash.update(data: data)
        done += Int64(data.count)
        if done == length && data.count % sector != 0 {
            data.append(Data(repeating: 0, count: sector - data.count % sector))
        }
        try writeAll(destination, data)
        progress("Image schrijven", Double(done) / Double(length) * 0.65)
    }
    guard fsync(destination) == 0 else { throw MufusError("Schijf kon de gegevens niet synchroniseren.") }
    let expected = hash.finalize().map { String(format: "%02x", $0) }.joined()
    // Verify the source again as well: this detects mutations while the image was being read.
    let current = try hashFD(source, length: length)
    guard current == expected, fstat(source, &sourceStat) == 0, sourceStat.st_size == length else { throw MufusError("Het bronbestand is gewijzigd. Schrijven afgebroken.") }
    let actual = try hashFD(destination, length: length) { progress("USB verifiëren", 0.65 + $0 * 0.34) }
    guard actual == expected else { throw MufusError("Verificatie mislukt: de USB-inhoud komt niet overeen met het image.") }
}

struct ISOEntry {
    let relative: String
    let url: URL
    let size: Int64
    var split: Bool {
        #if MUFUS_INTEGRATION_TESTS
        if let override = ProcessInfo.processInfo.environment["MUFUS_TEST_FAT32_LIMIT"], let limit = Int64(override) { return size > limit }
        #endif
        return size > 4_294_967_295
    }
}

func windowsInventory(_ root: URL) throws -> [ISOEntry] {
    let fm = FileManager.default
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    var enumerationError: Error?
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
        throw MufusError("Kan de Windows-ISO niet lezen.")
    }
    var entries: [ISOEntry] = []
    for case let observedURL as URL in enumerator {
        guard try observedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw MufusError("De ISO bevat een symbolische koppeling.")
        }
        let url = observedURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isDirectory == true { continue }
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MufusError("De ISO bevat een niet-ondersteund bestand.") }
        guard url.path.hasPrefix(root.path + "/") else { throw MufusError("Bestand buiten het ISO-volume.") }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { throw MufusError("Ongeldig ISO-pad.") }
        let entry = ISOEntry(relative: relative, url: url, size: Int64(values.fileSize ?? 0))
        if entry.split && relative.lowercased() != "sources/install.wim" {
            throw MufusError("\(relative) is groter dan FAT32 toestaat. Alleen sources/install.wim kan worden opgesplitst.")
        }
        entries.append(entry)
    }
    if let error = enumerationError { throw error }
    let names = Set(entries.map { $0.relative.lowercased() })
    guard names.count == entries.count else { throw MufusError("De ISO bevat conflicterende FAT32-bestandsnamen.") }
    if entries.contains(where: { $0.split }), names.contains(where: { $0.hasPrefix("sources/install") && $0.hasSuffix(".swm") }) {
        throw MufusError("De ISO bevat al SWM-bestanden die conflicteren met WIM-splitsing.")
    }
    guard names.contains("sources/boot.wim"), names.contains("sources/install.wim") || names.contains("sources/install.esd"),
          names.contains("efi/boot/bootx64.efi") || names.contains("efi/boot/bootaa64.efi") else {
        throw MufusError("Dit is geen ondersteunde Windows-UEFI-installatie-ISO.")
    }
    return entries.sorted { $0.relative < $1.relative }
}

func mountedISO(_ path: String) throws -> (URL, String) {
    let value = try plist("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", path])
    let entities = value["system-entities"] as? [[String: Any]] ?? []
    let devices = entities.compactMap { $0["dev-entry"] as? String }
    let device = devices.first { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil } ?? ""
    guard !device.isEmpty else { throw MufusError("Het gekoppelde image heeft geen volledig schijfapparaat.") }
    guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
        if !device.isEmpty { _ = try? run("/usr/bin/hdiutil", ["detach", device]) }
        throw MufusError("De ISO heeft geen leesbaar volume.")
    }
    return (URL(fileURLWithPath: mount), device)
}

func volumeForDisk(_ id: String) throws -> URL {
    let tree = try plist("/usr/sbin/diskutil", ["list", "-plist", id])
    let roots = tree["AllDisksAndPartitions"] as? [[String: Any]] ?? []
    for part in roots.flatMap({ $0["Partitions"] as? [[String: Any]] ?? [] }) {
        guard let child = part["DeviceIdentifier"] as? String, child.hasPrefix(id + "s"), part["Content"] as? String != "EFI" else { continue }
        if let mount = try diskInfo(child)["MountPoint"] as? String { return URL(fileURLWithPath: mount) }
    }
    throw MufusError("Het geformatteerde USB-volume kon niet worden gevonden.")
}

func executeJob(_ job: Job, policy: TargetPolicy = .physicalUSB, progress: (String, Double) -> Void) throws {
    try policy.requirePrivilege()
    guard let mode = JobMode(rawValue: job.mode), ["MBRFormat", "GPTFormat"].contains(job.partition),
          ["FAT32", "ExFAT", "JHFS+"].contains(job.filesystem) else { throw MufusError("Ongeldige taakinstellingen.") }
    try validateLabel(job.label)
    let disk = try policy.checked(job.disk, job.fingerprint)
    try ensureSourceNotOnTarget("/", disk.id)
    try ensureSourceNotOnTarget(Bundle.main.bundleURL.path, disk.id)
    let device = "/dev/" + disk.id
    var sourceFD: Int32 = -1
    var size: Int64 = 0
    defer { if sourceFD >= 0 { close(sourceFD) } }
    if mode != .format {
        try ensureSourceNotOnTarget(job.source, disk.id)
        (sourceFD, size) = try regularSource(job.source)
        guard size <= disk.size else { throw MufusError("Het image is groter dan de USB-schijf.") }
        if mode == .raw { try validateRawImage(sourceFD, path: job.source) }
    }
    var isoRoot: URL?, isoDevice: String?, entries: [ISOEntry] = []
    defer { if let d = isoDevice, !d.isEmpty { _ = try? run("/usr/bin/hdiutil", ["detach", d]) } }
    var wimtool = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wimlib-imagex").path
    #if MUFUS_INTEGRATION_TESTS
    wimtool = ProcessInfo.processInfo.environment["MUFUS_TEST_WIMLIB"] ?? wimtool
    #endif
    if mode == .windows {
        guard job.filesystem == "FAT32" else { throw MufusError("Windows-UEFI vereist FAT32.") }
        let mounted = try mountedISO(job.source)
        isoRoot = mounted.0; isoDevice = mounted.1
        entries = try windowsInventory(mounted.0)
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total + 512 * 1024 * 1024 < disk.size else { throw MufusError("Te weinig ruimte voor de Windows-installatie.") }
        if entries.contains(where: { $0.split }) {
            guard FileManager.default.isExecutableFile(atPath: wimtool) else { throw MufusError("De meegeleverde WIM-tool ontbreekt.") }
            _ = try run(wimtool, ["--version"])
        }
    }
    _ = isoRoot
    progress("USB voorbereiden", 0.01)
    _ = try policy.checked(job.disk, job.fingerprint)
    _ = try run("/usr/sbin/diskutil", ["unmountDisk", device])
    _ = try policy.checked(job.disk, job.fingerprint)
    if mode == .raw {
        let sector = (try diskInfo(disk.id)["DeviceBlockSize"] as? NSNumber)?.intValue ?? 512
        guard ((size + Int64(sector) - 1) / Int64(sector)) * Int64(sector) <= disk.size else { throw MufusError("Het afgeronde image past niet op de schijf.") }
        let dest = Darwin.open("/dev/r" + disk.id, O_RDWR | O_EXCL | O_NOFOLLOW | O_CLOEXEC)
        guard dest >= 0 else { throw MufusError("Kan USB niet exclusief openen: \(String(cString: strerror(errno))).") }
        do {
            defer { close(dest) }
            try clearStalePartitionTail(dest, imageLength: size, capacity: disk.size, sector: sector)
            try copyAndVerify(source: sourceFD, destination: dest, length: size, sector: sector, progress: progress)
        }
    } else {
        _ = try run("/usr/sbin/diskutil", ["eraseDisk", job.filesystem, job.label, job.partition, device])
        if mode == .windows {
            let destination = try volumeForDisk(disk.id)
            let total = max(entries.reduce(Int64(0)) { $0 + $1.size }, 1)
            var done: Int64 = 0
            for entry in entries {
                let target = destination.appendingPathComponent(entry.relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                progress("Kopiëren: \(entry.relative)", 0.05 + Double(done) / Double(total) * 0.6)
                if entry.split {
                    let swm = target.deletingPathExtension().appendingPathExtension("swm")
                    var partSize = "3800"
                    #if MUFUS_INTEGRATION_TESTS
                    partSize = ProcessInfo.processInfo.environment["MUFUS_TEST_WIM_PART_MB"] ?? partSize
                    #endif
                    _ = try run(wimtool, ["split", entry.url.path, swm.path, partSize, "--check"])
                    let pattern = target.deletingPathExtension().lastPathComponent + "*.swm"
                    _ = try run(wimtool, ["verify", swm.path, "--ref=" + target.deletingLastPathComponent().appendingPathComponent(pattern).path])
                } else {
                    try FileManager.default.copyItem(at: entry.url, to: target)
                }
                done += entry.size
            }
            done = 0
            // Hash every copied file; split WIM sets are verified by wimlib above.
            for entry in entries {
                if !entry.split {
                    let expected = try hashFile(entry.url.path)
                    let actual = try hashFile(destination.appendingPathComponent(entry.relative).path)
                    guard expected == actual else { throw MufusError("Verificatie mislukt voor \(entry.relative).") }
                }
                done += entry.size
                progress("Windows-bestanden verifiëren", 0.65 + Double(done) / Double(total) * 0.34)
            }
        }
        _ = try run("/usr/sbin/diskutil", ["unmountDisk", device])
    }
    _ = try run("/usr/sbin/diskutil", ["eject", device])
    progress("Gereed — USB veilig verwijderd", 1)
}
