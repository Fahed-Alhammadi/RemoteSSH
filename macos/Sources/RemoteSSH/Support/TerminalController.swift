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

    init(site: Site, startDirectory: String?, makeSession: () -> RemoteSession) {
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

    /// Changes the running shell to `dir` (Open Terminal Here while connected).
    func changeDirectory(to dir: String) {
        shell.write(" cd -- \(shellQuote(dir))\r")
        focus()
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
            status = .connected
            let size = view.getTerminal()
            let view = self.view
            let ending = try await session.runShell(shell, cols: size.cols, rows: size.rows, startIn: startDirectory) { data in
                // Main-queue blocks run in order, so output is never reordered.
                DispatchQueue.main.async { MainActor.assumeIsolated { view.feed(byteArray: ArraySlice(data)) } }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.view.feed(text: "\r\n\u{1b}[2m[Session ended: \(ending)]\u{1b}[0m\r\n") }
            }
        } catch {
            show(error: error.localizedDescription)
        }
        await session.disconnect()
    }

    private func show(error: String) {
        view.feed(text: "\u{1b}[31m\(error)\u{1b}[0m\r\n")
    }
}

extension TerminalController: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        shell.write(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        shell.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
