// Renders the RemoteSSH app icon (macOS only): swift scripts/make-icon.swift assets/icon.png
// macOS icon grid: 1024 canvas, 824 body, ~185 corner radius, soft drop shadow.
// Design "Quiet handoff" in the Workbench palette: an ink squircle holding two panes (slate = your computer,
// accent blue = your server) and one white chevron crossing the gap between them, a transfer and a prompt
// at once. Drawn shapes only (no fonts, no SF Symbols).
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Body: ink squircle with a soft drop shadow, light from above, hairline rim
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x12161D).setFill()
bodyPath.fill()
ctx.restoreGState()
NSGradient(colors: [color(0x0E1117), color(0x161B24), color(0x1D2430)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: bodyPath, angle: 90)
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
rim.lineWidth = 6
NSColor.white.withAlphaComponent(0.09).setStroke()
rim.stroke()

// Panes: same size, a disciplined gap; the server pane sits a step higher (the handoff goes up and over)
let paneW: CGFloat = 248, paneH: CGFloat = 476, gap: CGFloat = 64, step: CGFloat = 36, paneR: CGFloat = 52
let left = NSRect(x: 512 - gap / 2 - paneW, y: 512 - paneH / 2 - step / 2, width: paneW, height: paneH)
let right = NSRect(x: 512 + gap / 2, y: 512 - paneH / 2 + step / 2, width: paneW, height: paneH)

func pane(_ rect: NSRect, top: NSColor, bottom: NSColor, rows: NSColor, edge: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: paneR, yRadius: paneR)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    bottom.setFill()
    path.fill()
    ctx.restoreGState()
    NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)
    // Header bar and file rows, a whisper at large sizes, gone at small ones
    ctx.saveGState()
    path.addClip()
    rows.setFill()
    NSRect(x: rect.minX, y: rect.maxY - 70, width: rect.width, height: 4).fill()
    for i in 0..<5 {
        let y = rect.maxY - 132 - CGFloat(i) * 64
        let w = (rect.width - 88) * [1.0, 0.72, 0.86, 0.58, 0.78][i]
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 44, y: y, width: w, height: 14), xRadius: 7, yRadius: 7).fill()
    }
    ctx.restoreGState()
    let edgePath = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: paneR - 2, yRadius: paneR - 2)
    edgePath.lineWidth = 4
    edge.setStroke()
    edgePath.stroke()
}
pane(left, top: color(0x434E5E), bottom: color(0x323B48), rows: color(0xFFFFFF, 0.09), edge: color(0xFFFFFF, 0.08))
pane(right, top: color(0x4C7FF0), bottom: color(0x2F5FD0), rows: color(0xFFFFFF, 0.16), edge: color(0xFFFFFF, 0.14))

// Chevron: one heavy round stroke across the gap, cut out of the panes by an ink halo
let chevron = CGMutablePath()
let tip = CGPoint(x: 584, y: 512), arm: CGFloat = 120
chevron.move(to: CGPoint(x: tip.x - arm, y: tip.y + arm))
chevron.addLine(to: tip)
chevron.addLine(to: CGPoint(x: tip.x - arm, y: tip.y - arm))
let weight: CGFloat = 72
ctx.saveGState()
ctx.addPath(chevron.copy(strokingWithWidth: weight + 36, lineCap: .round, lineJoin: .round, miterLimit: 10))
color(0x161B24).setFill()
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(chevron.copy(strokingWithWidth: weight, lineCap: .round, lineJoin: .round, miterLimit: 10))
color(0xF5F7FA).setFill()
ctx.fillPath()
ctx.restoreGState()

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
