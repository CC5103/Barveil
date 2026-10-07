#!/usr/bin/env swift
// Renders Barveil's app icon into the asset catalog.
//
//     xcrun swift scripts/make-icons.swift
//
// The mark is the same abstract symbol used in the menu bar: one horizontal
// line above one filled triangle. It is flat, monochrome, and deliberately
// contains no screen, play-button circle, gradient, glow, or shadow.

import AppKit
import CoreGraphics
import Foundation

struct Palette {
    let tile: CGColor
    let mark: CGColor

    static let light = Palette(
        tile: rgb(0x202428),
        mark: rgb(0xF5F3EB),
    )

    static let dark = Palette(
        tile: rgb(0x101214),
        mark: rgb(0xF8F7F2),
    )

    static let tinted = Palette(
        tile: rgb(0x73777C),
        mark: rgb(0xF4F4F6),
    )
}

private func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha,
    )
}

private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func roundedTriangle(
    center: CGPoint,
    width: CGFloat,
    height: CGFloat,
    radius: CGFloat,
) -> CGPath {
    let topLeft = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
    let bottomLeft = CGPoint(x: center.x - width / 2, y: center.y + height / 2)
    let tip = CGPoint(x: center.x + width / 2, y: center.y)

    let path = CGMutablePath()
    path.move(to: CGPoint(x: topLeft.x, y: center.y))
    path.addArc(tangent1End: bottomLeft, tangent2End: tip, radius: radius)
    path.addArc(tangent1End: tip, tangent2End: topLeft, radius: radius)
    path.addArc(tangent1End: topLeft, tangent2End: bottomLeft, radius: radius)
    path.closeSubpath()
    return path
}

func drawIcon(palette: Palette) -> CGImage? {
    let size = 1024
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else { return nil }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)

    context.addPath(roundedRect(CGRect(x: 88, y: 88, width: 848, height: 848), radius: 194))
    context.setFillColor(palette.tile)
    context.fillPath()

    context.setFillColor(palette.mark)
    context.addPath(roundedRect(CGRect(x: 274, y: 272, width: 476, height: 74), radius: 37))
    context.fillPath()

    context.addPath(
        roundedTriangle(
            center: CGPoint(x: 526, y: 610),
            width: 316,
            height: 346,
            radius: 46,
        ),
    )
    context.fillPath()

    return context.makeImage()
}

func resized(_ image: CGImage, pixels: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: image.width, height: image.height)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icons", code: 1)
    }
    try data.write(to: url)
}

struct Slot {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var sizeLabel: String { "\(points)x\(points)" }
    var suffix: String { scale == 1 ? "" : "@\(scale)x" }
    var filename: String { "icon_\(points)x\(points)\(suffix).png" }
}

let slots: [Slot] = [
    Slot(points: 16, scale: 1), Slot(points: 16, scale: 2),
    Slot(points: 32, scale: 1), Slot(points: 32, scale: 2),
    Slot(points: 128, scale: 1), Slot(points: 128, scale: 2),
    Slot(points: 256, scale: 1), Slot(points: 256, scale: 2),
    Slot(points: 512, scale: 1), Slot(points: 512, scale: 2),
]

func contentsJSON() -> String {
    let images = slots.map {
        """
            {
              "filename" : "\($0.filename)",
              "idiom" : "mac",
              "scale" : "\($0.scale)x",
              "size" : "\($0.sizeLabel)"
            }
        """
    }
    return """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = root.appendingPathComponent("Barveil/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)

for existing in try FileManager.default.contentsOfDirectory(atPath: catalog.path)
where existing.hasSuffix(".png") {
    try FileManager.default.removeItem(at: catalog.appendingPathComponent(existing))
}

for slot in slots {
    guard let image = drawIcon(palette: .light),
          let scaled = resized(image, pixels: slot.pixels) else {
        FileHandle.standardError.write("failed to render \(slot.filename)\n".data(using: .utf8)!)
        exit(1)
    }
    try write(scaled, to: catalog.appendingPathComponent(slot.filename))
}

let variants = root.appendingPathComponent("Design/IconVariants")
try FileManager.default.createDirectory(at: variants, withIntermediateDirectories: true)
for (palette, filename) in [
    (Palette.light, "AppIcon-1024-Light.png"),
    (Palette.dark, "AppIcon-1024-Dark.png"),
    (Palette.tinted, "AppIcon-1024-Tinted.png"),
] {
    guard let image = drawIcon(palette: palette) else { continue }
    try write(image, to: variants.appendingPathComponent(filename))
}

try contentsJSON().write(
    to: catalog.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8,
)

print("wrote \(slots.count) icons to \(catalog.path)")
print("wrote light/dark/tinted sources to \(variants.path)")
