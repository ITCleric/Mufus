import Cocoa
import SwiftUI
import UniformTypeIdentifiers

final class Model: ObservableObject {
    @Published var disks: [Disk] = []
    @Published var selected = ""
    @Published var source = ""
    @Published var mode: JobMode = .raw
    @Published var filesystem = "FAT32"
    @Published var partition = "MBRFormat"
    @Published var label = "MUFUS"
    @Published var busy = false
    @Published var status = "Klaar voor gebruik"
    @Published var log = ""
    @Published var checksum = ""
    @Published var showLog = false
    @Published var error: String?
    var disk: Disk? { disks.first { $0.id == selected } }
    var canStart: Bool { disk != nil && !busy && (mode == .format || !source.isEmpty) }

    func refresh() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try externalDisks() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let disks):
                    self.disks = disks
                    if !disks.contains(where: { $0.id == self.selected }) { self.selected = disks.first?.id ?? "" }
                    self.status = disks.isEmpty ? "Sluit een USB-stick aan en klik op Vernieuwen" : "Klaar voor gebruik"
                case .failure(let err): self.error = err.localizedDescription
                }
            }
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Selecteer een ISO- of schijfimage"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["iso", "img", "dd", "bin"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            source = url.resolvingSymlinksInPath().path
            checksum = ""
        }
    }

    func calculateHash() {
        guard !source.isEmpty && !busy else { return }
        busy = true; status = "SHA-256 berekenen…"
        let path = source
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try hashFile(path) }
            DispatchQueue.main.async {
                self.busy = false; self.status = "Klaar voor gebruik"
                switch result {
                case .success(let hash): self.checksum = hash
                case .failure(let err): self.error = err.localizedDescription
                }
            }
        }
    }

    func start() {
        guard let disk = disk, canStart else { return }
        do {
            try validateLabel(label)
            _ = try checkedDisk(disk.id, disk.fingerprint)
            if mode != .format {
                try ensureSourceNotOnTarget(source, disk.id)
                let (fd, size) = try regularSource(source)
                defer { close(fd) }
                guard size <= disk.size else { throw MufusError("Het image past niet op deze USB-schijf.") }
                if mode == .raw { try validateRawImage(fd, path: source) }
            }
        } catch { self.error = error.localizedDescription; return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(disk.name) volledig wissen?"
        alert.informativeText = "Alle gegevens op \(disk.title) worden gewist.\n\n" + (mode == .format ? "De schijf wordt geformatteerd als \(filesystem)." : "Bron: \(URL(fileURLWithPath: source).lastPathComponent)\n\(mode.title)")
        alert.addButton(withTitle: "Annuleren")
        alert.addButton(withTitle: "Wis USB en start")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let job = Job(disk: disk.id, fingerprint: disk.fingerprint, source: source, mode: mode.rawValue,
                      filesystem: mode == .windows ? "FAT32" : filesystem, partition: partition, label: label)
        do {
            let data = try JSONEncoder().encode(job)
            let payload = data.base64EncodedString()
            guard let executable = Bundle.main.executableURL?.path else { throw MufusError("De app is niet correct geïnstalleerd.") }
            let command = shellQuote(executable) + " --helper " + shellQuote(payload)
            let script = "do shell script " + appleQuote(command) + " with administrator privileges"
            busy = true; checksum = ""; status = "Schrijven en verifiëren…"; log = ""
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try run("/usr/bin/osascript", ["-e", script]) }
                DispatchQueue.main.async {
                    self.busy = false
                    switch result {
                    case .success(let output):
                        self.log = String(decoding: output, as: UTF8.self)
                        self.status = "Gereed — USB veilig verwijderd"
                        self.disks.removeAll { $0.id == disk.id }; self.selected = ""
                        NSSound.beep()
                    case .failure(let err):
                        self.status = "Taak niet voltooid"
                        self.log = err.localizedDescription
                        self.error = err.localizedDescription
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func saveLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mufus-log.txt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try log.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    private let purple = Color(red: 0.56, green: 0.36, blue: 0.82)
    private var logo: NSImage {
        NSImage(contentsOf: Bundle.main.url(forResource: "Mufus", withExtension: "png") ?? URL(fileURLWithPath: "/")) ?? NSImage()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            tabs
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    diskCard
                    if model.mode != .format { imageCard }
                    if model.mode != .raw { optionsCard }
                    verificationNote
                }.padding(.vertical, 2)
            }
            footer
        }
        .padding(28)
        .frame(minWidth: 690, idealWidth: 720, maxWidth: .infinity, minHeight: 710, maxHeight: .infinity)
        .accentColor(purple)
        .disabled(model.busy)
        .onAppear(perform: model.refresh)
        .alert("Mufus", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showLog) { logSheet }
    }

    private var header: some View {
        HStack(spacing: 17) {
            Image(nsImage: logo).resizable().interpolation(.high).scaledToFit().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mufus").font(.system(size: 31, weight: .bold, design: .rounded))
                Text("Jouw USB. Klaar om te starten.").font(.callout).foregroundColor(.secondary)
            }
            Spacer()
            Text("1.0.1").font(.caption.weight(.medium)).foregroundColor(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Color.primary.opacity(0.045)).clipShape(Capsule())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabs: some View {
        HStack(spacing: 5) {
            modeTab(.raw, title: "Image schrijven", icon: "square.and.arrow.down")
            modeTab(.windows, title: "Windows USB", icon: "square.grid.2x2")
            modeTab(.format, title: "Formatteren", icon: "externaldrive")
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func modeTab(_ mode: JobMode, title: String, icon: String) -> some View {
        Button { model.mode = mode } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .foregroundColor(model.mode == mode ? .white : .secondary)
            .background(model.mode == mode ? purple : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(model.mode == mode ? "Geselecteerd" : "")
        .help(mode.title)
    }

    private var diskCard: some View {
        card {
            cardTitle("USB-schijf", subtitle: "Kies het apparaat dat je wilt voorbereiden.", icon: "externaldrive")
            HStack(spacing: 10) {
                Menu {
                    ForEach(model.disks) { disk in Button(disk.title) { model.selected = disk.id } }
                } label: {
                    HStack {
                        Text(model.disk?.title ?? "Geen USB-schijf gevonden").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton).frame(maxWidth: .infinity)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.primary.opacity(0.045)).cornerRadius(8)
                .accessibilityLabel("USB-schijf")
                .disabled(model.disks.isEmpty)
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise").frame(width: 23, height: 23) }
                    .help("USB-schijven vernieuwen")
            }.controlSize(.large)
            Label("Alleen fysieke externe USB-schijven", systemImage: "lock.shield")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var imageCard: some View {
        card {
            cardTitle(model.mode == .windows ? "Windows-installatie" : "Schijfimage",
                      subtitle: model.mode == .windows ? "Maak een UEFI-installatiestick voor een Windows-pc." : "Schrijf een hybride Linux-ISO of IMG/DD-image.", icon: "doc")
            HStack(spacing: 12) {
                Image(systemName: "doc.zipper").font(.system(size: 22)).foregroundColor(purple.opacity(0.8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.source.isEmpty ? "Selecteer een imagebestand" : URL(fileURLWithPath: model.source).lastPathComponent)
                        .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(model.source.isEmpty ? (model.mode == .windows ? "Windows 10 / 11 · ISO" : "ISO · IMG · DD · BIN") : model.source)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Selecteren…", action: model.chooseImage).controlSize(.large)
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(purple.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Text(model.mode == .windows ? "FAT32 met automatische WIM-splitsing" : "De partitie-indeling wordt uit het image overgenomen.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer(minLength: 8)
                Button("SHA-256", action: model.calculateHash).font(.caption).disabled(model.source.isEmpty)
            }
            if !model.checksum.isEmpty {
                Text(model.checksum).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var optionsCard: some View {
        card {
            cardTitle("Formatteeropties", subtitle: "Stel de indeling en volumenaam in.", icon: "slider.horizontal.3")
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Partitieschema").font(.caption).foregroundColor(.secondary)
                    Picker("Partitieschema", selection: $model.partition) {
                        Text("MBR").tag("MBRFormat"); Text("GPT").tag("GPTFormat")
                    }.labelsHidden().frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Bestandssysteem").font(.caption).foregroundColor(.secondary)
                    if model.mode == .windows {
                        HStack { Text("FAT32"); Spacer(); Image(systemName: "lock.fill").font(.caption).foregroundColor(.secondary) }
                            .padding(.horizontal, 9).frame(height: 28)
                            .background(Color.primary.opacity(0.04)).cornerRadius(6)
                    } else {
                        Picker("Bestandssysteem", selection: $model.filesystem) {
                            Text("FAT32").tag("FAT32"); Text("exFAT").tag("ExFAT"); Text("Mac OS uitgebreid").tag("JHFS+")
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Volumenaam").font(.caption).foregroundColor(.secondary)
                    TextField("MUFUS", text: $model.label).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity)
            }.controlSize(.large)
        }
    }

    private var verificationNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill").foregroundColor(purple)
            Text(model.mode == .format ? "Na het formatteren wordt je USB veilig verwijderd." : "Mufus verifieert de geschreven gegevens en verwijdert je USB daarna veilig.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 3).padding(.top, 2).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        if model.busy { ProgressView().controlSize(.small).scaleEffect(0.8) }
                        else { Circle().fill(model.status.hasPrefix("Gereed") ? Color.green : purple).frame(width: 7, height: 7) }
                        Text(model.status).font(.callout).foregroundColor(.secondary).lineLimit(2)
                    }
                    Button("Bekijk logboek") { model.showLog = true }.buttonStyle(.link).font(.caption).disabled(model.log.isEmpty)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: model.start) {
                    HStack(spacing: 10) { Text(model.mode == .format ? "Formatteer USB" : "Start schrijven"); Image(systemName: "arrow.right") }
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 5)
                }
                .keyboardShortcut(.defaultAction).disabled(!model.canStart)
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }.frame(maxWidth: .infinity)
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: logo).resizable().scaledToFit().frame(width: 30, height: 30)
                Text("Logboek").font(.title2.bold())
            }
            ScrollView { Text(model.log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Button("Bewaar…", action: model.saveLog); Spacer(); Button("Sluiten") { model.showLog = false } }
        }.padding(24).frame(width: 650, height: 420).accentColor(purple)
    }

    private func cardTitle(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(purple).font(.system(size: 16, weight: .medium)).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appMenu = NSMenu(), fileMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        appMenu.addItem(withTitle: "Over Mufus", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Verberg Mufus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Stop Mufus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(title: "Archief", action: nil, keyEquivalent: ""); fileItem.submenu = fileMenu; menu.addItem(fileItem)
        fileMenu.addItem(withTitle: "Selecteer image…", action: #selector(choose), keyEquivalent: "o")
        let edit = NSMenu(title: "Wijzig"), editItem = NSMenuItem(title: "Wijzig", action: nil, keyEquivalent: "")
        editItem.submenu = edit; menu.addItem(editItem)
        edit.addItem(withTitle: "Kopieer", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Plak", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecteer alles", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mufus"; window.delegate = self
        window.minSize = NSSize(width: 690, height: 740)
        if let iconURL = Bundle.main.url(forResource: "Mufus", withExtension: "png"), let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func choose() { if !model.busy { model.chooseImage() } }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Mufus", .applicationVersion: "1.0.1", .credits: NSAttributedString(string: "Native USB-tool voor macOS\nImages schrijven · Windows UEFI · Formatteren")])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model.busy ? .terminateCancel : .terminateNow }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
}

@main
struct MufusMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--helper" {
            do {
                guard CommandLine.arguments.count == 3, let data = Data(base64Encoded: CommandLine.arguments[2]) else { throw MufusError("Ongeldige hulptaak.") }
                let job = try JSONDecoder().decode(Job.self, from: data)
                try executeJob(job) { phase, fraction in
                    print("\(Int(fraction * 100))% — \(phase)"); fflush(stdout)
                }
                exit(0)
            } catch {
                fputs("Mufus: \(error.localizedDescription)\n", stderr); exit(1)
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTests(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--list-disks") {
            do { for disk in try externalDisks() { print(disk.title) }; exit(0) }
            catch { fputs("\(error)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
