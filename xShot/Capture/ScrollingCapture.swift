import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Stitches successive frames of a vertically scrolling region into one tall image.
/// Frames are compared row by row: rows that stay put between frames (sticky headers,
/// footers) are left out of the matching, and the scroll offset is the shift that makes
/// the remaining rows line up.
nonisolated final class ScrollStitcher: @unchecked Sendable {
    enum Result { case first, unchanged, appended(Int), noMatch, full }

    let width: Int
    let height: Int
    let maxRows = 30000
    private let rowBytes: Int
    private(set) var rows = 0
    private var data = Data()
    private var prevHashes: [Int] = []
    private var prevFlat: [Bool] = []

    /// 1/8 scale copy of the content, for the live preview.
    static let previewFactor = 8
    private(set) var preview = Data()
    private(set) var previewRows = 0
    private var contentRows = 0
    var previewWidth: Int { max(1, width / Self.previewFactor) }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        rowBytes = width * 4
    }

    func add(_ image: CGImage) -> Result {
        guard rows < maxRows else { return .full }
        guard let px = rgba(image) else { return .noMatch }
        let (hashes, flat) = rowInfo(px)
        let H = height

        if prevHashes.isEmpty {
            data.append(px)
            rows = H
            appendPreview(px, from: 0, count: H)
            prevHashes = hashes
            prevFlat = flat
            return .first
        }
        if hashes == prevHashes { return .unchanged }

        var top = 0
        while top < H, hashes[top] == prevHashes[top] { top += 1 }
        var footer = 0
        while footer < H - top, hashes[H - 1 - footer] == prevHashes[H - 1 - footer] { footer += 1 }
        let zoneEnd = H - footer

        var best: (offset: Int, matches: Int)?
        let minOverlap = max(8, (zoneEnd - top) / 10)
        if zoneEnd - top > minOverlap {
            for d in 1..<(zoneEnd - top - minOverlap) {
                var matches = 0, misses = 0
                let candidates = zoneEnd - d - top
                let allowedMisses = candidates / 30
                for i in top..<(zoneEnd - d) {
                    if hashes[i] == prevHashes[i + d] {
                        if !prevFlat[i + d] { matches += 1 }
                    } else {
                        misses += 1
                        if misses > allowedMisses { break }
                    }
                }
                guard misses <= allowedMisses, matches >= 6 else { continue }
                if best == nil || matches > best!.matches { best = (d, matches) }
            }
        }

        guard let (d, _) = best else { return .noMatch }

        // The stitched image ends with the previous frame's footer; swap it for the new rows plus the footer.
        data.removeLast(footer * rowBytes)
        data.append(px[((H - footer - d) * rowBytes)..<(H * rowBytes)])
        rows += d
        appendPreview(px, from: H - footer - d, count: d)
        prevHashes = hashes
        prevFlat = flat
        return rows >= maxRows ? .full : .appended(d)
    }

    func makeImage(colorSpace: CGColorSpace) -> CGImage? {
        guard rows > 0, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func makePreview() -> CGImage? {
        guard previewRows > 0, let provider = CGDataProvider(data: preview as CFData) else { return nil }
        return CGImage(width: previewWidth, height: previewRows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: previewWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func appendPreview(_ px: Data, from start: Int, count: Int) {
        let f = Self.previewFactor
        px.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt32.self)
            for r in start..<(start + count) {
                defer { contentRows += 1 }
                guard contentRows % f == 0 else { continue }
                var row = [UInt32](repeating: 0, count: previewWidth)
                for x in 0..<previewWidth { row[x] = pixels[r * width + min(x * f, width - 1)] }
                row.withUnsafeBytes { preview.append(contentsOf: $0) }
                previewRows += 1
            }
        }
    }

    private func rgba(_ image: CGImage) -> Data? {
        var data = Data(count: rowBytes * height)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    /// Per-row hash, and whether the row is a single flat color (matches anything, so it carries no signal).
    private func rowInfo(_ px: Data) -> ([Int], [Bool]) {
        var hashes = [Int](repeating: 0, count: height)
        var flat = [Bool](repeating: false, count: height)
        px.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt32.self)
            for r in 0..<height {
                let row = UnsafeBufferPointer(rebasing: pixels[(r * width)..<((r + 1) * width)])
                var hasher = Hasher()
                hasher.combine(bytes: UnsafeRawBufferPointer(row))
                hashes[r] = hasher.finalize()
                let first = row[0]
                flat[r] = !row.contains { $0 != first }
            }
        }
        return (hashes, flat)
    }
}

final class ScrollingCaptureSession {
    private static var current: ScrollingCaptureSession?
    static var isActive: Bool { current != nil }

    private let screen: NSScreen
    private let rect: CGRect
    private let scale: CGFloat
    private let stitcher: ScrollStitcher
    private var active = true
    private var autoScroll = false
    private var unchangedCount = 0
    private var loop: Task<Void, Never>?
    private var keyMonitor: Any?

    private var frameWindow: NSWindow?
    private let panel: NSPanel
    private let previewView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "向下滚动内容开始拼接")
    private let autoButton = NSButton(title: "自动滚动", target: nil, action: nil)

    static func start() {
        guard current == nil else { return }
        SelectionController.begin(purpose: .scroll) { selection in
            guard let selection, selection.rect.width >= 20, selection.rect.height >= 40 else { return }
            let session = ScrollingCaptureSession(selection: selection)
            current = session
            session.begin()
        }
    }

    private init(selection: Selection) {
        screen = selection.screen
        rect = selection.rect
        scale = selection.pixelScale
        stitcher = ScrollStitcher(width: Int(rect.width * scale), height: Int(rect.height * scale))
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    private func begin() {
        showFrame()
        showPanel()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch Int(event.keyCode) {
            case 53: self?.cancel(); return nil
            case 36, 76: self?.finish(); return nil
            default: return event
            }
        }
        loop = Task { await run() }
    }

    // MARK: Capture loop

    private func run() async {
        let filter: SCContentFilter
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
            let mine = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        } catch {
            Permissions.showScreenRecordingAlert()
            cancel()
            return
        }
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = stitcher.width
        config.height = stitcher.height
        config.showsCursor = false
        config.captureResolution = .best

        let stitcher = self.stitcher
        while active {
            if autoScroll { postScroll() }
            try? await Task.sleep(for: .milliseconds(autoScroll ? 180 : 70))
            guard active, let frame = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { continue }
            let result = await Task.detached(priority: .userInitiated) { stitcher.add(frame) }.value
            handle(result)
        }
    }

    private func handle(_ result: ScrollStitcher.Result) {
        let height = Int(CGFloat(stitcher.rows) / scale)
        switch result {
        case .first:
            updatePreview()
        case .appended:
            unchangedCount = 0
            statusLabel.stringValue = "已拼接 \(height) pt"
            statusLabel.textColor = .secondaryLabelColor
            updatePreview()
        case .unchanged:
            unchangedCount += 1
            if autoScroll, unchangedCount >= 8 {
                setAutoScroll(false)
                statusLabel.stringValue = "已到底部 · \(height) pt"
            }
        case .noMatch:
            statusLabel.stringValue = "滚动太快，请往回滚一点"
            statusLabel.textColor = .systemOrange
        case .full:
            setAutoScroll(false)
            statusLabel.stringValue = "已达最大长度"
            statusLabel.textColor = .systemOrange
        }
    }

    private func updatePreview() {
        guard let image = stitcher.makePreview() else { return }
        previewView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: Auto scroll

    @objc private func toggleAutoScroll() {
        setAutoScroll(!autoScroll)
    }

    private func setAutoScroll(_ on: Bool) {
        if on {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(options) else {
                statusLabel.stringValue = "自动滚动需要「辅助功能」权限"
                statusLabel.textColor = .systemOrange
                return
            }
            CGWarpMouseCursorPosition(scrollPoint)
            unchangedCount = 0
        }
        autoScroll = on
        autoButton.state = on ? .on : .off
        autoButton.title = on ? "停止滚动" : "自动滚动"
    }

    private var scrollPoint: CGPoint {
        CGPoint(x: screen.cgFrame.minX + rect.midX, y: screen.cgFrame.minY + rect.midY)
    }

    private func postScroll() {
        let step = Int32(max(20, rect.height * 0.3))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0) else { return }
        event.location = scrollPoint
        event.post(tap: .cghidEventTap)
    }

    // MARK: Finish

    @objc private func finish() {
        guard active else { return }
        let loop = loop
        tearDown()
        Task {
            await loop?.value
            guard let image = stitcher.makeImage(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return }
            CaptureCoordinator.shared.deliver(image, scale: scale)
        }
    }

    @objc private func cancel() {
        guard active else { return }
        tearDown()
    }

    private func tearDown() {
        active = false
        autoScroll = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        frameWindow?.orderOut(nil)
        panel.orderOut(nil)
        ScrollingCaptureSession.current = nil
    }

    // MARK: UI

    private func showFrame() {
        let inset: CGFloat = 3
        let frame = NSRect(x: screen.frame.minX + rect.minX - inset, y: screen.frame.maxY - rect.maxY - inset,
                           width: rect.width + inset * 2, height: rect.height + inset * 2)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let border = CAShapeLayer()
        border.path = CGPath(rect: view.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 4]
        view.layer?.addSublayer(border)
        w.contentView = view
        w.orderFrontRegardless()
        frameWindow = w
    }

    private func showPanel() {
        let panelWidth: CGFloat = 170
        let previewHeight = min(rect.height - 110, 420)

        previewView.imageScaling = .scaleProportionallyDown
        previewView.imageAlignment = .alignBottom
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        previewView.layer?.cornerRadius = 6
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.heightAnchor.constraint(equalToConstant: max(previewHeight, 60)).isActive = true
        previewView.widthAnchor.constraint(equalToConstant: panelWidth - 24).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = panelWidth - 24

        autoButton.setButtonType(.pushOnPushOff)
        autoButton.target = self
        autoButton.action = #selector(toggleAutoScroll)
        let done = NSButton(title: "完成 ↩", target: self, action: #selector(finish))
        done.bezelColor = .controlAccentColor
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        for b in [autoButton, done, cancel] {
            b.controlSize = .regular
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: panelWidth - 24).isActive = true
        }

        let stack = NSStackView(views: [previewView, statusLabel, autoButton, done, cancel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let size = stack.fittingSize

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        stack.frame = bg.bounds
        bg.addSubview(stack)

        // Beside the region if there's room, otherwise tucked inside its edge.
        let region = NSRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let visible = screen.visibleFrame
        var x = region.maxX + 12
        if x + size.width > visible.maxX { x = region.minX - 12 - size.width }
        if x < visible.minX { x = region.maxX - size.width - 12 }
        let y = min(max(region.maxY - size.height, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        panel.contentView = bg
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
    }
}
