import RemoteSSHCore
import SwiftUI

/// Saved sites, one click to connect, with the connected site marked. Mirrors the Electron sidebar.
struct SitesSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if model.sites.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Save the servers you use often and connect with one click.")
                                .foregroundStyle(.secondary)
                            Button("Add a Site", systemImage: "plus") { model.showSiteManager = true }
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(sites(in: "")) { row($0) }
                } header: {
                    HStack {
                        Text("Sites")
                        Spacer()
                        Button { model.showSiteManager = true } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless)
                            .help("Open the Site Manager (⌘S)")
                            .accessibilityLabel("Manage sites")
                    }
                }
                ForEach(folders, id: \.self) { folder in
                    Section(folder) {
                        ForEach(sites(in: folder)) { row($0) }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
    }

    private var folders: [String] {
        Set(model.sites.map(\.folder)).subtracting([""]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func sites(in folder: String) -> [Site] {
        model.sites.filter { $0.folder == folder }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func row(_ site: Site) -> some View {
        let active = site.id == model.currentSite?.id && model.connection != .disconnected
        return Button { model.connect(to: site) } label: {
            HStack(spacing: 10) {
                Image(systemName: site.serverProtocol == .sftp ? "lock" : "server.rack")
                    .foregroundStyle(site.serverProtocol == .sftp ? Theme.success : site.encryption == .plain ? Theme.warning : Theme.upload)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.name)
                        .fontWeight(active ? .semibold : .regular)
                        .foregroundStyle(active ? Theme.accent : .primary)
                        .lineLimit(1)
                    Text((site.user.isEmpty ? "" : "\(site.user)@") + site.host)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if active {
                    StatusDot(color: model.connection == .connected ? Theme.success : Theme.warning,
                              pulsing: model.connection == .connecting)
                        .accessibilityLabel(model.connection == .connected ? "Connected" : "Connecting")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(site.host.isEmpty)
        .help(site.host.isEmpty ? "This site has no host name" : "Connect to \(site.name)")
        .listRowBackground(active ? RoundedRectangle(cornerRadius: 6).fill(Theme.accentSoft).padding(.horizontal, 6) : nil)
    }
}
