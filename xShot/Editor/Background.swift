import AppKit
import CoreImage
import SwiftUI

enum BackgroundRatio: String, Codable, CaseIterable, Identifiable {
    case auto, square, fourThree, sixteenNine

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "自动"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        }
    }

    var value: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .fourThree: 4 / 3
        case .sixteenNine: 16 / 9
        }
    }
}

enum BackgroundPreset {
    case gradient([NSColor])
    case solid(NSColor)
    case transparent
    case wallpaper

    static let all: [BackgroundPreset] = [
        .gradient([.hex(0x7F7FD5), .hex(0x86A8E7), .hex(0x91EAE4)]),
        .gradient([.hex(0xA18CD1), .hex(0xFBC2EB)]),
        .gradient([.hex(0xFF5F6D), .hex(0xFFC371)]),
        .gradient([.hex(0xFFECD2), .hex(0xFCB69F)]),
        .gradient([.hex(0x2193B0), .hex(0x6DD5ED)]),
        .gradient([.hex(0x11998E), .hex(0x38EF7D)]),
        .gradient([.hex(0xF093FB), .hex(0xF5576C)]),
        .gradient([.hex(0x0F2027), .hex(0x203A43), .hex(0x2C5364)]),
        .solid(.white),
        .solid(.hex(0xEDEDF2)),
        .solid(.hex(0x1C1C1E)),
        .transparent,
        .wallpaper,
    ]
}

struct BackdropStyle: Codable, Equatable {
    var enabled = false
    var preset = 0
    var padding: Double = 64
    var cornerRadius: Double = 12
    var shadow: Double = 0.6
    var ratio = BackgroundRatio.auto

    var resolvedPreset: BackgroundPreset {
        BackgroundPreset.all.indices.contains(preset) ? BackgroundPreset.all[preset] : BackgroundPreset.all[0]
    }

    private static let key = "backgroundStyle"

    /// Last used look; always starts disabled so plain edits stay plain.
    static func load() -> BackdropStyle {
        guard let data = UserDefaults.standard.data(forKey: key),
              var style = try? JSONDecoder().decode(BackdropStyle.self, from: data) else { return BackdropStyle() }
        style.enabled = false
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum BackgroundRenderer {
    /// Composition layout in points: total size and where the screenshot sits.
    static func layout(imageSize: CGSize, style: BackdropStyle) -> (size: CGSize, imageRect: CGRect) {
        let pad = style.padding
        var size = CGSize(width: imageSize.width + pad * 2, height: imageSize.height + pad * 2)
        if let ratio = style.ratio.value {
            if size.width / size.height < ratio {
                size.width = size.height * ratio
            } else {
                size.height = size.width / ratio
            }
        }
        let rect = CGRect(x: (size.width - imageSize.width) / 2, y: (size.height - imageSize.height) / 2,
                          width: imageSize.width, height: imageSize.height)
        return (size, rect)
    }

    /// Draws the backdrop and the screenshot's shadow. `ctx` has y pointing down; `unit` converts style points to user space.
    static func drawBackground(in ctx: CGContext, rect: CGRect, imageRect: CGRect, style: BackdropStyle, unit: CGFloat) {
        ctx.saveGState()
        ctx.clip(to: rect)
        switch style.resolvedPreset {
        case let .gradient(colors):
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: colors.map(\.cgColor) as CFArray, locations: nil)!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case let .solid(color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .transparent:
            break
        case .wallpaper:
            if let wallpaper = Wallpaper.blurred {
                let w = CGFloat(wallpaper.width), h = CGFloat(wallpaper.height)
                let s = max(rect.width / w, rect.height / h)
                let draw = CGRect(x: rect.midX - w * s / 2, y: rect.midY - h * s / 2, width: w * s, height: h * s)
                ctx.interpolationQuality = .high
                ctx.drawFlipped(wallpaper, in: draw)
            } else {
                ctx.setFillColor(NSColor.hex(0x86A8E7).cgColor)
                ctx.fill(rect)
            }
        }
        ctx.restoreGState()

        guard style.shadow > 0 else { return }
        let deviceScale = abs(ctx.ctm.a) + abs(ctx.ctm.b)
        let radius = style.cornerRadius * unit
        ctx.saveGState()
        // Only paint outside the screenshot: window captures have transparent rounded corners
        // that would otherwise show the shape casting the shadow.
        ctx.addRect(rect)
        ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * style.shadow * unit * deviceScale),
                      blur: 40 * style.shadow * unit * deviceScale,
                      color: NSColor.black.withAlphaComponent(0.2 + 0.3 * style.shadow).cgColor)
        ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Full-resolution composition of `image` (pixels at `scale`) onto the background.
    static func compose(_ image: CGImage, scale: CGFloat, style: BackdropStyle) -> CGImage? {
        let imageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let (size, imageRect) = layout(imageSize: imageSize, style: style)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        drawBackground(in: ctx, rect: CGRect(origin: .zero, size: size), imageRect: imageRect, style: style, unit: 1)
        ctx.saveGState()
        let r = style.cornerRadius
        ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.drawFlipped(image, in: imageRect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

/// The current desktop picture, blurred, for the wallpaper background.
enum Wallpaper {
    private static var cache: CGImage??

    static var blurred: CGImage? {
        if let cache { return cache }
        let image = load()
        cache = .some(image)
        return image
    }

    private static func load() -> CGImage? {
        // The reported URL can be stale (a deleted file), so take the first one that actually loads.
        let screens = [NSScreen.main].compactMap { $0 } + NSScreen.screens
        let candidates = screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            + [URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")]
        guard let source = candidates.lazy.compactMap({ CGImageSourceCreateWithURL($0 as CFURL, nil) })
                .first(where: { CGImageSourceGetCount($0) > 0 }),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600,
              ] as CFDictionary) else { return nil }
        let ci = CIImage(cgImage: image)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 18).cropped(to: ci.extent)
        return CIContext().createCGImage(blurred, from: ci.extent)
    }
}

/// Draws the backdrop behind the canvas in the editor.
final class BackgroundPreviewView: NSView {
    var style = BackdropStyle()
    var imageRect = CGRect.zero
    var unit: CGFloat = 1

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if case .transparent = style.resolvedPreset { drawCheckerboard(ctx) }
        BackgroundRenderer.drawBackground(in: ctx, rect: bounds, imageRect: imageRect, style: style, unit: unit)
    }

    private func drawCheckerboard(_ ctx: CGContext) {
        let cell: CGFloat = 8
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(bounds)
        ctx.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor)
        var y: CGFloat = 0
        while y < bounds.height {
            var x: CGFloat = (Int(y / cell) % 2 == 0) ? 0 : cell
            while x < bounds.width {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell * 2
            }
            y += cell
        }
    }
}

// MARK: - Settings panel

final class BackgroundModel: ObservableObject {
    @Published var style: BackdropStyle {
        didSet {
            style.save()
            onChange?(style)
        }
    }

    var onChange: ((BackdropStyle) -> Void)?

    init(style: BackdropStyle) {
        self.style = style
    }
}

struct BackgroundPanel: View {
    @ObservedObject var model: BackgroundModel
    var showsToggle = true

    private let columns = Array(repeating: GridItem(.fixed(40), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsToggle {
                Toggle("背景美化", isOn: $model.style.enabled)
                    .toggleStyle(.switch)
                    .font(.headline)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(BackgroundPreset.all.indices, id: \.self) { index in
                    swatch(BackgroundPreset.all[index])
                        .frame(width: 40, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(model.style.preset == index ? Color.accentColor : Color.primary.opacity(0.15),
                                          lineWidth: model.style.preset == index ? 2.5 : 1))
                        .onTapGesture {
                            model.style.preset = index
                            model.style.enabled = true
                        }
                }
            }

            slider("边距", value: $model.style.padding, range: 0...200)
            slider("圆角", value: $model.style.cornerRadius, range: 0...40)
            slider("阴影", value: $model.style.shadow, range: 0...1)

            Picker("比例", selection: $model.style.ratio) {
                ForEach(BackgroundRatio.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .frame(width: 260)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 32, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if editing { model.style.enabled = true }
            }
        }
    }

    @ViewBuilder
    private func swatch(_ preset: BackgroundPreset) -> some View {
        switch preset {
        case let .gradient(colors):
            LinearGradient(colors: colors.map(Color.init(nsColor:)), startPoint: .topLeading, endPoint: .bottomTrailing)
        case let .solid(color):
            Color(nsColor: color)
        case .transparent:
            Image(systemName: "square.dashed").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
                .foregroundStyle(.secondary)
        case .wallpaper:
            if let image = Wallpaper.blurred {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The style applied to a mock window, scaled like a typical screenshot.
struct BackdropPreview: View {
    let style: BackdropStyle

    // An 800×500 pt sample rendered at 1/2 scale (sharp at ~200 pt wide) keeps padding and radii in proportion.
    private static let scale: CGFloat = 0.5
    private static let sample: CGImage? = {
        let w = 200, h = 125
        guard let ctx = CGContext(data: nil, width: w * 2, height: h * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor.hex(0xECECEF).cgColor)
        ctx.fill(CGRect(x: 0, y: h - 14, width: w, height: 14))
        for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(NSColor.hex(UInt32(color)).cgColor)
            ctx.fillEllipse(in: CGRect(x: 7 + i * 9, y: h - 10, width: 6, height: 6))
        }
        ctx.setFillColor(NSColor.hex(0xD8D8DE).cgColor)
        for (i, width) in [150, 120, 165, 90, 140, 110].enumerated() {
            ctx.fill(CGRect(x: 14, y: h - 30 - i * 14, width: width, height: 6))
        }
        return ctx.makeImage()
    }()

    var body: some View {
        var s = style
        s.enabled = true
        let image = Self.sample.flatMap { BackgroundRenderer.compose($0, scale: Self.scale, style: s) }
        return Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
        }
    }
}

extension NSColor {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
