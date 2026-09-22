import AppKit

// 使用原生矢量绘图生成各档图标，不依赖图片处理库。
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: Double(pixels) / 1024)
    (transform as NSAffineTransform).concat()
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 195, yRadius: 195).fill()
    NSColor(red: 0.91, green: 0.769, blue: 0.722, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 369, y: 175, width: 286, height: 674), xRadius: 48, yRadius: 48).fill()
    NSColor(calibratedWhite: 0.19, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 414, y: 585, width: 196, height: 196)).fill()
    for y in [255, 365, 475] { NSBezierPath(roundedRect: NSRect(x: 446, y: y, width: 132, height: 82), xRadius: 18, yRadius: 18).fill() }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(name).png"))
}
