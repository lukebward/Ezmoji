// Generates the app icon PNGs for an .iconset directory.
// Usage: swift scripts/make_icon.swift <output-iconset-dir>
// Then:  iconutil -c icns <output-iconset-dir> -o Resources/AppIcon.icns
import AppKit

let variants: [(pixels: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

func renderIcon(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: ~10% transparent margin, ~22% continuous corner radius.
    let inset = s * 0.098
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.224, yRadius: body.width * 0.224)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.32, green: 0.18, blue: 0.80, alpha: 1),
        NSColor(calibratedRed: 0.62, green: 0.36, blue: 1.00, alpha: 1),
    ])!.draw(in: path, angle: 90)

    let emoji = "😀" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: body.width * 0.60)]
    let glyphSize = emoji.size(withAttributes: attrs)
    emoji.draw(
        at: NSPoint(x: body.midX - glyphSize.width / 2, y: body.midY - glyphSize.height / 2),
        withAttributes: attrs
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count > 1 else {
    print("usage: swift make_icon.swift <output-iconset-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for v in variants {
    let data = renderIcon(pixels: v.pixels)
    try data.write(to: outDir.appendingPathComponent("\(v.name).png"))
}
print("Wrote \(variants.count) PNGs to \(outDir.path)")
