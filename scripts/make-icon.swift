// Renders the RemoteSSH app icon (macOS only): swift scripts/make-icon.swift assets/icon.png
// macOS icon grid: 1024 canvas, 824 body, ~185 corner radius, soft drop shadow.
// Design: ink squircle, teal→cyan sync ring (two arrows) around a ">_" prompt. Drawn shapes only.
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let center = CGPoint(x: 512, y: 512)

// Body with shadow
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x0B1220).setFill()
bodyPath.fill()
ctx.restoreGState()

// Ink gradient with a teal glow from the top-left
NSGradient(colors: [color(0x0A1019), color(0x0F1E2A), color(0x123A44)], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
    .draw(in: bodyPath, angle: 60)
ctx.saveGState()
bodyPath.addClip()
NSGradient(colors: [color(0x2DD4BF, 0.30), color(0x2DD4BF, 0)])!
    .draw(fromCenter: NSPoint(x: 330, y: 760), radius: 0, toCenter: NSPoint(x: 330, y: 760), radius: 520, options: [])
ctx.restoreGState()
// Hairline rim
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
rim.lineWidth = 6
NSColor.white.withAlphaComponent(0.10).setStroke()
rim.stroke()

// Sync ring: two arcs with arrowheads, filled with a teal→cyan→sky gradient
let radius: CGFloat = 268, stroke: CGFloat = 62
let ring = CGMutablePath()
func rad(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }
for (start, end) in [(CGFloat(28), CGFloat(150)), (208, 330)] {
    let arc = CGMutablePath()
    arc.addArc(center: center, radius: radius, startAngle: rad(start), endAngle: rad(end), clockwise: false)
    ring.addPath(arc.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10))
    // Arrowhead at the counter-clockwise end, pointing along the tangent
    let a = rad(end)
    let p = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    let radial = CGPoint(x: cos(a), y: sin(a)), tangent = CGPoint(x: -sin(a), y: cos(a))
    let head = CGMutablePath()
    head.move(to: CGPoint(x: p.x + tangent.x * 96, y: p.y + tangent.y * 96))
    head.addLine(to: CGPoint(x: p.x + radial.x * 76 - tangent.x * 6, y: p.y + radial.y * 76 - tangent.y * 6))
    head.addLine(to: CGPoint(x: p.x - radial.x * 76 - tangent.x * 6, y: p.y - radial.y * 76 - tangent.y * 6))
    head.closeSubpath()
    ring.addPath(head.copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ring.addPath(head)
}
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 40, color: color(0x2DD4BF, 0.45).cgColor)
ctx.addPath(ring)
color(0x2DD4BF).setFill()
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(ring)
ctx.clip()
NSGradient(colors: [color(0x14B8A6), color(0x22D3EE), color(0x7DD3FC)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: 180, y: 180, width: 664, height: 664), angle: 45)
ctx.restoreGState()

// ">_" prompt
let ink = color(0xF0FDFA)
ink.setStroke()
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 398, y: 600))
chevron.line(to: NSPoint(x: 486, y: 512))
chevron.line(to: NSPoint(x: 398, y: 424))
chevron.lineWidth = 54
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.stroke()
ink.setFill()
NSBezierPath(roundedRect: NSRect(x: 520, y: 398, width: 112, height: 50), xRadius: 25, yRadius: 25).fill()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
