import AppKit
import Observation
import RemoteSSHCore
import SwiftTerm

enum TerminalStatus {
    case connecting
    case connected
    case ended
}

/// The terminal panel's shell: its own SSH connection to the site (never the browse session),
/// shown in a SwiftTerm view that lives as long as the controller.
@MainActor
@Observable
final class TerminalController {
    let siteID: UUID
    /// "user@host", shown next to the tab.
    let label: String
    /// Folder the shell started in; Restart starts there again.
    let startDirectory: String?
    private(set) var status: TerminalStatus = .connecting

    @ObservationIgnored let view: TerminalView
    @ObservationIgnored private let shell = RemoteShell()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let onConnected: (RemoteSession) -> Void
    @ObservationIgnored private lazy var output = TerminalOutputBuffer { [weak self] data, skipped in
        guard let view = self?.view else { return }
        if skipped { view.feed(text: "\r\n\u{1b}[2m[Output skipped: it arrived faster than it could be shown]\u{1b}[0m\r\n") }
        view.feed(byteArray: ArraySlice(data))
    }

    /// `onConnected` runs after the shell's connection logged in (to share its key passphrase).
    init(site: Site, startDirectory: String?, makeSession: () -> RemoteSession, onConnected: @escaping (RemoteSession) -> Void) {
        self.onConnected = onConnected
        siteID = site.id
        label = "\(site.effectiveUser)@\(site.host)"
        self.startDirectory = startDirectory
        view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.nativeBackgroundColor = Theme.Terminal.background
        view.nativeForegroundColor = Theme.Terminal.foreground
        view.caretColor = Theme.Terminal.cursor
        view.selectedTextBackgroundColor = Theme.Terminal.selection
        view.installColors(Theme.Terminal.ansi.map { hex in
            SwiftTerm.Color(red8: UInt16(hex >> 16 & 0xff), green8: UInt16(hex >> 8 & 0xff), blue8: UInt16(hex & 0xff))
        })
        view.optionAsMetaKey = false // Option keeps typing special characters, as in Terminal.app.
        view.terminalDelegate = self
        let session = makeSession()
        Task { await run(session) }
    }

    /// Changes the running shell to `dir` (Open Terminal Here while connected). Returns false, typing
    /// nothing, when the folder name contains control characters.
    @discardableResult
    func changeDirectory(to dir: String) -> Bool {
        guard let command = changeDirectoryCommand(dir) else { return false }
        shell.write(command + "\r")
        focus()
        return true
    }

    func close() {
        closed = true
        shell.close()
    }

    func focus() {
        view.window?.makeFirstResponder(view)
    }

    private func run(_ remote: RemoteSession) async {
        defer { status = .ended }
        guard let session = remote as? SFTPSession else {
            show(error: "The terminal needs an SFTP (SSH) site.")
            return
        }
        do {
            try await session.connect()
            guard !closed else { return await session.disconnect() }
            onConnected(session)
            status = .connected
            let size = view.getTerminal()
            let output = self.output
            let ending = try await session.runShell(shell, cols: size.cols, rows: size.rows, startIn: startDirectory) { data in
                output.append(data)
            }
            output.append(Data("\r\n\u{1b}[2m[Session ended: \(ending)]\u{1b}[0m\r\n".utf8))
        } catch {
            show(error: error.localizedDescription)
        }
        await session.disconnect()
    }

    private func show(error: String) {
        output.append(Data("\u{1b}[31m\(error)\u{1b}[0m\r\n".utf8))
    }
}

/// Collects shell output from the SSH connection's thread and feeds it to the terminal view in one piece
/// about every 16 ms, instead of one main-queue hop per network chunk. When output arrives faster than the
/// view can take it, the buffer keeps the newest part instead of growing without limit.
final class TerminalOutputBuffer: @unchecked Sendable {
    private static let limit = 4 << 20  // bytes
    private let lock = NSLock()
    private var pending = Data()
    private var skipped = false
    private var scheduled = false
    private let deliver: @MainActor (Data, Bool) -> Void

    init(deliver: @escaping @MainActor (Data, Bool) -> Void) {
        self.deliver = deliver
    }

    func append(_ data: Data) {
        lock.lock()
        pending.append(data)
        if pending.count > Self.limit {
            pending = Data(pending.suffix(Self.limit / 2))
            skipped = true
        }
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    @MainActor private func flush() {
        lock.lock()
        let data = pending
        let wasSkipped = skipped
        pending = Data()
        skipped = false
        scheduled = false
        lock.unlock()
        deliver(data, wasSkipped)
    }
}

extension TerminalController: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        shell.write(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        shell.resize(cols: newCols, rows: newRows)
    }

    /// Links in the output (OSC 8 or detected URLs) come from the server: only web and mail links are opened,
    /// and only after the user confirms the real address.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let alert = NSAlert()
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            alert.messageText = "This link can't be opened from the terminal"
            alert.informativeText = "RemoteSSH only opens web (http, https) and mail links from the terminal.\n\n\(link)"
            alert.runModal()
            return
        }
        alert.messageText = "Open this link?"
        alert.informativeText = "The terminal output links to:\n\n\(url.absoluteString)\n\nOnly open it if you trust where it goes."
        alert.addButton(withTitle: "Open Link")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(url)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
