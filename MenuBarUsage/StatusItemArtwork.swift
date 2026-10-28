import AppKit

/// Menu bar artwork. A SwiftUI stack clips after the CPU pair, and `Text` +
/// `Image` drops SF Symbols. A hand-scaled bitmap shears the digits, so this
/// lays the line out with AppKit text in a flipped image and does not touch
/// the context transform.
enum StatusItemArtwork {
    static let menuPointSize: CGFloat = 13

    static func image(for parts: StatusItemParts, pointSize: CGFloat = menuPointSize) -> NSImage? {
        let string = attributed(parts.tokens(memorySymbol: resolvedMemorySymbol()), pointSize: pointSize)
        guard string.length > 0 else { return nil }
        let bounds = string.boundingRect(
            with: NSSize(width: 4_000, height: 800),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let size = NSSize(width: ceil(bounds.width) + 2, height: ceil(bounds.height) + 4)
        guard size.width > 1, size.height > 1 else { return nil }
        let image = NSImage(size: size, flipped: true) { rect in
            string.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Writes a 4× preview of the `36%` / `68%` label. Same drawing path as the menu bar.
    static func writePreview(to url: URL) -> Int32 {
        let sample = UsageFormatting.statusItem(cpu: 36, memory: 68)
        guard let menu = image(for: sample),
              let preview = image(for: sample, pointSize: menuPointSize * 4),
              let png = previewPNG(of: preview) else {
            fputs("Could not draw the status item.\n", stderr)
            return 1
        }
        do {
            try png.write(to: url)
        } catch {
            fputs("Could not write \(url.path): \(error.localizedDescription)\n", stderr)
            return 1
        }
        let point = menu.size
        print("status image \(Int(point.width))×\(Int(point.height)) pt, 4× preview \(url.path)")
        return 0
    }

    static func resolvedMemorySymbol() -> String {
        for name in [StatusItemParts.memorySymbol, StatusItemParts.memorySymbolFallback] {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                return name
            }
        }
        return StatusItemParts.memorySymbol
    }

    private static func attributed(_ tokens: [StatusItemParts.Token], pointSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .medium)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let string = NSMutableAttributedString()
        for token in tokens {
            if let name = token.symbol,
               let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                symbol.isTemplate = false
                let attachment = NSTextAttachment()
                attachment.image = symbol
                let baseline = (font.capHeight - symbol.size.height) / 2
                attachment.bounds = NSRect(x: 0, y: baseline, width: symbol.size.width, height: symbol.size.height)
                string.append(NSAttributedString(attachment: attachment))
                string.append(NSAttributedString(string: " \(token.text)", attributes: textAttributes))
            } else {
                string.append(NSAttributedString(string: " \(token.text) ", attributes: textAttributes))
            }
        }
        return string
    }

    private static func previewPNG(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        guard let matte = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: rep.pixelsWide,
            pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        matte.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: matte)
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)).fill()
        let painted = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        painted.addRepresentation(rep)
        painted.isTemplate = false
        painted.draw(
            in: NSRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        )
        NSGraphicsContext.restoreGraphicsState()
        return matte.representation(using: .png, properties: [:])
    }
}
