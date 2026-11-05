// Renders AppIcon.svg into a macOS .iconset, plus AppIcon-1024.png (the macOS
// shape) and AppIcon-iOS.png: opaque and full-bleed, since iOS masks the
// corners itself and draws transparent pixels as black.
// Usage: swift render.swift <AppIcon.svg> <out-dir>
// Uses AppKit's built-in SVG support, so only the Command Line Tools are needed.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: render.swift <AppIcon.svg> <out-dir>\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: args[2])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// The sizes iconutil expects in an .iconset.
for size in [16, 32, 128, 256, 512] {
    try png(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try png(1024).write(to: out.appendingPathComponent("AppIcon-1024.png"))

// iOS: the SVG's 824px square (rx 185, the same 22.5% as iOS's mask) scaled
// to fill 1024, over the same gradient so the corners aren't transparent.
func iosPNG() -> Data {
    let px = 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let colors = [CGColor(srgbRed: 0x1E / 255, green: 0x29 / 255, blue: 0x3B / 255, alpha: 1),
                  CGColor(srgbRed: 0x02 / 255, green: 0x06 / 255, blue: 0x17 / 255, alpha: 1)]
    let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: px), end: .zero, options: [])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = 1024.0 / 824.0
    svg.draw(in: NSRect(x: -100 * scale, y: -100 * scale, width: 1024 * scale, height: 1024 * scale))
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}
try iosPNG().write(to: out.appendingPathComponent("AppIcon-iOS.png"))
