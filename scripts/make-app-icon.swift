import AppKit
import UniformTypeIdentifiers

// A native vector/text mark, rendered at the sizes used by Finder and the Dock.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let image = NSImage(size: NSSize(width: 512, height: 512))
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let edge = CGFloat(size)
    NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.77, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: edge * 0.06, y: edge * 0.06, width: edge * 0.88, height: edge * 0.88),
                 xRadius: edge * 0.2, yRadius: edge * 0.2).fill()
    let label = "译" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: edge * 0.60, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    let bounds = label.size(withAttributes: attributes)
    label.draw(at: NSPoint(x: (edge - bounds.width) / 2, y: (edge - bounds.height) / 2), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(rep)
}
let tiff = image.tiffRepresentation!
let source = CGImageSourceCreateWithData(tiff as CFData, nil)!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.icns.identifier as CFString,
                                                CGImageSourceGetCount(source), nil)!
for index in 0..<CGImageSourceGetCount(source) {
    CGImageDestinationAddImageFromSource(destination, source, index, nil)
}
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write application icon") }
