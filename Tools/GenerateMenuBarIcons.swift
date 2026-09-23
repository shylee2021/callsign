// Run from the repository root: swift Tools/GenerateMenuBarIcons.swift
import AppKit

let canvas = CGRect(x: 0, y: 0, width: 20, height: 20)
let box = canvas.insetBy(dx: 1, dy: 1)
let configuration = NSImage.SymbolConfiguration(pointSize: box.height, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
let window = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!
    .withSymbolConfiguration(configuration)!
let scale = min(box.width / window.size.width, box.height / window.size.height)
let size = CGSize(width: window.size.width * scale, height: window.size.height * scale)
let windowFrame = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                         width: size.width, height: size.height)
let plate = CGRect(x: box.minX + box.width * 0.365, y: box.minY + box.height * 0.09,
                   width: box.width * 0.65, height: box.height * 0.27)
let slash = CGMutablePath()
slash.move(to: CGPoint(x: box.minX + box.width * 0.125, y: box.minY + box.height * 0.875))
slash.addLine(to: CGPoint(x: box.minX + box.width * 0.96, y: box.minY + box.height * 0.04))

// ponytail: native 20 pt menu-bar assets at 1x/2x; use vectors if this mark is needed at larger sizes.
for paused in [false, true] {
    let name = paused ? "MenuBarIconPaused" : "MenuBarIcon"
    let directory = URL(fileURLWithPath: "Callsign/Assets.xcassets/\(name).imageset", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for scale in [1, 2] {
        let context = CGContext(data: nil, width: 20 * scale, height: 20 * scale, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        window.draw(in: windowFrame)
        // Erase the window under the plate instead of painting an opaque background.
        context.setBlendMode(.clear)
        context.addPath(CGPath(roundedRect: plate.insetBy(dx: -box.width * 0.045, dy: -box.height * 0.045),
                               cornerWidth: box.width * 0.12, cornerHeight: box.width * 0.12, transform: nil))
        context.fillPath()
        context.setBlendMode(.normal)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(CGPath(roundedRect: plate, cornerWidth: box.width * 0.08,
                               cornerHeight: box.width * 0.08, transform: nil))
        context.fillPath()
        if paused {
            context.setLineCap(.round)
            context.setBlendMode(.clear)
            context.setLineWidth(box.width * 0.15)
            context.addPath(slash)
            context.strokePath()
            context.setBlendMode(.normal)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(box.width * 0.0625)
            context.addPath(slash)
            context.strokePath()
        }
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        bitmap.size = canvas.size
        let filename = scale == 1 ? "\(name).png" : "\(name)@2x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x"])
    }
    let contents: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"]
    ]
    var data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    try data.write(to: directory.appendingPathComponent("Contents.json"))
    print(directory.path)
}
