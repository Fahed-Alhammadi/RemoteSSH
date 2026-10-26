import RemoteSSHCore
import SwiftUI

/// The bottom panel: Activity (message log), Transfers and Terminal tabs. Mirrors the Electron dock.
struct DockView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = 0

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if model.dockOpen {
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.bar)
    }

    private var tabBar: some View {
        let t = model.transfers
        let errors = model.log.lazy.filter { $0.kind == .error }.count
        return HStack(spacing: 2) {
            tab(.activity, "Activity", "text.alignleft") {
                if errors > 0 { Badge(count: errors, color: Theme.danger) }
            }
            tab(.transfers, "Transfers", "arrow.up.arrow.down") {
                if !t.queued.isEmpty { Badge(count: t.queued.count, color: Theme.accent) }
            }
            tab(.terminal, "Terminal", "terminal") {
                if let terminal = model.terminal {
                    StatusDot(color: terminal.status == .connected ? Theme.success : terminal.status == .connecting ? Theme.warning : .secondary,
                              pulsing: terminal.status == .connecting)
                        .scaleEffect(0.8)
                }
            }
            Spacer(minLength: 8)
            if model.dockOpen && model.dockPanel == .transfers {
                Picker("Show transfers", selection: $filter) {
                    Text("Queued \(t.queued.count)").tag(0)
                    Text("Failed \(t.failed.count)").tag(1)
                    Text("Done \(t.finished.count)").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            if model.showTerminal, let terminal = model.terminal {
                TerminalHeader(terminal: terminal)
                IconButton(model.terminalMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           model.terminalMaximized ? "Restore" : "Maximize") { model.terminalMaximized.toggle() }
            }
            IconButton(model.dockOpen ? "chevron.down" : "chevron.up", model.dockOpen ? "Hide panel" : "Show panel") {
                model.dockOpen.toggle()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    @ViewBuilder
    private var content: some View {
        switch model.dockPanel {
        case .activity: LogView()
        case .transfers: TransfersList(tab: filter)
        case .terminal:
            if let terminal = model.terminal { TerminalPanel(terminal: terminal).padding(.top, 8) } else { TerminalPlaceholder().padding(.top, 8) }
        }
    }

    private func tab<Extra: View>(_ panel: DockPanel, _ title: String, _ symbol: String, @ViewBuilder extra: () -> Extra) -> some View {
        let active = model.dockOpen && model.dockPanel == panel
        return Button {
            if active { model.dockOpen = false }
            else if panel == .terminal { model.showTerminalTab(true) }
            else { model.showDock(panel) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(active ? Theme.accent : .secondary)
                Text(title).foregroundStyle(active ? .primary : .secondary)
                extra()
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle().fill(active ? Theme.accent : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct Badge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}
