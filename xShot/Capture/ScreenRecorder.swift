import AppKit
import AVFoundation
import ScreenCaptureKit

final class ScreenRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var startDate: Date?
    var onStateChange: (() -> Void)?
    var onFinish: ((URL) -> Void)?

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var outputURL: URL?
    private var frameWindow: NSWindow?
    private var delivered = false
    private let sampleQueue = DispatchQueue(label: "xShot.recorder.samples")

    func start(screen: NSScreen, rect: CGRect) async throws {
        guard !isRecording else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.displayNotFound
        }
        let mine = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        // H.264 needs even dimensions.
        config.width = Int(rect.width * scale) / 2 * 2
        config.height = Int(rect.height * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Prefs.recordFPS))
        config.showsCursor = Prefs.recordCursor
        config.queueDepth = 6
        config.capturesAudio = Prefs.recordSystemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = Prefs.recordMicrophone

        // GIF-only recordings keep the intermediate MP4 out of the screenshot folder.
        let folder = Prefs.recordFormat == .gif
            ? FileManager.default.temporaryDirectory.appendingPathComponent("xShot", isDirectory: true)
            : Prefs.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = ImageExport.uniqueURL(in: folder, name: ImageExport.fileName(prefix: "录屏", ext: "mp4"))

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mp4
        recordingConfig.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        outputURL = url
        delivered = false
        isRecording = true
        startDate = Date()
        showFrame(screen: screen, rect: rect)
        onStateChange?()
    }

    func stop() {
        guard isRecording, let stream else { return }
        isRecording = false
        startDate = nil
        frameWindow?.orderOut(nil)
        frameWindow = nil
        onStateChange?()
        Task {
            try? await stream.stopCapture()
            // Fallback in case the recording delegate never reports completion.
            try? await Task.sleep(for: .seconds(2))
            self.deliver()
        }
    }

    private func deliver() {
        guard !delivered, let url = outputURL else { return }
        delivered = true
        stream = nil
        output = nil
        onFinish?(url)
    }

    private func failed(_ error: Error) {
        NSLog("xShot: recording failed: \(error)")
        if isRecording {
            isRecording = false
            startDate = nil
            frameWindow?.orderOut(nil)
            frameWindow = nil
            onStateChange?()
        }
        stream = nil
        output = nil
        Toast.show("录制失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
    }

    /// Dashed border around the recorded area. xShot's windows are excluded from capture, so it never shows up in the video.
    private func showFrame(screen: NSScreen, rect: CGRect) {
        guard rect.size != screen.frame.size else { return }
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
        border.strokeColor = NSColor.systemRed.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 4]
        view.layer?.addSublayer(border)
        w.contentView = view
        w.orderFrontRegardless()
        frameWindow = w
    }
}

extension ScreenRecorder: SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.failed(error) } }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.failed(error) } }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver() } }
    }
}
