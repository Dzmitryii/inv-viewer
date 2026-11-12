import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ExportRuler {
    let first: SIMD2<Double>
    let second: SIMD2<Double>
    let distance: Double

    @MainActor
    func draw(in context: CGContext, rect: CGRect) {
        func point(_ unit: SIMD2<Double>) -> CGPoint {
            CGPoint(x: rect.minX + unit.x * rect.width, y: rect.maxY - unit.y * rect.height)
        }
        RulerOverlay.draw(in: context, first: point(first), second: point(second), distance: distance, viewport: rect)
    }
}

struct ExportFrame {
    let image: CGImage
    let aspect: Double
    let labels: [String]
    var ruler: ExportRuler? = nil
}

enum PNGExportError: Error { case unavailable }

enum PNGExport {
    @MainActor
    static func encode(_ frame: ExportFrame, includeRuler: Bool) throws -> Data {
        // Render at source resolution (or close to it for anisotropic voxels).
        // Only the image and trustworthy side labels enter the PNG.
        let bound = min(4096, frame.aspect >= 1 ?
            max(Double(frame.image.width), Double(frame.image.height) * frame.aspect) :
            max(Double(frame.image.height), Double(frame.image.width) / frame.aspect))
        let w = max(1, Int((bound * min(1, frame.aspect)).rounded()))
        let h = max(1, Int((bound * min(1, 1 / frame.aspect)).rounded()))
        let margin = frame.labels.count == 4 ? max(14, Int(bound / 24)) : 0
        guard let context = CGContext(data: nil, width: w + 2 * margin, height: h + 2 * margin,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw PNGExportError.unavailable }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w + 2 * margin, height: h + 2 * margin))
        context.interpolationQuality = .none
        let content = CGRect(x: margin, y: margin, width: w, height: h)
        context.draw(frame.image, in: content)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if includeRuler, let ruler = frame.ruler {
            context.saveGState()
            context.clip(to: content)
            ruler.draw(in: context, rect: content)
            context.restoreGState()
        }
        if margin > 0 {
            let m = CGFloat(margin)
            let centers = [CGPoint(x: m / 2, y: m + CGFloat(h) / 2), CGPoint(x: 1.5 * m + CGFloat(w), y: m + CGFloat(h) / 2),
                           CGPoint(x: m + CGFloat(w) / 2, y: 1.5 * m + CGFloat(h)), CGPoint(x: m + CGFloat(w) / 2, y: m / 2)]
            for (label, point) in zip(frame.labels, centers) {
                let text = NSAttributedString(string: label, attributes: [
                    .foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: m * 0.49, weight: .semibold)
                ])
                let size = text.size()
                text.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw PNGExportError.unavailable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PNGExportError.unavailable }
        return data as Data
    }
}

