import AppKit

enum SelectionPurpose {
    case capture, ocr, record, scroll

    var hint: String {
        switch self {
        case .capture: "拖动选择区域 · 空格切换窗口模式 · 单击截取全屏 · Esc 取消"
        case .ocr: "拖动选择要识别文字的区域 · Esc 取消"
        case .record: "拖动选择录制区域 · 空格切换窗口模式 · 单击录制全屏 · Esc 取消"
        case .scroll: "拖动选择要滚动截图的区域 · 空格切换窗口模式 · Esc 取消"
        }
    }
}

struct Selection {
    let screen: NSScreen
    /// Screen-local rect, top-left origin, in points.
    let rect: CGRect
    /// Frozen image of the whole screen.
    let frozen: CGImage
    let windowID: CGWindowID?

    var pixelScale: CGFloat { CGFloat(frozen.width) / screen.frame.width }

    var croppedImage: CGImage? {
        let s = pixelScale
        let px = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s).integral
        return frozen.cropping(to: px)
    }
}

final class SelectionController {
    private static var current: SelectionController?

    let purpose: SelectionPurpose
    private let completion: (Selection?) -> Void
    private var overlays: [OverlayWindow] = []
    private let windows: [WindowInfo]
    private(set) var windowMode: Bool
    private(set) var hoveredWindow: WindowInfo?

    static var isActive: Bool { current != nil }

    static func begin(purpose: SelectionPurpose, windowMode: Bool = false, completion: @escaping (Selection?) -> Void) {
        guard current == nil else { return }
        let screens = NSScreen.screens
        let windows = Capturer.visibleWindows()
        Task {
            do {
                let images = try await Capturer.captureDisplays(screens)
                let controller = SelectionController(purpose: purpose, windowMode: windowMode, windows: windows, completion: completion)
                current = controller
                controller.show(Array(zip(screens, images)))
            } catch {
                NSLog("xShot: capture failed: \(error)")
                Permissions.showScreenRecordingAlert()
                completion(nil)
            }
        }
    }

    private init(purpose: SelectionPurpose, windowMode: Bool, windows: [WindowInfo], completion: @escaping (Selection?) -> Void) {
        self.purpose = purpose
        self.windowMode = windowMode
        self.windows = windows
        self.completion = completion
    }

    private func show(_ frozen: [(NSScreen, CGImage)]) {
        let mouseScreen = NSScreen.underMouse
        for (screen, image) in frozen {
            let w = OverlayWindow(screen: screen, image: image, controller: self)
            overlays.append(w)
            if screen == mouseScreen {
                w.makeKeyAndOrderFront(nil)
            } else {
                w.orderFrontRegardless()
            }
        }
        NSApp.activate()
        overlays.first { $0.screen == mouseScreen }?.makeKey()
        updateHover()
        NSCursor.crosshair.set()
    }

    func toggleWindowMode() {
        windowMode.toggle()
        updateHover()
    }

    func updateHover() {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: p.x, y: primaryHeight - p.y)
        let hovered = windowMode ? windows.first { $0.frame.contains(cgPoint) } : nil
        hoveredWindow = hovered
        overlays.forEach { $0.overlayView.needsDisplay = true }
    }

    func finish(_ selection: Selection?) {
        guard SelectionController.current === self else { return }
        SelectionController.current = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        NSCursor.arrow.set()
        // Give the window server a beat to remove the overlays before anything captures live content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [completion] in completion(selection) }
    }
}

final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(screen: NSScreen, image: CGImage, controller: SelectionController) {
        overlayView = OverlayView(screen: screen, image: image, controller: controller)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        container.layer?.contents = image
        container.layer?.contentsGravity = .resize
        overlayView.frame = container.bounds
        overlayView.autoresizingMask = [.width, .height]
        container.addSubview(overlayView)
        contentView = container
        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    let screen: NSScreen
    let image: CGImage
    unowned let controller: SelectionController

    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?

    init(screen: NSScreen, image: CGImage, controller: SelectionController) {
        self.screen = screen
        self.image = image
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let p = NSEvent.mouseLocation
        if NSMouseInRect(p, screen.frame, false) {
            mouse = CGPoint(x: p.x - screen.frame.minX, y: screen.frame.maxY - p.y)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private var pixelScale: CGFloat { CGFloat(image.width) / bounds.width }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    /// Hovered window rect in this screen's local coordinates.
    private var hoveredRect: CGRect? {
        guard controller.windowMode, let w = controller.hoveredWindow else { return nil }
        let origin = screen.cgFrame.origin
        let r = w.frame.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds)
        return r.isNull || r.isEmpty ? nil : r
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        mouse = localPoint(event)
        if controller.windowMode { controller.updateHover() }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        mouse = localPoint(event)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = localPoint(event)
        dragStart = p
        mouse = p
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var p = localPoint(event)
        mouse = p
        if selection == nil, hypot(p.x - start.x, p.y - start.y) < 3 { return }
        if event.modifierFlags.contains(.shift) {
            let side = max(abs(p.x - start.x), abs(p.y - start.y))
            p = CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side))
        }
        selection = CGRect(from: start, to: p).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if let sel = selection, sel.width >= 4, sel.height >= 4 {
            let snapped = snapToPixels(sel)
            controller.finish(Selection(screen: screen, rect: snapped, frozen: image, windowID: nil))
            return
        }
        selection = nil
        if controller.windowMode {
            if let rect = hoveredRect, let id = controller.hoveredWindow?.id {
                controller.finish(Selection(screen: screen, rect: rect, frozen: image, windowID: id))
            }
        } else if controller.purpose != .ocr, controller.purpose != .scroll {
            controller.finish(Selection(screen: screen, rect: bounds, frozen: image, windowID: nil))
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.finish(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: controller.finish(nil)
        case 49 where controller.purpose != .ocr:
            selection = nil
            dragStart = nil
            controller.toggleWindowMode()
        default: break
        }
    }

    private func snapToPixels(_ r: CGRect) -> CGRect {
        let s = pixelScale
        let px = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s).integral
        return CGRect(x: px.minX / s, y: px.minY / s, width: px.width / s, height: px.height / s)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let hole = selection ?? hoveredRect
        if let hole {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.addRect(bounds)
            ctx.addRect(hole)
            ctx.fillPath(using: .evenOdd)
            if selection == nil {
                ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.18).cgColor)
                ctx.fill(hole)
            }
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(hole.insetBy(dx: 0.5, dy: 0.5))
            drawSizeLabel(ctx, for: hole)
        } else if controller.windowMode {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
            ctx.fill(bounds)
        }

        if let mouse, selection == nil, !controller.windowMode {
            drawCrosshair(ctx, at: mouse)
        }
        if let mouse, !controller.windowMode, Prefs.showMagnifier {
            drawLoupe(ctx, at: mouse)
        }
        if mouse != nil, selection == nil {
            drawHint(ctx)
        }
    }

    private func drawCrosshair(_ ctx: CGContext, at p: CGPoint) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        let x = floor(p.x) + 0.5, y = floor(p.y) + 0.5
        ctx.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: bounds.height),
                                         CGPoint(x: 0, y: y), CGPoint(x: bounds.width, y: y)])
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineDash(phase: 4, lengths: [4, 4])
        ctx.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: bounds.height),
                                         CGPoint(x: 0, y: y), CGPoint(x: bounds.width, y: y)])
        ctx.restoreGState()
    }

    private func drawLoupe(_ ctx: CGContext, at p: CGPoint) {
        let cells = 15, cell: CGFloat = 8
        let size = CGFloat(cells) * cell
        let labelHeight: CGFloat = 22
        var origin = CGPoint(x: p.x + 24, y: p.y + 24)
        if origin.x + size > bounds.maxX - 4 { origin.x = p.x - 24 - size }
        if origin.y + size + labelHeight > bounds.maxY - 4 { origin.y = p.y - 24 - size - labelHeight }
        let rect = CGRect(origin: origin, size: CGSize(width: size, height: size))

        let s = pixelScale
        let half = CGFloat(cells / 2)
        let src = CGRect(x: floor(p.x * s) - half, y: floor(p.y * s) - half, width: CGFloat(cells), height: CGFloat(cells))
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let visible = src.intersection(imageBounds)

        ctx.saveGState()
        let clip = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(clip)
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(rect)
        ctx.interpolationQuality = .none
        if !visible.isEmpty, let crop = image.cropping(to: visible) {
            let dst = CGRect(x: rect.minX + (visible.minX - src.minX) * cell, y: rect.minY + (visible.minY - src.minY) * cell,
                             width: visible.width * cell, height: visible.height * cell)
            ctx.drawFlipped(crop, in: dst)
        }
        let center = CGRect(x: rect.minX + half * cell, y: rect.minY + half * cell, width: cell, height: cell)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(center)
        ctx.restoreGState()

        ctx.addPath(clip)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()

        let text = "\(Int(p.x * s)), \(Int(p.y * s))"
        drawPill(ctx, text: text, center: CGPoint(x: rect.midX, y: rect.maxY + labelHeight / 2 + 2))
    }

    private func drawSizeLabel(_ ctx: CGContext, for r: CGRect) {
        let s = pixelScale
        let text = "\(Int(round(r.width * s))) × \(Int(round(r.height * s)))"
        var center = CGPoint(x: r.midX, y: r.maxY + 16)
        if center.y > bounds.maxY - 14 { center.y = r.maxY - 16 }
        drawPill(ctx, text: text, center: center)
    }

    private func drawHint(_ ctx: CGContext) {
        guard screen == NSScreen.underMouse else { return }
        let hint = controller.windowMode ? "单击选择窗口 · 空格切换回区域模式 · Esc 取消" : controller.purpose.hint
        drawPill(ctx, text: hint, center: CGPoint(x: bounds.midX, y: 60))
    }

    private func drawPill(_ ctx: CGContext, text: String, center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let box = CGRect(x: center.x - size.width / 2 - 8, y: center.y - size.height / 2 - 3,
                         width: size.width + 16, height: size.height + 6)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil))
        ctx.fillPath()
        str.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3))
    }
}
