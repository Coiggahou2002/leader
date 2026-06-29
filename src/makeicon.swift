// makeicon.swift — generate Leader.iconset (cloud on a rounded blue gradient).
// Run: swift makeicon.swift <output.iconset dir>
import AppKit

func iconImage(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.2237                                  // macOS squircle-ish
    let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    clip.addClip()
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.15, green: 0.35, blue: 0.88, alpha: 1)])!
    grad.draw(in: rect, angle: -90)
    // emoji (man in suit, light skin), centered — drawn in full color
    let emoji = "👨🏻‍💼"
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.6)]
    let str = NSAttributedString(string: emoji, attributes: attrs)
    let ss = str.size()
    str.draw(at: NSPoint(x: (size - ss.width) / 2, y: (size - ss.height) / 2))
    img.unlockFocus()
    return img
}

func pngData(_ px: Int) -> Data {
    let img = iconImage(CGFloat(px))
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Leader.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    try! pngData(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("✅ iconset -> \(out)")
