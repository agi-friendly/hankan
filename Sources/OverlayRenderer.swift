import AppKit

struct OverlayTranslation {
    let paragraph: OverlayParagraph
    let text: String
}

struct OverlayPaintResult {
    let image: NSImage
    let overflowIDs: Set<Int>
}

@MainActor
enum OverlayRenderer {
    static func render(image: CGImage, translations: [OverlayTranslation], displayScale: CGFloat) -> OverlayPaintResult {
        let scale = max(0.1, displayScale)
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let source = NSImage(cgImage: image, size: size)
        let pixels = NSBitmapImageRep(cgImage: image)
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var patches: [Patch] = []
        var overflowIDs: Set<Int> = []

        for translation in translations {
            let paragraph = translation.paragraph
            let rect = paragraph.bounds.intersection(imageBounds)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            let background = backgroundColor(pixels: pixels, rect: rect)
            let foreground: NSColor = luminance(background) < 0.45
                ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1)
            let logicalRect = CGRect(x: rect.minX / scale, y: rect.minY / scale,
                                     width: rect.width / scale, height: rect.height / scale)
            let heights = paragraph.lineBounds.map { $0.height / scale }.sorted()
            let lineHeight = heights.isEmpty ? logicalRect.height : heights[heights.count / 2]
            let fontSize = min(30, max(10, lineHeight * 0.94))
            let text = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Keep the translated paragraph inside its original footprint; growing
            // into adjacent comments would hide information the user did not select.
            let contentRect = logicalRect.insetBy(dx: 0.5, dy: 0)
            let fitted = fittingText(text, in: contentRect.size, preferredSize: fontSize, color: foreground)
            let padding = min(4 / scale, lineHeight * 0.16)
            let mask = logicalRect.insetBy(dx: -padding, dy: -padding)
                .intersection(CGRect(origin: .zero, size: size))
            let displayText: TextLayout
            let textRect: CGRect
            if let fitted = fitted {
                displayText = fitted
                textRect = contentRect
            } else {
                overflowIDs.insert(paragraph.id)
                // The caller opens the complete translation when this region is clicked.
                textRect = mask.insetBy(dx: 0.5, dy: 0)
                guard let hint = fittingText("번역 보기…", in: textRect.size, preferredSize: 12, color: foreground)
                    ?? fittingText("⋯", in: textRect.size, preferredSize: 12, color: foreground) else {
                    // Keep the source intact if even a visible hint cannot fit.
                    continue
                }
                displayText = hint
            }
            patches.append(Patch(mask: mask, textRect: textRect, background: background,
                                 text: displayText))
        }

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width,
                                             pixelsHigh: image.height, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return OverlayPaintResult(image: source, overflowIDs: Set(translations.map { $0.paragraph.id }))
        }
        bitmap.size = size
        // Render once at the capture's pixel resolution. Lazy NSImage drawing can
        // replay TextKit layouts in different backing contexts during image export.
        NSGraphicsContext.saveGraphicsState()
        let context = bitmapContext.cgContext
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        source.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: true, hints: nil)
        for patch in patches {
            patch.background.setFill()
            patch.mask.fill()
            NSGraphicsContext.saveGraphicsState()
            patch.textRect.clip()
            patch.text.draw(at: patch.textRect.origin)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        let rendered = NSImage(size: size)
        rendered.addRepresentation(bitmap)
        return OverlayPaintResult(image: rendered, overflowIDs: overflowIDs)
    }

    private struct Patch {
        let mask: CGRect
        let textRect: CGRect
        let background: NSColor
        let text: TextLayout
    }

    private static func styledText(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: style
        ])
    }

    private static func fittingText(_ text: String, in size: NSSize, preferredSize: CGFloat, color: NSColor) -> TextLayout? {
        guard size.width > 0, size.height > 0 else { return nil }
        var pointSize = max(10, preferredSize)
        while true {
            let candidate = styledText(text, size: pointSize, color: color)
            let layout = TextLayout(text: candidate, size: size)
            if layout.fits { return layout }
            if pointSize == 10 { return nil }
            pointSize = max(10, pointSize - 0.5)
        }
    }

    private final class TextLayout {
        private let storage: NSTextStorage
        private let manager = NSLayoutManager()
        private let container: NSTextContainer
        private let glyphs: NSRange
        let fits: Bool

        init(text: NSAttributedString, size: NSSize) {
            storage = NSTextStorage(attributedString: text)
            // An unbounded measuring height prevents TextKit from accepting a
            // partially clipped first/last line as if it occupied the whole box.
            container = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byWordWrapping
            manager.usesFontLeading = true
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            glyphs = manager.glyphRange(for: container)
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let used = manager.usedRect(for: container)
            let ink = manager.boundingRect(forGlyphRange: glyphs, in: container)
            // Measure and draw the SAME glyph layout. Separate NSString measurement
            // and drawing can disagree for Korean fallback fonts and lose a final line.
            fits = NSMaxRange(glyphs) == manager.numberOfGlyphs
                && NSMaxRange(characters) == storage.length
                && max(used.maxX, ink.maxX) <= size.width + 0.01
                && max(used.maxY, ink.maxY) <= size.height + 0.01
        }

        func draw(at origin: NSPoint) {
            manager.drawBackground(forGlyphRange: glyphs, at: origin)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
    }

    private static func backgroundColor(pixels: NSBitmapImageRep, rect: CGRect) -> NSColor {
        // Border samples are less likely to contain glyphs than the rectangle centre.
        // A dominant quantized colour avoids white letters corrupting a dark surface.
        var groups: [Int: [(CGFloat, CGFloat, CGFloat)]] = [:]
        let steps = max(8, min(48, Int(rect.width / 8)))
        func sample(_ x: CGFloat, _ y: CGFloat) {
            let px = min(max(Int(x.rounded()), 0), pixels.pixelsWide - 1)
            let py = min(max(Int(y.rounded()), 0), pixels.pixelsHigh - 1)
            guard let color = pixels.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { return }
            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
            let bucket = Int(r * 15) * 256 + Int(g * 15) * 16 + Int(b * 15)
            groups[bucket, default: []].append((r, g, b))
        }
        for index in 0...steps {
            let fraction = CGFloat(index) / CGFloat(steps)
            let x = rect.minX + rect.width * fraction
            let y = rect.minY + rect.height * fraction
            sample(x, rect.minY - 2)
            sample(x, rect.maxY + 2)
            sample(rect.minX - 2, y)
            sample(rect.maxX + 2, y)
        }
        guard let group = groups.values.max(by: { $0.count < $1.count }), !group.isEmpty else {
            return .black
        }
        let count = CGFloat(group.count)
        let sum = group.reduce((CGFloat(0), CGFloat(0), CGFloat(0))) { total, pixel in
            (total.0 + pixel.0, total.1 + pixel.1, total.2 + pixel.2)
        }
        return NSColor(deviceRed: sum.0 / count, green: sum.1 / count, blue: sum.2 / count, alpha: 1)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        return rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722
    }
}
