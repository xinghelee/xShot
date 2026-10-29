import AppKit

final class CanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    private struct Snapshot {
        let base: CGImage
        let annotations: [Annotation]
    }

    private enum Drag {
        case none
        case creating(Annotation, added: Bool)
        case moving(Annotation, last: CGPoint)
        case handle(Annotation, index: Int)
        case cropping(origin: CGPoint)
        case movingCrop(start: CGPoint, original: CGRect)
    }

    private(set) var base: CGImage
    let imageScale: CGFloat
    private(set) var annotations: [Annotation] = []
    private var selected: Annotation? { didSet { needsDisplay = true } }
    private var cropRect: CGRect?
    private var drag = Drag.none
    private var pendingSnapshot: Snapshot?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var textField: NSTextField?
    private var editingText: Annotation?
    private var editingIsNew = false

    var onStateChange: (() -> Void)?
    var onToolChange: ((Tool) -> Void)?
    var onImageSizeChange: (() -> Void)?
    var onSave: (() -> Void)?
    var onBackgroundShortcut: (() -> Void)?

    var tool: Tool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            commitText()
            if oldValue == .crop { applyCrop() }
            if tool != .select { selected = nil }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    var color: NSColor = .systemRed {
        didSet { modifySelected { $0.color = color } }
    }

    /// 0 = small, 1 = medium, 2 = large.
    var sizeLevel = 1 {
        didSet {
            modifySelected {
                $0.width = strokeWidth
                $0.fontSize = fontSize
            }
        }
    }

    var background = BackdropStyle()

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isDirty: Bool { canUndo }

    private var strokeWidth: CGFloat { [2, 4, 7][sizeLevel] * imageScale }
    private var fontSize: CGFloat { [14, 22, 34][sizeLevel] * imageScale }
    private var viewScale: CGFloat { bounds.width / CGFloat(base.width) }
    private var imageBounds: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }

    init(image: CGImage, scale: CGFloat) {
        base = image
        imageScale = scale
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor = switch tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Coordinates

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / viewScale, y: p.y / viewScale)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * viewScale, y: r.minY * viewScale, width: r.width * viewScale, height: r.height * viewScale)
    }

    private func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * viewScale, y: p.y * viewScale) }

    // MARK: Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: viewScale, y: viewScale)
        ctx.interpolationQuality = .high
        render(in: ctx)
        ctx.restoreGState()

        if let selected, editingText == nil {
            let r = viewRect(selected.bounds).insetBy(dx: -4, dy: -4)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
            for h in selected.handles {
                let p = viewPoint(h)
                let dot = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: dot)
            }
        }

        if let cropRect {
            let r = viewRect(cropRect)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.addRect(bounds)
            ctx.addRect(r)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            // Rule-of-thirds guides.
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.maxY),
                                                 CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y)])
            }
            let label = "\(Int(cropRect.width)) × \(Int(cropRect.height))  ↩ 确认"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let size = (label as NSString).size(withAttributes: attrs)
            let box = CGRect(x: r.minX, y: max(0, r.minY - size.height - 8), width: size.width + 12, height: size.height + 4)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.fill(box)
            (label as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attrs)
        }
    }

    private func render(in ctx: CGContext) {
        ctx.drawFlipped(base, in: imageBounds)
        for a in annotations where a !== editingText {
            a.draw(in: ctx, base: base)
        }
    }

    /// Final image at full resolution.
    func renderedImage() -> CGImage? {
        commitText()
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(base.height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        render(in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// What gets copied/saved: annotations flattened, plus the background if enabled.
    func finalImage() -> CGImage? {
        guard let image = renderedImage() else { return nil }
        guard background.enabled else { return image }
        return BackgroundRenderer.compose(image, scale: imageScale, style: background) ?? image
    }

    /// Rounded corners while the background preview is on; the backdrop view draws the shadow.
    func applyFrameLook(cornerRadius: CGFloat?) {
        if let cornerRadius {
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = true
            layer?.shadowOpacity = 0
        } else {
            layer?.cornerRadius = 0
            layer?.masksToBounds = false
            layer?.shadowOpacity = 0.35
        }
    }

    // MARK: Undo

    private func snapshot() -> Snapshot {
        Snapshot(base: base, annotations: annotations.map { $0.copy() })
    }

    private func pushUndo(_ s: Snapshot? = nil) {
        undoStack.append(s ?? snapshot())
        redoStack.removeAll()
        onStateChange?()
    }

    private func restore(_ s: Snapshot) {
        let sizeChanged = s.base.width != base.width || s.base.height != base.height
        base = s.base
        annotations = s.annotations
        selected = nil
        cropRect = nil
        if sizeChanged { onImageSizeChange?() }
        needsDisplay = true
        onStateChange?()
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(s)
    }

    @objc func redo(_ sender: Any?) {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(s)
    }

    @objc func copy(_ sender: Any?) {
        guard let image = finalImage() else { return }
        ImageExport.copy(image, scale: imageScale)
        Toast.show("已复制")
    }

    @objc func saveDocument(_ sender: Any?) { onSave?() }

    @objc func delete(_ sender: Any?) { deleteSelected() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): canUndo
        case #selector(redo(_:)): canRedo
        case #selector(delete(_:)): selected != nil
        default: true
        }
    }

    private func modifySelected(_ change: (Annotation) -> Void) {
        guard let selected else { return }
        pushUndo()
        change(selected)
        selected.invalidateCache()
        needsDisplay = true
    }

    private func deleteSelected() {
        guard let s = selected else { return }
        pushUndo()
        annotations.removeAll { $0 === s }
        selected = nil
    }

    // MARK: Crop

    func applyCrop() {
        guard let rect = cropRect?.integral.intersection(imageBounds), rect.width >= 2, rect.height >= 2,
              rect != imageBounds, let cropped = base.cropping(to: rect) else {
            cropRect = nil
            needsDisplay = true
            return
        }
        pushUndo()
        base = cropped
        for a in annotations {
            a.move(by: CGVector(dx: -rect.minX, dy: -rect.minY))
        }
        cropRect = nil
        onImageSizeChange?()
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        let tolerance = 6 / viewScale

        if tool == .crop {
            if let c = cropRect, c.contains(p) {
                drag = .movingCrop(start: p, original: c)
            } else {
                drag = .cropping(origin: p)
                cropRect = nil
            }
            return
        }

        if let s = selected, let index = s.handles.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= tolerance * 1.5 }) {
            pendingSnapshot = snapshot()
            drag = .handle(s, index: index)
            return
        }

        if let hit = annotations.reversed().first(where: { $0.hitTest(p, tolerance: tolerance) }),
           tool == .select || hit === selected || (tool == .text && hit.kind == .text) {
            if hit.kind == .text, event.clickCount == 2 || tool == .text {
                beginEditing(hit, isNew: false)
                return
            }
            selected = hit
            pendingSnapshot = snapshot()
            drag = .moving(hit, last: p)
            return
        }

        selected = nil
        guard let kind = tool.kind else {
            drag = .none
            return
        }

        let a = Annotation(kind: kind)
        a.color = color
        a.width = strokeWidth
        a.fontSize = fontSize
        a.start = p
        a.end = p
        a.points = [p]

        switch kind {
        case .text:
            beginEditing(a, isNew: true)
        case .counter:
            a.number = (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
            pushUndo()
            annotations.append(a)
            needsDisplay = true
        default:
            pendingSnapshot = snapshot()
            drag = .creating(a, added: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var p = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case .none:
            return
        case let .creating(a, added):
            if a.kind == .pen || a.kind == .highlighter {
                if shift, let first = a.points.first {
                    a.points = [first, constrain(p, from: first, kind: .line)]
                } else {
                    a.points.append(p)
                }
            } else {
                a.end = shift ? constrain(p, from: a.start, kind: a.kind) : p
            }
            if !added, hypot(p.x - a.start.x, p.y - a.start.y) > 2 / viewScale {
                pushUndo(pendingSnapshot)
                annotations.append(a)
                drag = .creating(a, added: true)
            }
            a.invalidateCache()
        case let .moving(a, last):
            if pendingSnapshot != nil {
                pushUndo(pendingSnapshot)
                pendingSnapshot = nil
            }
            a.move(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            drag = .moving(a, last: p)
        case let .handle(a, index):
            if pendingSnapshot != nil {
                pushUndo(pendingSnapshot)
                pendingSnapshot = nil
            }
            if shift { p = constrain(p, from: index == 0 ? a.end : a.start, kind: a.kind) }
            if index == 0 { a.start = p } else { a.end = p }
            a.invalidateCache()
        case let .cropping(origin):
            p = CGPoint(x: min(max(p.x, 0), CGFloat(base.width)), y: min(max(p.y, 0), CGFloat(base.height)))
            cropRect = CGRect(from: origin, to: shift ? constrain(p, from: origin, kind: .rect) : p)
        case let .movingCrop(start, original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, 0), CGFloat(base.width) - r.width)
            r.origin.y = min(max(r.minY, 0), CGFloat(base.height) - r.height)
            cropRect = r
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case let .creating(a, added) = drag, added, a.kind != .pen, a.kind != .highlighter {
            selected = a
        }
        if case .cropping = drag, let c = cropRect, c.width < 2 || c.height < 2 {
            cropRect = nil
        }
        drag = .none
        pendingSnapshot = nil
        needsDisplay = true
        onStateChange?()
    }

    /// Snaps lines to 45° steps and boxes to squares.
    private func constrain(_ p: CGPoint, from o: CGPoint, kind: Annotation.Kind) -> CGPoint {
        let dx = p.x - o.x, dy = p.y - o.y
        switch kind {
        case .arrow, .line, .pen, .highlighter:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: o.x + cos(angle) * len, y: o.y + sin(angle) * len)
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: o.x + (dx < 0 ? -side : side), y: o.y + (dy < 0 ? -side : side))
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch Int(event.keyCode) {
        case 51, 117:
            deleteSelected()
        case 53:
            if cropRect != nil { cropRect = nil; needsDisplay = true } else { selected = nil }
        case 36, 76:
            if tool == .crop { applyCrop() }
        case 123, 124, 125, 126:
            guard let selected else { return }
            let step: CGFloat = (mods.contains(.shift) ? 10 : 1) * imageScale
            let d: CGVector = switch Int(event.keyCode) {
            case 123: CGVector(dx: -step, dy: 0)
            case 124: CGVector(dx: step, dy: 0)
            case 125: CGVector(dx: 0, dy: step)
            default: CGVector(dx: 0, dy: -step)
            }
            pushUndo()
            selected.move(by: d)
            needsDisplay = true
        default:
            if mods.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "b" {
                onBackgroundShortcut?()
                return
            }
            guard mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased(),
                  let t = Tool.allCases.first(where: { $0.shortcut == ch }) else {
                super.keyDown(with: event)
                return
            }
            tool = t
            onToolChange?(t)
        }
    }

    // MARK: Text editing

    private func beginEditing(_ a: Annotation, isNew: Bool) {
        commitText()
        editingText = a
        editingIsNew = isNew
        selected = nil

        let field = NSTextField(string: a.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: a.fontSize * viewScale, weight: .bold)
        field.textColor = a.color
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = "输入文字"
        textField = field
        layoutTextField()
        addSubview(field)
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func layoutTextField() {
        guard let field = textField, let a = editingText else { return }
        let width = max(field.attributedStringValue.size().width, 80) + 24
        let height = field.intrinsicContentSize.height
        let origin = viewPoint(a.start)
        field.frame = CGRect(x: origin.x - 2, y: origin.y, width: width, height: height)
    }

    func controlTextDidChange(_ obj: Notification) {
        layoutTextField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    private func commitText() {
        guard let field = textField, let a = editingText else { return }
        textField = nil
        editingText = nil
        let text = field.stringValue
        field.removeFromSuperview()
        if editingIsNew {
            if !text.isEmpty {
                pushUndo()
                a.text = text
                annotations.append(a)
                selected = a
            }
        } else if text.isEmpty {
            pushUndo()
            annotations.removeAll { $0 === a }
        } else if text != a.text {
            pushUndo()
            a.text = text
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
