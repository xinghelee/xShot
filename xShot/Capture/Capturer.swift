import AppKit
import ScreenCaptureKit
import Vision

enum CaptureError: LocalizedError {
    case displayNotFound, windowNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "找不到显示器"
        case .windowNotFound: "找不到窗口"
        }
    }
}

struct WindowInfo {
    let id: CGWindowID
    /// Global Quartz coordinates.
    let frame: CGRect
}

enum Capturer {
    /// Captures every screen, excluding xShot's own windows.
    static func captureDisplays(_ screens: [NSScreen]) async throws -> [CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mine = content.applications.filter { $0.processID == getpid() }
        var images: [CGImage] = []
        for screen in screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                throw CaptureError.displayNotFound
            }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            images.append(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
        }
        return images
    }

    static func captureDisplay(_ screen: NSScreen) async throws -> CGImage {
        try await captureDisplays([screen])[0]
    }

    /// Captures a single window on its own (transparent corners, optional shadow).
    static func captureWindow(_ id: CGWindowID, shadow: Bool) async throws -> (CGImage, CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.shouldBeOpaque = false
        config.ignoreShadowsSingleWindow = !shadow
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), scale)
    }

    /// Normal app windows on screen, front to back.
    static func visibleWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let pid = getpid()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  frame.width > 30, frame.height > 30 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 { return nil }
            return WindowInfo(id: id, frame: frame)
        }
    }
}

enum TextRecognizer {
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}
