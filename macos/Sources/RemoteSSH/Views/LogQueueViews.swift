import RemoteSSHCore
import SwiftUI

struct LogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.log) { line in
                        LogRow(line: line).id(line.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.log.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .contextMenu {
                Button("Copy All", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.map { "[\($0.kind.rawValue)] \($0.text)" }.joined(separator: "\n"), forType: .string)
                }
                Button("Clear", systemImage: "trash") { model.clearLog() }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 14)
            Text(line.text)
                .foregroundStyle(line.kind == .error ? Theme.danger : .primary)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var symbol: String {
        switch line.kind {
        case .status, .trace: return "info.circle"
        case .command: return "arrow.right.circle"
        case .response: return "arrow.left.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch line.kind {
        case .status, .trace: return .secondary
        case .command: return Theme.upload
        case .response: return Theme.success
        case .error: return Theme.danger
        }
    }
}

struct QueueView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var selection: Set<TransferItem.ID> = []

    var body: some View {
        let t = model.transfers
        let showingTerminal = model.showTerminal
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { showingTerminal ? Self.terminalTab : tab }, set: select)) {
                    Label("Queued (\(t.queued.count))", systemImage: "tray.full").tag(0)
                    Label("Failed (\(t.failed.count))", systemImage: "exclamationmark.triangle").tag(1)
                    Label("Done (\(t.finished.count))", systemImage: "checkmark.circle").tag(2)
                    Label("Terminal", systemImage: "terminal").tag(Self.terminalTab)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                if showingTerminal, let terminal = model.terminal { TerminalHeader(terminal: terminal) }
            }
            .padding(6)

            if showingTerminal {
                if let terminal = model.terminal { TerminalPanel(terminal: terminal) } else { TerminalPlaceholder() }
            } else {
                transferTable
            }
        }
    }

    private static let terminalTab = 3

    private func select(_ value: Int) {
        if value == Self.terminalTab {
            model.showTerminalTab(true)
        } else {
            tab = value
            model.showTerminal = false
        }
    }

    private var transferTable: some View {
        let t = model.transfers
        return Table(rows, selection: $selection) {
            TableColumn("") { item in
                Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(item.direction == .upload ? Theme.upload : Theme.download)
                    .help(item.direction == .upload ? "Upload" : "Download")
            }
            .width(22)
            TableColumn("Local File") { item in
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.fileName).lineLimit(1)
                    Text(item.localPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 150, ideal: 260)
            TableColumn("Remote File") { item in
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.site(for: item.siteID)?.host ?? "").font(.caption2).foregroundStyle(.secondary)
                    Text(item.remotePath).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 150, ideal: 260)
            TableColumn("Size") { item in Text(Format.bytes(item.size)).monospacedDigit() }
                .width(70)
            TableColumn("Status") { item in status(item) }
                .width(min: 120, ideal: 200)
        }
        .contextMenu(forSelectionType: TransferItem.ID.self) { ids in
            if tab == 1 { Button("Retry", systemImage: "arrow.clockwise") { t.retry(ids) } }
            if tab == 0 { Button("Cancel", systemImage: "xmark.circle") { t.cancel(ids) } }
            Button("Remove", systemImage: "minus.circle") { t.remove(ids) }
            Divider()
            Button("Clear Completed", systemImage: "checkmark.circle") { t.clearFinished() }
            Button(t.processing ? "Pause Queue" : "Resume Queue", systemImage: t.processing ? "pause.circle" : "play.circle") { t.toggleProcessing() }
        }
    }

    private var rows: [TransferItem] {
        switch tab {
        case 1: return model.transfers.failed
        case 2: return model.transfers.finished
        default: return model.transfers.queued
        }
    }

    @ViewBuilder
    private func status(_ item: TransferItem) -> some View {
        switch item.status {
        case .transferring:
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: Double(item.transferred), total: Double(max(item.size ?? 1, 1)))
                let speed = model.transfers.speeds[item.id].map { " · " + Format.bytes(Int64($0)) + "/s" } ?? ""
                Text(Format.bytes(item.transferred) + speed).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        case .queued:
            Label("Waiting", systemImage: "clock").foregroundStyle(.secondary)
        case .finished:
            Label(item.error ?? "Done", systemImage: item.error == nil ? "checkmark.circle.fill" : "arrow.uturn.right.circle")
                .foregroundStyle(item.error == nil ? .green : .secondary)
        case .failed:
            Label(item.error ?? "Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
        }
    }
}
