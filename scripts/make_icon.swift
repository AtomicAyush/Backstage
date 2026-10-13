// Draws Backstage's app icon (theatre masks on a stage-curtain gradient) into an .icns.
//   swift scripts/make_icon.swift scripts/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Backstage.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The macOS icon grid: an 824/1024 rounded square, centred.
    let inset = size * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.42, green: 0.07, blue: 0.13, alpha: 1),
                        NSColor(red: 0.16, green: 0.03, blue: 0.08, alpha: 1)])!.draw(in: shape, angle: -90)
    // A warm spotlight from above.
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 1, green: 0.85, blue: 0.55, alpha: 0.35), .clear])!
        .draw(fromCenter: NSPoint(x: tile.midX, y: tile.maxY), radius: 0,
              toCenter: NSPoint(x: tile.midX, y: tile.maxY), radius: tile.height * 0.95, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()
    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.46, weight: .regular)
        .applying(.init(paletteColors: [NSColor(red: 1, green: 0.93, blue: 0.82, alpha: 1)]))
    if let masks = NSImage(systemSymbolName: "theatermasks.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let drawn = masks.size
        masks.draw(in: NSRect(x: tile.midX - drawn.width / 2, y: tile.midY - drawn.height / 2 - tile.height * 0.02,
                              width: drawn.width, height: drawn.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
