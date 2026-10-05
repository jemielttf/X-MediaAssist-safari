// SPDX-License-Identifier: AGPL-3.0-or-later
#if SWIFT_PACKAGE
import XMediaAssistPreferences
#endif
import AVFoundation
import CoreImage
import ImageIO
import CGifski

struct GIFConversionLimits {
    var maximumDuration = 30.0
    var maximumFrames = 1500
    var maximumPixels = 1920 * 1080
    var maximumInputPixels = 3840 * 2160
    var maximumInputSamples = 18_000
    var maximumInputBytes = 100 * 1024 * 1024
    var maximumOutputBytes = 100 * 1024 * 1024
    var maximumSeconds = 120.0
}

enum GIFConversionError: LocalizedError {
    case unsupported, limit, encoding, timedOut, busy
    var warningCode: String {
        switch self {
        case .unsupported: return "gif_unsupported"
        case .limit: return "gif_limit"
        case .encoding: return "gif_encoding"
        case .timedOut: return "gif_timeout"
        case .busy: return "gif_busy"
        }
    }

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
    init(file: FileHandle, limits: GIFConversionLimits, deadline: TimeInterval) {
        self.file = file
        self.deadline = deadline
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

// AVAssetTrack is not Sendable in the current SDK. Metadata loading completes
// before this one-way handoff; only encodingQueue accesses these objects afterward.
// Remove this narrow conformance when AVAssetTrack gains SDK Sendable support.
private struct GIFVideoSource: @unchecked Sendable {
    let asset: AVAsset
    let track: AVAssetTrack
    let duration: Double
    let size: CGSize
    let transform: CGAffineTransform
}

struct GIFConverter {
    private static let slot = DispatchSemaphore(value: 1)
    // gifski clamps delays to at least two centiseconds.
    private static let minimumFrameDuration = 0.02

    private static let encodingQueue = DispatchQueue(label: "XMediaAssist.GIFEncoding", qos: .userInitiated)

    private static func reserveSlot() -> Bool {
        // Immediate try-acquire only: this never blocks a cooperative executor thread.
        slot.wait(timeout: .now()) == .success
    }

    // Cancel AVFoundation loading on timeout, and wait for the loading task to exit
    // before releasing its asset or the conversion slot. The timer is also joined.
    static func withMetadataDeadline<Value: Sendable>(
        _ deadline: TimeInterval,
        cancelLoading: @escaping @Sendable () -> Void,
        load: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw GIFConversionError.timedOut }
        let value = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await load() }
                group.addTask {
                    try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                    cancelLoading()
                    throw GIFConversionError.timedOut
                }
                defer { group.cancelAll() }
                do { return try await group.next()! }
                catch {
                    if ProcessInfo.processInfo.systemUptime >= deadline { throw GIFConversionError.timedOut }
                    throw error
                }
            }
        } onCancel: { cancelLoading() }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GIFConversionError.timedOut }
        return value
    }

    static func convert(_ input: URL, to output: URL, options: GIFConversionOptions = .defaults, limits: GIFConversionLimits = .init()) async throws {
        guard reserveSlot() else { throw GIFConversionError.busy }
        defer { slot.signal() }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.maximumSeconds
        let inputSize = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard inputSize <= limits.maximumInputBytes else { throw GIFConversionError.limit }
        let asset = AVURLAsset(url: input)
        let source = try await withMetadataDeadline(deadline, cancelLoading: { asset.cancelLoading() }) {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GIFConversionError.unsupported }
            let (timeRange, size, transform) = try await track.load(.timeRange, .naturalSize, .preferredTransform)
            return GIFVideoSource(asset: asset, track: track, duration: timeRange.duration.seconds, size: size, transform: transform)
        }
        let duration = source.duration, size = source.size
        guard duration.isFinite, duration > 0, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw GIFConversionError.unsupported }
        guard duration <= limits.maximumDuration, size.width * size.height <= Double(limits.maximumInputPixels) else { throw GIFConversionError.limit }
        _ = try outputRect(CGRect(origin: .zero, size: size).applying(source.transform), options: options, limits: limits)
        // The encoder has blocking C calls; keep them off Swift's cooperative executor.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            encodingQueue.async {
                do {
                    try encode(asset: source.asset, track: source.track, duration: duration, transform: source.transform, to: output, options: options, limits: limits, deadline: deadline)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func encode(asset: AVAsset, track: AVAssetTrack, duration: Double,
                               transform: CGAffineTransform, to output: URL, options: GIFConversionOptions, limits: GIFConversionLimits, deadline: TimeInterval) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GIFConversionError.timedOut }
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw GIFConversionError.encoding }
        let file = try FileHandle(forWritingTo: output)
        let state = GIFOutput(file: file, limits: limits, deadline: deadline)
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
        var sampleCount = 0
        while let sample = timing.copyNextSampleBuffer() {
            try state.check()
            sampleCount += 1
            guard sampleCount <= limits.maximumInputSamples else { throw GIFConversionError.limit }
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { throw GIFConversionError.limit }
            times.append(pts)
        }
        guard timingReader.status == .completed, !times.isEmpty else { throw GIFConversionError.unsupported }
        // Compressed samples may be in decode order (B frames); decoded output is presentation order.
        times.sort()
        let selected = try selectedTimes(times, duration: duration, options: options, maximumFrames: limits.maximumFrames)
        // gifski uses a positive first PTS as the final frame delay and shifts all PTS by it.
        let finalDelay = max(minimumFrameDuration, duration - selected.last!)
        var encoder: OpaquePointer?
        var finished = false
        defer { if let encoder, !finished { state.abort(GIFConversionError.encoding); _ = gifski_finish(encoder) } }
        let context = Unmanaged.passUnretained(state).toOpaque()
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
        var decodedSamples = 0
        while let sample = frames.copyNextSampleBuffer() {
            try state.check()
            decodedSamples += 1
            guard decodedSamples <= limits.maximumInputSamples else { throw GIFConversionError.limit }
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { throw GIFConversionError.unsupported }
            guard index < selected.count else { continue }
            if decodedStart == nil { decodedStart = pts }
            let relativePTS = pts - decodedStart!
            if relativePTS < selected[index] - 0.000001 { continue }
            try autoreleasepool {
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw GIFConversionError.unsupported }
                let inputWidth = CVPixelBufferGetWidth(pixels), inputHeight = CVPixelBufferGetHeight(pixels)
                guard inputHeight > 0, inputWidth <= limits.maximumInputPixels / inputHeight else { throw GIFConversionError.limit }
                let oriented = CIImage(cvPixelBuffer: pixels).transformed(by: transform)
                let rect = try outputRect(oriented.extent, options: options, limits: limits)
                // Normalize after orientation, then scale uniformly. Render from (0, 0),
                // avoiding translation-dependent rounding or a blank edge.
                let image = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: options.scale, y: options.scale))
                let width = Int(rect.width), height = Int(rect.height)
                guard width > 0, height > 0, width <= limits.maximumPixels / height else { throw GIFConversionError.limit }
                if encoder == nil {
                    // Zero dimensions enable gifski's automatic downscaling. Use the
                    // actual oriented/scaled frame size so it preserves our output size.
                    var settings = GifskiSettings(width: UInt32(width), height: UInt32(height), quality: UInt8(options.quality), fast: false, repeat: 0)
                    guard let created = gifski_new(&settings) else { throw GIFConversionError.encoding }
                    encoder = created
                    try check(gifski_set_progress_callback(created, { raw in
                        guard let raw else { return 0 }
                        do { try Unmanaged<GIFOutput>.fromOpaque(raw).takeUnretainedValue().check(); return 1 }
                        catch { return 0 }
                    }, context))
                    try check(gifski_set_write_callback(created, { count, buffer, raw in
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
                }
                guard let encoder else { throw GIFConversionError.encoding }
                var rgba = [UInt8](repeating: 0, count: width * height * 4)
                ci.render(image, toBitmap: &rgba, rowBytes: width * 4, bounds: rect, format: .RGBA8, colorSpace: color)
                try check(gifski_add_frame_rgba(encoder, UInt32(index), UInt32(width), UInt32(height), &rgba, relativePTS + finalDelay))
            }
            index += 1
        }
        guard reader.status == .completed, index == selected.count, let encoder else { throw GIFConversionError.unsupported }
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

    /// Select at most one frame per fixed time bucket, retaining the original PTS.
    /// Input timestamps are sorted; empty buckets are never filled with duplicates.
    static func selectedTimes(_ times: [Double], duration: Double, options: GIFConversionOptions, maximumFrames: Int) throws -> [Double] {
        guard let start = times.first, times.allSatisfy({ $0.isFinite }),
              duration.isFinite, duration > 0 else { throw GIFConversionError.unsupported }
        var selected = [Double]()
        var lastBucket = -1.0
        // Only compensate for floating-point rounding at an exact boundary.
        let epsilon = 0.000000001
        for time in times {
            let pts = time - start
            guard pts.isFinite, pts >= 0 else { throw GIFConversionError.unsupported }
            let bucket = floor((pts + epsilon) * options.maximumFrameRate)
            guard bucket > lastBucket else { continue }
            if let last = selected.last {
                // A candidate near a bucket boundary may be too close to the
                // previous frame. Leave this bucket open for its next candidate.
                guard pts - last >= minimumFrameDuration - epsilon else { continue }
                // Drop a short final tail rather than lengthen the animation.
                guard duration - pts >= minimumFrameDuration - epsilon else { continue }
            }
            guard selected.count < maximumFrames else { throw GIFConversionError.limit }
            selected.append(pts)
            lastBucket = bucket
        }
        return selected
    }

    static func outputRect(_ oriented: CGRect, options: GIFConversionOptions, limits: GIFConversionLimits) throws -> CGRect {
        guard !oriented.isNull, !oriented.isInfinite,
              oriented.origin.x.isFinite, oriented.origin.y.isFinite,
              oriented.width.isFinite, oriented.height.isFinite,
              oriented.width > 0, oriented.height > 0 else { throw GIFConversionError.unsupported }
        // Uniform scaling preserves aspect ratio, up to unavoidable whole-pixel rounding.
        let width = max(1, floor(oriented.width * options.scale))
        let height = max(1, floor(oriented.height * options.scale))
        guard width * height <= Double(limits.maximumPixels) else { throw GIFConversionError.limit }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private static func check(_ result: GifskiError) throws {
        guard result == GIFSKI_OK else { throw GIFConversionError.encoding }
    }
}
