import AppKit
import RemoteSSHCore

/// The standard About panel, with links to the website and the source code under the copyright
/// (which comes from `NSHumanReadableCopyright` in Info.plist).
enum AboutPanel {
    static let website = URL(string: "https://fahed-alhammadi.github.io/RemoteSSH/")!
    static let repository = URL(string: "https://github.com/\(ReleaseCheck.repository)")!

    @MainActor static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: "Website", attributes: base.merging([.link: website]) { $1 }))
        credits.append(NSAttributedString(string: "    ", attributes: base))
        credits.append(NSAttributedString(string: "GitHub", attributes: base.merging([.link: repository]) { $1 }))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
