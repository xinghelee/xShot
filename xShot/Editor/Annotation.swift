import AppKit

enum Tool: Int, CaseIterable {
    case select, arrow, line, rect, ellipse, pen, highlighter, text, counter, pixelate, crop

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .pixelate: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: "选择 (V)"
        case .arrow: "箭头 (A)"
        case .line: "直线 (L)"
        case .rect: "矩形 (R)"
        case .ellipse: "椭圆 (O)"
        case .pen: "画笔 (P)"
        case .highlighter: "荧光笔 (H)"
        case .text: "文字 (T)"
        case .counter: "序号 (N)"
        case .pixelate: "马赛克 (X)"
        case .crop: "裁剪 (C)"
        }
    }

    var shortcut: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rect: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .pixelate: "x"
        case .crop: "c"
        }
    }

    var kind: Annotation.Kind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .rect: .rect
        case .ellipse: .ellipse
        case .pen: .pen
        case .highlighter: .highlighter
        case .text: .text
        case .counter: .counter
        case .pixelate: .pixelate
        case .select, .crop: nil
        }
    }
}

/// A single markup element. All geometry is in image pixel coordinates with a top-left origin.
final class Annotation {
    enum Kind { case arrow, line, rect, ellipse, pen, highlighter, text, counter, pixelate }

    let kind: Kind
    var start = CGPoint.zero
    var end = CGPoint.zero
    var points: [CGPoint] = []
    var color = NSColor.systemRed
    var width: CGFloat = 4
    var fontSize: CGFloat = 32
    var text = ""
    var number = 1
    private var pixelCache: (rect: CGRect, image: CGImage)?

    init(kind: Kind) {
        self.kind = kind
    }

    func copy() -> Annotation {
        let a = Annotation(kind: kind)
        a.start = start
        a.end = end
        a.points = points
        a.color = color
        a.width = width
        a.fontSize = fontSize
        a.text = text
        a.number = number
        return a
    }

    var rect: CGRect { CGRect(from: start, to: end) }

    /// Endpoints that can be dragged to reshape the annotation.
    var handles: [CGPoint] {
        switch kind {
        case .arrow, .line, .rect, .ellipse, .pixelate: [start, end]
        default: []
        }
    }

    var counterRadius: CGFloat { fontSize * 0.7 }

    var textAttributes: [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = fontSize * 0.08
        return [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: color, .shadow: shadow]
    }

    var bounds: CGRect {
        switch kind {
        case .pen, .highlighter:
            guard let first = points.first else { return .null }
            var r = CGRect(origin: first, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -width, dy: -width)
        case .text:
            let size = (text as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: start, size: size)
        case .counter:
            return CGRect(x: start.x - counterRadius, y: start.y - counterRadius, width: counterRadius * 2, height: counterRadius * 2)
        default:
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let t = tolerance + width / 2
        switch kind {
        case .arrow, .line:
            return distance(p, segment: (start, end)) <= t
        case .pen, .highlighter:
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= t }
            return zip(points, points.dropFirst()).contains { distance(p, segment: ($0, $1)) <= t * (kind == .highlighter ? 2 : 1) }
        case .rect:
            let outer = rect.insetBy(dx: -t, dy: -t)
            let inner = rect.insetBy(dx: t, dy: t)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        case .ellipse:
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            let d = sqrt(nx * nx + ny * ny)
            return abs(d - 1) * min(r.width, r.height) / 2 <= t
        case .text, .counter, .pixelate:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    func move(by d: CGVector) {
        start.x += d.dx; start.y += d.dy
        end.x += d.dx; end.y += d.dy
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        pixelCache = nil
    }

    func invalidateCache() { pixelCache = nil }

    private func distance(_ p: CGPoint, segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Drawing

    /// Draws into a context whose user space is image pixels with y pointing down.
    /// `NSGraphicsContext.current` must wrap the same context (needed for text).
    func draw(in ctx: CGContext, base: CGImage) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let deviceScale = abs(ctx.ctm.a) + abs(ctx.ctm.b)
        if kind != .highlighter, kind != .pixelate, kind != .text {
            ctx.setShadow(offset: .zero, blur: max(1.5, width * 0.8 * deviceScale), color: NSColor.black.withAlphaComponent(0.3).cgColor)
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch kind {
        case .arrow:
            drawArrow(ctx)
        case .line:
            ctx.strokeLineSegments(between: [start, end])
        case .rect:
            let r = rect
            let radius = min(width, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        case .ellipse:
            ctx.strokeEllipse(in: rect)
        case .pen:
            strokePoints(ctx, lineWidth: width)
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(width * 4)
            ctx.setLineCap(.square)
            strokePoints(ctx, lineWidth: width * 4)
        case .text:
            (text as NSString).draw(at: start, withAttributes: textAttributes)
        case .counter:
            drawCounter(ctx)
        case .pixelate:
            if let img = pixelated(base: base) {
                ctx.interpolationQuality = .none
                ctx.drawFlipped(img, in: pixelCache!.rect)
            }
        }
    }

    private func strokePoints(_ ctx: CGContext, lineWidth w: CGFloat) {
        guard let first = points.first else { return }
        if points.count == 1 {
            ctx.setFillColor(kind == .highlighter ? color.withAlphaComponent(0.45).cgColor : color.cgColor)
            ctx.fillEllipse(in: CGRect(x: first.x - w / 2, y: first.y - w / 2, width: w, height: w))
            return
        }
        ctx.move(to: first)
        // Smooth the stroke with quadratic curves through midpoints.
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            ctx.addQuadCurve(to: mid, control: points[i - 1])
        }
        ctx.addLine(to: points[points.count - 1])
        ctx.strokePath()
    }

    private func drawArrow(_ ctx: CGContext) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let headLength = min(max(width * 4, 12), length * 0.7)
        let headWidth = headLength * 0.85
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let tail = width * 0.35, neck = width

        let path = CGMutablePath()
        path.move(to: CGPoint(x: start.x + nx * tail / 2, y: start.y + ny * tail / 2))
        path.addLine(to: CGPoint(x: base.x + nx * neck / 2, y: base.y + ny * neck / 2))
        path.addLine(to: CGPoint(x: base.x + nx * headWidth / 2, y: base.y + ny * headWidth / 2))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: base.x - nx * headWidth / 2, y: base.y - ny * headWidth / 2))
        path.addLine(to: CGPoint(x: base.x - nx * neck / 2, y: base.y - ny * neck / 2))
        path.addLine(to: CGPoint(x: start.x - nx * tail / 2, y: start.y - ny * tail / 2))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setLineWidth(max(1, width * 0.3))
        ctx.drawPath(using: .fillStroke)
    }

    private func drawCounter(_ ctx: CGContext) {
        let r = counterRadius
        let circle = CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        ctx.fillEllipse(in: circle)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(max(1, r * 0.12))
        ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: r * 1.1, weight: .bold),
            .foregroundColor: color.isLight ? NSColor.black : NSColor.white,
        ]
        let str = "\(number)" as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2), withAttributes: attrs)
    }

    private func pixelated(base: CGImage) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        if let cache = pixelCache, cache.rect == r { return cache.image }
        guard let crop = base.cropping(to: r) else { return nil }
        let block = max(6, width * 3)
        let w = max(1, Int(r.width / block)), h = max(1, Int(r.height / block))
        guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .medium
        small.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = small.makeImage() else { return nil }
        pixelCache = (r, img)
        return img
    }
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.7
    }
}
