import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
let output = URL(fileURLWithPath: args.first ?? "Resources/AppIcon.icns")
let previewDir = args.dropFirst().first.map { URL(fileURLWithPath: $0) }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func notchPath(top: CGFloat, midX: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat, shoulder: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let l = midX - width / 2, r = midX + width / 2, bottom = top - height
    p.move(to: CGPoint(x: l - shoulder, y: top))
    p.addQuadCurve(to: CGPoint(x: l, y: top - shoulder), control: CGPoint(x: l, y: top))
    p.addLine(to: CGPoint(x: l, y: bottom + radius))
    p.addQuadCurve(to: CGPoint(x: l + radius, y: bottom), control: CGPoint(x: l, y: bottom))
    p.addLine(to: CGPoint(x: r - radius, y: bottom))
    p.addQuadCurve(to: CGPoint(x: r, y: bottom + radius), control: CGPoint(x: r, y: bottom))
    p.addLine(to: CGPoint(x: r, y: top - shoulder))
    p.addQuadCurve(to: CGPoint(x: r + shoulder, y: top), control: CGPoint(x: r, y: top))
    p.closeSubpath()
    return p
}

func spark(_ ctx: CGContext, center c: CGPoint, size: CGFloat, color: CGColor, width: CGFloat) {
    let k = size / 24
    let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(12, 3, 12, 21), (3, 12, 21, 12), (5.6, 5.6, 18.4, 18.4), (18.4, 5.6, 5.6, 18.4)]
    let o = CGPoint(x: c.x - size / 2, y: c.y - size / 2)
    for l in lines {
        ctx.move(to: CGPoint(x: o.x + l.0 * k, y: o.y + l.1 * k))
        ctx.addLine(to: CGPoint(x: o.x + l.2 * k, y: o.y + l.3 * k))
    }
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

func badge(_ ctx: CGContext, center c: CGPoint, diameter d: CGFloat, color: CGColor, small: Bool, ring: Bool = false, glow: CGColor? = nil, tiny: Bool = false) {
    let rect = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -d * 0.05), blur: d * 0.18, color: rgb(0x000000, 0.45))
        ctx.setFillColor(rgb(0x0C0D10))
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
    }
    ctx.setFillColor(rgb(0x0C0D10))
    ctx.fillEllipse(in: rect)
    if !small {
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
        ctx.setLineWidth(d * 0.02)
        ctx.strokeEllipse(in: rect.insetBy(dx: d * 0.01, dy: d * 0.01))
    }
    if ring {
        ctx.setStrokeColor(color.copy(alpha: 0.9)!)
        ctx.setLineWidth(d * (small ? 0.07 : 0.045))
        ctx.strokeEllipse(in: rect.insetBy(dx: d * 0.06, dy: d * 0.06))
    }
    let g = d * (tiny ? 0.86 : small ? 0.66 : 0.58)
    if let glow, !small {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: d * 0.12, color: glow)
        spark(ctx, center: c, size: g, color: color, width: g * (small ? 3.4 : 2.6) / 24)
        ctx.restoreGState()
    }
    spark(ctx, center: c, size: g, color: color, width: g * (tiny ? 4.4 : small ? 3.6 : 2.6) / 24)
}

func render(_ px: Int) -> CGImage {
    let size = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let small = px <= 32
    let inset: CGFloat = small ? 36 : 100
    let body = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let shape = squircle(body)
    let space = CGColorSpace(name: CGColorSpace.sRGB)

    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x1B1D22))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x464B57), rgb(0x2A2D35), rgb(0x18191E)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    if !small {
        let glow = CGGradient(colorsSpace: space, colors: [rgb(0xD97757, 0.22), rgb(0xD97757, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: body.minY + body.height * 0.36), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: body.minY + body.height * 0.36), endRadius: body.width * 0.55, options: [])
        let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY), options: [])
    }

    let notchW = body.width * (small ? 0.62 : 0.54)
    let notchH = body.height * (small ? 0.20 : 0.17)
    let notch = notchPath(top: body.maxY, midX: 512, width: notchW, height: notchH,
                          radius: notchH * 0.5, shoulder: notchH * 0.22)
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: rgb(0x000000, 0.5))
        ctx.addPath(notch)
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addPath(notch)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()

    let clay = rgb(0xD97757)
    let areaTop = body.maxY - notchH
    let cy = body.minY + (areaTop - body.minY) * 0.47
    let d = body.width * (small ? 0.66 : 0.56)
    badge(ctx, center: CGPoint(x: 512, y: cy), diameter: d, color: clay, small: small, ring: px > 16, glow: rgb(0xD97757, 0.6), tiny: px <= 16)
    ctx.restoreGState()

    if !small {
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("earshot-icon-\(getpid())")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
var cache: [Int: CGImage] = [:]
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let img = cache[px] ?? render(px)
        cache[px] = img
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(img, to: iconset.appendingPathComponent(name))
    }
}

if let png = cache[256] {
    writePNG(png, to: output.deletingPathExtension().appendingPathExtension("png"))
}

if let previewDir {
    try fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
    for (px, img) in cache { writePNG(img, to: previewDir.appendingPathComponent("icon-\(px).png")) }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output.path)")
