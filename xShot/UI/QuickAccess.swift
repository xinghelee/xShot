import AppKit

final class QuickAccessManager {
    static let shared = QuickAccessManager()

    private var panels: [QuickAccessPanel] = []
    private var screen: NSScreen?
    private let maxPanels = 5

    func show(_ item: CaptureItem) {
        screen = NSScreen.underMouse
        let panel = QuickAccessPanel(item: item)
        panels.append(panel)
        while panels.count > maxPanels { dismiss(panels[0], animated: false) }
        layout(newPanel: panel)
    }

    func refresh(_ item: CaptureItem) {
        panels.first { $0.item === item }?.reload()
    }

    func dismiss(_ panel: QuickAccessPanel, animated: Bool = true) {
        guard let index = panels.firstIndex(where: { $0 === panel }) else { return }
        panels.remove(at: index)
        if animated {
            var target = panel.frame
            target.origin.x = (screen?.visibleFrame.minX ?? 0) - target.width - 20
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            })
        } else {
            panel.orderOut(nil)
        }
        layout(newPanel: nil)
    }

    private func layout(newPanel: QuickAccessPanel?) {
        guard let visible = (screen ?? NSScreen.underMouse)?.visibleFrame else { return }
        var y = visible.minY + 20
        for panel in panels.reversed() {
            let target = NSRect(x: visible.minX + 20, y: y, width: panel.frame.width, height: panel.frame.height)
            if panel === newPanel {
                panel.setFrame(target.offsetBy(dx: -target.width - 40, dy: 0), display: false)
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
            y += panel.frame.height + 12
        }
    }
}

final class QuickAccessPanel: NSPanel {
    let item: CaptureItem
    private let hostView: QuickAccessView
    private var closeTimer: Timer?

    init(item: CaptureItem) {
        self.item = item
        let size = Self.size(for: item)
        hostView = QuickAccessView(frame: NSRect(origin: .zero, size: size))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hostView.panel = self
        contentView = hostView
        reload()
        scheduleClose()
    }

    static func size(for item: CaptureItem) -> NSSize {
        let width: CGFloat = 230
        let aspect = item.pointSize.height / max(item.pointSize.width, 1)
        return NSSize(width: width, height: min(max(width * aspect, 130), 220))
    }

    func reload() {
        hostView.configure(with: item)
    }

    func scheduleClose() {
        closeTimer?.invalidate()
        let timeout = Prefs.quickAccessTimeout
        guard timeout > 0 else { return }
        closeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeout), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                QuickAccessManager.shared.dismiss(self)
            }
        }
    }

    func pauseClose() {
        closeTimer?.invalidate()
        closeTimer = nil
    }

    // MARK: Actions

    @objc func closeAction() {
        QuickAccessManager.shared.dismiss(self)
    }

    @objc func copyAction() {
        CaptureCoordinator.copy(item)
        Toast.show("已复制")
        closeAction()
    }

    @objc func saveAction() {
        if let url = item.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            do {
                item.fileURL = try ImageExport.save(item.image, scale: item.scale)
                CaptureHistory.shared.update(item, imageChanged: false)
                Toast.show("已保存到 \(Prefs.saveFolder.lastPathComponent)")
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        }
        closeAction()
    }

    @objc func editAction() {
        CaptureCoordinator.shared.openEditor(item)
        pauseClose()
    }

    @objc func pinAction() {
        CaptureCoordinator.shared.pin(item)
        closeAction()
    }

    @objc func ocrAction() {
        CaptureCoordinator.recognize(item.image)
    }

    @objc func gifAction() {
        CaptureCoordinator.shared.exportGIF(item)
    }

    @objc func saveAsAction() {
        ImageExport.saveWithPanel(item.image, scale: item.scale)
    }

    @objc func openAction() {
        switch item.kind {
        case .image: editAction()
        case .video, .gif: if let url = item.fileURL { NSWorkspace.shared.open(url) }
        }
    }

    @objc func deleteAction() {
        if let url = item.fileURL { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        closeAction()
    }
}

final class QuickAccessView: NSView, NSDraggingSource {
    weak var panel: QuickAccessPanel?

    private let background = NSVisualEffectView()
    private let imageView = NSImageView()
    private let hoverLayer = NSView()
    private let primaryButton = HUDButton(title: "复制")
    private let secondaryButton = HUDButton(title: "保存")
    private let closeButton = HUDIconButton(symbol: "xmark", tooltip: "关闭")
    private let editButton = HUDIconButton(symbol: "pencil.tip.crop.circle", tooltip: "标注")
    private let pinButton = HUDIconButton(symbol: "pin", tooltip: "钉在屏幕上")
    private let ocrButton = HUDIconButton(symbol: "text.viewfinder", tooltip: "识别文字")
    private let gifButton = HUDIconButton(symbol: "photo.stack", tooltip: "导出 GIF")
    private let playBadge = NSImageView()
    private var mouseDownPoint: NSPoint?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds.insetBy(dx: 4, dy: 4)
        imageView.autoresizingMask = [.width, .height]
        imageView.unregisterDraggedTypes()
        addSubview(imageView)

        playBadge.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
        playBadge.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        playBadge.contentTintColor = .white
        playBadge.frame = NSRect(x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44)
        playBadge.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(playBadge)

        hoverLayer.frame = bounds
        hoverLayer.autoresizingMask = [.width, .height]
        hoverLayer.wantsLayer = true
        hoverLayer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        hoverLayer.isHidden = true
        addSubview(hoverLayer)

        let stack = NSStackView(views: [primaryButton, secondaryButton])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        hoverLayer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: hoverLayer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: hoverLayer.centerYAnchor),
        ])

        for (button, corner) in [(closeButton, 0), (editButton, 1), (gifButton, 1), (pinButton, 2), (ocrButton, 3)] {
            button.translatesAutoresizingMaskIntoConstraints = false
            hoverLayer.addSubview(button)
            let top = corner < 2
            let left = corner % 2 == 0
            NSLayoutConstraint.activate([
                top ? button.topAnchor.constraint(equalTo: hoverLayer.topAnchor, constant: 8)
                    : button.bottomAnchor.constraint(equalTo: hoverLayer.bottomAnchor, constant: -8),
                left ? button.leadingAnchor.constraint(equalTo: hoverLayer.leadingAnchor, constant: 8)
                     : button.trailingAnchor.constraint(equalTo: hoverLayer.trailingAnchor, constant: -8),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: CaptureItem) {
        imageView.image = item.nsImage
        let isImage = item.kind == .image
        playBadge.isHidden = item.kind != .video
        editButton.isHidden = !isImage
        pinButton.isHidden = !isImage
        ocrButton.isHidden = !isImage
        gifButton.isHidden = item.kind != .video
        secondaryButton.setText(item.fileURL == nil ? "保存" : "在访达中显示")
        guard let panel else { return }
        closeButton.target = panel; closeButton.action = #selector(QuickAccessPanel.closeAction)
        editButton.target = panel; editButton.action = #selector(QuickAccessPanel.editAction)
        pinButton.target = panel; pinButton.action = #selector(QuickAccessPanel.pinAction)
        ocrButton.target = panel; ocrButton.action = #selector(QuickAccessPanel.ocrAction)
        gifButton.target = panel; gifButton.action = #selector(QuickAccessPanel.gifAction)
        primaryButton.target = panel; primaryButton.action = #selector(QuickAccessPanel.copyAction)
        secondaryButton.target = panel; secondaryButton.action = #selector(QuickAccessPanel.saveAction)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hoverLayer.isHidden = false
        panel?.pauseClose()
    }

    override func mouseExited(with event: NSEvent) {
        hoverLayer.isHidden = true
        panel?.scheduleClose()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragging = false
        if event.clickCount == 2 { panel?.openAction() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownPoint, let panel else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        let item = panel.item
        guard let url = item.fileURL ?? ImageExport.temporaryFile(item.image, scale: item.scale) else { return }
        dragging = true
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(bounds, contents: item.nsImage)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let panel else { return }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = panel
        }
        add("复制", #selector(QuickAccessPanel.copyAction))
        if panel.item.kind == .image {
            add("标注…", #selector(QuickAccessPanel.editAction))
            add("钉在屏幕上", #selector(QuickAccessPanel.pinAction))
            add("识别文字", #selector(QuickAccessPanel.ocrAction))
            add("另存为…", #selector(QuickAccessPanel.saveAsAction))
        } else {
            add("打开", #selector(QuickAccessPanel.openAction))
            if panel.item.kind == .video { add("导出 GIF", #selector(QuickAccessPanel.gifAction)) }
        }
        if panel.item.fileURL != nil {
            add("在访达中显示", #selector(QuickAccessPanel.saveAction))
            menu.addItem(.separator())
            add("移到废纸篓", #selector(QuickAccessPanel.deleteAction))
        }
        menu.addItem(.separator())
        add("关闭", #selector(QuickAccessPanel.closeAction))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        if operation != [], let panel { QuickAccessManager.shared.dismiss(panel) }
    }
}

final class HUDButton: NSButton {
    convenience init(title: String) {
        self.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        font = .systemFont(ofSize: 12, weight: .semibold)
        contentTintColor = .black
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        setText(title)
    }

    func setText(_ text: String) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HUDIconButton: NSButton {
    convenience init(symbol: String, tooltip: String) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        toolTip = tooltip
        isBordered = false
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
