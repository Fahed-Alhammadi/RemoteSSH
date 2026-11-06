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

/// Whether `text` contains a C0 or C1 control character or DEL (U+0000–U+001F, U+007F–U+009F).
/// Typed into a terminal these act as keys, not text: Ctrl-U erases the line, Ctrl-C interrupts, ESC starts
/// a sequence. Quoting doesn't help, so a folder name containing one could run a different command.
public func containsControlCharacters(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
}

/// The ` cd -- '<dir>'` line typed into a shell (the leading space keeps it out of history with
/// HISTCONTROL=ignorespace), or nil when `dir` contains control characters and must not be typed.
public func changeDirectoryCommand(_ dir: String) -> String? {
    containsControlCharacters(dir) ? nil : " cd -- \(shellQuote(dir))"
}

/// Logged when a folder can't be typed into the terminal.
public let unsafeTerminalFolderMessage = "The folder name contains control characters; not changing directory."
