import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: CaptureItem.Kind
    let scale: CGFloat
    var pixelWidth: Int
    var pixelHeight: Int
    /// The user-visible file (screenshot folder). For videos and GIFs this is the only copy.
    var savedPath: String?
    /// Name of history's own PNG copy inside the entry folder (images only).
    var fileName: String
    /// Bumped whenever the image is replaced, so cached thumbnails are refreshed.
    var revision = 0
    /// Set when the capture has a background: `original.png` then holds the image without it, so it stays adjustable.
    var backdrop: BackdropStyle?
}

/// Keeps every capture (own PNG copy + thumbnail) in Application Support, pruned by age.
final class CaptureHistory: ObservableObject {
    static let shared = CaptureHistory()

    @Published private(set) var entries: [HistoryEntry] = []

    nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("xShot/History", isDirectory: true)
    var folder: URL { Self.folder }
    private let maxEntries = 3000
    private let io = DispatchQueue(label: "xShot.history")
    private var thumbs: [String: NSImage] = [:]
    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = list
        }
        prune()
    }

    // MARK: Paths

    func directory(_ entry: HistoryEntry) -> URL { folder.appendingPathComponent(entry.id.uuidString, isDirectory: true) }
    func imageURL(_ entry: HistoryEntry) -> URL { directory(entry).appendingPathComponent(entry.fileName) }
    func thumbnailURL(_ entry: HistoryEntry) -> URL { directory(entry).appendingPathComponent("thumb.jpg") }
    func originalURL(_ entry: HistoryEntry) -> URL { directory(entry).appendingPathComponent("original.png") }

    func savedURL(_ entry: HistoryEntry) -> URL? {
        guard let path = entry.savedPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The file to drag out or reveal: the saved copy if it is still there, otherwise history's own.
    func fileURL(_ entry: HistoryEntry) -> URL? {
        if let url = savedURL(entry) { return url }
        guard entry.kind == .image else { return nil }
        io.sync {}
        return imageURL(entry)
    }

    // MARK: Recording

    func record(_ item: CaptureItem) {
        guard Prefs.historyDays != 0 else { return }
        let base = item.fileURL?.deletingPathExtension().lastPathComponent
            ?? (ImageExport.fileName(prefix: "截图", ext: "png") as NSString).deletingPathExtension
        var entry = HistoryEntry(id: UUID(), date: Date(), kind: item.kind, scale: item.scale,
                                 pixelWidth: item.image.width, pixelHeight: item.image.height,
                                 savedPath: item.fileURL?.path, fileName: base + ".png")
        entry.backdrop = item.original == nil ? nil : item.backdrop
        item.historyID = entry.id
        try? FileManager.default.createDirectory(at: directory(entry), withIntermediateDirectories: true)
        writeFiles(entry, image: item.image, original: item.original)
        entries.insert(entry, at: 0)
        prune()
        saveIndex()
    }

    /// Call after an item's file location or image changed.
    func update(_ item: CaptureItem, imageChanged: Bool) {
        guard let id = item.historyID, let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let url = item.fileURL { entries[i].savedPath = url.path }
        if imageChanged {
            entries[i].pixelWidth = item.image.width
            entries[i].pixelHeight = item.image.height
            entries[i].revision += 1
            entries[i].backdrop = item.original == nil ? nil : item.backdrop
            writeFiles(entries[i], image: item.image, original: item.original)
        }
        saveIndex()
    }

    /// Thumbnail is written synchronously (it is small and the grid shows it right away);
    /// the full-size PNG is encoded on a background queue.
    private func writeFiles(_ entry: HistoryEntry, image: CGImage, original: CGImage?) {
        if let thumb = Self.thumbnail(image, maxPixels: 480) {
            thumbs[thumbKey(entry)] = NSImage(cgImage: thumb, size: .zero)
            Self.write(thumb, type: .jpeg, to: thumbnailURL(entry))
        }
        guard entry.kind == .image else { return }
        let full = image
        let url = imageURL(entry), plainURL = originalURL(entry)
        io.async {
            Self.write(full, type: .png, to: url)
            if let original { Self.write(original, type: .png, to: plainURL) } else { try? FileManager.default.removeItem(at: plainURL) }
        }
    }

    // MARK: Reading

    private func thumbKey(_ entry: HistoryEntry) -> String { "\(entry.id)-\(entry.revision)" }

    func thumbnail(_ entry: HistoryEntry) -> NSImage? {
        let key = thumbKey(entry)
        if let cached = thumbs[key] { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(entry)) else { return nil }
        thumbs[key] = image
        return image
    }

    /// Rebuilds a capture item; videos and GIFs get their poster frame from the thumbnail.
    func item(for entry: HistoryEntry) -> CaptureItem? {
        let image: CGImage?
        if entry.kind == .image {
            io.sync {}
            let source = CGImageSourceCreateWithURL(imageURL(entry) as CFURL, nil)
            image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        } else {
            image = thumbnail(entry)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let image else { return nil }
        let item = CaptureItem(kind: entry.kind, image: image, scale: entry.scale, fileURL: savedURL(entry))
        item.historyID = entry.id
        if let backdrop = entry.backdrop, let source = CGImageSourceCreateWithURL(originalURL(entry) as CFURL, nil),
           let original = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            item.original = original
            item.backdrop = backdrop
        }
        return item
    }

    // MARK: Removing

    func remove(_ ids: Set<UUID>) {
        let removed = entries.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        deleteFolders(removed)
        saveIndex()
    }

    func clear() {
        remove(Set(entries.map(\.id)))
    }

    /// Drops entries past the retention period (0 only stops recording; nothing is deleted), and videos/GIFs whose file is gone.
    func prune() {
        let days = Prefs.historyDays
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : nil
        let fm = FileManager.default
        var stale = Set<UUID>()
        for (index, entry) in entries.enumerated() {
            if index >= maxEntries || (cutoff.map { entry.date < $0 } ?? false) {
                stale.insert(entry.id)
            } else if entry.kind == .image ? !fm.fileExists(atPath: thumbnailURL(entry).path) : savedURL(entry) == nil {
                stale.insert(entry.id)
            }
        }
        remove(stale)
    }

    private func deleteFolders(_ list: [HistoryEntry]) {
        let dirs = list.map(directory)
        for entry in list { thumbs = thumbs.filter { !$0.key.hasPrefix(entry.id.uuidString) } }
        io.async { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let url = indexURL
        io.async { try? data.write(to: url, options: .atomic) }
    }

    /// Bytes used by history's own files (saved files in the screenshot folder are not counted).
    nonisolated static func diskUsage() -> Int64 {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    // MARK: Image helpers

    private nonisolated static func thumbnail(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let s = min(1, CGFloat(maxPixels) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * s)), h = max(1, Int(CGFloat(image.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // JPEG has no alpha; give transparent captures a neutral backdrop.
        ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private nonisolated static func write(_ image: CGImage, type: UTType, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
        let props: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
