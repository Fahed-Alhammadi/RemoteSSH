import AppKit
import RemoteSSHCore
import SwiftUI
import UniformTypeIdentifiers

private let remoteDragPrefix = "remotessh-remote:"

extension FileEntry {
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }
    static let parentEntry = FileEntry(name: "..", isDirectory: true)
}

/// Shared file table used by both panes.
struct FileTable: View {
    let entries: [FileEntry]
    let showHidden: Bool
    let comparison: [String: DirectoryComparison.State]
    let showParent: Bool
    @Binding var selection: Set<FileEntry.ID>
    let itemProvider: (FileEntry) -> NSItemProvider
    let onOpen: (FileEntry) -> Void
    let menu: (Set<FileEntry.ID>) -> AnyView

    @State private var sortOrder = [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
    @State private var filter = ""

    /// Filtered + sorted once per render (directories first).
    private func makeRows() -> [FileEntry] {
        var dirs: [FileEntry] = []
        var files: [FileEntry] = []
        for e in entries where (showHidden || !e.isHidden) && (filter.isEmpty || e.name.localizedCaseInsensitiveContains(filter)) {
            if e.isDirectory { dirs.append(e) } else { files.append(e) }
        }
        dirs.sort(using: sortOrder)
        files.sort(using: sortOrder)
        return (showParent ? [FileEntry.parentEntry] : []) + dirs + files
    }

    var body: some View {
        let rows = makeRows()
        VStack(spacing: 0) {
            Table(of: FileEntry.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { e in
                    HStack(spacing: 6) {
                        FileIcon(entry: e)
                        Text(e.name)
                            .foregroundStyle(color(for: e))
                            .lineLimit(1)
                        if e.isLink, let target = e.linkTarget {
                            Text("→ \(target)").foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
                .width(min: 160, ideal: 260)
                TableColumn("Size", value: \.sortSize) { e in
                    Text(e.isDirectory ? "—" : Format.bytes(e.size))
                        .monospacedDigit()
                        .foregroundStyle(e.isDirectory ? .tertiary : .primary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Kind") { e in Text(e.name == ".." ? "" : e.fileType).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 90)
                TableColumn("Modified", value: \.sortDate) { e in Text(Format.date(e.modified)).foregroundStyle(.secondary) }
                    .width(min: 90, ideal: 130)
                TableColumn("Permissions") { e in
                    Text(e.permissions).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 95)
                TableColumn("Owner") { e in Text(e.owner.isEmpty ? "" : "\(e.owner):\(e.group)").foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 100)
            } rows: {
                ForEach(rows) { entry in
                    if entry.name == ".." {
                        TableRow(entry)
                    } else {
                        TableRow(entry).itemProvider { itemProvider(entry) }
                    }
                }
            }
            .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
                menu(ids)
            } primaryAction: { ids in
                guard ids.count == 1, let id = ids.first, let entry = rows.first(where: { $0.id == id }) else { return }
                onOpen(entry)
            }

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter", text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(summary(rows)).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    private func summary(_ rows: [FileEntry]) -> String {
        let visible = rows.filter { $0.name != ".." }
        let selected = visible.filter { selection.contains($0.id) }
        let set = selected.isEmpty ? visible : selected
        var files = 0
        var total: Int64 = 0
        for e in set where !e.isDirectory {
            files += 1
            total += e.size ?? 0
        }
        let dirs = set.count - files
        let prefix = selected.isEmpty ? "" : "Selected: "
        return "\(prefix)\(files) file\(files == 1 ? "" : "s"), \(dirs) folder\(dirs == 1 ? "" : "s") · \(Format.bytes(total))"
    }

    private func color(for e: FileEntry) -> Color {
        switch comparison[e.name] {
        case .onlyHere: return Theme.success
        case .different: return Theme.danger
        case .newer: return Theme.warning
        default: return .primary
        }
    }
}

// MARK: - Local pane

struct LocalPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<FileEntry.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            PathBar(title: "Local", icon: "laptopcomputer", path: model.localPath, enabled: true,
                    submit: { model.navigateLocal(to: $0) }, up: model.navigateLocalUp, refresh: model.refreshLocal)
            Divider()
            FileTable(
                entries: model.localEntries,
                showHidden: model.settings.showHiddenFiles,
                comparison: model.comparison(forRemote: false),
                showParent: model.localPath != "/",
                selection: $selection,
                itemProvider: { e in NSItemProvider(contentsOf: model.localURL(e.name)) ?? NSItemProvider() },
                onOpen: open,
                menu: { ids in AnyView(menu(ids)) }
            )
            .onDrop(of: [.utf8PlainText], isTargeted: nil, perform: dropRemote)
        }
        .onChange(of: model.localPath) { selection = [] }
    }

    private func entries(_ ids: Set<FileEntry.ID>) -> [FileEntry] {
        model.localEntries.filter { ids.contains($0.id) }
    }

    private func open(_ e: FileEntry) {
        if e.name == ".." { model.navigateLocalUp() }
        else if e.isDirectory { model.navigateLocal(to: model.localURL(e.name).path) }
        else if model.connection == .connected { model.upload([e]) }
    }

    @ViewBuilder
    private func menu(_ ids: Set<FileEntry.ID>) -> some View {
        let sel = entries(ids)
        Button("Upload", systemImage: "arrow.up.circle") { model.upload(sel) }
            .disabled(sel.isEmpty || model.connection != .connected)
        Divider()
        Button("Open", systemImage: "arrow.up.forward.app") { model.localOpen(sel) }.disabled(sel.isEmpty)
        Button("Show in Finder", systemImage: "folder") { model.localReveal(sel) }
        Divider()
        Button("New Folder", systemImage: "folder.badge.plus") { model.localMakeDirectory() }
        Button("Refresh", systemImage: "arrow.clockwise") { model.refreshLocal() }
        Divider()
        Button("Rename", systemImage: "pencil") { if let e = sel.first { model.localRename(e) } }.disabled(sel.count != 1)
        Button("Move to Trash", systemImage: "trash", role: .destructive) { model.localTrash(sel) }.disabled(sel.isEmpty)
    }

    /// Remote rows dragged onto the local pane → download.
    private func dropRemote(_ providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        for p in accepted {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String, s.hasPrefix(remoteDragPrefix) else { return }
                let name = RemotePath.lastComponent(of: String(s.dropFirst(remoteDragPrefix.count)))
                Task { @MainActor in
                    if let entry = model.remoteEntries.first(where: { $0.name == name }) { model.download([entry]) }
                }
            }
        }
        return !accepted.isEmpty
    }
}

// MARK: - Remote pane

struct RemotePane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<FileEntry.ID> = []
    @State private var chmodTargets: ChmodTargets?

    var body: some View {
        let connected = model.connection == .connected
        VStack(spacing: 0) {
            PathBar(title: "Remote", icon: "server.rack", path: model.remotePath, enabled: connected,
                    submit: { path in Task { await model.navigateRemote(to: path) } },
                    up: { Task { await model.navigateRemote(to: RemotePath.parent(of: model.remotePath)) } },
                    refresh: model.refreshRemote)
            Divider()
            ZStack {
                FileTable(
                    entries: model.remoteEntries,
                    showHidden: model.settings.showHiddenFiles,
                    comparison: model.comparison(forRemote: true),
                    showParent: connected && model.remotePath != "/",
                    selection: $selection,
                    itemProvider: { e in NSItemProvider(object: (remoteDragPrefix + RemotePath.join(model.remotePath, e.name)) as NSString) },
                    onOpen: open,
                    menu: { ids in AnyView(menu(ids)) }
                )
                if !connected {
                    let connecting = model.connection == .connecting
                    VStack(spacing: 8) {
                        Image(systemName: connecting ? "antenna.radiowaves.left.and.right" : "powerplug")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 52, height: 52)
                            .background(.background, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                            .accessibilityHidden(true)
                        Text(connecting ? "Connecting…" : "Not connected").font(.headline).padding(.top, 4)
                        if !connecting {
                            Text("Pick a site on the left, or type an address above.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if model.sites.isEmpty {
                                Button("Add a Site", systemImage: "plus") { model.showSiteManager = true }
                                    .buttonStyle(.borderedProminent)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                } else if model.remoteBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: dropLocal)
        }
        .onChange(of: model.remotePath) { selection = [] }
        .sheet(item: $chmodTargets) { targets in
            ChmodSheet(entries: targets.entries) { mode in model.remoteChmod(targets.entries, mode: mode) }
        }
    }

    private func entries(_ ids: Set<FileEntry.ID>) -> [FileEntry] {
        model.remoteEntries.filter { ids.contains($0.id) }
    }

    private func open(_ e: FileEntry) {
        if e.name == ".." { Task { await model.navigateRemote(to: RemotePath.parent(of: model.remotePath)) } }
        else if e.isDirectory { Task { await model.navigateRemote(to: RemotePath.join(model.remotePath, e.name)) } }
        else { model.download([e]) }
    }

    @ViewBuilder
    private func menu(_ ids: Set<FileEntry.ID>) -> some View {
        let sel = entries(ids)
        let connected = model.connection == .connected
        Button("Download", systemImage: "arrow.down.circle") { model.download(sel) }.disabled(sel.isEmpty || !connected)
        Button("View/Edit", systemImage: "square.and.pencil") { if let e = sel.first { model.viewEdit(e) } }
            .disabled(sel.count != 1 || sel.first?.isDirectory == true)
        Divider()
        Button("New Folder", systemImage: "folder.badge.plus") { model.remoteMakeDirectory() }.disabled(!connected)
        Button("New Folder and Open", systemImage: "folder.badge.plus") { model.remoteMakeDirectory(enter: true) }.disabled(!connected)
        Button("Refresh", systemImage: "arrow.clockwise") { model.refreshRemote() }.disabled(!connected)
        Divider()
        Button("Rename", systemImage: "pencil") { if let e = sel.first { model.remoteRename(e) } }.disabled(sel.count != 1)
        Button("Permissions…", systemImage: "lock.shield") { chmodTargets = ChmodTargets(entries: sel) }.disabled(sel.isEmpty)
        Button("Copy URL", systemImage: "link") { model.copyURLs(sel) }.disabled(sel.isEmpty)
        Button("Open Terminal Here", systemImage: "terminal") {
            let folder = sel.count == 1 && sel[0].isDirectory ? RemotePath.join(model.remotePath, sel[0].name) : model.remotePath
            model.openTerminal(in: folder, reuse: true)
        }
        .disabled(!model.canOpenTerminal)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { model.remoteDelete(sel) }.disabled(sel.isEmpty)
    }

    /// Finder files or local rows dropped onto the remote pane → upload.
    private func dropLocal(_ providers: [NSItemProvider]) -> Bool {
        guard model.connection == .connected else { return false }
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in model.upload(paths: [url.path]) }
            }
        }
        return true
    }
}

private struct ChmodTargets: Identifiable {
    let entries: [FileEntry]
    var id: String { entries.map(\.name).joined(separator: "/") }
}

/// Editable path field; keeps its own text so typing isn't overwritten until navigation succeeds.
struct PathBar: View {
    let title: String
    let icon: String
    let path: String
    let enabled: Bool
    let submit: (String) -> Void
    let up: () -> Void
    let refresh: () -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
                .labelStyle(PaneTitleStyle())
                .padding(.trailing, 6)
            IconButton("arrow.turn.left.up", "Parent folder", action: up)
            IconButton("arrow.clockwise", "Refresh", action: refresh)
            TextField("Path", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .accessibilityLabel("\(title) path")
                .onSubmit { submit(text) }
        }
        .disabled(!enabled)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .onAppear { text = path }
        .onChange(of: path) { text = path }
    }
}
