import AppKit

/// One template image for the menu bar. `MenuBarExtra` clips a stack after the
/// first pair, and `Text` + `Image` drops SF Symbols, so both symbols and
/// percents are drawn into a single bitmap.
enum StatusItemArtwork {
    static func image(for parts: StatusItemParts) -> NSImage? {
        image(tokens: parts.tokens(memorySymbol: resolvedMemorySymbol()))
    }

    static func resolvedMemorySymbol() -> String {
        for name in [StatusItemParts.memorySymbol, StatusItemParts.memorySymbolFallback] {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                return name
            }
        }
        return StatusItemParts.memorySymbol
    }

    static func image(tokens: [StatusItemParts.Token]) -> NSImage? {
        guard !tokens.isEmpty else { return nil }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))

        struct Run {
            var image: NSImage?
            var text: NSString
            var textWidth: CGFloat
            var imageSize: NSSize
        }

        let runs: [Run] = tokens.map { token in
            let text = (token.symbol == nil ? " \(token.text) " : " \(token.text)") as NSString
            let textSize = text.size(withAttributes: attributes)
            let symbol = token.symbol.flatMap { name in
                NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfiguration)
            }
            return Run(
                image: symbol,
                text: text,
                textWidth: ceil(textSize.width),
                imageSize: symbol?.size ?? .zero
            )
        }

        let pad: CGFloat = 1
        let width = pad + runs.reduce(CGFloat(0)) { $0 + $1.imageSize.width + $1.textWidth } + pad
        let contentHeight = runs.map { max($0.imageSize.height, $0.text.size(withAttributes: attributes).height) }.max() ?? 0
        let height = max(ceil(contentHeight), 1)
        let size = NSSize(width: max(ceil(width), 1), height: height)
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)

        var x = pad
        for run in runs {
            if let symbol = run.image, run.imageSize.width > 0 {
                let y = (height - run.imageSize.height) / 2
                symbol.draw(
                    in: NSRect(x: x, y: y, width: run.imageSize.width, height: run.imageSize.height),
                    from: NSRect(origin: .zero, size: run.imageSize),
                    operation: .sourceOver,
                    fraction: 1
                )
                x += run.imageSize.width
            }
            let textHeight = run.text.size(withAttributes: attributes).height
            run.text.draw(at: NSPoint(x: x, y: (height - textHeight) / 2), withAttributes: attributes)
            x += run.textWidth
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }
}
