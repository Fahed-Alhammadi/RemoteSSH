import RemoteSSHCore
import SwiftUI

struct PromptSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: PromptKind
    @State private var text = ""
    @State private var remember = true
    @State private var overwriteChoice: OverwriteAction = .overwrite
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if case .text(_, _, let initial) = prompt { text = initial }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch prompt {
        case let .hostKey(host, port, keyType, fingerprint, changed):
            Label(changed ? "WARNING: Host key mismatch!" : "Unknown host key",
                  systemImage: changed ? "exclamationmark.octagon.fill" : "questionmark.circle.fill")
                .font(.headline)
                .foregroundStyle(changed ? .red : .primary)
            Text(changed
                 ? "The server's host key does not match the key that was cached. Someone could be trying to intercept the connection, or the server administrator changed the key."
                 : "The server's host key is unknown. You have no guarantee that the server is the computer you think it is.")
            Grid(alignment: .leading) {
                GridRow { Text("Host:").foregroundStyle(.secondary); Text("\(host):\(port)") }
                GridRow { Text("Hostkey algorithm:").foregroundStyle(.secondary); Text(keyType) }
                GridRow { Text("Fingerprint:").foregroundStyle(.secondary); Text(fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            }
            Text("Trust this host and carry on connecting? The key will be remembered.").foregroundStyle(.secondary)
            buttons(ok: "Trust", cancel: "Cancel") { model.prompts.answer(.bool($0)) }

        case let .certificate(host, port, reason):
            Label("Unknown certificate", systemImage: "lock.trianglebadge.exclamationmark").font(.headline)
            Text("The server's TLS certificate for \(host):\(port) could not be verified:")
            Text(reason).font(.system(.body, design: .monospaced)).foregroundStyle(.orange)
            Text("Connect anyway? The certificate will be trusted for this site from now on.").foregroundStyle(.secondary)
            buttons(ok: "Connect Anyway", cancel: "Cancel") { model.prompts.answer(.bool($0)) }

        case let .password(p):
            Label("Enter password", systemImage: "key.fill").font(.headline)
            Text(p)
            SecureField("Password", text: $text).textFieldStyle(.roundedBorder)
                .onSubmit { model.prompts.answer(.text(text)) }
            buttons(ok: "OK", cancel: "Cancel") { model.prompts.answer(.text($0 ? text : nil)) }

        case let .text(title, message, _):
            Text(title).font(.headline)
            Text(message)
            TextField("", text: $text).textFieldStyle(.roundedBorder)
                .onSubmit { model.prompts.answer(.text(text)) }
            buttons(ok: "OK", cancel: "Cancel") { model.prompts.answer(.text($0 ? text : nil)) }

        case let .overwrite(file, source, target, direction):
            Label("Target file already exists", systemImage: "doc.on.doc.fill").font(.headline)
            Text("The target file \"\(file)\" already exists. Please choose an action.")
            Grid(alignment: .leading, horizontalSpacing: 12) {
                GridRow { Text("Source file:").foregroundStyle(.secondary); fileInfo(source) }
                GridRow { Text("Target file:").foregroundStyle(.secondary); fileInfo(target) }
            }
            Picker("Action:", selection: $overwriteChoice) {
                ForEach(OverwriteAction.allCases.filter { $0 != .ask }) { a in Text(a.displayName).tag(a) }
            }
            .pickerStyle(.radioGroup)
            Toggle("Always use this action for \(direction == .download ? "downloads" : "uploads") in this session", isOn: $applyToAll)
            HStack {
                Spacer()
                Button("Cancel") { model.prompts.answer(.overwrite(.skip, applyToAll: false)) }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { model.prompts.answer(.overwrite(overwriteChoice, applyToAll: applyToAll)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func fileInfo(_ f: PromptKind.FileInfo) -> some View {
        VStack(alignment: .leading) {
            Text(f.path).lineLimit(1).truncationMode(.middle)
            Text([Format.bytes(f.size), Format.date(f.modified)].filter { !$0.isEmpty }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func buttons(ok: String, cancel: String, _ action: @escaping (Bool) -> Void) -> some View {
        HStack {
            Spacer()
            Button(cancel) { action(false) }.keyboardShortcut(.cancelAction)
            Button(ok) { action(true) }.keyboardShortcut(.defaultAction)
        }
    }
}

/// "Change file attributes" dialog.
struct ChmodSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [FileEntry]
    let apply: (Int) -> Void
    @State private var mode = 0o644

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change file attributes").font(.headline)
            Text(entries.count == 1 ? "Please select the new attributes for \"\(entries[0].name)\"." : "Please select the new attributes for the \(entries.count) selected items.")
            Grid(alignment: .leading, horizontalSpacing: 18) {
                GridRow {
                    Text("")
                    Text("Read").bold(); Text("Write").bold(); Text("Execute").bold()
                }
                row("Owner permissions", shift: 6)
                row("Group permissions", shift: 3)
                row("Public permissions", shift: 0)
            }
            HStack {
                Text("Numeric value:")
                TextField("", text: Binding(
                    get: { Permissions.octalString(mode) },
                    set: { if let v = Int($0, radix: 8), v <= 0o777 { mode = v } }
                ))
                .frame(width: 60)
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { apply(mode); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { mode = entries.first?.permissionBits ?? 0o644 }
    }

    private func row(_ title: String, shift: Int) -> some View {
        GridRow {
            Text(title)
            ForEach([4, 2, 1], id: \.self) { bit in
                Toggle("", isOn: Binding(
                    get: { mode & (bit << shift) != 0 },
                    set: { on in mode = on ? mode | (bit << shift) : mode & ~(bit << shift) }
                ))
                .labelsHidden()
            }
        }
    }
}
