import Foundation
import RemoteSSHCore

/// The terminal: an SSH shell on its own connection to the current SFTP site.
extension AppModel {
    var canOpenTerminal: Bool {
        connection == .connected && currentSite?.serverProtocol == .sftp
    }

    /// Shows the terminal in `dir`. With `reuse`, a running shell on the same site just changes folder.
    func openTerminal(in dir: String?, reuse: Bool) {
        guard canOpenTerminal, let site = currentSite else {
            error("The terminal needs a connection to an SFTP site.")
            return
        }
        if reuse, let dir, let terminal, terminal.siteID == site.id, terminal.status == .connected {
            terminal.changeDirectory(to: dir)
        } else {
            terminal?.close()
            let password = password(for: site) ?? ""
            // Only errors from the terminal's connection go to the message log.
            let sink = makeLogSink()
            terminal = TerminalController(site: site, startDirectory: dir) {
                makeSession(for: site, password: password, log: { line in if line.kind == .error { sink(line) } })
            }
            status("Terminal opened: \(site.effectiveUser)@\(site.host)")
        }
        showDock(.terminal)
    }

    /// Shows the Terminal tab, starting a shell when none is open and the site allows one.
    func showTerminalTab(_ show: Bool) {
        if show, terminal == nil, canOpenTerminal {
            openTerminal(in: remotePath.isEmpty ? nil : remotePath, reuse: false)
        } else if show {
            showDock(.terminal)
        } else if dockPanel == .terminal {
            dockOpen = false
        }
    }

    func toggleTerminal() {
        showTerminalTab(!showTerminal)
    }

    func restartTerminal() {
        openTerminal(in: terminal?.startDirectory, reuse: false)
    }

    func closeTerminal() {
        terminal?.close()
        terminal = nil
        terminalMaximized = false
        if dockPanel == .terminal { dockPanel = .activity }
    }
}
