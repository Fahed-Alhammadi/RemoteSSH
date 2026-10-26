import SwiftTerm
import SwiftUI

/// The terminal's ink inset inside the queue area. The SwiftTerm view belongs to the controller, so
/// switching tabs keeps the session and its scrollback.
struct TerminalPanel: View {
    let terminal: TerminalController

    var body: some View {
        TerminalHost(terminal: terminal)
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 2))
            .background(SwiftUI.Color(nsColor: Theme.Terminal.background), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06)))
            .padding([.horizontal, .bottom], 8)
    }
}

private struct TerminalHost: NSViewRepresentable {
    let terminal: TerminalController

    func makeNSView(context: Context) -> TerminalView {
        DispatchQueue.main.async { terminal.focus() }
        return terminal.view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}
}

/// The Terminal tab before a shell is open: says what is needed, or offers to open one.
struct TerminalPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal").font(.title2).foregroundStyle(SwiftUI.Color(nsColor: Theme.Terminal.cursor))
            Text(message).foregroundStyle(SwiftUI.Color(nsColor: Theme.Terminal.foreground)).multilineTextAlignment(.center)
            if model.canOpenTerminal {
                Button("Open Terminal", systemImage: "terminal") { model.showTerminalTab(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SwiftUI.Color(nsColor: Theme.Terminal.background), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .bottom], 8)
    }

    private var message: String {
        if model.canOpenTerminal { return "Open a shell on the server, in the folder you are viewing." }
        if model.connection == .connected { return "The terminal needs an SFTP (SSH) site. FTP servers do not offer a shell." }
        return "Connect to an SFTP site to open a terminal on the server."
    }
}

/// Status, "user@host" and the Restart / Close buttons, on the right of the tab picker.
struct TerminalHeader: View {
    @Environment(AppModel.self) private var model
    let terminal: TerminalController

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color, pulsing: terminal.status == .connecting)
                .id(terminal.status)
            Text(text).foregroundStyle(.secondary)
            Text(terminal.label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            Button { model.restartTerminal() } label: { Image(systemName: "arrow.clockwise") }
                .help("Restart the terminal")
                .disabled(!model.canOpenTerminal)
            Button { model.closeTerminal() } label: { Image(systemName: "xmark") }
                .help("Close the terminal")
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    private var color: SwiftUI.Color {
        switch terminal.status {
        case .connecting: Theme.warning
        case .connected: Theme.success
        case .ended: .secondary
        }
    }

    private var text: String {
        switch terminal.status {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .ended: "Ended"
        }
    }
}
