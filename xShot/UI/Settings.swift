import AppKit
import ServiceManagement
import SwiftUI

final class SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "xShot 设置"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutSettings().tabItem { Label("快捷键", systemImage: "keyboard") }
            BackgroundSettings().tabItem { Label("背景", systemImage: "photo.artframe") }
            RecordingSettings().tabItem { Label("录屏", systemImage: "record.circle") }
        }
        .frame(width: 540, height: 560)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PrefKey.copyToClipboard) private var copyToClipboard = true
    @AppStorage(PrefKey.autoSave) private var autoSave = true
    @AppStorage(PrefKey.saveFolder) private var saveFolder = ""
    @AppStorage(PrefKey.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    @AppStorage(PrefKey.showQuickAccess) private var showQuickAccess = true
    @AppStorage(PrefKey.quickAccessTimeout) private var quickAccessTimeout = 0
    @AppStorage(PrefKey.windowShadow) private var windowShadow = true
    @AppStorage(PrefKey.playSound) private var playSound = true
    @AppStorage(PrefKey.showMagnifier) private var showMagnifier = true
    @AppStorage(PrefKey.historyDays) private var historyDays = 7
    @State private var historySize = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("xShot: launch at login failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("截图后") {
                Toggle("复制到剪贴板", isOn: $copyToClipboard)
                Toggle("保存到文件夹", isOn: $autoSave)
                Toggle("显示快速预览浮窗", isOn: $showQuickAccess)
                Picker("浮窗自动关闭", selection: $quickAccessTimeout) {
                    Text("从不").tag(0)
                    Text("5 秒").tag(5)
                    Text("10 秒").tag(10)
                    Text("20 秒").tag(20)
                    Text("60 秒").tag(60)
                }
                .disabled(!showQuickAccess)
                Toggle("播放快门声", isOn: $playSound)
            }
            Section("文件") {
                LabeledContent("保存位置") {
                    HStack {
                        Text(displayFolder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("选择…", action: chooseFolder)
                    }
                }
                Picker("图片格式", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("截图") {
                Toggle("窗口截图包含阴影", isOn: $windowShadow)
                Toggle("区域选择时显示放大镜", isOn: $showMagnifier)
            }
            Section {
                Picker("保留截图历史", selection: $historyDays) {
                    Text("1 天").tag(1)
                    Text("1 周").tag(7)
                    Text("1 个月").tag(30)
                    Text("永久").tag(-1)
                    Text("关闭").tag(0)
                }
                .onChange(of: historyDays) { _, _ in
                    CaptureHistory.shared.prune()
                    updateHistorySize()
                }
                LabeledContent("占用空间") {
                    HStack {
                        Text(historySize).foregroundStyle(.secondary)
                        Button("打开历史") { HistoryWindowController.show() }
                        Button("清空…") {
                            HistoryActions.confirmClear()
                            updateHistorySize()
                        }
                    }
                }
            } header: {
                Text("截图历史")
            } footer: {
                Text("历史记录单独保存每张截图的副本，即使关闭了「保存到文件夹」或删除了文件也能找回。录屏和 GIF 只记录文件位置。选「关闭」后不再记录新的截图，已有历史保留。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: updateHistorySize)
    }

    private func updateHistorySize() {
        Task.detached {
            let bytes = CaptureHistory.diskUsage()
            let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            await MainActor.run { historySize = text }
        }
    }

    private var displayFolder: String {
        (saveFolder.isEmpty ? Prefs.defaultFolder.path : saveFolder).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.saveFolder
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url.path }
    }
}

private struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action).frame(width: 150, height: 24)
                    }
                }
            } footer: {
                Text("点击后按下新的快捷键，按 ⌫ 清除，按 Esc 取消。与系统截屏冲突的快捷键（⇧⌘3 / ⇧⌘4 / ⇧⌘5 等）会在 xShot 运行期间自动接管，退出后恢复，不改动系统设置。区域截图时按空格可切换到窗口截图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("恢复默认快捷键") {
                    HotKeyAction.allCases.forEach { $0.combo = $0.defaultCombo }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct BackgroundSettings: View {
    @AppStorage(PrefKey.autoBackground) private var autoBackground = AutoBackground.off.rawValue
    @StateObject private var model = BackgroundModel(style: BackdropStyle.load())

    var body: some View {
        Form {
            Section {
                Picker("截图后自动添加背景", selection: $autoBackground) {
                    ForEach(AutoBackground.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("复制、保存和预览浮窗里的都是加好背景的图。之后打开标注编辑器，背景仍可调整或关掉。开启后窗口截图不再带系统阴影，由背景的阴影代替。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("样式") {
                HStack(alignment: .top, spacing: 0) {
                    BackgroundPanel(model: model, showsToggle: false)
                    BackdropPreview(style: model.style)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(.top, 8)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.style = BackdropStyle.load() }
    }
}

private struct RecordingSettings: View {
    @AppStorage(PrefKey.recordCursor) private var recordCursor = true
    @AppStorage(PrefKey.recordSystemAudio) private var recordSystemAudio = false
    @AppStorage(PrefKey.recordMicrophone) private var recordMicrophone = false
    @AppStorage(PrefKey.recordFPS) private var recordFPS = 60
    @AppStorage(PrefKey.recordFormat) private var recordFormat = RecordingFormat.mp4.rawValue
    @AppStorage(PrefKey.gifFPS) private var gifFPS = 15
    @AppStorage(PrefKey.gifMaxWidth) private var gifMaxWidth = 960

    var body: some View {
        Form {
            Section {
                Toggle("显示鼠标指针", isOn: $recordCursor)
                Toggle("录制系统声音", isOn: $recordSystemAudio)
                Toggle("录制麦克风", isOn: $recordMicrophone)
                Picker("帧率", selection: $recordFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            } footer: {
                Text("录屏存放在截图文件夹中。录制时点击菜单栏的红色按钮或再按一次录屏快捷键停止。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("输出格式", selection: $recordFormat) {
                    ForEach(RecordingFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("GIF 帧率", selection: $gifFPS) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("20 fps").tag(20)
                    Text("25 fps").tag(25)
                }
                Picker("GIF 最大宽度", selection: $gifMaxWidth) {
                    Text("480 px").tag(480)
                    Text("640 px").tag(640)
                    Text("960 px").tag(960)
                    Text("1280 px").tag(1280)
                    Text("原始尺寸").tag(0)
                }
            } header: {
                Text("GIF")
            } footer: {
                Text("录完后也可以在预览浮窗上点 GIF 按钮把 MP4 转成 GIF。帧率越低、宽度越小，文件越小。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcut recorder

private struct ShortcutRecorder: NSViewRepresentable {
    let action: HotKeyAction

    func makeNSView(context: Context) -> ShortcutRecorderView {
        ShortcutRecorderView(action: action)
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {}
}

final class ShortcutRecorderView: NSButton {
    private let hotKeyAction: HotKeyAction
    private var recording = false { didSet { refresh() } }

    init(action: HotKeyAction) {
        hotKeyAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        self.action = #selector(startRecording)
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFromNotification), name: .hotKeysChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func refreshFromNotification() { refresh() }

    private func refresh() {
        if recording {
            title = "按下快捷键…"
        } else {
            title = hotKeyAction.combo?.display ?? "未设置"
        }
    }

    @objc private func startRecording() {
        HotKeyCenter.shared.unregisterAll()
        recording = true
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        recording = false
        HotKeyCenter.shared.registerAll()
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        if recording { stopRecording() }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 53 where mods.isEmpty:
            stopRecording()
        case 51 where mods.isEmpty, 117 where mods.isEmpty:
            hotKeyAction.combo = nil
            stopRecording()
        default:
            let isFunctionKey = (96...122).contains(Int(event.keyCode))
            guard !mods.subtracting(.shift).isEmpty || isFunctionKey else {
                NSSound.beep()
                return
            }
            hotKeyAction.combo = KeyCombo(event: event)
            stopRecording()
        }
    }
}
