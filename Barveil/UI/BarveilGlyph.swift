// The menu-bar glyph is deliberately abstract: one horizontal bar above one
// play triangle. It is drawn as a template image so macOS handles light/dark
// menu bars and accessibility contrast automatically.

import AppKit

enum BarveilGlyphState {
    case off
    case ready
    case hiding
}

enum BarveilGlyph {
    static func menuBarImage(state: BarveilGlyphState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let alpha: CGFloat = state == .off ? 0.44 : 1
            let ink = NSColor.black.withAlphaComponent(alpha)
            ink.setFill()
            ink.setStroke()

            switch state {
            case .off:
                fillBar(x: 3.5, width: 11)
                strokeTriangle()
            case .ready:
                fillBar(x: 2.7, width: 12.6)
                fillTriangle()
            case .hiding:
                fillBar(x: 2.7, width: 5.1)
                fillBar(x: 10.2, width: 5.1)
                fillTriangle()
            }

            return true
        }
        image.isTemplate = true
        return image
    }

    private static func fillBar(x: CGFloat, width: CGFloat) {
        NSBezierPath(
            roundedRect: NSRect(x: x, y: 2.6, width: width, height: 1.8),
            xRadius: 0.9,
            yRadius: 0.9,
        ).fill()
    }

    private static func trianglePath(scale: CGFloat = 1, offsetY: CGFloat = 0) -> NSBezierPath {
        let topLeft = CGPoint(x: 6.0, y: 5.8 + offsetY)
        let bottomLeft = CGPoint(x: 6.0, y: 16.0 + offsetY)
        let tip = CGPoint(x: 15.0, y: 10.9 + offsetY)

        let scaledTopLeft = CGPoint(x: 9 + (topLeft.x - 9) * scale, y: 9 + (topLeft.y - 9) * scale)
        let scaledBottomLeft = CGPoint(x: 9 + (bottomLeft.x - 9) * scale, y: 9 + (bottomLeft.y - 9) * scale)
        let scaledTip = CGPoint(x: 9 + (tip.x - 9) * scale, y: 9 + (tip.y - 9) * scale)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: scaledTopLeft.x, y: (scaledTopLeft.y + scaledBottomLeft.y) / 2))
        path.addArc(tangent1End: scaledBottomLeft, tangent2End: scaledTip, radius: 1.35 * scale)
        path.addArc(tangent1End: scaledTip, tangent2End: scaledTopLeft, radius: 1.35 * scale)
        path.addArc(tangent1End: scaledTopLeft, tangent2End: scaledBottomLeft, radius: 1.35 * scale)
        path.closeSubpath()
        return NSBezierPath(cgPath: path)
    }

    private static func fillTriangle() {
        trianglePath().fill()
    }

    private static func strokeTriangle() {
        let path = trianglePath(scale: 0.94, offsetY: 0.20)
        path.lineWidth = 1.45
        NSColor.black.withAlphaComponent(0.44).setStroke()
        path.stroke()
    }
}
