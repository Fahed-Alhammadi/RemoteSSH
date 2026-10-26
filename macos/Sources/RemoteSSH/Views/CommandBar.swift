import SwiftUI

/// One address field, password and Connect, then grouped actions. Mirrors the Electron command bar.
struct CommandBar: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var password = ""

    var body: some View {
        @Bindable var model = model
        let connected = model.connection == .connected
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                field(icon: "globe") {
                    TextField("", text: $address, prompt: Text("sftp://user@host:22/path"))
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Server address")
                }
                .frame(minWidth: 180, maxWidth: .infinity)
                field(icon: "key") {
                    SecureField("", text: $password, prompt: Text("Password"))
                        .accessibilityLabel("Password")
                }
                .frame(width: 150)
                Button(action: connect) {
                    Label("Connect", systemImage: "bolt.horizontal.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(address.isEmpty || model.connection == .connecting)
            }
            .onSubmit(connect)

            group {
                IconButton("arrow.clockwise", "Refresh both panes") { model.refreshLocal(); model.refreshRemote() }
                IconButton("arrow.triangle.2.circlepath", "Reconnect (⌘R)") { model.reconnect() }
                    .disabled(model.currentSite == nil || model.connection == .connecting)
                IconButton("eject", "Disconnect (⌘D)") { Task { await model.disconnect() } }
                    .disabled(!connected)
            }
            group {
                IconButton(model.transfers.processing ? "pause.circle" : "play.circle",
                           model.transfers.processing ? "Pause the transfer queue" : "Resume the transfer queue",
                           active: !model.transfers.processing) { model.transfers.toggleProcessing() }
                IconButton("stop.circle", "Stop all transfers") { model.transfers.stopAll() }
                    .disabled(model.transfers.activeCount == 0)
            }
            group {
                IconButton("rectangle.split.2x1", "Directory comparison", active: model.compareDirectories) {
                    model.compareDirectories.toggle()
                }
                IconButton("link", "Synchronized browsing", active: model.synchronizedBrowsing) {
                    model.toggleSynchronizedBrowsing()
                }
                .disabled(!connected)
                IconButton(model.settings.showHiddenFiles ? "eye" : "eye.slash", "Show hidden files", active: model.settings.showHiddenFiles) {
                    model.settings.showHiddenFiles.toggle()
                }
                IconButton("terminal", "Terminal (⌃`)", active: model.showTerminal) { model.toggleTerminal() }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 49)
        .background(.bar)
    }

    private func connect() {
        guard !address.isEmpty else { return }
        model.quickConnect(host: address, user: "", password: password, port: "")
    }

    private func field<Content: View>(icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
            content().textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) {
            Divider().frame(height: 22).padding(.trailing, 8)
            content()
        }
    }
}

/// Toolbar-style icon button; `active` marks a toggle that is on (tint + background, plus the label for VoiceOver).
struct IconButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void

    init(_ symbol: String, _ label: String, active: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .foregroundStyle(active ? Theme.accent : .secondary)
                .background(active ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "On" : "")
    }
}
