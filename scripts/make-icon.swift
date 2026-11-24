// Draws the v2 app icon (design spec palette: work #15171A, teal #2EB5A5,
// orange #F29A4A, green #5CC48A) and writes Packaging/AppIcon.icns.
// usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let unit = size / 1024
    // macOS icon grid: 824 pt body centred in 1024 with a continuous-ish corner.
    let body = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * unit, yRadius: 185 * unit)
    NSGradient(starting: color(0x2A3B4F), ending: color(0x0D1015))!.draw(in: shape, angle: -90)
    // Terminal card with the focused-pane teal edge.
    let card = NSRect(x: 190 * unit, y: 230 * unit, width: 644 * unit, height: 470 * unit)
    color(0x121417).setFill()
    NSBezierPath(roundedRect: card, xRadius: 56 * unit, yRadius: 56 * unit).fill()
    color(0x2EB5A5).setFill()
    NSBezierPath(roundedRect: NSRect(x: card.minX, y: card.maxY - 22 * unit, width: card.width, height: 22 * unit),
                 xRadius: 11 * unit, yRadius: 11 * unit).fill()
    // Prompt chevron and cursor.
    let chevron = NSBezierPath()
    chevron.lineWidth = 46 * unit
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: 290 * unit, y: 560 * unit))
    chevron.line(to: NSPoint(x: 420 * unit, y: 465 * unit))
    chevron.line(to: NSPoint(x: 290 * unit, y: 370 * unit))
    color(0x2EB5A5).setStroke()
    chevron.stroke()
    color(0xE7E9EC).setFill()
    NSBezierPath(roundedRect: NSRect(x: 480 * unit, y: 345 * unit, width: 190 * unit, height: 44 * unit),
                 xRadius: 22 * unit, yRadius: 22 * unit).fill()
    // Liveness beacons: working, attention, done.
    for (index, hex) in [0x2EB5A5, 0xF29A4A, 0x5CC48A].enumerated() {
        let x = (300 + CGFloat(index) * 110) * unit
        color(hex).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 34 * unit, y: 760 * unit, width: 68 * unit, height: 68 * unit)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let data = draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Packaging/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")
