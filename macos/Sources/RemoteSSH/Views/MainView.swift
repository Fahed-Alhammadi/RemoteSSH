import RemoteSSHCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            QuickConnectBar()
            Divider()
            VSplitView {
                if model.showLog {
                    LogView().frame(minHeight: 60, idealHeight: 130)
                }
                HSplitView {
                    LocalPane().frame(minWidth: 300)
                    RemotePane().frame(minWidth: 300)
                }
                .frame(minHeight: 240, idealHeight: 420)
                if model.showQueue {
                    QueueView().frame(minHeight: 90, idealHeight: 170)
                }
            }
            Divider()
            StatusBar()
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.showSiteManager) {
            SiteManagerView().environment(model)
        }
        .sheet(item: Binding(get: { model.prompts.current }, set: { _ in })) { prompt in
            PromptSheet(prompt: prompt)
                .environment(model)
                .interactiveDismissDisabled()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let connected = model.connection == .connected
        ToolbarItemGroup(placement: .navigation) {
            Button { model.showSiteManager = true } label: { Label("Site Manager", systemImage: "square.stack.3d.up") }
                .help("Open the Site Manager (⌘S)")
        }
        ToolbarItemGroup {
            Button { model.refreshLocal(); model.refreshRemote() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh both panes")
            Button { model.reconnect() } label: { Label("Reconnect", systemImage: "arrow.triangle.2.circlepath") }
                .help("Reconnect to the last server")
                .disabled(model.currentSite == nil || model.connection == .connecting)
            Button { Task { await model.disconnect() } } label: { Label("Disconnect", systemImage: "eject") }
                .help("Disconnect from the server")
                .disabled(!connected)
        }
        ToolbarItemGroup {
            Button { model.transfers.toggleProcessing() } label: {
                Label(model.transfers.processing ? "Pause Queue" : "Resume Queue",
                      systemImage: model.transfers.processing ? "pause.circle" : "play.circle")
            }
            .help(model.transfers.processing ? "Pause the transfer queue" : "Resume the transfer queue")
            Button { model.transfers.stopAll() } label: { Label("Stop", systemImage: "stop.circle") }
                .help("Cancel running transfers")
                .disabled(model.transfers.activeCount == 0)
        }
        ToolbarItemGroup {
            Toggle(isOn: Binding(get: { model.compareDirectories }, set: { model.compareDirectories = $0 })) {
                Label("Compare", systemImage: "arrow.left.arrow.right.square")
            }
            .help("Highlight differences between the local and remote folders")
            Toggle(isOn: Binding(get: { model.synchronizedBrowsing }, set: { _ in model.toggleSynchronizedBrowsing() })) {
                Label("Sync Browsing", systemImage: "link.circle")
            }
            .help("Navigate both panes together")
            Toggle(isOn: Binding(get: { model.showTerminal }, set: { model.showTerminalTab($0) })) {
                Label("Terminal", systemImage: "terminal")
            }
            .help("Show the SSH terminal (⌃`)")
        }
    }
}

struct QuickConnectBar: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var user = ""
    @State private var password = ""
    @State private var port = ""

    var body: some View {
        HStack(spacing: 10) {
            field("network", "Host (sftp://example.com)") { TextField("", text: $host, prompt: Text("Host — sftp://example.com")).frame(minWidth: 180) }
            field("person", "Username") { TextField("", text: $user, prompt: Text("Username")).frame(width: 130) }
            field("key", "Password") { SecureField("", text: $password, prompt: Text("Password")).frame(width: 130) }
            field("number", "Port") { TextField("", text: $port, prompt: Text("Port")).frame(width: 60) }
            Button(action: connect) {
                Label("Connect", systemImage: "bolt.horizontal.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(host.isEmpty || model.connection == .connecting)
            if model.connection == .connecting { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onSubmit(connect)
    }

    private func connect() {
        model.quickConnect(host: host, user: user, password: password, port: port)
    }

    private func field<Content: View>(_ icon: String, _ help: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
            content()
        }
        .help(help)
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
