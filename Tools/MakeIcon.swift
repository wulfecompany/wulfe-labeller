// Renders the Wülfe Labeller app icon to a 1024×1024 PNG.
// Usage: swift MakeIcon.swift output.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

/// macOS-style continuous "squircle" (superellipse).
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

let red = rgb(1, 0, 0)

// Full-bleed square: macOS 26 applies its own rounded mask. (An icon that's already
// rounded with transparent margins gets placed inside a grey frame instead.)
ctx.setFillColor(red)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.translateBy(x: 512, y: 512)
ctx.scaleBy(x: 1.34, y: 1.34)
ctx.translateBy(x: -512, y: -512)

// Document sheet with a folded corner.
let doc = CGRect(x: 512 - 200, y: 512 - 255, width: 400, height: 510)
let fold: CGFloat = 112
let radius: CGFloat = 34
let sheet = CGMutablePath()
sheet.move(to: CGPoint(x: doc.minX + radius, y: doc.minY))
sheet.addLine(to: CGPoint(x: doc.maxX - radius, y: doc.minY))
sheet.addQuadCurve(to: CGPoint(x: doc.maxX, y: doc.minY + radius), control: CGPoint(x: doc.maxX, y: doc.minY))
sheet.addLine(to: CGPoint(x: doc.maxX, y: doc.maxY - fold))
sheet.addLine(to: CGPoint(x: doc.maxX - fold, y: doc.maxY))
sheet.addLine(to: CGPoint(x: doc.minX + radius, y: doc.maxY))
sheet.addQuadCurve(to: CGPoint(x: doc.minX, y: doc.maxY - radius), control: CGPoint(x: doc.minX, y: doc.maxY))
sheet.addLine(to: CGPoint(x: doc.minX, y: doc.minY + radius))
sheet.addQuadCurve(to: CGPoint(x: doc.minX + radius, y: doc.minY), control: CGPoint(x: doc.minX, y: doc.minY))
sheet.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0.35, 0, 0, 0.35))
ctx.addPath(sheet)
ctx.setFillColor(rgb(1, 1, 1))
ctx.fillPath()
ctx.restoreGState()

// Folded corner flap.
let flap = CGMutablePath()
flap.move(to: CGPoint(x: doc.maxX - fold, y: doc.maxY))
flap.addLine(to: CGPoint(x: doc.maxX - fold, y: doc.maxY - fold + 18))
flap.addQuadCurve(to: CGPoint(x: doc.maxX - fold + 18, y: doc.maxY - fold), control: CGPoint(x: doc.maxX - fold, y: doc.maxY - fold))
flap.addLine(to: CGPoint(x: doc.maxX, y: doc.maxY - fold))
flap.closeSubpath()
ctx.addPath(flap)
ctx.setFillColor(rgb(1, 0.78, 0.78))
ctx.fillPath()

// Scan line position (y, in bottom-left coordinates). Lines below remain, above are wiped.
let scanY: CGFloat = 548

// Remaining "text" lines below the scan line.
let lineHeight: CGFloat = 30
let lineGap: CGFloat = 30
let widths: [CGFloat] = [300, 300, 236, 300, 180]
var y = scanY - 78
for w in widths {
    guard y - lineHeight > doc.minY + 36 else { break }
    let r = CGRect(x: doc.minX + 50, y: y - lineHeight, width: w, height: lineHeight)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
    ctx.setFillColor(rgb(1, 0, 0, 0.30))
    ctx.fillPath()
    y -= lineHeight + lineGap
}

// Scanner bar: a red "cut" with a white bar, extending past the sheet's edges.
let barHeight: CGFloat = 36
let cut: CGFloat = 16
let barRect = CGRect(x: 512 - 330, y: scanY - barHeight / 2, width: 660, height: barHeight)
ctx.addPath(CGPath(roundedRect: barRect.insetBy(dx: -cut, dy: -cut), cornerWidth: (barHeight + 2 * cut) / 2,
                   cornerHeight: (barHeight + 2 * cut) / 2, transform: nil))
ctx.setFillColor(red)
ctx.fillPath()

// Soft glow above the bar (the "wiped" area).
let glow = CGGradient(colorsSpace: cs, colors: [rgb(1, 0, 0, 0.16), rgb(1, 0, 0, 0)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addPath(sheet)
ctx.clip()
ctx.drawLinearGradient(glow, start: CGPoint(x: 0, y: scanY + barHeight / 2 + cut), end: CGPoint(x: 0, y: scanY + 150), options: [])
ctx.restoreGState()

ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
ctx.setFillColor(rgb(1, 1, 1))
ctx.fillPath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
