import Foundation

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg

    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
}

enum AutoBackground: String, CaseIterable, Identifiable {
    case off, windows, all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "关闭"
        case .windows: "仅窗口截图"
        case .all: "所有截图"
        }
    }

    func applies(toWindow isWindow: Bool) -> Bool {
        self == .all || (self == .windows && isWindow)
    }
}

enum PrefKey {
    static let copyToClipboard = "copyToClipboard"
    static let autoSave = "autoSave"
    static let saveFolder = "saveFolder"
    static let imageFormat = "imageFormat"
    static let showQuickAccess = "showQuickAccess"
    static let quickAccessTimeout = "quickAccessTimeout"
    static let windowShadow = "windowShadow"
    static let playSound = "playSound"
    static let showMagnifier = "showMagnifier"
    static let recordCursor = "recordCursor"
    static let recordSystemAudio = "recordSystemAudio"
    static let recordMicrophone = "recordMicrophone"
    static let recordFPS = "recordFPS"
    static let recordFormat = "recordFormat"
    static let gifFPS = "gifFPS"
    static let gifMaxWidth = "gifMaxWidth"
    static let historyDays = "historyDays"
    static let autoBackground = "autoBackground"
}

enum Prefs {
    private static var defaults: UserDefaults { .standard }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("xShot")
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            PrefKey.copyToClipboard: true,
            PrefKey.autoSave: true,
            PrefKey.imageFormat: ImageFormat.png.rawValue,
            PrefKey.showQuickAccess: true,
            PrefKey.quickAccessTimeout: 0,
            PrefKey.windowShadow: true,
            PrefKey.playSound: true,
            PrefKey.showMagnifier: true,
            PrefKey.recordCursor: true,
            PrefKey.recordSystemAudio: false,
            PrefKey.recordMicrophone: false,
            PrefKey.recordFPS: 60,
            PrefKey.recordFormat: RecordingFormat.mp4.rawValue,
            PrefKey.gifFPS: 15,
            PrefKey.gifMaxWidth: 960,
            PrefKey.historyDays: 7,
            PrefKey.autoBackground: AutoBackground.off.rawValue,
        ])
    }

    static var copyToClipboard: Bool { defaults.bool(forKey: PrefKey.copyToClipboard) }
    static var autoSave: Bool { defaults.bool(forKey: PrefKey.autoSave) }
    static var showQuickAccess: Bool { defaults.bool(forKey: PrefKey.showQuickAccess) }
    static var quickAccessTimeout: Int { defaults.integer(forKey: PrefKey.quickAccessTimeout) }
    static var windowShadow: Bool { defaults.bool(forKey: PrefKey.windowShadow) }
    static var playSound: Bool { defaults.bool(forKey: PrefKey.playSound) }
    static var showMagnifier: Bool { defaults.bool(forKey: PrefKey.showMagnifier) }
    static var recordCursor: Bool { defaults.bool(forKey: PrefKey.recordCursor) }
    static var recordSystemAudio: Bool { defaults.bool(forKey: PrefKey.recordSystemAudio) }
    static var recordMicrophone: Bool { defaults.bool(forKey: PrefKey.recordMicrophone) }
    static var recordFPS: Int { max(1, defaults.integer(forKey: PrefKey.recordFPS)) }

    static var gifFPS: Int { max(1, defaults.integer(forKey: PrefKey.gifFPS)) }
    static var gifMaxWidth: Int { defaults.integer(forKey: PrefKey.gifMaxWidth) }

    /// 0 = off, -1 = keep forever.
    static var historyDays: Int { defaults.integer(forKey: PrefKey.historyDays) }

    static var autoBackground: AutoBackground {
        AutoBackground(rawValue: defaults.string(forKey: PrefKey.autoBackground) ?? "") ?? .off
    }

    static var recordFormat: RecordingFormat {
        RecordingFormat(rawValue: defaults.string(forKey: PrefKey.recordFormat) ?? "") ?? .mp4
    }

    static var imageFormat: ImageFormat {
        ImageFormat(rawValue: defaults.string(forKey: PrefKey.imageFormat) ?? "") ?? .png
    }

    static var saveFolder: URL {
        if let path = defaults.string(forKey: PrefKey.saveFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultFolder
    }
}
