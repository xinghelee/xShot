import AppKit

/// A floating, always-on-top copy of a screenshot.
final class PinPanel: NSPanel {
    private static var pins: [PinPanel] = []

    private let image: CGImage
    private let scale: CGFloat
    private var zoom: CGFloat = 1
    private var dragOrigin: (mouse: NSPoint, frame: NSPoint)?

    static func pin(image: CGImage, scale: CGFloat) {
        let panel = PinPanel(image: image, scale: scale)
        pins.append(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private var baseSize: NSSize { NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    private init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        let screen = NSScreen.underMouse.visibleFrame
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, screen.width * 0.8 / size.width, screen.height * 0.8 / size.height)
        size = NSSize(width: size.width * fit, height: size.height * fit)
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        zoom = fit
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            closePin()
            return
        }
        dragOrigin = (NSEvent.mouseLocation, frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let p = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: dragOrigin.frame.x + p.x - dragOrigin.mouse.x, y: dragOrigin.frame.y + p.y - dragOrigin.mouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.05
        if event.modifierFlags.contains(.option) {
            alphaValue = min(1, max(0.15, alphaValue + delta))
            return
        }
        setZoom(zoom * (1 + delta), anchor: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: NSEvent.mouseLocation)
    }

    private func setZoom(_ value: CGFloat, anchor: NSPoint) {
        let newZoom = min(5, max(0.1, value))
        let size = NSSize(width: baseSize.width * newZoom, height: baseSize.height * newZoom)
        let rx = (anchor.x - frame.minX) / frame.width
        let ry = (anchor.y - frame.minY) / frame.height
        let origin = NSPoint(x: anchor.x - size.width * rx, y: anchor.y - size.height * ry)
        zoom = newZoom
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53, 51: closePin()
        case 24 where event.modifierFlags.contains(.command): setZoom(zoom * 1.2, anchor: NSPoint(x: frame.midX, y: frame.midY))
        case 27 where event.modifierFlags.contains(.command): setZoom(zoom / 1.2, anchor: NSPoint(x: frame.midX, y: frame.midY))
        case 29 where event.modifierFlags.contains(.command): setZoom(1, anchor: NSPoint(x: frame.midX, y: frame.midY))
        default: super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "") {
            menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        add("复制", #selector(copy(_:)), key: "c")
        add("标注…", #selector(annotate))
        add("另存为…", #selector(saveAs))
        add("识别文字", #selector(recognize))
        menu.addItem(.separator())
        add("实际大小", #selector(actualSize))
        let opacity = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [100, 80, 60, 40] {
            let item = sub.addItem(withTitle: "\(value)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = Int(round(alphaValue * 100)) == value ? .on : .off
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(.separator())
        add("关闭", #selector(closePin))
        if let view = contentView { NSMenu.popUpContextMenu(menu, with: event, for: view) }
    }

    @objc func copy(_ sender: Any?) {
        ImageExport.copy(image, scale: scale)
        Toast.show("已复制")
    }

    @objc private func annotate() {
        let item = CaptureItem(kind: .image, image: image, scale: scale)
        CaptureCoordinator.shared.openEditor(item)
    }

    @objc private func saveAs() { ImageExport.saveWithPanel(image, scale: scale) }
    @objc private func recognize() { CaptureCoordinator.recognize(image) }
    @objc private func actualSize() { setZoom(1, anchor: NSPoint(x: frame.midX, y: frame.midY)) }
    @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }

    @objc private func closePin() {
        orderOut(nil)
        PinPanel.pins.removeAll { $0 === self }
    }
}
