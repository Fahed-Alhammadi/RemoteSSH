import AppKit
import Foundation
import RemoteSSHCore

/// Watches files opened via View/Edit and offers to upload them when they are saved.
@MainActor
final class EditWatcher {
    private struct Watched {
        let local: URL
        let remote: String
        let siteID: UUID
        var modified: Date?
    }

    private unowned let model: AppModel
    private var files: [Watched] = []
    private var timer: Timer?

    init(model: AppModel) {
        self.model = model
    }

    func watch(local: URL, remote: String, siteID: UUID) {
        files.append(Watched(local: local, remote: remote, siteID: siteID, modified: LocalFileSystem.modified(local.path)))
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        // Forget files whose temp copy is gone; stop polling when nothing is left.
        files.removeAll { !FileManager.default.fileExists(atPath: $0.local.path) }
        if files.isEmpty {
            timer?.invalidate()
            timer = nil
            return
        }
        for i in files.indices {
            guard let now = LocalFileSystem.modified(files[i].local.path), now != files[i].modified else { continue }
            files[i].modified = now
            let f = files[i]
            let alert = NSAlert()
            alert.messageText = "\(f.local.lastPathComponent) has changed"
            alert.informativeText = "Upload it back to \(f.remote)?"
            alert.addButton(withTitle: "Upload")
            alert.addButton(withTitle: "Don't Upload")
            if alert.runModal() == .alertFirstButtonReturn, let site = model.site(for: f.siteID) {
                model.transfers.enqueueSingleUpload(local: f.local.path, remote: f.remote, site: site, overwrite: true)
            }
        }
    }
}
