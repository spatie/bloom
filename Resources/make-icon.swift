#!/usr/bin/env swift
// Draws Bloom's app icon and writes Resources/AppIcon.icns.
//
// Kept as source rather than a checked-in binary blob so the icon can be adjusted by editing
// numbers here and re-running:  swift Resources/make-icon.swift

import AppKit
import Foundation

/// Three parallel tracks of different lengths, crossed by a baton. Parallel work, conducted.
/// It has to survive being drawn at 16 points, so there are only four shapes in it.
func drawIcon(size: CGFloat, into context: CGContext) {
    let scale = size / 1024

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }

    // Background: a rounded square with a vertical gradient, in the app's blue.
    let inset: CGFloat = 44 * scale
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = 232 * scale
    let background = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    context.saveGState()
    context.addPath(background)
    context.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0.16, green: 0.30, blue: 0.62, alpha: 1),
            CGColor(srgbRed: 0.09, green: 0.14, blue: 0.33, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // The three tracks. Different lengths so the icon is not symmetrical, which reads as
    // "several things in flight" rather than as a menu glyph.
    let trackHeight: CGFloat = 74 * scale
    let trackRadius = trackHeight / 2
    let tracks: [(y: CGFloat, start: CGFloat, end: CGFloat, alpha: CGFloat)] = [
        (640, 210, 700, 0.34),
        (500, 210, 850, 0.55),
        (360, 210, 560, 0.34),
    ]

    for track in tracks {
        let bar = CGRect(
            x: track.start * scale,
            y: (track.y - 37) * scale,
            width: (track.end - track.start) * scale,
            height: trackHeight
        )
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: track.alpha))
        context.addPath(CGPath(
            roundedRect: bar, cornerWidth: trackRadius, cornerHeight: trackRadius, transform: nil
        ))
        context.fillPath()
    }

    // The baton: a thick diagonal with a rounded cap, drawn in solid white so it separates from
    // the tracks at every size.
    context.setLineCap(.round)
    context.setLineWidth(84 * scale)
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.move(to: point(330, 250))
    context.addLine(to: point(760, 760))
    context.strokePath()

    context.restoreGState()
}

func makePNG(size: Int) -> Data {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: representation)!
    NSGraphicsContext.current = graphics
    drawIcon(size: CGFloat(size), into: graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    return representation.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes iconutil expects, each in one and two times resolution.
for base in [16, 32, 128, 256, 512] {
    try makePNG(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try makePNG(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = [
    "-c", "icns", iconset.path,
    "-o", root.appendingPathComponent("AppIcon.icns").path,
]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

print(convert.terminationStatus == 0 ? "wrote AppIcon.icns" : "iconutil failed")
