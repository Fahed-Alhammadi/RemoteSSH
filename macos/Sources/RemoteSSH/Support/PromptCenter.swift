import RemoteSSHCore
import Foundation
import Observation

/// Modal questions raised by the engine or the queue, answered by sheets in the UI.
enum PromptKind: Identifiable {
    case hostKey(host: String, port: Int, keyType: String, fingerprint: String, changed: Bool)
    case certificate(host: String, port: Int, reason: String)
    case password(prompt: String)
    case overwrite(file: String, source: FileInfo, target: FileInfo, direction: TransferDirection)
    case text(title: String, message: String, initial: String)

    struct FileInfo {
        var path: String
        var size: Int64?
        var modified: Date?
    }

    var id: String {
        switch self {
        case .hostKey(let h, let p, _, _, _): return "hostkey-\(h):\(p)"
        case .certificate(let h, let p, _): return "cert-\(h):\(p)"
        case .password(let p): return "pw-\(p)"
        case .overwrite(let f, _, _, _): return "ow-\(f)"
        case .text(let t, _, _): return "text-\(t)"
        }
    }
}

enum PromptAnswer {
    case bool(Bool)
    case text(String?)
    case overwrite(OverwriteAction, applyToAll: Bool)
}

@MainActor
@Observable
final class PromptCenter: SessionPrompter {
    private(set) var current: PromptKind?
    @ObservationIgnored private var continuation: CheckedContinuation<PromptAnswer, Never>?
    @ObservationIgnored private var waiting: [(PromptKind, CheckedContinuation<PromptAnswer, Never>)] = []

    func ask(_ kind: PromptKind) async -> PromptAnswer {
        await withCheckedContinuation { cont in
            if current == nil {
                current = kind
                continuation = cont
            } else {
                waiting.append((kind, cont))
            }
        }
    }

    func answer(_ answer: PromptAnswer) {
        let cont = continuation
        continuation = nil
        current = nil
        cont?.resume(returning: answer)
        if !waiting.isEmpty {
            let (kind, next) = waiting.removeFirst()
            current = kind
            continuation = next
        }
    }

    // MARK: SessionPrompter (called from engine threads)

    nonisolated func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, changed: Bool) async -> Bool {
        if case .bool(let ok) = await ask(.hostKey(host: host, port: port, keyType: keyType, fingerprint: fingerprint, changed: changed)) { return ok }
        return false
    }

    nonisolated func confirmCertificate(host: String, port: Int, reason: String) async -> Bool {
        if case .bool(let ok) = await ask(.certificate(host: host, port: port, reason: reason)) { return ok }
        return false
    }

    nonisolated func requestPassword(prompt: String) async -> String? {
        if case .text(let t) = await ask(.password(prompt: prompt)) { return t }
        return nil
    }

    func requestText(title: String, message: String, initial: String = "") async -> String? {
        if case .text(let t) = await ask(.text(title: title, message: message, initial: initial)) { return t }
        return nil
    }
}
