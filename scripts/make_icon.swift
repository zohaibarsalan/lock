#!/usr/bin/swift

import AppKit
import Foundation

let outputDirectory: URL

if CommandLine.arguments.count > 1 {
    outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
} else {
    fputs("Usage: make_icon.swift <output-directory>\n", stderr)
    exit(1)
}

let fileManager = FileManager.default
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let iconSizes: [(name: String, points: CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

for icon in iconSizes {
    let image = drawIcon(size: icon.points)
    let destination = outputDirectory.appendingPathComponent("\(icon.name).png")
    try pngData(from: image)?.write(to: destination)
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let inset = size * 0.08
    let cardRect = rect.insetBy(dx: inset, dy: inset)
    let cornerRadius = size * 0.26
    let path = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)

    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.31, green: 0.52, blue: 1.0, alpha: 1.0),
            NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.92, alpha: 1.0)
        ]
    )!
    gradient.draw(in: path, angle: 315)

    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()

    let glow = NSBezierPath(roundedRect: NSRect(x: size * 0.24, y: size * 0.6, width: size * 0.52, height: size * 0.24), xRadius: size * 0.12, yRadius: size * 0.12)
    NSColor.white.withAlphaComponent(0.12).setFill()
    glow.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    if let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .bold)
        let symbolImage = symbol.withSymbolConfiguration(config) ?? symbol
        let symbolRect = NSRect(
            x: size * 0.22,
            y: size * 0.20,
            width: size * 0.56,
            height: size * 0.56
        )
        NSColor.white.set()
        symbolImage.draw(in: symbolRect)
    }

    image.unlockFocus()
    return image
}

func pngData(from image: NSImage) throws -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        return nil
    }

    return bitmap.representation(using: .png, properties: [:])
}
