import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift GenerateIcon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let size = NSSize(width: 1024, height: 1024)
guard
    let bitmapContext = CGContext(
        data: nil,
        width: 1024,
        height: 1024,
        bitsPerComponent: 8,
        bytesPerRow: 1024 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
else {
    fputs("Could not create icon canvas\n", stderr)
    exit(1)
}

let outputContext = NSGraphicsContext(
    cgContext: bitmapContext,
    flipped: false
)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = outputContext

let canvas = NSRect(origin: .zero, size: size)
let canvasGradient = NSGradient(colors: [
    NSColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1),
    NSColor(red: 0.055, green: 0.06, blue: 0.075, alpha: 1)
])!
canvasGradient.draw(in: canvas, angle: -90)

let windowRect = NSRect(x: 44, y: 44, width: 936, height: 936)
let windowPath = NSBezierPath(
    roundedRect: windowRect,
    xRadius: 188,
    yRadius: 188
)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
shadow.shadowBlurRadius = 32
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(red: 0.025, green: 0.03, blue: 0.04, alpha: 1).setFill()
windowPath.fill()
NSGraphicsContext.restoreGraphicsState()

let topBar = NSRect(x: 44, y: 790, width: 936, height: 190)
NSGraphicsContext.saveGraphicsState()
windowPath.addClip()
let topBarGradient = NSGradient(colors: [
    NSColor(red: 0.25, green: 0.26, blue: 0.29, alpha: 1),
    NSColor(red: 0.105, green: 0.115, blue: 0.14, alpha: 1)
])!
topBarGradient.draw(in: topBar, angle: -90)
NSColor.white.withAlphaComponent(0.10).setFill()
NSRect(x: 44, y: 786, width: 936, height: 4).fill()
NSGraphicsContext.restoreGraphicsState()

NSColor.white.withAlphaComponent(0.28).setStroke()
windowPath.lineWidth = 10
windowPath.stroke()

NSColor(red: 1, green: 0.38, blue: 0.35, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 154, y: 852, width: 42, height: 42)).fill()
NSColor(red: 1, green: 0.76, blue: 0.24, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 224, y: 852, width: 42, height: 42)).fill()
NSColor(red: 0.28, green: 0.82, blue: 0.47, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 294, y: 852, width: 42, height: 42)).fill()

let promptAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 186, weight: .bold),
    .foregroundColor: NSColor(red: 0.36, green: 0.90, blue: 0.55, alpha: 1)
]
NSString(string: "❯_").draw(at: NSPoint(x: 190, y: 366), withAttributes: promptAttributes)

NSGraphicsContext.restoreGraphicsState()

guard
    let outputImage = bitmapContext.makeImage(),
    let png = NSBitmapImageRep(cgImage: outputImage)
        .representation(using: .png, properties: [:])
else {
    fputs("Could not encode icon\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
