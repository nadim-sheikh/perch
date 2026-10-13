// Renders Perch's app icon: run `swift Tools/make-icon.swift <out.png>`
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background with a deep indigo gradient.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
bg.addClip()
let grad = NSGradient(colors: [NSColor(red: 0.07, green: 0.08, blue: 0.16, alpha: 1),
                              NSColor(red: 0.16, green: 0.17, blue: 0.38, alpha: 1)])!
grad.draw(in: rect, angle: -90)
// Soft blue glow behind the cloud.
let glow = NSGradient(colors: [NSColor(red: 0.45, green: 0.7, blue: 1, alpha: 0.55), NSColor(red: 0.45, green: 0.7, blue: 1, alpha: 0)])!
glow.draw(fromCenter: NSPoint(x: size / 2, y: 470), radius: 0, toCenter: NSPoint(x: size / 2, y: 470), radius: 360, options: [])

// The notch at the top.
let notchW: CGFloat = 330, notchH: CGFloat = 92
let notch = NSBezierPath(roundedRect: CGRect(x: size / 2 - notchW / 2, y: rect.maxY - notchH, width: notchW, height: notchH + 60),
                         xRadius: 46, yRadius: 46)
NSColor.black.setFill()
notch.fill()
// Two little eyes in the notch.
NSColor.white.setFill()
for dx in [-26.0, 26.0] {
    NSBezierPath(roundedRect: CGRect(x: size / 2 + dx - 9, y: rect.maxY - 58, width: 18, height: 30), xRadius: 9, yRadius: 9).fill()
}

// Cloud: overlapping circles + rounded base.
func cloudPath(center c: CGPoint, width w: CGFloat) -> NSBezierPath {
    let h = w * 0.78
    let p = NSBezierPath()
    let bumps: [(CGFloat, CGFloat, CGFloat)] = [(0.30, 0.48, 0.26), (0.52, 0.34, 0.30), (0.74, 0.46, 0.25), (0.18, 0.66, 0.18), (0.84, 0.66, 0.17)]
    let origin = CGPoint(x: c.x - w / 2, y: c.y + h / 2)   // top-left in flipped terms
    for (x, y, r) in bumps {
        p.append(NSBezierPath(ovalIn: CGRect(x: origin.x + w * (x - r), y: origin.y - h * y - w * r, width: w * r * 2, height: w * r * 2)))
    }
    p.append(NSBezierPath(roundedRect: CGRect(x: origin.x + w * 0.06, y: origin.y - h * 0.98, width: w * 0.88, height: h * 0.46),
                          xRadius: h * 0.23, yRadius: h * 0.23))
    return p
}
let cloudCenter = CGPoint(x: size / 2, y: 430)
let cloud = cloudPath(center: cloudCenter, width: 520)
ctx.setShadow(offset: .zero, blur: 70, color: NSColor(red: 0.5, green: 0.78, blue: 1, alpha: 0.9).cgColor)
NSGradient(colors: [NSColor(red: 0.86, green: 0.94, blue: 1, alpha: 1), NSColor(red: 0.52, green: 0.78, blue: 0.99, alpha: 1)])!
    .draw(in: cloud, angle: -90)
ctx.setShadow(offset: .zero, blur: 0, color: nil)
// Gloss
ctx.saveGState()
cloud.addClip()
NSGradient(colors: [NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0)])!
    .draw(in: CGRect(x: cloudCenter.x - 260, y: cloudCenter.y, width: 520, height: 200), angle: -90)
ctx.restoreGState()

// Happy eyes ^ ^
NSColor.white.setStroke()
for dx in [-62.0, 62.0] {
    let e = NSBezierPath()
    e.lineWidth = 22
    e.lineCapStyle = .round
    e.move(to: NSPoint(x: cloudCenter.x + dx - 34, y: cloudCenter.y - 20))
    e.curve(to: NSPoint(x: cloudCenter.x + dx + 34, y: cloudCenter.y - 20),
            controlPoint1: NSPoint(x: cloudCenter.x + dx - 18, y: cloudCenter.y + 24),
            controlPoint2: NSPoint(x: cloudCenter.x + dx + 18, y: cloudCenter.y + 24))
    NSColor(red: 0.2, green: 0.32, blue: 0.62, alpha: 1).setStroke()
    e.stroke()
}
// Blush
NSColor(red: 1, green: 0.55, blue: 0.7, alpha: 0.45).setFill()
for dx in [-118.0, 118.0] { NSBezierPath(ovalIn: CGRect(x: cloudCenter.x + dx - 26, y: cloudCenter.y - 78, width: 52, height: 30)).fill() }
ctx.restoreGState()

// Subtle rim
NSColor(white: 1, alpha: 0.12).setStroke()
bg.lineWidth = 4
bg.stroke()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
