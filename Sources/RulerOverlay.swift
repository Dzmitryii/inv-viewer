import AppKit

enum RulerOverlay {
    @MainActor
    static func draw(in context: CGContext, first: CGPoint, second: CGPoint?, distance: Double?, viewport: CGRect) {
        let color = NSColor.systemYellow
        if let second, let distance {
            for (stroke, width) in [(NSColor.black.withAlphaComponent(0.8), 3.0), (color, 1.25)] {
                context.setStrokeColor(stroke.cgColor)
                context.setLineWidth(width)
                context.move(to: first)
                context.addLine(to: second)
                context.strokePath()
            }
            let number = distance.formatted(.number.precision(.fractionLength(1)))
            let caption = NSAttributedString(string: String(localized: " \(number) мм "), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: color,
                .backgroundColor: NSColor.black.withAlphaComponent(0.9)
            ])
            let size = caption.size()
            if viewport.width >= size.width, viewport.height >= size.height {
                caption.draw(at: CGPoint(
                    x: min(viewport.maxX - size.width, max(viewport.minX, (first.x + second.x - size.width) / 2)),
                    y: min(viewport.maxY - size.height, max(viewport.minY, (first.y + second.y) / 2 + 6))
                ))
            }
        }
        context.setFillColor(color.cgColor)
        for point in [first, second].compactMap({ $0 }) {
            context.fillEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        }
    }
}
