import AppKit
import CryptoKit
import RemoteSSHCore
import Security

/// Checks GitHub for a newer release, then downloads, verifies and swaps in the new app and relaunches.
@MainActor
final class Updater {
    static let shared = Updater()
    static let autoCheckKey = "RemoteSSH.checkForUpdates"

    private var busy = false
    private var checkedAtLaunch = false

    private var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Once per launch, a few seconds after the window appears, if enabled in Settings.
    func checkAtLaunch() {
        guard !checkedAtLaunch else { return }
        checkedAtLaunch = true
        guard UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true, currentVersion != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await check(manual: false)
        }
    }

    /// `manual` checks report "up to date" and errors; launch checks stay silent unless there is an update.
    func check(manual: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let current = currentVersion else {
                throw UpdateError("Updates only work for the RemoteSSH.app bundle.")
            }
            guard let release = try await ReleaseCheck.latest(),
                  ReleaseCheck.compare(release.version, current) == .orderedDescending else {
                if manual { alert("You're up to date", "RemoteSSH \(current) is the latest version.") }
                return
            }
            try await offer(release, current: current)
        } catch {
            if manual { alert("Could not update", error.localizedDescription, style: .warning) }
        }
    }

    private func offer(_ release: ReleaseInfo, current: String) async throws {
        let app = Bundle.main.bundleURL
        let blocker = installBlocker(app)
        guard let download = release.downloadURL, blocker == nil else {
            // No macOS download, or the app can't replace itself: offer the release page instead.
            let note = blocker ?? "Download it from GitHub."
            if ask("RemoteSSH \(release.version) is available", "You have version \(current). \(note)",
                   buttons: ["Open Download Page", "Later"]) {
                NSWorkspace.shared.open(release.pageURL)
            }
            return
        }
        guard ask("RemoteSSH \(release.version) is available",
                  "You have version \(current). Download and install it now? RemoteSSH will relaunch.",
                  buttons: ["Install and Relaunch", "Later"]) else { return }
        let newApp = try await fetch(download, sha256: release.sha256)
        try relaunch(replacing: app, with: newApp)
    }

    /// Why the running app can't be replaced in place, or nil when it can.
    private func installBlocker(_ app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return "Move RemoteSSH to the Applications folder, then check again."
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "RemoteSSH can't replace itself in \(app.deletingLastPathComponent().path)."
        }
        return nil
    }

    /// Downloads and unpacks the zip, then checks the checksum, bundle ID and code signature. When this app is
    /// signed with a Developer ID, the update must be signed by the same team.
    private func fetch(_ url: URL, sha256: String?) async throws -> URL {
        let (zip, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        if let sha256 {
            let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
            guard digest.map({ String(format: "%02x", $0) }).joined() == sha256 else {
                throw UpdateError("The download is damaged (checksum mismatch).")
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteSSH-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
            let newApp = dir.appendingPathComponent("RemoteSSH.app")
            guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The download does not contain RemoteSSH.")
            }
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            if let team = teamIdentifier(of: Bundle.main.bundleURL), !isSigned(newApp, byTeam: team) {
                throw UpdateError("The download is not signed by the RemoteSSH developer.")
            }
            return newApp
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// A detached shell waits for this process to quit, swaps the bundles (restoring on failure) and reopens the app.
    private func relaunch(replacing app: URL, with newApp: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && mv "$3" "$2"; then rm -rf "$2.old"; else mv "$2.old" "$2"; fi
        rm -rf "$(dirname "$3")"
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path, newApp.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("Could not verify the downloaded app (\((tool as NSString).lastPathComponent) failed).")
        }
    }

    /// The Team ID in an app's signature, or nil for ad-hoc and unsigned builds.
    private func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether `app` has a valid signature from an Apple-issued certificate of `team`.
    private func isSigned(_ app: URL, byTeam team: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private func ask(_ title: String, _ message: String, buttons: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
