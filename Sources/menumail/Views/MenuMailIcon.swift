import AppKit

/// MenuMail's icons, drawn in code so the menu bar glyph, the app icon (rendered into
/// AppIcon.icns at build time via `--render-iconset`) and the logo PNGs share one design.
///
/// The design: a white envelope hanging from a menu bar strip like a popover, on a blue tile,
/// with a red new-mail dot. The menu bar glyph is a small blue version with a red count pill.
enum MenuMailIcon {
    /// The menu bar item: the glyph, plus a red pill with the new-mail count when there is one.
    static func menuBar(count: String?) -> NSImage {
        let glyphSize: CGFloat = 18
        let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let text = count.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.white]) }
        let pillHeight: CGFloat = 14
        let pillWidth = text.map { max(pillHeight, ceil($0.size().width) + 8) } ?? 0
        let gap: CGFloat = text == nil ? 0 : 3
        let size = NSSize(width: glyphSize + gap + pillWidth, height: glyphSize)

        let image = NSImage(size: size, flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            drawMenuBarGlyph(in: NSRect(x: 0, y: 0, width: glyphSize, height: glyphSize))
            NSGraphicsContext.restoreGraphicsState()
            if let text {
                let pill = NSRect(x: glyphSize + gap, y: (glyphSize - pillHeight) / 2, width: pillWidth, height: pillHeight)
                dot.setFill()
                NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
                let textSize = text.size()
                text.draw(at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2))
            }
            return true
        }
        image.isTemplate = false  // Keep the colors instead of tinting to the menu bar style.
        image.accessibilityDescription = count.map { "MenuMail, \($0) new" } ?? "MenuMail"
        return image
    }

    nonisolated static func appIcon(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            drawAppIcon(in: rect)
            return true
        }
    }

    /// The tile alone, edge to edge (no icon margin or shadow), as a PNG: for places like the
    /// logo on Google's consent screen.
    nonisolated static func logoPNG(pixels: Int) -> Data {
        let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: true) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 824)
            transform.translateX(by: -100, yBy: -100)
            transform.concat()
            drawAppIcon(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
            return true
        }
        return png(image, pixels: pixels)
    }

    /// Writes the PNG sizes `iconutil -c icns` expects into `directory` (an .iconset folder).
    nonisolated static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png(appIcon(size: NSSize(width: pixels, height: pixels)), pixels: pixels)
                    .write(to: directory.appending(path: name))
            }
        }
    }

    nonisolated static func png(_ image: NSImage, pixels: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: Drawing (y-down coordinates)

    nonisolated private static let tileTop = NSColor(srgbRed: 0.310, green: 0.486, blue: 1.000, alpha: 1)  // #4F7CFF
    nonisolated private static let tileBottom = NSColor(srgbRed: 0.137, green: 0.263, blue: 0.784, alpha: 1)  // #2343C8
    nonisolated private static let flap = NSColor(srgbRed: 0.184, green: 0.357, blue: 0.910, alpha: 1)  // #2F5BE8
    nonisolated private static let dot = NSColor(srgbRed: 1.000, green: 0.353, blue: 0.306, alpha: 1)  // #FF5A4E

    /// 24×24 grid: a blue menu bar strip above a blue envelope with a white flap. Blue reads on
    /// both light and dark menu bars.
    nonisolated private static func drawMenuBarGlyph(in rect: NSRect) {
        scale(to: rect, grid: 24)
        tileTop.setFill()
        NSBezierPath(roundedRect: NSRect(x: 3, y: 2.5, width: 18, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
        let body = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 7.5, width: 17, height: 13), xRadius: 2.8, yRadius: 2.8)
        NSGradient(starting: tileTop, ending: tileBottom)?.draw(in: body, angle: 90)
        NSColor.white.setStroke()
        stroke([NSPoint(x: 6, y: 10), NSPoint(x: 12, y: 14.5), NSPoint(x: 18, y: 10)], width: 1.8)
    }

    /// 1024×1024 grid on Apple's icon template (824pt tile inset by 100).
    nonisolated private static func drawAppIcon(in rect: NSRect) {
        scale(to: rect, grid: 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        withShadow(alpha: 0.28, blur: 28, offset: -10) {
            tileBottom.setFill()
            tile.fill()
        }
        NSGradient(starting: tileTop, ending: tileBottom)?.draw(in: tile, angle: 90)

        // The menu bar strip, with the status item the envelope drops down from.
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: 190, y: 230, width: 644, height: 92), xRadius: 46, yRadius: 46).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 478, y: 250, width: 52, height: 52)).fill()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 462, y: 392))
        arrow.line(to: NSPoint(x: 504, y: 350))
        arrow.line(to: NSPoint(x: 546, y: 392))
        arrow.close()
        arrow.fill()

        // The envelope.
        let body = NSRect(x: 250, y: 388, width: 524, height: 380)
        NSBezierPath(roundedRect: body, xRadius: 64, yRadius: 64).fill()
        flap.setStroke()
        stroke([NSPoint(x: body.minX + 45, y: body.minY + 40), NSPoint(x: body.midX, y: body.minY + body.height * 0.55),
                NSPoint(x: body.maxX - 45, y: body.minY + 40)], width: 44)

        // The new-mail dot.
        withShadow(alpha: 0.25, blur: 12, offset: -4) {
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: 680, y: 336, width: 148, height: 148)).fill()
        }
    }

    nonisolated private static func stroke(_ points: [NSPoint], width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    nonisolated private static func withShadow(alpha: CGFloat, blur: CGFloat, offset: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: offset)
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    nonisolated private static func scale(to rect: NSRect, grid: CGFloat) {
        let factor = min(rect.width, rect.height) / grid
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX - grid / 2 * factor, yBy: rect.midY - grid / 2 * factor)
        transform.scale(by: factor)
        transform.concat()
    }
}
