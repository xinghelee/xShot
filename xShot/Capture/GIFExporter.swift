import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum RecordingFormat: String, CaseIterable, Identifiable {
    case mp4, gif, both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mp4: "MP4"
        case .gif: "GIF"
        case .both: "MP4 + GIF"
        }
    }
}

nonisolated enum GIFExporter {
    /// Converts a video to a looping GIF. `maxWidth` is in pixels; 0 keeps the original size.
    ///
    /// Screen recordings are variable-frame-rate (nothing is written while the screen is still),
    /// so every frame is decoded in order and each GIF tick shows whatever frame was on screen
    /// at that moment. Consecutive ticks on the same frame are merged into one longer GIF frame.
    static func export(video: URL, to output: URL, fps: Int, maxWidth: Int) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let timeRange = try await track.load(.timeRange)
        let duration = timeRange.duration.seconds
        guard duration > 0 else { throw CocoaError(.fileReadCorruptFile) }

        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let step = 1 / Double(fps)
        let ticks = max(1, Int((duration * Double(fps)).rounded()))
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, ticks, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        var current: CVPixelBuffer?
        var currentImage: CGImage?
        var pending: (frame: CVPixelBuffer, image: CGImage, delay: Double)?
        var added = 0
        var tick = 0

        func flush() {
            guard let p = pending else { return }
            CGImageDestinationAddImage(dest, p.image, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: p.delay,
                kCGImagePropertyGIFUnclampedDelayTime: p.delay,
            ]] as CFDictionary)
            added += 1
            pending = nil
        }

        func emitCurrent() {
            guard let frame = current else { return }
            if let p = pending, p.frame === frame {
                pending?.delay += step
                return
            }
            if currentImage == nil { currentImage = makeImage(frame, maxWidth: maxWidth, context: ciContext) }
            guard let image = currentImage else { return }
            flush()
            pending = (frame, image, step)
        }

        while let sample = trackOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = (sample.presentationTimeStamp - timeRange.start).seconds
            while tick < ticks, Double(tick) * step < pts {
                emitCurrent()
                tick += 1
            }
            current = buffer
            currentImage = nil
        }
        while tick < ticks {
            emitCurrent()
            tick += 1
        }
        flush()

        guard reader.status != .failed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard added > 0, CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func makeImage(_ buffer: CVPixelBuffer, maxWidth: Int, context: CIContext) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        let width = image.extent.width
        if maxWidth > 0, width > CGFloat(maxWidth) {
            let s = CGFloat(maxWidth) / width
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        }
        return context.createCGImage(image, from: image.extent.integral)
    }
}
