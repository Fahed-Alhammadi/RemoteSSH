import RemoteSSHCore
import SwiftUI

/// SF Symbol + tint per file kind. Pure lookup (no NSWorkspace/Launch Services calls),
/// so it stays cheap for directories with thousands of entries.
struct FileIcon: View {
    let entry: FileEntry

    var body: some View {
        let style = Self.style(for: entry)
        Image(systemName: style.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(style.color)
            .frame(width: 18)
    }

    struct Style {
        let symbol: String
        let color: Color
    }

    static func style(for e: FileEntry) -> Style {
        if e.name == ".." { return Style(symbol: "arrow.turn.left.up", color: .secondary) }
        if e.isDirectory { return Style(symbol: e.isLink ? "folder.badge.gearshape" : "folder.fill", color: .accentColor) }
        if e.isLink { return Style(symbol: "link", color: .secondary) }
        return byExtension[(e.name as NSString).pathExtension.lowercased()] ?? Style(symbol: "doc", color: .secondary)
    }

    private static let byExtension: [String: Style] = {
        var map: [String: Style] = [:]
        func add(_ exts: [String], _ symbol: String, _ color: Color) {
            for e in exts { map[e] = Style(symbol: symbol, color: color) }
        }
        add(["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff", "svg", "ico"], "photo", .teal)
        add(["mp4", "mov", "mkv", "avi", "webm", "m4v"], "film", .purple)
        add(["mp3", "wav", "flac", "aac", "m4a", "ogg"], "waveform", .pink)
        add(["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"], "doc.zipper", .brown)
        add(["pdf"], "doc.richtext", .red)
        add(["txt", "md", "log", "rtf", "csv"], "doc.text", .secondary)
        add(["doc", "docx", "odt", "pages"], "doc.richtext", .blue)
        add(["xls", "xlsx", "ods", "numbers"], "tablecells", .green)
        add(["ppt", "pptx", "odp"], "rectangle.on.rectangle", .orange)
        add(["swift", "c", "h", "cpp", "m", "py", "js", "ts", "go", "rs", "java", "kt", "rb", "php", "css", "scss", "vue", "jsx", "tsx"],
            "chevron.left.forwardslash.chevron.right", .indigo)
        add(["html", "htm", "xml"], "globe", .indigo)
        add(["json", "yml", "yaml", "toml", "ini", "conf", "cfg", "env", "plist"], "gearshape", .gray)
        add(["sh", "bash", "zsh", "fish", "command"], "terminal", .green)
        add(["key", "pem", "crt", "cer", "pub", "p12"], "key", .yellow)
        add(["sql", "db", "sqlite", "sqlite3"], "cylinder", .cyan)
        add(["dmg", "iso", "img"], "externaldrive", .gray)
        add(["app", "exe", "bin", "pkg", "deb", "rpm", "apk"], "app.badge", .gray)
        return map
    }()
}
