import AppKit

// Draws the Eddy icon: a synthwave-dusk squircle with three pastel currents.
func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor(srgbRed: 0.10, green: 0.08, blue: 0.20, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.09, green: 0.07, blue: 0.21, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.10, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 0.38, green: 0.15, blue: 0.40, alpha: 1),
    ])!.draw(in: body, angle: -90)
    // Horizon glow.
    let glow = NSGradient(colors: [
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.75, alpha: 0.55),
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.75, alpha: 0.0),
    ])!
    glow.draw(fromCenter: NSPoint(x: 512 * s, y: 60 * s), radius: 0, toCenter: NSPoint(x: 512 * s, y: 60 * s), radius: 560 * s, options: [])

    let colors: [NSColor] = [
        NSColor(srgbRed: 0.62, green: 0.91, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.70, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.78, green: 0.68, blue: 1.00, alpha: 1),
    ]
    for (index, color) in colors.enumerated() {
        let y = (620 - CGFloat(index) * 140) * s
        let path = NSBezierPath()
        path.lineWidth = 44 * s
        path.lineCapStyle = .round
        let left = 230 * s, right = 794 * s
        let amp = (48 - CGFloat(index) * 6) * s
        let phase = CGFloat(index) * 0.9
        path.move(to: NSPoint(x: left, y: y + sin(phase) * amp))
        var x = left
        while x <= right {
            let t = (x - left) / (right - left)
            path.line(to: NSPoint(x: x, y: y + sin(t * .pi * 2 + phase) * amp))
            x += 2 * s
        }
        NSGraphicsContext.saveGraphicsState()
        let g = NSShadow()
        g.shadowColor = color.withAlphaComponent(0.85)
        g.shadowBlurRadius = 36 * s
        g.shadowOffset = .zero
        g.set()
        color.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    // Soft top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.12).setStroke()
    squircle.lineWidth = 2 * s
    squircle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let data = draw(size: CGFloat(px)).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
