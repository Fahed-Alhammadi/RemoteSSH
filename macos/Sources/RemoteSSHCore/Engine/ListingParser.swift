import Foundation

/// Parses FTP directory listings: MLSD (RFC 3659), Unix `ls -l` style and DOS/IIS style,
/// which together cover practically every server in use today.
public enum ListingParser {
    public static func parse(_ text: String, now: Date = Date()) -> [FileEntry] {
        var result: [FileEntry] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix("total ") { continue }
            let entry = parseMLSD(line) ?? parseUnix(line, now: now) ?? parseDOS(line)
            if let entry, entry.name != ".", entry.name != ".." {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: MLSD — "type=file;size=123;modify=20240101120000;UNIX.mode=0644; name"
    static func parseMLSD(_ line: String) -> FileEntry? {
        guard let space = line.firstIndex(of: " "), line[..<space].contains("=") else { return nil }
        let factsPart = line[..<space]
        let name = String(line[line.index(after: space)...])
        var facts: [String: String] = [:]
        for fact in factsPart.split(separator: ";") {
            let kv = fact.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { facts[kv[0].lowercased()] = String(kv[1]) }
        }
        guard let type = facts["type"]?.lowercased() else { return nil }
        if type == "cdir" || type == "pdir" { return nil }
        let isLink = type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink")
        let isDir = type == "dir" || type.hasPrefix("os.unix=slink") && name.hasSuffix("/")
        var entry = FileEntry(name: name, isDirectory: isDir, isLink: isLink)
        if let size = facts["size"] ?? facts["sizd"], let s = Int64(size) { entry.size = s }
        if let modify = facts["modify"] { entry.modified = parseMLSDTime(modify) }
        if let mode = facts["unix.mode"], let bits = Int(mode, radix: 8) {
            entry.permissions = Permissions.symbolic(mode: UInt32(bits) | (isDir ? 0o040000 : 0))
        } else if let perm = facts["perm"] {
            entry.permissions = perm
        }
        entry.owner = facts["unix.owner"] ?? facts["unix.ownername"] ?? facts["unix.uid"] ?? ""
        entry.group = facts["unix.group"] ?? facts["unix.groupname"] ?? facts["unix.gid"] ?? ""
        return entry
    }

    // DateFormatter creation is expensive; listings can have thousands of lines.
    private static let mlsdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    private static let dosFormatters: [DateFormatter] = ["MM-dd-yy hh:mma", "MM-dd-yyyy hh:mma", "MM-dd-yy HH:mm", "MM-dd-yyyy HH:mm", "yyyy-MM-dd HH:mm"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    private static let calendar = Calendar(identifier: .gregorian)

    static func parseMLSDTime(_ s: String) -> Date? {
        mlsdFormatter.date(from: String(s.prefix(14)))
    }

    // MARK: Unix — "drwxr-xr-x  2 user group  4096 Jan  1 12:00 name"
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func parseUnix(_ line: String, now: Date) -> FileEntry? {
        guard let first = line.first, "-dlbcpsDL".contains(first) else { return nil }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 6 else { return nil }
        let perms = String(tokens[0])
        guard perms.count >= 10 else { return nil }

        // Find the month token; size precedes it, day + time/year follow it.
        guard let monthIdx = tokens.indices.dropFirst(2).first(where: { idx in
            months.contains(tokens[idx].prefix(3).lowercased()) && idx + 2 < tokens.count && Int(tokens[idx - 1]) != nil
        }) else { return nil }

        let size = Int64(tokens[monthIdx - 1])
        let month = months.firstIndex(of: tokens[monthIdx].prefix(3).lowercased())! + 1
        guard let day = Int(tokens[monthIdx + 1]) else { return nil }
        let timeOrYear = tokens[monthIdx + 2]

        var comps = DateComponents()
        comps.month = month
        comps.day = day
        let cal = calendar
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":")
            comps.hour = Int(hm[0])
            comps.minute = hm.count > 1 ? Int(hm[1]) : 0
            comps.year = cal.component(.year, from: now)
            if let d = cal.date(from: comps), d > now.addingTimeInterval(86400) { comps.year! -= 1 }
        } else {
            comps.year = Int(timeOrYear)
        }

        // Name = everything after the time/year token, preserving spaces.
        guard let nameStart = rangeAfterToken(line, tokenIndex: monthIdx + 2) else { return nil }
        var name = String(line[nameStart...])
        var target: String?
        let isLink = first == "l" || first == "L"
        if isLink, let arrow = name.range(of: " -> ") {
            target = String(name[arrow.upperBound...])
            name = String(name[..<arrow.lowerBound])
        }

        var owner = ""
        var group = ""
        let ownerTokens = tokens[1..<(monthIdx - 1)]
        if ownerTokens.count >= 3 { owner = String(ownerTokens[ownerTokens.startIndex + 1]); group = String(ownerTokens[ownerTokens.startIndex + 2]) }
        else if ownerTokens.count == 2 { owner = String(ownerTokens[ownerTokens.startIndex + 1]) }

        return FileEntry(
            name: name,
            isDirectory: first == "d" || first == "D",
            isLink: isLink,
            size: size,
            modified: cal.date(from: comps),
            permissions: perms,
            owner: owner,
            group: group,
            linkTarget: target
        )
    }

    /// Returns the index right after the given whitespace-separated token and the following spaces.
    static func rangeAfterToken(_ line: String, tokenIndex: Int) -> String.Index? {
        var idx = line.startIndex
        var count = -1
        var inToken = false
        while idx < line.endIndex {
            let isSpace = line[idx] == " "
            if !isSpace && !inToken {
                count += 1
                inToken = true
                if count == tokenIndex + 1 { return idx }
            } else if isSpace {
                inToken = false
            }
            idx = line.index(after: idx)
        }
        return nil
    }

    // MARK: DOS/IIS — "01-01-24  12:00PM       <DIR>          name"
    static func parseDOS(_ line: String) -> FileEntry? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 4 else { return nil }
        let datePart = tokens[0]
        let timePart = tokens[1]
        guard datePart.filter({ $0 == "-" || $0 == "/" }).count == 2, timePart.contains(":") else { return nil }
        let isDir = tokens[2].uppercased() == "<DIR>"
        let size = isDir ? nil : Int64(tokens[2].replacingOccurrences(of: ",", with: ""))
        guard isDir || size != nil, let nameStart = rangeAfterToken(line, tokenIndex: 2) else { return nil }

        let dateString = datePart.replacingOccurrences(of: "/", with: "-") + " " + timePart
        let date = dosFormatters.lazy.compactMap { $0.date(from: dateString) }.first
        return FileEntry(name: String(line[nameStart...]), isDirectory: isDir, size: size, modified: date)
    }
}
