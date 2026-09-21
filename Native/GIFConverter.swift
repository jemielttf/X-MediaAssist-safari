// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import CoreImage
import ImageIO
import CGifski

struct GIFConversionLimits {
    var maximumDuration = 30.0
    var maximumFrames = 1500
    var maximumPixels = 1920 * 1080
    var maximumInputBytes = 100 * 1024 * 1024
    var maximumOutputBytes = 100 * 1024 * 1024
    var maximumSeconds = 120.0
}

enum GIFConversionError: LocalizedError {
    case unsupported, limit, encoding, timedOut, busy
    var errorDescription: String? {
        switch self {
        case .unsupported: return "この映像をGIFへ変換できませんでした。"
        case .limit: return "GIF変換の容量・長さ・解像度・フレーム数の上限を超えています。"
        case .encoding: return "GIFの生成または書き込みに失敗しました。"
        case .timedOut: return "GIF変換の制限時間を超えました。"
        case .busy: return "別のGIFを変換中のため、今回はMP4で保存しました。"
        }
    }
}

// C callbacks run on encoder threads. This state remains alive through finish().
private final class GIFOutput {
    let file: FileHandle
    let deadline: TimeInterval
    let limit: Int
    private let lock = NSLock()
    private var bytes = 0
    private var failure: Error?
    init(file: FileHandle, limits: GIFConversionLimits) {
        self.file = file
        deadline = ProcessInfo.processInfo.systemUptime + limits.maximumSeconds
        limit = limits.maximumOutputBytes
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw GIFConversionError.timedOut }
    }
    func abort(_ error: Error) { lock.lock(); failure = error; lock.unlock() }
    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GIFConversionError.timedOut }
        guard data.count <= limit - bytes else { throw GIFConversionError.limit }
        try file.write(contentsOf: data)
        bytes += data.count
    }
}

struct GIFConverter {
    private static let slot = DispatchSemaphore(value: 1)

    static func convert(_ input: URL, to output: URL, limits: GIFConversionLimits = .init()) throws {
        guard slot.wait(timeout: .now()) == .success else { throw GIFConversionError.busy }
        defer { slot.signal() }
        let inputSize = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard inputSize <= limits.maximumInputBytes else { throw GIFConversionError.limit }
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .video).first else { throw GIFConversionError.unsupported }
        let duration = track.timeRange.duration.seconds
        let size = track.naturalSize
        guard duration.isFinite, duration > 0, size.width > 0, size.height > 0 else { throw GIFConversionError.unsupported }
        guard duration <= limits.maximumDuration, size.width * size.height <= Double(limits.maximumPixels) else { throw GIFConversionError.limit }
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw GIFConversionError.encoding }
        let file = try FileHandle(forWritingTo: output)
        let state = GIFOutput(file: file, limits: limits)
        var completed = false
        defer {
            try? file.close()
            if !completed { try? FileManager.default.removeItem(at: output) }
        }
        // Scan compressed sample timestamps first: bounded metadata, no frame bitmap array.
        let timingReader = try AVAssetReader(asset: asset)
        let timing = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        timingReader.add(timing)
        guard timingReader.startReading() else { throw GIFConversionError.unsupported }
        defer { timingReader.cancelReading() }
        var times = [Double]()
        while let sample = timing.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            try state.check()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite, times.count < limits.maximumFrames else { throw GIFConversionError.limit }
            times.append(pts)
        }
        guard timingReader.status == .completed, !times.isEmpty else { throw GIFConversionError.unsupported }
        // Compressed samples may be in decode order (B frames); decoded output is presentation order.
        times.sort()
        let start = times[0]
        var selected = [Double]()
        for time in times {
            if selected.isEmpty || time - selected.last! >= 0.02 - 0.000001 { selected.append(time) }
        }
        selected = selected.map { $0 - start }
        // gifski uses a positive first PTS as the final frame delay and shifts all PTS by it.
        let finalDelay = max(0.02, duration - selected.last!)
        var settings = GifskiSettings(width: 0, height: 0, quality: 90, fast: false, repeat: 0)
        guard let encoder = gifski_new(&settings) else { throw GIFConversionError.encoding }
        var finished = false
        defer { if !finished { state.abort(GIFConversionError.encoding); _ = gifski_finish(encoder) } }
        let context = Unmanaged.passUnretained(state).toOpaque()
        try check(gifski_set_progress_callback(encoder, { raw in
            guard let raw else { return 0 }
            do { try Unmanaged<GIFOutput>.fromOpaque(raw).takeUnretainedValue().check(); return 1 }
            catch { return 0 }
        }, context))
        try check(gifski_set_write_callback(encoder, { count, buffer, raw in
            guard let raw else { return 1 }
            let state = Unmanaged<GIFOutput>.fromOpaque(raw).takeUnretainedValue()
            do {
                if count > 0 {
                    guard let buffer else { return 1 }
                    try state.write(Data(bytes: buffer, count: count))
                }
                return 0
            } catch { state.abort(error); return 1 }
        }, context))
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        frames.alwaysCopiesSampleData = false
        reader.add(frames)
        guard reader.startReading() else { throw GIFConversionError.unsupported }
        defer { reader.cancelReading() }
        let ci = CIContext(options: [.cacheIntermediates: false])
        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        var index = 0
        var decodedStart: Double?
        let transform = track.preferredTransform
        while let sample = frames.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            try state.check()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { throw GIFConversionError.unsupported }
            guard index < selected.count else { continue }
            if decodedStart == nil { decodedStart = pts }
            let relativePTS = pts - decodedStart!
            if relativePTS < selected[index] - 0.000001 { continue }
            try autoreleasepool {
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw GIFConversionError.unsupported }
                let image = CIImage(cvPixelBuffer: pixels).transformed(by: transform)
                let rect = image.extent.integral
                let width = Int(rect.width), height = Int(rect.height)
                guard width > 0, height > 0, width <= limits.maximumPixels / height else { throw GIFConversionError.limit }
                var rgba = [UInt8](repeating: 0, count: width * height * 4)
                ci.render(image, toBitmap: &rgba, rowBytes: width * 4, bounds: rect, format: .RGBA8, colorSpace: color)
                try check(gifski_add_frame_rgba(encoder, UInt32(index), UInt32(width), UInt32(height), &rgba, relativePTS + finalDelay))
            }
            index += 1
        }
        guard reader.status == .completed, index == selected.count else { throw GIFConversionError.unsupported }
        let result = gifski_finish(encoder)
        finished = true
        try state.check()
        try check(result)
        try file.synchronize()
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif",
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw GIFConversionError.encoding }
        completed = true
    }

    private static func check(_ result: GifskiError) throws {
        guard result == GIFSKI_OK else { throw GIFConversionError.encoding }
    }
}
