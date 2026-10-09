import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.black.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

for layer in stride(from: 12, through: 0, by: -1) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.30, alpha: 0.25)
    shadow.shadowBlurRadius = CGFloat(18 + layer * 4)
    shadow.shadowOffset = .zero
    shadow.set()
    let path = NSBezierPath()
    for point in 0...180 {
        let angle = Double(point) * .pi * 2 / 180
        let wobble = 1 + 0.06 * sin(angle * 3 + Double(layer) * 0.1)
        let x = cos(angle) * (145 + Double(layer) * 1.3) * wobble
        let y = sin(angle) * (235 + Double(layer) * 1.3) * wobble
        let rotation = -0.48
        let position = NSPoint(x: 512 + x * cos(rotation) - y * sin(rotation), y: 512 + x * sin(rotation) + y * cos(rotation))
        if point == 0 { path.move(to: position) } else { path.line(to: position) }
    }
    path.close()
    path.lineWidth = layer == 0 ? 8 : 2
    NSColor(calibratedRed: 0.24, green: 0.88, blue: 0.35, alpha: layer == 0 ? 0.9 : 0.14).setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
}
NSGraphicsContext.restoreGraphicsState()
let folder = "Pulse/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder + "/AppIcon.png"))
let catalog: [String: Any] = ["images": [["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]], "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: catalog, options: .prettyPrinted).write(to: URL(fileURLWithPath: folder + "/Contents.json"))
let root: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: root).write(to: URL(fileURLWithPath: "Pulse/Assets.xcassets/Contents.json"))
print("Generated opaque 1024px Pulse app icon")