import AppKit

/// Programmatically drawn application icon (a SwiftPM executable has no
/// asset catalog): macOS-style squircle with a blue→violet gradient, a soft
/// top sheen, and a white git-branch glyph.
enum AppIcon {
    static func make(size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        // macOS icon grid: the squircle occupies ~824/1024 with even margins.
        let margin = size * 100 / 1024
        let rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
        let radius = rect.width * 0.2237
        let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // Subtle drop shadow behind the tile.
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = size * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
        shadow.set()
        NSColor.black.setFill()
        squircle.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Background gradient (top → bottom).
        NSGradient(
            starting: NSColor(calibratedRed: 0.20, green: 0.51, blue: 0.99, alpha: 1),
            ending: NSColor(calibratedRed: 0.40, green: 0.20, blue: 0.85, alpha: 1)
        )?.draw(in: squircle, angle: -90)

        // Soft sheen across the upper half.
        NSGradient(
            starting: NSColor.white.withAlphaComponent(0.14),
            ending: NSColor.white.withAlphaComponent(0)
        )?.draw(in: squircle, angle: -90)

        // White git-branch glyph.
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.width * 0.4, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(
            systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "GitBrowser"
        )?.withSymbolConfiguration(configuration) {
            let targetWidth = rect.width * 0.56
            let scale = targetWidth / symbol.size.width
            let targetHeight = symbol.size.height * scale
            let glyphShadow = NSShadow()
            glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            glyphShadow.shadowBlurRadius = size * 0.012
            glyphShadow.shadowOffset = NSSize(width: 0, height: -size * 0.006)
            NSGraphicsContext.current?.saveGraphicsState()
            glyphShadow.set()
            symbol.draw(in: NSRect(
                x: rect.midX - targetWidth / 2,
                y: rect.midY - targetHeight / 2,
                width: targetWidth,
                height: targetHeight
            ))
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        return image
    }
}
