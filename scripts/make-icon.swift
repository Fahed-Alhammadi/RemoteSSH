// Renders the RemoteSSH app icon (macOS only): swift scripts/make-icon.swift assets/icon.png
// macOS icon grid: 1024 canvas, 824 body, ~185 corner radius, soft drop shadow.
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Body with shadow
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x312E81).setFill()
bodyPath.fill()
ctx.restoreGState()

// Gradient fill: indigo → blue → teal
NSGradient(colors: [color(0x4338CA), color(0x2563EB), color(0x06B6D4)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: bodyPath, angle: -55)
// Top highlight
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSBezierPath(roundedRect: NSRect(x: 100, y: 520, width: 824, height: 404), xRadius: 185, yRadius: 185), angle: -90)

// Terminal window
let term = NSRect(x: 222, y: 330, width: 580, height: 430)
let termPath = NSBezierPath(roundedRect: term, xRadius: 56, yRadius: 56)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.30).cgColor)
color(0x0F172A, 0.92).setFill()
termPath.fill()
ctx.restoreGState()
NSColor.white.withAlphaComponent(0.18).setStroke()
termPath.lineWidth = 4
termPath.stroke()

// Traffic lights
for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
    color(hex).setFill()
    NSBezierPath(ovalIn: NSRect(x: term.minX + 48 + CGFloat(i) * 52, y: term.maxY - 76, width: 32, height: 32)).fill()
}

// Prompt ">_" drawn as strokes (no system fonts or symbols, so the icon can be redistributed)
let cyan = color(0x67E8F9)
cyan.setStroke()
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: term.minX + 78, y: term.minY + 250))
chevron.line(to: NSPoint(x: term.minX + 178, y: term.minY + 170))
chevron.line(to: NSPoint(x: term.minX + 78, y: term.minY + 90))
chevron.lineWidth = 38
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.stroke()
cyan.setFill()
NSBezierPath(roundedRect: NSRect(x: term.minX + 222, y: term.minY + 72, width: 130, height: 36), xRadius: 18, yRadius: 18).fill()

// Sync badge: white disc with an up arrow and a down arrow
let badge = NSRect(x: 612, y: 172, width: 260, height: 260)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.white.setFill()
NSBezierPath(ovalIn: badge).fill()
ctx.restoreGState()
func arrow(x: CGFloat, up: Bool) {
    let top = badge.midY + 70, bottom = badge.midY - 70
    let (tip, tail) = up ? (top, bottom) : (bottom, top)
    let head: CGFloat = up ? -38 : 38
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: tail))
    path.line(to: NSPoint(x: x, y: tip))
    path.move(to: NSPoint(x: x - 34, y: tip + head))
    path.line(to: NSPoint(x: x, y: tip))
    path.line(to: NSPoint(x: x + 34, y: tip + head))
    path.lineWidth = 24
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}
color(0x2563EB).setStroke()
arrow(x: badge.midX - 40, up: true)
arrow(x: badge.midX + 40, up: false)
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
