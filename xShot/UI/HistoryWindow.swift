import AppKit
import SwiftUI

final class HistoryWindowController {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "截图历史"
            w.contentMinSize = NSSize(width: 480, height: 360)
            w.contentView = NSHostingView(rootView: HistoryView())
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("xShot.history")
            window = w
        }
        CaptureHistory.shared.prune()
        if let window, !window.isVisible { moveToMouseScreen(window) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is only a request (refused when triggered after the menu closed or from a hotkey);
        // make sure the window still comes to the front.
        window?.orderFrontRegardless()
    }

    private static func moveToMouseScreen(_ window: NSWindow) {
        let screen = NSScreen.underMouse.visibleFrame
        guard !screen.intersects(window.frame) else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
        window.setFrame(frame, display: false)
    }
}

// MARK: - Actions

enum HistoryActions {
    private static var history: CaptureHistory { .shared }

    static func open(_ entry: HistoryEntry) {
        if entry.kind == .image { edit(entry) } else if let url = history.savedURL(entry) { NSWorkspace.shared.open(url) }
    }

    static func copy(_ entry: HistoryEntry) {
        guard let item = history.item(for: entry) else { return }
        CaptureCoordinator.copy(item)
        Toast.show("已复制")
    }

    static func edit(_ entry: HistoryEntry) {
        guard let item = history.item(for: entry) else { return }
        CaptureCoordinator.shared.openEditor(item)
    }

    static func pin(_ entry: HistoryEntry) {
        guard let item = history.item(for: entry) else { return }
        CaptureCoordinator.shared.pin(item)
    }

    static func recognize(_ entry: HistoryEntry) {
        guard let item = history.item(for: entry) else { return }
        CaptureCoordinator.recognize(item.image)
    }

    static func showQuickAccess(_ entry: HistoryEntry) {
        guard let item = history.item(for: entry) else { return }
        QuickAccessManager.shared.show(item)
    }

    static func reveal(_ entry: HistoryEntry) {
        guard let url = history.fileURL(entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func saveAs(_ entry: HistoryEntry) {
        guard let item = history.item(for: entry) else { return }
        ImageExport.saveWithPanel(item.image, scale: item.scale, window: NSApp.keyWindow)
    }

    static func remove(_ ids: Set<UUID>) {
        history.remove(ids)
    }

    static func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "清空截图历史？"
        alert.informativeText = "只删除历史记录里的副本，截图文件夹中已保存的文件不受影响。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { history.clear() }
    }

    static func dragProvider(_ entry: HistoryEntry) -> NSItemProvider {
        guard let url = history.fileURL(entry) else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}

// MARK: - Views

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, images, recordings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .images: "截图"
        case .recordings: "录屏"
        }
    }

    func includes(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: true
        case .images: entry.kind == .image
        case .recordings: entry.kind != .image
        }
    }
}

private struct HistoryView: View {
    @ObservedObject private var history = CaptureHistory.shared
    @State private var filter = HistoryFilter.all
    @State private var selection: UUID?

    private var visible: [HistoryEntry] { history.entries.filter(filter.includes) }

    private var groups: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var result: [(day: Date, entries: [HistoryEntry])] = []
        for entry in visible {
            let day = calendar.startOfDay(for: entry.date)
            if result.last?.day == day { result[result.count - 1].entries.append(entry) } else { result.append((day, [entry])) }
        }
        return result
    }

    private var selected: HistoryEntry? { history.entries.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("\(visible.count) 项").foregroundStyle(.secondary)
                Button("清空…") { HistoryActions.confirmClear() }.disabled(history.entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView("暂无记录", systemImage: "clock.arrow.circlepath",
                                       description: Text(Prefs.historyDays == 0 ? "截图历史已在设置中关闭。" : "截图和录屏会自动出现在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.day) { group in
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)], spacing: 16) {
                            ForEach(group.entries) { entry in
                                HistoryCell(entry: entry, selected: entry.id == selection)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { HistoryActions.open(entry) }
                                    .simultaneousGesture(TapGesture().onEnded { selection = entry.id })
                                    .onDrag { HistoryActions.dragProvider(entry) }
                                    .contextMenu { menu(for: entry) }
                            }
                        }
                        .padding(.horizontal, 16)
                    } header: {
                        Text(Self.dayTitle(group.day))
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .focusable()
        .focusEffectDisabled()
        .onCopyCommand {
            if let selected { HistoryActions.copy(selected) }
            return []
        }
        .onDeleteCommand {
            if let id = selection { HistoryActions.remove([id]) }
        }
    }

    @ViewBuilder
    private func menu(for entry: HistoryEntry) -> some View {
        Button("复制") { HistoryActions.copy(entry) }
        if entry.kind == .image {
            Button("标注") { HistoryActions.edit(entry) }
            Button("钉在屏幕上") { HistoryActions.pin(entry) }
            Button("识别文字") { HistoryActions.recognize(entry) }
        } else {
            Button("打开") { HistoryActions.open(entry) }
        }
        Button("显示预览浮窗") { HistoryActions.showQuickAccess(entry) }
        Divider()
        Button("在访达中显示") { HistoryActions.reveal(entry) }
        if entry.kind == .image { Button("另存为…") { HistoryActions.saveAs(entry) } }
        Divider()
        Button("从历史中移除") { HistoryActions.remove([entry.id]) }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = calendar.isDate(day, equalTo: Date(), toGranularity: .year) ? "M月d日 EEEE" : "yyyy年M月d日 EEEE"
        return f.string(from: day)
    }
}

private struct HistoryCell: View {
    let entry: HistoryEntry
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
                if let thumb = CaptureHistory.shared.thumbnail(entry) {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .padding(8)
                }
                if entry.kind != .image {
                    Label(entry.kind == .gif ? "GIF" : "视频", systemImage: entry.kind == .gif ? "photo.stack" : "play.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(8)
                }
                if hovering { hoverButtons }
            }
            .frame(height: 130)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))

            HStack {
                Text(entry.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "zh_CN"))))
                Spacer()
                Text(verbatim: "\(entry.pixelWidth) × \(entry.pixelHeight)").foregroundStyle(.secondary)
            }
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 2)
        }
        .onHover { hovering = $0 }
    }

    private var hoverButtons: some View {
        HStack(spacing: 4) {
            iconButton("doc.on.doc", help: "复制") { HistoryActions.copy(entry) }
            if entry.kind == .image {
                iconButton("pencil.tip", help: "标注") { HistoryActions.edit(entry) }
                iconButton("pin", help: "钉在屏幕上") { HistoryActions.pin(entry) }
            } else {
                iconButton("play", help: "打开") { HistoryActions.open(entry) }
            }
            iconButton("trash", help: "从历史中移除") { HistoryActions.remove([entry.id]) }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
