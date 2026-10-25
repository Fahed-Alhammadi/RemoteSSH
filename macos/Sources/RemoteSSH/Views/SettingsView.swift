import RemoteSSHCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Updater.autoCheckKey) private var checkForUpdates = true

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Stepper("Maximum simultaneous transfers: \(model.settings.maxConcurrentTransfers)", value: $model.settings.maxConcurrentTransfers, in: 1...10)
                Stepper("Retries on failure: \(model.settings.retryCount)", value: $model.settings.retryCount, in: 0...10)
                Picker("Default action for existing files (downloads):", selection: $model.settings.defaultOverwriteDownload) {
                    ForEach(OverwriteAction.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Default action for existing files (uploads):", selection: $model.settings.defaultOverwriteUpload) {
                    ForEach(OverwriteAction.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Download limit (KiB/s, 0 = unlimited):", value: $model.settings.downloadLimitKiB, format: .number)
                TextField("Upload limit (KiB/s, 0 = unlimited):", value: $model.settings.uploadLimitKiB, format: .number)
            }
            .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }

            Form {
                Stepper("Timeout: \(model.settings.connectTimeout) seconds", value: $model.settings.connectTimeout, in: 5...300, step: 5)
                Toggle("Send TCP keep-alive", isOn: $model.settings.keepAlive)
                Text("FTP speed limits are enforced by libcurl; SFTP transfers are not throttled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Connection", systemImage: "network") }

            Form {
                Toggle("Show hidden files", isOn: $model.settings.showHiddenFiles)
                Toggle("Highlight differences between panes", isOn: $model.settings.showDirectoryComparison)
            }
            .tabItem { Label("Interface", systemImage: "macwindow") }

            Form {
                Toggle("Check for updates at startup", isOn: $checkForUpdates)
                Button("Check Now") { Task { await Updater.shared.check(manual: true) } }
                Text("Updates are downloaded from the project's GitHub releases.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
}
