// Рисует иконку приложения: карточка контакта + лупа.
// Запуск: swift scripts/make-icon.swift <out.png>   (1024×1024)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Подложка по сетке macOS: 824×824 в холсте 1024, скругление ~185, мягкая тень.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
color(0x2F5BE0).setFill()
tilePath.fill()
ctx.restoreGState()
ctx.saveGState()
tilePath.addClip()
NSGradient(starting: color(0x5AA2FF), ending: color(0x2442C9))!.draw(in: tile, angle: -90)
// лёгкий блик сверху
NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
    .draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
ctx.restoreGState()

// Карточка контакта
let card = CGRect(x: 232, y: 262, width: 470, height: 520)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor.white.setFill()
NSBezierPath(roundedRect: card, xRadius: 56, yRadius: 56).fill()
ctx.restoreGState()

// Аватар
let avatar = CGRect(x: card.midX - 95, y: card.maxY - 60 - 190, width: 190, height: 190)
color(0xDCE8FF).setFill()
NSBezierPath(ovalIn: avatar).fill()
ctx.saveGState()
NSBezierPath(ovalIn: avatar).addClip()
color(0x6E8DD6).setFill()
NSBezierPath(ovalIn: CGRect(x: avatar.midX - 42, y: avatar.midY - 12, width: 84, height: 84)).fill()
NSBezierPath(ovalIn: CGRect(x: avatar.midX - 82, y: avatar.minY - 70, width: 164, height: 150)).fill()
ctx.restoreGState()

// Строки «полей»
let rows: [(CGFloat, UInt32)] = [(300, 0xB9C6E4), (230, 0xD3DCEF), (270, 0xD3DCEF), (190, 0xD3DCEF)]
var y = avatar.minY - 70
for (i, (w, c)) in rows.enumerated() {
    color(c).setFill()
    let h: CGFloat = i == 0 ? 34 : 26
    NSBezierPath(roundedRect: CGRect(x: card.minX + 60, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    y -= i == 0 ? 62 : 50
}

// Лупа
let center = CGPoint(x: 630, y: 400)
let r: CGFloat = 138
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
// ручка
let angle = -CGFloat.pi / 4
let start = CGPoint(x: center.x + cos(angle) * (r + 10), y: center.y + sin(angle) * (r + 10))
let end = CGPoint(x: center.x + cos(angle) * (r + 150), y: center.y + sin(angle) * (r + 150))
let handle = NSBezierPath()
handle.move(to: start); handle.line(to: end)
handle.lineWidth = 62; handle.lineCapStyle = .round
color(0xFF9F0A).setStroke()
handle.stroke()
// кольцо
let ring = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
ring.lineWidth = 46
color(0xFFB340).setStroke()
ring.stroke()
ctx.restoreGState()
// стекло: лёгкий тон и «увеличенная» строка поля под лупой
let lens = NSBezierPath(ovalIn: CGRect(x: center.x - r + 23, y: center.y - r + 23, width: 2 * (r - 23), height: 2 * (r - 23)))
ctx.saveGState()
lens.addClip()
color(0xEAF2FF, 0.55).setFill()
lens.fill()
color(0x3F6FE8).setFill()
NSBezierPath(roundedRect: CGRect(x: center.x - 150, y: center.y + 8, width: 210, height: 52), xRadius: 26, yRadius: 26).fill()
color(0x9DB4EC).setFill()
NSBezierPath(roundedRect: CGRect(x: center.x - 150, y: center.y - 70, width: 260, height: 40), xRadius: 20, yRadius: 20).fill()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
