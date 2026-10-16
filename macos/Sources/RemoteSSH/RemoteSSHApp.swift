import AppKit
import RemoteSSHCore
import SwiftUI

@main
struct RemoteSSHApp: App {
    @State private var model = AppModel()

    init() {
        // Needed when launched as a bare SwiftPM executable (outside the .app bundle).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("RemoteSSH") {
            MainView()
                .environment(model)
                .tint(Theme.accent)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    Updater.shared.checkAtLaunch()
                }
        }
        .commands { commands }

        Settings {
            SettingsView().environment(model).tint(Theme.accent)
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", systemImage: "arrow.down.circle") { Task { await Updater.shared.check(manual: true) } }
        }
        CommandGroup(after: .newItem) {
            Button("Site Manager…", systemImage: "square.stack.3d.up") { model.showSiteManager = true }
                .keyboardShortcut("s", modifiers: .command)
            Divider()
            Button("Import from RemoteSSH…", systemImage: "square.and.arrow.down") { model.importSites() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Export Sites…", systemImage: "square.and.arrow.up") { model.exportSites() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.sites.isEmpty)
        }
        CommandMenu("Server") {
            Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") { model.reconnect() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.currentSite == nil)
            Button("Disconnect", systemImage: "eject") { Task { await model.disconnect() } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.connection != .connected)
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshRemote(); model.refreshLocal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Custom Command…", systemImage: "terminal") { model.customCommand() }
                .disabled(model.connection != .connected || model.currentSite?.serverProtocol != .ftp)
        }
        CommandMenu("Transfer") {
            Button(model.transfers.processing ? "Pause Queue" : "Resume Queue",
                   systemImage: model.transfers.processing ? "pause.circle" : "play.circle") { model.transfers.toggleProcessing() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Stop All Transfers", systemImage: "stop.circle") { model.transfers.stopAll() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Clear Completed", systemImage: "checkmark.circle") { model.transfers.clearFinished() }
        }
        CommandGroup(after: .toolbar) {
            Toggle("Message Log", isOn: Binding(get: { model.showLog }, set: { model.showLog = $0 }))
                .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("Transfer Queue", isOn: Binding(get: { model.showQueue }, set: { model.showQueue = $0 }))
                .keyboardShortcut("q", modifiers: [.command, .option])
            Toggle("Directory Comparison", isOn: Binding(get: { model.compareDirectories }, set: { model.compareDirectories = $0 }))
            Toggle("Synchronized Browsing", isOn: Binding(get: { model.synchronizedBrowsing }, set: { _ in model.toggleSynchronizedBrowsing() }))
                .keyboardShortcut("y", modifiers: .command)
            Divider()
        }
    }
}
