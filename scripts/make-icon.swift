// Renders Resources/AppIcon.icns, an open eye in the night sky. scripts/build.sh runs it when the icon is missing.
import AppKit

func superellipse(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...720 {
        let t = CGFloat(step) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(x: rect.midX + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n),
                            y: rect.midY + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n))
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func eye(center: CGPoint, width: CGFloat, height: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let left = CGPoint(x: center.x - width / 2, y: center.y), right = CGPoint(x: center.x + width / 2, y: center.y)
    let reach = height * 0.67
    path.move(to: left)
    path.addCurve(to: right, control1: CGPoint(x: center.x - width * 0.24, y: center.y + reach),
                  control2: CGPoint(x: center.x + width * 0.24, y: center.y + reach))
    path.addCurve(to: left, control1: CGPoint(x: center.x + width * 0.24, y: center.y - reach),
                  control2: CGPoint(x: center.x - width * 0.24, y: center.y - reach))
    path.closeSubpath()
    return path
}

func render(size: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.interpolationQuality = .high

    let body = superellipse(in: CGRect(x: 100, y: 100, width: 824, height: 824))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.3))
    context.addPath(body)
    context.setFillColor(color(0x161A45))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()
    let sky = CGGradient(colorsSpace: space, colors: [color(0x2E3486), color(0x0E1033)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0x7C8CFF, 0.42), color(0x7C8CFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 500), endRadius: 430, options: [])
    for (x, y, r, a) in [(262.0, 790.0, 6.0, 0.9), (356, 842, 3.5, 0.6), (690, 812, 5, 0.8), (790, 728, 3.5, 0.55),
                         (214, 664, 3, 0.5), (838, 610, 4, 0.6), (300, 246, 3.5, 0.45), (742, 222, 4.5, 0.5)] {
        context.setFillColor(color(0xFFFFFF, a))
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    let center = CGPoint(x: 512, y: 500)
    let white = eye(center: center, width: 600, height: 330)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: color(0x000000, 0.45))
    context.addPath(white)
    context.setFillColor(color(0xEEF1FF))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(white)
    context.clip()
    let sclera = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xD6DCF7)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sclera, start: CGPoint(x: 512, y: 670), end: CGPoint(x: 512, y: 330), options: [])
    // The iris is a small night sky with a crescent moon.
    let iris = CGRect(x: center.x - 136, y: center.y - 136, width: 272, height: 272)
    context.saveGState()
    context.addEllipse(in: iris)
    context.clip()
    let night = CGGradient(colorsSpace: space, colors: [color(0x1E2670), color(0x0B0E33)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(night, startCenter: center, startRadius: 0, endCenter: center, endRadius: 136, options: [])
    for (x, y, r, a) in [(452.0, 420.0, 3.0, 0.7), (600, 568, 2.5, 0.55), (430, 562, 2, 0.45)] {
        context.setFillColor(color(0xFFFFFF, a))
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    let crescent = CGPath(ellipseIn: CGRect(x: 426, y: 432, width: 156, height: 156), transform: nil)
        .subtracting(CGPath(ellipseIn: CGRect(x: 400, y: 470, width: 140, height: 140), transform: nil))
    context.saveGState()
    context.setShadow(offset: .zero, blur: 36, color: color(0xFFD27A, 0.8))
    context.addPath(crescent)
    context.setFillColor(color(0xFFE2A0))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(crescent)
    context.clip()
    let gold = CGGradient(colorsSpace: space, colors: [color(0xFFF3D2), color(0xF4BC55)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gold, start: CGPoint(x: 586, y: 578), end: CGPoint(x: 496, y: 432),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    context.setStrokeColor(color(0x0A0D30, 0.55))
    context.setLineWidth(5)
    context.strokeEllipse(in: iris.insetBy(dx: 2.5, dy: 2.5))
    // The upper lid casts a soft shadow onto the eye.
    let lid = CGGradient(colorsSpace: space, colors: [color(0x10133D, 0.35), color(0x10133D, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(lid, start: CGPoint(x: 512, y: 720), end: CGPoint(x: 512, y: 560), options: [])
    context.restoreGState()
    context.restoreGState()

    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! render(size: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try! render(size: 1024).write(to: URL(fileURLWithPath: "build/AppIcon-1024.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
