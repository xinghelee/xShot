import AppKit
import AVFoundation

final class CaptureItem {
    enum Kind: String, Codable { case image, video, gif }

    let kind: Kind
    /// The capture itself, or a poster frame for videos.
    var image: CGImage
    let scale: CGFloat
    var fileURL: URL?
    var historyID: UUID?
    /// Set when a background was applied automatically: the capture before compositing, and the style used.
    var original: CGImage?
    var backdrop: BackdropStyle?

    init(kind: Kind, image: CGImage, scale: CGFloat, fileURL: URL? = nil) {
        self.kind = kind
        self.image = image
        self.scale = scale
        self.fileURL = fileURL
    }

    var pointSize: NSSize { NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }
}

final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    let recorder = ScreenRecorder()

    private init() {
        recorder.onFinish = { [weak self] url in self?.deliverVideo(url) }
    }

    func perform(_ action: HotKeyAction) {
        if action == .record {
            toggleRecording()
            return
        }
        if action == .history {
            HistoryWindowController.show()
            return
        }
        guard !SelectionController.isActive, !ScrollingCaptureSession.isActive, !recorder.isRecording else { return }
        switch action {
        case .area: captureArea(windowMode: false)
        case .window: captureArea(windowMode: true)
        case .fullscreen: captureFullscreen()
        case .scroll: ScrollingCaptureSession.start()
        case .ocr: recognizeText()
        case .record, .history: break
        }
    }

    // MARK: Screenshots

    private func captureArea(windowMode: Bool) {
        SelectionController.begin(purpose: .capture, windowMode: windowMode) { selection in
            guard let selection else { return }
            Task {
                let isWindow = selection.windowID != nil
                // The backdrop draws its own shadow; the system one would double it.
                let shadow = Prefs.windowShadow && !Prefs.autoBackground.applies(toWindow: true)
                if let id = selection.windowID, let (image, scale) = try? await Capturer.captureWindow(id, shadow: shadow) {
                    self.deliver(image, scale: scale, isWindow: true)
                } else if let image = selection.croppedImage {
                    self.deliver(image, scale: selection.pixelScale, isWindow: isWindow)
                }
            }
        }
    }

    private func captureFullscreen() {
        let screen = NSScreen.underMouse
        Task {
            do {
                let image = try await Capturer.captureDisplay(screen)
                deliver(image, scale: CGFloat(image.width) / screen.frame.width)
            } catch {
                Permissions.showScreenRecordingAlert()
            }
        }
    }

    func deliver(_ image: CGImage, scale: CGFloat, isWindow: Bool = false) {
        Shutter.play()
        let item = CaptureItem(kind: .image, image: image, scale: scale)
        if Prefs.autoBackground.applies(toWindow: isWindow) {
            var style = BackdropStyle.load()
            style.enabled = true
            if let composed = BackgroundRenderer.compose(image, scale: scale, style: style) {
                item.original = image
                item.backdrop = style
                item.image = composed
            }
        }
        if Prefs.copyToClipboard { ImageExport.copy(item.image, scale: scale) }
        if Prefs.autoSave {
            do { item.fileURL = try ImageExport.save(item.image, scale: scale) } catch { NSAlert(error: error).runModal() }
        }
        CaptureHistory.shared.record(item)
        if Prefs.showQuickAccess {
            QuickAccessManager.shared.show(item)
        } else if Prefs.copyToClipboard {
            Toast.show("已复制到剪贴板")
        }
    }

    // MARK: OCR

    private func recognizeText() {
        SelectionController.begin(purpose: .ocr) { selection in
            guard let image = selection?.croppedImage else { return }
            Self.recognize(image)
        }
    }

    static func recognize(_ image: CGImage) {
        Task {
            do {
                let text = try await TextRecognizer.recognize(image)
                if text.isEmpty {
                    Toast.show("未识别到文字", symbol: "text.magnifyingglass")
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    Toast.show("已复制识别的文字（\(text.count) 字）", symbol: "text.viewfinder")
                }
            } catch {
                Toast.show("识别失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: Recording

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            return
        }
        guard !SelectionController.isActive else { return }
        SelectionController.begin(purpose: .record) { selection in
            guard let selection else { return }
            Task {
                do {
                    try await self.recorder.start(screen: selection.screen, rect: selection.rect)
                } catch {
                    NSLog("xShot: failed to start recording: \(error)")
                    Toast.show("无法开始录制：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    private func deliverVideo(_ url: URL) {
        Task {
            switch Prefs.recordFormat {
            case .mp4:
                await showVideo(url)
            case .gif:
                if let gif = await makeGIF(from: url) {
                    try? FileManager.default.removeItem(at: url)
                    showGIF(gif)
                } else {
                    await showVideo(url)
                }
            case .both:
                await showVideo(url)
                if let gif = await makeGIF(from: url) { showGIF(gif) }
            }
        }
    }

    func exportGIF(_ item: CaptureItem) {
        guard item.kind == .video, let url = item.fileURL else { return }
        Task {
            if let gif = await makeGIF(from: url) { showGIF(gif) }
        }
    }

    private func makeGIF(from video: URL) async -> URL? {
        Toast.show("正在生成 GIF…", symbol: "hourglass", duration: 3600)
        let folder = Prefs.saveFolder
        let output = ImageExport.uniqueURL(in: folder, name: video.deletingPathExtension().lastPathComponent + ".gif")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await GIFExporter.export(video: video, to: output, fps: Prefs.gifFPS, maxWidth: Prefs.gifMaxWidth)
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? ""
            Toast.show("GIF 已生成 \(size)", symbol: "photo.stack")
            return output
        } catch {
            Toast.show("GIF 生成失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            return nil
        }
    }

    private func showGIF(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let poster = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let item = CaptureItem(kind: .gif, image: poster, scale: 2, fileURL: url)
        CaptureHistory.shared.record(item)
        QuickAccessManager.shared.show(item)
    }

    private func showVideo(_ url: URL) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        guard let poster = try? await generator.image(at: .zero).image else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let item = CaptureItem(kind: .video, image: poster, scale: 2, fileURL: url)
        CaptureHistory.shared.record(item)
        QuickAccessManager.shared.show(item)
    }

    // MARK: Item actions

    func openEditor(_ item: CaptureItem) {
        EditorWindowController.open(image: item.original ?? item.image, scale: item.scale, backdrop: item.backdrop) { result in
            let edited = result.image
            item.image = edited
            item.original = result.backdrop == nil ? nil : result.plain
            item.backdrop = result.backdrop
            if Prefs.copyToClipboard { ImageExport.copy(edited, scale: item.scale) }
            if let url = item.fileURL {
                try? ImageExport.write(edited, scale: item.scale, to: url)
            } else if Prefs.autoSave {
                item.fileURL = try? ImageExport.save(edited, scale: item.scale)
            }
            CaptureHistory.shared.update(item, imageChanged: true)
            QuickAccessManager.shared.refresh(item)
        }
    }

    static func copy(_ item: CaptureItem) {
        switch item.kind {
        case .image:
            ImageExport.copy(item.image, scale: item.scale)
        case .video:
            guard let url = item.fileURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        case .gif:
            // Raw GIF data keeps the animation when pasting into chat apps; the file URL covers Finder.
            guard let url = item.fileURL else { return }
            let pbItem = NSPasteboardItem()
            if let data = try? Data(contentsOf: url) { pbItem.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif")) }
            pbItem.setString(url.absoluteString, forType: .fileURL)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([pbItem])
        }
    }

    func pin(_ item: CaptureItem) {
        PinPanel.pin(image: item.image, scale: item.scale)
    }
}
