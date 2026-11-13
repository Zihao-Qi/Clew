import AppKit

// Turns a square source art image into a macOS app icon: redrawn as an 824 pt rounded tile
// on a transparent 1024 canvas (the macOS icon grid) with rounded corners and a soft shadow.
// Usage: swift make-app-icon.swift <input> <output.png> [--crop x,y,w,h]
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    fputs("Usage: swift make-app-icon.swift <input> <output.png> [--crop x,y,w,h]\n", stderr)
    exit(1)
}

let src = NSImage(contentsOfFile: args[0])!
let out = args[1]
let srcRep = src.representations.first!
let scale = CGFloat(srcRep.pixelsWide) / src.size.width

let crop: NSRect
if let cropFlagIndex = args.firstIndex(of: "--crop"), cropFlagIndex + 1 < args.count {
    let parts = args[cropFlagIndex + 1].split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else {
        fputs("Invalid --crop values; expected x,y,w,h in top-left pixels.\n", stderr)
        exit(1)
    }
    let (x, yTop, w, h) = (parts[0], parts[1], parts[2], parts[3])
    crop = NSRect(x: x / scale,
                  y: (CGFloat(srcRep.pixelsHigh) - (yTop + h)) / scale,
                  width: w / scale,
                  height: h / scale)
} else {
    crop = NSRect(origin: .zero, size: src.size)
}

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Soft shadow under the tile.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 22
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(srgbRed: 247/255, green: 242/255, blue: 231/255, alpha: 1).setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

// The tile's art, clipped to the rounded square.
NSGraphicsContext.saveGraphicsState()
path.addClip()
src.draw(in: tile, from: crop, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
