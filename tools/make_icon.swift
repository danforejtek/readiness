// Draws the Readiness app icon (light, dark and tinted variants, 1024×1024, opaque) into the asset catalog.
// Run from the project root:  swift tools/make_icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = "ReadinessApp/ReadinessApp/Assets.xcassets/AppIcon.appiconset"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

struct Style { let bgTop: CGColor; let bgBottom: CGColor; let ring: CGColor; let track: CGColor; let line: CGColor }

func draw(_ style: Style, to name: String) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let s = CGFloat(size)
    // background (origin bottom-left)
    let grad = CGGradient(colorsSpace: space, colors: [style.bgBottom, style.bgTop] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: s * 0.3, y: s),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let c = CGPoint(x: s / 2, y: s / 2)
    let r: CGFloat = 330
    ctx.setLineCap(.round)
    // ring track and 3/4 score arc, starting at 12 o'clock going clockwise
    ctx.setLineWidth(72)
    ctx.setStrokeColor(style.track)
    ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(style.ring)
    ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.5, clockwise: true)
    ctx.strokePath()

    // heartbeat line across the centre
    let pts: [(CGFloat, CGFloat)] = [(-215, 0), (-95, 0), (-60, 40), (-30, 0), (0, 0), (30, 175), (75, -165),
                                    (110, 30), (130, 0), (215, 0)]
    ctx.setLineWidth(46)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(style.line)
    ctx.move(to: CGPoint(x: c.x + pts[0].0, y: c.y + pts[0].1))
    for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: c.x + p.0, y: c.y + p.1)) }
    ctx.strokePath()

    let url = URL(fileURLWithPath: "\(out)/\(name)")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest), "could not write \(name)")
    print("wrote", name)
}

draw(Style(bgTop: rgb(0x0E7490), bgBottom: rgb(0x166534), ring: rgb(0xFFFFFF), track: rgb(0xFFFFFF, 0.22),
           line: rgb(0xFFFFFF)), to: "icon-light.png")
draw(Style(bgTop: rgb(0x111827), bgBottom: rgb(0x020617), ring: rgb(0x34D399), track: rgb(0x34D399, 0.20),
           line: rgb(0x5EEAD4)), to: "icon-dark.png")
draw(Style(bgTop: rgb(0x000000), bgBottom: rgb(0x000000), ring: rgb(0xFFFFFF), track: rgb(0xFFFFFF, 0.25),
           line: rgb(0xFFFFFF)), to: "icon-tinted.png")

let contents = """
{
  "images" : [
    { "filename" : "icon-light.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "icon-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
      "filename" : "icon-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contents.write(toFile: "\(out)/Contents.json", atomically: true, encoding: .utf8)
try! #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(
    toFile: "ReadinessApp/ReadinessApp/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
print("wrote Contents.json")
