// Renders the LyricsBar app icon: a Touch Bar–like rounded strip with a music note, on a macOS squircle.
// usage: swift make_icon.swift <out.png> [size]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S = CGFloat(CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 1024)
let k = S / 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }

// 1. macOS icon body (824pt rounded rect on the 1024 grid): deep indigo night
let body = NSRect(x: 100*k, y: 100*k, width: 824*k, height: 824*k)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186*k, yRadius: 186*k)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10*k), blur: 28*k, color: c(0,0,0,0.45).cgColor)
c(16,14,34).setFill(); bodyPath.fill()
ctx.restoreGState()
ctx.saveGState(); bodyPath.addClip()
NSGradient(colors: [c(40,32,78), c(14,12,30)])!.draw(in: body, angle: -90)
NSGradient(colors: [c(255,255,255,0.08), c(255,255,255,0)])!.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height/2), angle: -90)
ctx.restoreGState()

// 2. the bar: big rounded strip with a sunset glow (violet → pink → amber)
let bar = NSRect(x: 136*k, y: 372*k, width: 752*k, height: 280*k)
let rad = 64*k
let barPath = NSBezierPath(roundedRect: bar, xRadius: rad, yRadius: rad)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70*k, color: c(255,90,160,0.45).cgColor)
c(20,14,40).setFill(); barPath.fill()
ctx.restoreGState()
ctx.saveGState(); barPath.addClip()
NSGradient(colors: [c(92,62,255), c(196,74,220), c(255,96,150), c(255,170,88)],
           atLocations: [0, 0.38, 0.68, 1], colorSpace: .sRGB)!.draw(in: bar, angle: 0)
// darken the bottom a little for depth, sheen on top
NSGradient(colors: [c(10,6,30,0.45), c(10,6,30,0)])!.draw(in: NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: bar.height*0.6), angle: 90)
NSGradient(colors: [c(255,255,255,0.18), c(255,255,255,0)])!.draw(in: NSRect(x: bar.minX, y: bar.midY + bar.height*0.1, width: bar.width, height: bar.height*0.4), angle: -90)

// 3. visualizer bars behind the note (a smooth "spectrum": fuller in the lows, tapering to the highs)
let n = 30
let gap = 9*k
let inset = 34*k
let w = (bar.width - 2*inset - CGFloat(n-1)*gap) / CGFloat(n)
for i in 0..<n {
    let x = CGFloat(i) / CGFloat(n-1)
    let shape = 0.35 + 0.55*exp(-pow((x - 0.25)/0.28, 2)) + 0.25*exp(-pow((x - 0.7)/0.15, 2))
    let wobble = 0.18*sin(CGFloat(i)*2.3) + 0.12*sin(CGFloat(i)*5.1 + 1)
    let h = max(0.12, min(0.95, shape + wobble)) * (bar.height - 60*k)
    let r = NSRect(x: bar.minX + inset + CGFloat(i)*(w+gap), y: bar.midY - h/2, width: w, height: h)
    c(255,255,255,0.30).setFill()
    NSBezierPath(roundedRect: r, xRadius: w/2, yRadius: w/2).fill()
}
// soft dark pool behind the note so it stays readable over the bars
let pool = NSGradient(colors: [c(30,12,50,0.55), c(30,12,50,0)])!
pool.draw(fromCenter: NSPoint(x: bar.midX, y: bar.midY), radius: 0,
          toCenter: NSPoint(x: bar.midX, y: bar.midY), radius: 190*k, options: [])
ctx.restoreGState()
c(255,255,255,0.22).setStroke()
let rim = NSBezierPath(roundedRect: bar.insetBy(dx: 1.5*k, dy: 1.5*k), xRadius: rad-1.5*k, yRadius: rad-1.5*k); rim.lineWidth = 3*k; rim.stroke()

// 4. a single eighth note (♪), centred on its actual ink bounds (not the font's line box)
let font = NSFont.systemFont(ofSize: 230*k, weight: .black)
let glyph = NSAttributedString(string: "\u{266A}", attributes: [.font: font, .foregroundColor: NSColor.white])
let line = CTLineCreateWithAttributedString(glyph)
let ink = CTLineGetImageBounds(line, ctx)          // tight bounds of the drawn shape
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4*k), blur: 18*k, color: c(40,0,60,0.6).cgColor)
ctx.textPosition = CGPoint(x: bar.midX - ink.width/2 - ink.minX, y: bar.midY - ink.height/2 - ink.minY)
CTLineDraw(line, ctx)
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
