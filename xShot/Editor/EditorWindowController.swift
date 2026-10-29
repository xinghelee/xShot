import AppKit
import SwiftUI

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [EditorWindowController] = []

    private let canvas: CanvasView
    private let container = CanvasContainer()
    private let onDone: (EditorResult) -> Void
    private let toolControl = NSSegmentedControl()
    private let sizeControl = NSSegmentedControl(labels: ["细", "中", "粗"], trackingMode: .selectOne, target: nil, action: nil)
    private var colorButtons: [ColorSwatch] = []
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let backgroundButton = NSButton()
    private let backgroundModel = BackgroundModel(style: BackdropStyle.load())
    private lazy var backgroundPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BackgroundPanel(model: backgroundModel))
        return popover
    }()

    private static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white,
    ]

    /// `backdrop` reopens a capture whose background was applied automatically, so it stays editable.
    static func open(image: CGImage, scale: CGFloat, backdrop: BackdropStyle? = nil, onDone: @escaping (EditorResult) -> Void) {
        let controller = EditorWindowController(image: image, scale: scale, onDone: onDone)
        if var backdrop {
            backdrop.enabled = true
            controller.backgroundModel.style = backdrop
        }
        openEditors.append(controller)
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
    }

    private init(image: CGImage, scale: CGFloat, onDone: @escaping (EditorResult) -> Void) {
        canvas = CanvasView(image: image, scale: scale)
        self.onDone = onDone

        let visible = NSScreen.underMouse.visibleFrame
        let imageSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let width = min(max(imageSize.width + 80, 860), visible.width * 0.9)
        let height = min(max(imageSize.height + 140, 520), visible.height * 0.9)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "xShot 标注"
        window.minSize = NSSize(width: 760, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        toolControl.segmentCount = Tool.allCases.count
        toolControl.trackingMode = .selectOne
        for tool in Tool.allCases {
            toolControl.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: tool.rawValue)
            toolControl.setToolTip(tool.title, forSegment: tool.rawValue)
            toolControl.setWidth(30, forSegment: tool.rawValue)
        }
        toolControl.selectedSegment = canvas.tool.rawValue
        toolControl.target = self
        toolControl.action = #selector(toolChanged)

        let colors = NSStackView()
        colors.spacing = 4
        for (i, color) in Self.palette.enumerated() {
            let swatch = ColorSwatch(color: color)
            swatch.target = self
            swatch.action = #selector(colorChanged(_:))
            swatch.tag = i
            swatch.isSelectedSwatch = i == 0
            colorButtons.append(swatch)
            colors.addArrangedSubview(swatch)
        }

        sizeControl.selectedSegment = canvas.sizeLevel
        sizeControl.target = self
        sizeControl.action = #selector(sizeChanged)

        configureIconButton(undoButton, symbol: "arrow.uturn.backward", tip: "撤销 ⌘Z", action: #selector(undo))
        configureIconButton(redoButton, symbol: "arrow.uturn.forward", tip: "重做 ⇧⌘Z", action: #selector(redo))
        configureIconButton(backgroundButton, symbol: "photo.artframe", tip: "背景美化 (B)", action: #selector(toggleBackgroundPanel))
        backgroundButton.title = "背景"
        backgroundButton.imagePosition = .imageLeading
        backgroundButton.setButtonType(.pushOnPushOff)

        let pin = NSButton(title: "钉住", target: self, action: #selector(pinAction))
        let copy = NSButton(title: "复制", target: self, action: #selector(copyAction))
        let save = NSButton(title: "另存为…", target: self, action: #selector(saveAsAction))
        let done = NSButton(title: "完成", target: self, action: #selector(doneAction))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        done.bezelColor = .controlAccentColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbar = NSStackView(views: [toolControl, separator(), colors, separator(), sizeControl, undoButton, redoButton, separator(), backgroundButton,
                                          spacer, pin, copy, save, done])
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        container.canvas = canvas
        container.addSubview(canvas)
        container.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbar)
        content.addSubview(container)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        canvas.onStateChange = { [weak self] in self?.updateButtons() }
        canvas.onToolChange = { [weak self] tool in self?.toolControl.selectedSegment = tool.rawValue }
        canvas.onImageSizeChange = { [weak self] in self?.container.needsLayout = true }
        canvas.onSave = { [weak self] in self?.saveAsAction() }
        canvas.onBackgroundShortcut = { [weak self] in self?.toggleBackgroundPanel() }
        backgroundModel.onChange = { [weak self] style in self?.applyBackground(style) }
        applyBackground(backgroundModel.style)
        updateButtons()
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return box
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    private func updateButtons() {
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
        window?.isDocumentEdited = canvas.isDirty
    }

    // MARK: Actions

    @objc private func toolChanged() {
        if let tool = Tool(rawValue: toolControl.selectedSegment) { canvas.tool = tool }
        window?.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: ColorSwatch) {
        colorButtons.forEach { $0.isSelectedSwatch = $0 === sender }
        canvas.color = Self.palette[sender.tag]
        window?.makeFirstResponder(canvas)
    }

    @objc private func sizeChanged() {
        canvas.sizeLevel = sizeControl.selectedSegment
        window?.makeFirstResponder(canvas)
    }

    @objc private func toggleBackgroundPanel() {
        if backgroundPopover.isShown {
            backgroundPopover.performClose(nil)
            return
        }
        if !backgroundModel.style.enabled { backgroundModel.style.enabled = true }
        backgroundPopover.show(relativeTo: backgroundButton.bounds, of: backgroundButton, preferredEdge: .maxY)
    }

    private func applyBackground(_ style: BackdropStyle) {
        canvas.background = style
        container.style = style
        backgroundButton.state = style.enabled ? .on : .off
    }

    @objc private func undo() { canvas.undo(nil) }
    @objc private func redo() { canvas.redo(nil) }

    @objc private func copyAction() { canvas.copy(nil) }

    @objc private func saveAsAction() {
        guard let image = canvas.finalImage() else { return }
        ImageExport.saveWithPanel(image, scale: canvas.imageScale, window: window)
    }

    @objc private func pinAction() {
        guard let image = canvas.finalImage() else { return }
        PinPanel.pin(image: image, scale: canvas.imageScale)
    }

    @objc private func doneAction() {
        if canvas.tool == .crop { canvas.applyCrop() }
        guard let plain = canvas.renderedImage(), let image = canvas.finalImage() else { return }
        onDone(EditorResult(image: image, plain: plain, backdrop: canvas.background.enabled ? canvas.background : nil))
        closeEditor()
    }

    private func closeEditor() {
        window?.delegate = nil
        window?.close()
        Self.openEditors.removeAll { $0 === self }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canvas.isDirty else {
            Self.openEditors.removeAll { $0 === self }
            return true
        }
        let alert = NSAlert()
        alert.messageText = "要保留标注修改吗？"
        alert.addButton(withTitle: "保留")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: sender) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: self.doneAction()
                case .alertSecondButtonReturn: self.closeEditor()
                default: break
                }
            }
        }
        return false
    }
}

/// Centers the canvas and scales it to fit.
final class CanvasContainer: NSView {
    weak var canvas: CanvasView?
    private let backdrop = BackgroundPreviewView()
    var style = BackdropStyle() {
        didSet { needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let canvas else { return }
        let imageSize = CGSize(width: CGFloat(canvas.base.width) / canvas.imageScale,
                               height: CGFloat(canvas.base.height) / canvas.imageScale)
        let (total, imageRect) = style.enabled
            ? BackgroundRenderer.layout(imageSize: imageSize, style: style)
            : (imageSize, CGRect(origin: .zero, size: imageSize))
        let available = bounds.insetBy(dx: 24, dy: 24)
        let fit = min(1, available.width / max(total.width, 1), available.height / max(total.height, 1))
        let frame = CGRect(x: floor(bounds.midX - total.width * fit / 2), y: floor(bounds.midY - total.height * fit / 2),
                           width: floor(total.width * fit), height: floor(total.height * fit))
        let local = CGRect(x: round(imageRect.minX * fit), y: round(imageRect.minY * fit),
                           width: floor(imageRect.width * fit), height: floor(imageRect.height * fit))

        backdrop.isHidden = !style.enabled
        backdrop.frame = frame
        backdrop.style = style
        backdrop.imageRect = local
        backdrop.unit = fit
        backdrop.needsDisplay = true

        canvas.frame = local.offsetBy(dx: frame.minX, dy: frame.minY)
        canvas.applyFrameLook(cornerRadius: style.enabled ? style.cornerRadius * fit : nil)
        canvas.needsDisplay = true
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }
}

final class ColorSwatch: NSButton {
    let color: NSColor
    var isSelectedSwatch = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: r).stroke()
        if isSelectedSwatch {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}

struct EditorResult {
    /// What gets copied and saved (background included).
    let image: CGImage
    /// Annotated image without the background, for editing again later.
    let plain: CGImage
    let backdrop: BackdropStyle?
}
