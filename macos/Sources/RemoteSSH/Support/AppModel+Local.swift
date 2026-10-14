import AppKit
import Foundation
import RemoteSSHCore

/// Local-pane operations.
extension AppModel {
    func localURL(_ name: String) -> URL {
        URL(fileURLWithPath: localPath).appendingPathComponent(name)
    }

    func refreshLocal() {
        do { localEntries = try LocalFileSystem.list(localPath) } catch { self.error(error.localizedDescription) }
    }

    func navigateLocal(to path: String, sync: Bool = true) {
        let normalized = (path as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue else {
            error("Directory \(normalized) does not exist")
            return
        }
        if sync, synchronizedBrowsing, connection == .connected, let base = syncBase, normalized.hasPrefix(base.local) {
            let remote = base.remote + normalized.dropFirst(base.local.count)
            Task { await navigateRemote(to: remote) }
        }
        localPath = normalized
        refreshLocal()
    }

    func navigateLocalUp() {
        navigateLocal(to: (localPath as NSString).deletingLastPathComponent)
    }

    func localMakeDirectory() {
        Task {
            guard let name = await prompts.requestText(title: "Create Directory", message: "Name of the new directory:", initial: "New directory"),
                  !name.isEmpty else { return }
            do {
                try FileManager.default.createDirectory(at: localURL(name), withIntermediateDirectories: false)
                refreshLocal()
            } catch { self.error(error.localizedDescription) }
        }
    }

    func localRename(_ entry: FileEntry) {
        Task {
            guard let name = await prompts.requestText(title: "Rename", message: "New name for \(entry.name):", initial: entry.name),
                  !name.isEmpty, name != entry.name else { return }
            do {
                try FileManager.default.moveItem(at: localURL(entry.name), to: localURL(name))
                refreshLocal()
            } catch { self.error(error.localizedDescription) }
        }
    }

    func localTrash(_ entries: [FileEntry]) {
        NSWorkspace.shared.recycle(entries.map { localURL($0.name) }) { _, error in
            Task { @MainActor in
                if let error { self.error(error.localizedDescription) }
                self.refreshLocal()
            }
        }
    }

    func localOpen(_ entries: [FileEntry]) {
        entries.forEach { NSWorkspace.shared.open(localURL($0.name)) }
    }

    func localReveal(_ entries: [FileEntry]) {
        let urls = entries.isEmpty ? [URL(fileURLWithPath: localPath)] : entries.map { localURL($0.name) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
