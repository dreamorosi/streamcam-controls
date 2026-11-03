// Own vector artwork, rendered offscreen. No camera or screen access.
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let variants = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"),
    (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
    (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]

for (size, name) in variants {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.94, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.17, blue: 0.42, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 226, y: 226, width: 572, height: 572))
    ring.lineWidth = 32
    ring.stroke()
    for blade in 0..<6 {
        let angle = Double(blade) * .pi / 3
        func point(_ radius: Double, _ offset: Double) -> NSPoint {
            NSPoint(x: 512 + radius * cos(angle + offset), y: 512 + radius * sin(angle + offset))
        }
        let path = NSBezierPath()
        path.move(to: point(264, 0))
        path.line(to: point(264, .pi / 3 - 0.04))
        path.line(to: point(116, .pi / 3 - 0.04))
        path.line(to: point(116, -0.55))
        path.close()
        NSColor.white.withAlphaComponent(0.95).setFill()
        path.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: directory.appendingPathComponent("icon_\(name).png"))
}
