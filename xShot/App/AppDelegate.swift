import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var retained: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var recordingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        NSApp.mainMenu = Self.makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "xShot")
        menu.delegate = self
        statusItem.menu = menu

        HotKeyCenter.shared.onAction = { CaptureCoordinator.shared.perform($0) }
        HotKeyCenter.shared.registerAll()
        NotificationCenter.default.addObserver(forName: .hotKeysChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HotKeyCenter.shared.registerAll() }
        }

        CaptureCoordinator.shared.recorder.onStateChange = { [weak self] in self?.updateRecordingState() }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        openDebugWindows()
    }

    /// `--settings` opens Settings; `--history` opens history; `--edit-latest` edits the newest history entry; `--edit <image> [--background]` opens the editor. Used for UI checks.
    private func openDebugWindows() {
        let args = CommandLine.arguments
        if args.contains("--settings") { SettingsWindowController.show() }
        if args.contains("--history") { HistoryWindowController.show() }
        if args.contains("--edit-latest"), let entry = CaptureHistory.shared.entries.first { HistoryActions.edit(entry) }
        if let i = args.firstIndex(of: "--edit"), i + 1 < args.count,
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            EditorWindowController.open(image: image, scale: 2, backdrop: args.contains("--background") ? BackdropStyle.load() : nil) { _ in }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemScreenshotShortcuts.restore()
    }

    // MARK: - Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addAction(.area, title: "截取区域", symbol: "rectangle.dashed")
        addAction(.window, title: "截取窗口", symbol: "macwindow")
        addAction(.fullscreen, title: "截取全屏", symbol: "display")
        addAction(.scroll, title: "滚动长截图", symbol: "arrow.down.to.line.compact")
        menu.addItem(.separator())
        addAction(.ocr, title: "识别文字 (OCR)", symbol: "text.viewfinder")
        addAction(.record, title: "录制屏幕", symbol: "record.circle")
        menu.addItem(.separator())
        addAction(.history, title: "截图历史…", symbol: "clock.arrow.circlepath")

        let icons = NSMenuItem(title: "隐藏桌面图标", action: #selector(toggleDesktopIcons), keyEquivalent: "")
        icons.target = self
        icons.state = DesktopIcons.isHidden ? .on : .off
        menu.addItem(icons)
        let folder = NSMenuItem(title: "打开截图文件夹", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "退出 xShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addAction(_ action: HotKeyAction, title: String, symbol: String) {
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let combo = action.combo, let key = combo.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = combo.nsModifiers
        }
        menu.addItem(item)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotKeyAction(rawValue: raw) else { return }
        if action == .history {
            HistoryWindowController.show()
            return
        }
        // Let the menu finish closing before the overlay freezes the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CaptureCoordinator.shared.perform(action)
        }
    }

    @objc private func toggleDesktopIcons() {
        DesktopIcons.setHidden(!DesktopIcons.isHidden)
    }

    @objc private func openFolder() {
        let url = Prefs.saveFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        SettingsWindowController.show()
    }

    // MARK: - Recording state

    private func updateRecordingState() {
        let recorder = CaptureCoordinator.shared.recorder
        guard let button = statusItem.button else { return }
        if recorder.isRecording {
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopRecording)
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "停止录制")
            button.contentTintColor = .systemRed
            button.imagePosition = .imageLeading
            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRecordingTitle() }
            }
            updateRecordingTitle()
        } else {
            recordingTimer?.invalidate()
            recordingTimer = nil
            button.title = ""
            button.action = nil
            button.contentTintColor = nil
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "xShot")
            statusItem.menu = menu
        }
    }

    private func updateRecordingTitle() {
        guard let start = CaptureCoordinator.shared.recorder.startDate else { return }
        let seconds = Int(Date().timeIntervalSince(start))
        statusItem.button?.title = String(format: " %02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func stopRecording() {
        CaptureCoordinator.shared.recorder.stop()
    }

    // MARK: - Main menu (key equivalents for editor / text fields)

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 xShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: #selector(CanvasView.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: #selector(CanvasView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "存储", action: #selector(CanvasView.saveDocument(_:)), keyEquivalent: "s")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
