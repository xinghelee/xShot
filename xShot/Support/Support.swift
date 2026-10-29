import AppKit
import ImageIO
import UniformTypeIdentifiers

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Frame in global Quartz coordinates (origin at top-left of the primary display).
    var cgFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }
}

extension CGContext {
    /// Draws an image upright into a context whose y axis points down.
    func drawFlipped(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum ImageExport {
    static func data(_ image: CGImage, format: ImageFormat, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        if format == .jpg { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func copy(_ image: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let png = data(image, format: .png, scale: scale) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    static func fileName(prefix: String, ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(prefix) \(f.string(from: Date())).\(ext)"
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(i).\(ext)")
            i += 1
        }
        return url
    }

    /// Saves into the configured screenshot folder.
    static func save(_ image: CGImage, scale: CGFloat) throws -> URL {
        let folder = Prefs.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = Prefs.imageFormat
        let url = uniqueURL(in: folder, name: fileName(prefix: "截图", ext: format.rawValue))
        try write(image, scale: scale, to: url)
        return url
    }

    static func write(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        let format: ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpg : .png
        guard let data = data(image, format: format, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    static func temporaryFile(_ image: CGImage, scale: CGFloat) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, name: fileName(prefix: "截图", ext: "png"))
        return (try? write(image, scale: scale, to: url)) != nil ? url : nil
    }

    static func saveWithPanel(_ image: CGImage, scale: CGFloat, window: NSWindow? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = fileName(prefix: "截图", ext: Prefs.imageFormat.rawValue)
        panel.directoryURL = Prefs.saveFolder
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try write(image, scale: scale, to: url) } catch { NSAlert(error: error).runModal() }
        }
        NSApp.activate()
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }
}

enum Shutter {
    private static let sound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    static func play() {
        guard Prefs.playSound else { return }
        sound?.stop()
        sound?.play()
    }
}

enum Permissions {
    static func showScreenRecordingAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在「系统设置 › 隐私与安全性 › 屏幕与系统录音」中允许 xShot，然后重新启动 xShot。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}

enum DesktopIcons {
    static var isHidden: Bool {
        let out = run("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"])
        return ["0", "false", "no"].contains(out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func setHidden(_ hidden: Bool) {
        _ = run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        _ = run("/usr/bin/killall", ["Finder"])
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

/// Small transient HUD message.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.4) {
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)

        let size = stack.fittingSize
        let screen = NSScreen.underMouse.visibleFrame
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width, height: size.height)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = size.height / 2
        bg.layer?.masksToBounds = true
        stack.frame = bg.bounds
        bg.addSubview(stack)
        p.contentView = bg
        p.orderFrontRegardless()
        panel = p

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard panel === p else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    p.orderOut(nil)
                    if panel === p { panel = nil }
                }
            })
        }
    }
}
