import Citadel
import Foundation
import NIOCore

/// An interactive shell on a PTY, run by `SFTPSession.runShell`. Writes and resizes are
/// queued and sent in order by the session; `close()` ends the shell.
public final class RemoteShell: Sendable {
    typealias Operation = @Sendable (TTYStdinWriter) async throws -> Void

    let operations: AsyncStream<Operation>
    private let continuation: AsyncStream<Operation>.Continuation

    public init() {
        (operations, continuation) = AsyncStream.makeStream()
    }

    public func write(_ data: Data) {
        continuation.yield { try await $0.write(ByteBuffer(bytes: data)) }
    }

    public func write(_ text: String) {
        write(Data(text.utf8))
    }

    public func resize(cols: Int, rows: Int) {
        continuation.yield { try await $0.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    public func close() {
        continuation.finish()
    }
}

/// Quotes a string as one POSIX shell word.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
