import AppKit

// Bundled pre-rendered white glyphs (Resources/*.png):
//  - claude.png: real Claude starburst, recolored white
//  - openai.svg: OpenAI (ChatGPT) logo, LobeHub icons-static-svg 1.95.0,
//    drawn white for the menubar
//  - figma.png: F mark, drawn white from the official path data
// Shown as-is (already white, transparent background) — no template,
// no code-drawn fallback.

private final class BundleToken {}

enum ProviderIcons {
    static func claude() -> NSImage? {
        bundled(named: "claude")
    }

    static func openAI() -> NSImage? {
        guard let svg = bundled(named: "openai", ext: "svg") else { return nil }
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
            fit(svg, in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }

    static func figma() -> NSImage? {
        bundled(named: "figma")
    }

    /// Dropdown icon, 16×16 in colour: Claude starburst tinted brand orange,
    /// OpenAI mark as a template (black/white with the menu), Figma "F" drawn
    /// in its five brand colours.
    static func menuIcon(_ provider: String) -> NSImage? {
        let box = NSSize(width: 16, height: 16)
        switch provider {
        case "claude":
            guard let glyph = claude() else { return nil }
            return NSImage(size: box, flipped: false) { r in
                fit(glyph, in: r)
                NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).set() // #D97757
                r.fill(using: .sourceAtop)
                return true
            }
        case "openai":
            guard let glyph = bundled(named: "openai", ext: "svg") else { return nil }
            let img = NSImage(size: box, flipped: false) { r in fit(glyph, in: r); return true }
            img.isTemplate = true
            return img
        case "figma":
            return NSImage(size: box, flipped: false) { _ in
                // 2×3 grid of 5-pt cells; each piece = circle + square filling its flat side.
                let u: CGFloat = 5, ox: CGFloat = 3, oy: CGFloat = 0.5
                func piece(_ hex: UInt32, circle cx: CGFloat, _ cy: CGFloat, rect: NSRect?) {
                    NSColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                            blue: CGFloat(hex & 0xFF) / 255, alpha: 1).set()
                    NSBezierPath(ovalIn: NSRect(x: ox + (cx - 0.5) * u, y: oy + (cy - 0.5) * u, width: u, height: u)).fill()
                    if let rect {
                        NSRect(x: ox + rect.minX * u, y: oy + rect.minY * u,
                               width: rect.width * u, height: rect.height * u).fill()
                    }
                }
                piece(0xF24E1E, circle: 0.5, 2.5, rect: NSRect(x: 0.5, y: 2, width: 0.5, height: 1))
                piece(0xFF7262, circle: 1.5, 2.5, rect: NSRect(x: 1, y: 2, width: 0.5, height: 1))
                piece(0xA259FF, circle: 0.5, 1.5, rect: NSRect(x: 0.5, y: 1, width: 0.5, height: 1))
                piece(0x1ABCFE, circle: 1.5, 1.5, rect: nil)
                piece(0x0ACF83, circle: 0.5, 0.5, rect: NSRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
                return true
            }
        default:
            return nil
        }
    }

    /// Draws `glyph` aspect-fit and centred in `r`.
    private static func fit(_ glyph: NSImage, in r: NSRect) {
        guard glyph.size.width > 0, glyph.size.height > 0 else { return }
        let scale = min(r.width / glyph.size.width, r.height / glyph.size.height)
        let w = glyph.size.width * scale, h = glyph.size.height * scale
        glyph.draw(in: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
    }

    private static func bundled(named: String, ext: String = "png") -> NSImage? {
        for bundle in [Bundle.main, Bundle(for: BundleToken.self)] {
            if let url = bundle.url(forResource: named, withExtension: ext),
               let img = NSImage(contentsOf: url)
            {
                img.isTemplate = false
                return img
            }
        }
        return nil
    }
}
