import AppKit
import RemoteSSHCore
import SwiftUI

struct SiteManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var sites: [Site] = []
    @State private var passwords: [UUID: String] = [:]
    @State private var deleted: Set<UUID> = []
    @State private var selection: UUID?
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                siteList
                    .frame(minWidth: 220, idealWidth: 240)
                detail
                    .frame(minWidth: 460)
            }
            Divider()
            HStack {
                ControlGroup {
                    Button("New Site", systemImage: "plus") { newSite() }
                    Button("Duplicate", systemImage: "plus.square.on.square") { duplicate() }.disabled(selection == nil)
                    Button("Delete", systemImage: "trash") { delete() }.disabled(selection == nil)
                }
                .fixedSize()
                Menu {
                    Button("Import from RemoteSSH…", systemImage: "square.and.arrow.down") { importSites() }
                    Button("Export Sites…", systemImage: "square.and.arrow.up") { exportSites() }
                } label: {
                    Label("Import/Export", systemImage: "arrow.up.arrow.down.square")
                }
                .fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { save(); dismiss() }
                Button("Connect", systemImage: "bolt.horizontal.fill") {
                    save()
                    if let site = sites.first(where: { $0.id == selection }) { model.connect(to: site) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(width: 780, height: 520)
        .onAppear {
            sites = model.sites
            selection = sites.first?.id
        }
    }

    // MARK: List

    private var folders: [String] {
        Array(Set(sites.map(\.folder))).sorted()
    }

    private var siteList: some View {
        List(selection: $selection) {
            ForEach(folders, id: \.self) { folder in
                Section {
                    ForEach(sites.filter { $0.folder == folder }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { site in
                        Label {
                            Text(site.name)
                        } icon: {
                            Image(systemName: site.serverProtocol == .sftp ? "lock.rectangle.stack.fill" : "externaldrive.connected.to.line.below.fill")
                                .foregroundStyle(site.serverProtocol == .sftp ? Color.green : Color.blue)
                        }
                        .tag(site.id)
                    }
                } header: {
                    Label(folder.isEmpty ? "My Sites" : folder, systemImage: "folder")
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let index = sites.firstIndex(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 0) {
                Picker("", selection: $tab) {
                    Text("General").tag(0)
                    Text("Advanced").tag(1)
                    Text("Transfer Settings").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)
                Form {
                    switch tab {
                    case 0: general($sites[index])
                    case 1: advanced($sites[index])
                    default: transfer($sites[index])
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            Text("Select a site or create a new one.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func general(_ site: Binding<Site>) -> some View {
        TextField("Name:", text: site.name)
        TextField("Folder:", text: site.folder, prompt: Text("e.g. Work/Production"))
        Picker("Protocol:", selection: site.serverProtocol) {
            ForEach(ServerProtocol.allCases) { Text($0.displayName).tag($0) }
        }
        HStack {
            TextField("Host:", text: site.host)
            TextField("Port:", value: site.port, format: .number.grouping(.never), prompt: Text("\(site.wrappedValue.effectivePort)"))
                .frame(width: 120)
        }
        if site.wrappedValue.serverProtocol == .ftp {
            Picker("Encryption:", selection: site.encryption) {
                ForEach(FTPEncryption.allCases) { Text($0.displayName).tag($0) }
            }
        }
        Picker("Logon Type:", selection: site.logonType) {
            ForEach(LogonType.allCases.filter { site.wrappedValue.serverProtocol == .sftp || $0 != .keyFile }) {
                Text($0.displayName).tag($0)
            }
        }
        if site.wrappedValue.logonType != .anonymous {
            TextField("User:", text: site.user)
        }
        if site.wrappedValue.logonType == .normal {
            SecureField("Password:", text: passwordBinding(site.wrappedValue.id))
        }
        if site.wrappedValue.logonType == .keyFile {
            HStack {
                TextField("Key file:", text: site.keyFilePath)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { site.wrappedValue.keyFilePath = url.path }
                }
            }
        }
        TextField("Comments:", text: site.comments, axis: .vertical)
            .lineLimit(3...6)
    }

    @ViewBuilder
    private func advanced(_ site: Binding<Site>) -> some View {
        HStack {
            TextField("Default local directory:", text: site.defaultLocalDirectory)
            Button("Browse…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { site.wrappedValue.defaultLocalDirectory = url.path }
            }
        }
        TextField("Default remote directory:", text: site.defaultRemoteDirectory)
        if site.wrappedValue.serverProtocol == .ftp {
            Toggle("Trust this server's TLS certificate even if it can't be verified", isOn: site.trustInvalidCertificate)
        }
    }

    @ViewBuilder
    private func transfer(_ site: Binding<Site>) -> some View {
        if site.wrappedValue.serverProtocol == .ftp {
            Picker("Transfer mode:", selection: site.transferMode) {
                Text("Passive (recommended)").tag(TransferMode.passive)
                Text("Active").tag(TransferMode.active)
            }
            .pickerStyle(.radioGroup)
        } else {
            Text("SFTP has no transfer mode settings.").foregroundStyle(.secondary)
        }
        Text("Concurrent transfers and speed limits are global (Settings).").foregroundStyle(.secondary)
    }

    private func passwordBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { passwords[id] ?? Keychain.password(for: id) ?? "" },
            set: { passwords[id] = $0 }
        )
    }

    // MARK: Actions

    private func newSite() {
        let folder = sites.first(where: { $0.id == selection })?.folder ?? ""
        let site = Site(name: "New site", folder: folder)
        sites.append(site)
        selection = site.id
        tab = 0
    }

    private func duplicate() {
        guard var copy = sites.first(where: { $0.id == selection }) else { return }
        let original = copy.id
        copy.id = UUID()
        copy.name += " (copy)"
        sites.append(copy)
        passwords[copy.id] = passwords[original] ?? Keychain.password(for: original)
        selection = copy.id
    }

    private func delete() {
        guard let id = selection else { return }
        sites.removeAll { $0.id == id }
        deleted.insert(id)
        selection = sites.first?.id
    }

    /// Persist pending edits first so import/export works on the current list.
    private func importSites() {
        save()
        model.importSites()
        sites = model.sites
        passwords = [:]
        deleted = []
        selection = sites.last?.id ?? selection
    }

    private func exportSites() {
        save()
        model.exportSites()
    }

    private func save() {
        for id in deleted { Keychain.setPassword(nil, for: id) }
        for (id, pw) in passwords where sites.contains(where: { $0.id == id }) {
            Keychain.setPassword(pw, for: id)
        }
        model.sites = sites
        model.saveSites()
    }
}
