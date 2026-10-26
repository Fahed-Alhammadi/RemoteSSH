import RemoteSSHCore
import SwiftUI

/// "Workbench" layout, the same as the Electron app: sites sidebar | command bar, panes, bottom panel.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SitesSidebar()
        } detail: {
            VStack(spacing: 0) {
                CommandBar()
                Divider()
                if model.dockOpen && model.showTerminal && model.terminalMaximized {
                    DockView()
                } else if model.dockOpen {
                    VSplitView {
                        panes.frame(minHeight: 220, idealHeight: 440)
                        DockView().frame(minHeight: 120, idealHeight: 220)
                    }
                } else {
                    panes
                    Divider()
                    DockView()
                }
                Divider()
                StatusBar()
            }
            .toolbar(removing: .title)
        }
        .navigationTitle("RemoteSSH")
        .sheet(isPresented: $model.showSiteManager) {
            SiteManagerView().environment(model)
        }
        .sheet(item: Binding(get: { model.prompts.current }, set: { _ in })) { prompt in
            PromptSheet(prompt: prompt)
                .environment(model)
                .interactiveDismissDisabled()
        }
    }

    private var panes: some View {
        HSplitView {
            LocalPane().frame(minWidth: 300)
            RemotePane().frame(minWidth: 300)
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let site = model.currentSite, model.connection == .connected {
                let secure = site.serverProtocol == .sftp || site.encryption != .plain
                StatusDot(color: secure ? Theme.success : Theme.warning)
                Image(systemName: secure ? "lock.shield.fill" : "exclamationmark.shield")
                    .foregroundStyle(secure ? Theme.success : Theme.warning)
                    .help(secure ? "The connection is encrypted" : "The connection is not encrypted")
                Text(site.displayAddress).foregroundStyle(.secondary)
            } else {
                StatusDot(color: model.connection == .connecting ? Theme.warning : .secondary,
                          pulsing: model.connection == .connecting)
                    .id(model.connection == .connecting)
                Text(model.connection == .connecting ? "Connecting…" : "Not connected").foregroundStyle(.secondary)
            }
            Spacer()
            let q = model.transfers.queued
            Image(systemName: "tray.full").foregroundStyle(.secondary)
            Text("\(q.count) queued · \(Format.bytes(model.transfers.queuedBytes))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

enum Format {
    static func bytes(_ n: Int64?) -> String {
        guard let n else { return "" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func date(_ d: Date?) -> String { d.map(dateFormatter.string(from:)) ?? "" }
}
