import XCTest
import AVFoundation
import ImageIO
import XMediaAssistPreferences
@testable import XMediaAssistCore

final class GIFConversionTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xma-gif-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Writes an H.264 test video. Even frames are red, odd frames blue.
    func makeVideo(_ url: URL, rotated: Bool = false, width: Int = 64, height: Int = 32,
                   times: [Double] = [0, 0.1, 0.2, 0.3], duration: Double = 0.4) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in times.indices {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height { for x in 0..<width {
                let n = y * stride + x * 4
                bytes[n] = frame % 2 == 0 ? 0 : 255
                bytes[n + 1] = UInt8((frame * 37) % 180)
                bytes[n + 2] = frame % 2 == 0 ? 255 : 0
                bytes[n + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(seconds: times[frame], preferredTimescale: 60000)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
        input.markAsFinished()
        let finished = expectation(description: "video encoded")
        writer.finishWriting { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    func options(fps: Double = 20, scale: Double = 1, quality: Int = 95) throws -> GIFConversionOptions {
        try GIFConversionOptions(message: ["quality": quality, "maximumFrameRate": fps, "scale": scale])
    }

    func testPTSSelectionPreservesSlowSources() throws {
        for (sourceFPS, cap) in [(15, 20), (20, 20), (24, 30), (30, 30)] {
            let pts = (0..<sourceFPS).map { Double($0) / Double(sourceFPS) }
            XCTAssertEqual(try GIFConverter.selectedTimes(pts, duration: 1, options: options(fps: Double(cap)), maximumFrames: 1500), pts)
        }
    }

    func testPTSSelectionKeepsExpectedCountsForAllCapsAndFractionalRates() throws {
        for rate in [15.0, 20, 24, 25, 30, 60, 30000.0 / 1001, 60000.0 / 1001, 30.001, 19.999, 20.001] {
            let pts = (0..<Int(ceil(rate * 10))).map { Double($0) / rate }
            for cap in [15.0, 20, 25, 30] {
                let selected = try GIFConverter.selectedTimes(pts, duration: 10, options: options(fps: cap), maximumFrames: 1500)
                XCTAssertEqual(Double(selected.count), min(rate, cap) * 10, accuracy: 1, "source \(rate), cap \(cap)")
                XCTAssertLessThanOrEqual(selected.count, Int(cap * 10))
                XCTAssertTrue(selected.allSatisfy(pts.contains), "Retain source PTS without interpolation")
                for (a, b) in zip(selected, selected.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b - a, 0.02 - 0.000000001)
                }
            }
        }
        let thirty = (0..<30).map { Double($0) / 30 }
        let expectedIndices = [0, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 23, 24, 26, 27, 29]
        XCTAssertEqual(try GIFConverter.selectedTimes(thirty, duration: 1, options: options(), maximumFrames: 1500), expectedIndices.map { thirty[$0] })
    }

    func testPTSSelectionHandlesBucketBoundariesDuplicatesAndVFRGaps() throws {
        let boundaries = [0.0, 0, 0.049, 0.05, 0.05, 0.099, 0.1, 0.149, 0.15]
        XCTAssertEqual(try GIFConverter.selectedTimes(boundaries, duration: 0.2, options: options(), maximumFrames: 1500), [0, 0.05, 0.1, 0.15])
        // Reject the 2ms boundary candidate, but allow the later frame in that bucket.
        let vfr = [0.0, 0.099, 0.101, 0.122, 0.15, 2.099, 2.101, 2.13]
        let expected = [0.0, 0.099, 0.122, 0.15, 2.099, 2.13]
        XCTAssertEqual(try GIFConverter.selectedTimes(vfr, duration: 3, options: options(), maximumFrames: 1500), expected)
        let shifted = try GIFConverter.selectedTimes(vfr.map { $0 + 4 }, duration: 3, options: options(), maximumFrames: 1500)
        XCTAssertEqual(shifted.count, expected.count)
        for (actual, wanted) in zip(shifted, expected) { XCTAssertEqual(actual, wanted, accuracy: 0.000000001) }
        XCTAssertEqual(try GIFConverter.selectedTimes([0, 0.049, 0.051, 0.15], duration: 0.2, options: options(), maximumFrames: 1500), [0, 0.051, 0.15])
        XCTAssertEqual(try GIFConverter.selectedTimes([0, 0.09, 0.11], duration: 0.2, options: options(), maximumFrames: 1500), [0, 0.09, 0.11])
        XCTAssertEqual(try GIFConverter.selectedTimes([0, 0.09, 0.109999, 0.12], duration: 0.2, options: options(), maximumFrames: 1500), [0, 0.09, 0.12])
    }

    func testPTSSelectionDropsShortTailAndChecksSelectedFrameLimit() throws {
        let pts = [0.0, 0.1, 0.2, 0.399]
        XCTAssertEqual(try GIFConverter.selectedTimes(pts, duration: 0.4, options: options(), maximumFrames: 3), [0, 0.1, 0.2])
        XCTAssertEqual(try GIFConverter.selectedTimes([0, 0.1, 0.38], duration: 0.4, options: options(), maximumFrames: 3), [0, 0.1, 0.38])
        XCTAssertEqual(try GIFConverter.selectedTimes([0], duration: 0.01, options: options(), maximumFrames: 1), [0])
        let long = (0..<1800).map { Double($0) / 60 }
        XCTAssertEqual(try GIFConverter.selectedTimes(long, duration: 30, options: options(), maximumFrames: 600).count, 600)
        XCTAssertThrowsError(try GIFConverter.selectedTimes(long, duration: 30, options: options(), maximumFrames: 599))
    }

    func testRealEncoderPreservesHDOutputSizesAndOrientations() async throws {
        for rotated in [false, true] {
            let folder = try directory(), input = folder.appendingPathComponent("input.mp4")
            try await makeVideo(input, rotated: rotated, width: 1280, height: 720, times: [0, 0.1], duration: 0.2)
            for scale in [1.0, 0.75, 0.5] {
                let output = folder.appendingPathComponent("\(scale).gif")
                try await GIFConverter.convert(input, to: output, options: options(scale: scale))
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, Int(Double(rotated ? 720 : 1280) * scale), "scale \(scale), rotated \(rotated)")
                XCTAssertEqual(image.height, Int(Double(rotated ? 1280 : 720) * scale), "scale \(scale), rotated \(rotated)")
                XCTAssertEqual(Double(image.width) / Double(image.height), rotated ? 9.0 / 16 : 16.0 / 9, accuracy: 0.000001)
            }
        }
    }

    func testInputAndOutputLimitsAreSeparate() async throws {
        let fourK = CGRect(x: -2160, y: 0, width: 3840, height: 2160)
        XCTAssertEqual(try GIFConverter.outputRect(fourK, options: options(scale: 0.5), limits: .init()), CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertThrowsError(try GIFConverter.outputRect(fourK, options: options(), limits: .init()))
        let folder = try directory(), input = folder.appendingPathComponent("input.mp4"), output = folder.appendingPathComponent("output.gif")
        try await makeVideo(input, times: (0..<60).map { Double($0) / 60 }, duration: 1)
        var limits = GIFConversionLimits()
        limits.maximumFrames = 20
        limits.maximumPixels = 32 * 16
        try await GIFConverter.convert(input, to: output, options: options(scale: 0.5), limits: limits)
        let limitedOutput = folder.appendingPathComponent("limited.gif")
        limits.maximumInputSamples = 30
        do {
            try await GIFConverter.convert(input, to: limitedOutput, options: options(scale: 0.5), limits: limits)
            XCTFail("Input sample safety cap must be enforced")
        } catch GIFConversionError.limit { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: limitedOutput.path))
        limits.maximumInputSamples = 18_000
        limits.maximumInputPixels = 32 * 16
        do {
            try await GIFConverter.convert(input, to: limitedOutput, options: options(scale: 0.5), limits: limits)
            XCTFail("Input decode size safety cap must be enforced")
        } catch GIFConversionError.limit { }
    }

    func testSavePassesValidatedOptionsToConverter() async throws {
        let folder = try directory(), input = folder.appendingPathComponent("input.mp4")
        try Data("source".utf8).write(to: input)
        let expected = try options(fps: 25, scale: 0.75, quality: 70)
        let request = try MediaDownloadRequest(message: [
            "type": "download", "url": "https://video.twimg.com/a.mp4", "postId": "123", "author": "example",
            "mediaIndex": 1, "mediaType": "animated_gif", "gifOptions": expected.message
        ])
        let save = MediaSave(request: request, directory: folder) { _, output, options in
            XCTAssertEqual(options, expected)
            try Data("complete".utf8).write(to: output)
        }
        let filename = try await save.finish(input)
        XCTAssertEqual(filename, "example-123-1.gif")
    }

    func testRealEncoderPreservesFramesTimingLoopAndOrientation() async throws {
        for rotated in [false, true] {
            let folder = try directory(), input = folder.appendingPathComponent("input.mp4"), output = folder.appendingPathComponent("output.gif")
            try await makeVideo(input, rotated: rotated)
            try await GIFConverter.convert(input, to: output)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 4)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, rotated ? 32 : 64)
            XCTAssertEqual(image.height, rotated ? 64 : 32)
            var duration = 0.0
            for index in 0..<CGImageSourceGetCount(source) {
                let info = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
                let gif = try XCTUnwrap(info[kCGImagePropertyGIFDictionary as String] as? [String: Any])
                duration += try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
            }
            XCTAssertEqual(duration, 0.4, accuracy: 0.04)
            let properties = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [String: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount as String] as? Int, 0)
            var pixel = [UInt8](repeating: 0, count: 4)
            // Downsample the first frame to one pixel: it must be the red frame.
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(pixel[0], 200)
            XCTAssertLessThan(pixel[2], 40)
        }
    }

    func testLimitsTimeoutAndOutputFailureLeaveNoPartialGIF() async throws {
        let folder = try directory(), input = folder.appendingPathComponent("input.mp4")
        try await makeVideo(input)
        var cases = [GIFConversionLimits]()
        var limits = GIFConversionLimits(); limits.maximumDuration = 0.1; cases.append(limits)
        limits = .init(); limits.maximumFrames = 2; cases.append(limits)
        limits = .init(); limits.maximumPixels = 10; cases.append(limits)
        limits = .init(); limits.maximumInputBytes = 10; cases.append(limits)
        limits = .init(); limits.maximumOutputBytes = 10; cases.append(limits)
        // An expired budget is covered by testExpiredConversionBudgetLeavesNoFileAndReleasesSlot.
        for limits in cases {
            let output = folder.appendingPathComponent("failed.gif")
            do {
                try await GIFConverter.convert(input, to: output, limits: limits)
                XCTFail("Conversion should reject this limit")
            } catch { /* Expected: input limits or encoding failure. */ }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testMetadataTimeoutCancelsLoadingAndWaitsForCleanup() async throws {
        let cancelled = expectation(description: "asset loading cancelled")
        let started = expectation(description: "loading started")
        let cleanedUp = expectation(description: "loading cleanup finished")
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        do {
            let _: Int = try await GIFConverter.withMetadataDeadline(deadline, cancelLoading: { cancelled.fulfill() }) {
                started.fulfill()
                defer { cleanedUp.fulfill() }
                try await Task.sleep(for: .seconds(10))
                return 1
            }
            XCTFail("Metadata loading must time out")
        } catch GIFConversionError.timedOut { /* Expected. */ }
        await fulfillment(of: [started, cancelled, cleanedUp], timeout: 0.1)
    }

    func testCompletedMetadataLoadDisarmsTimeout() async throws {
        let cancelled = expectation(description: "finished loading must not be cancelled")
        cancelled.isInverted = true
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        let value = try await GIFConverter.withMetadataDeadline(deadline, cancelLoading: { cancelled.fulfill() }) { 42 }
        XCTAssertEqual(value, 42)
        await fulfillment(of: [cancelled], timeout: 0.1)
    }

    func testExpiredConversionBudgetLeavesNoFileAndReleasesSlot() async throws {
        let folder = try directory(), input = folder.appendingPathComponent("input.mp4")
        let output = folder.appendingPathComponent("output.gif")
        try await makeVideo(input)
        var limits = GIFConversionLimits()
        limits.maximumSeconds = 0
        do {
            try await GIFConverter.convert(input, to: output, limits: limits)
            XCTFail("Expired budget must time out")
        } catch GIFConversionError.timedOut { /* Expected. */ }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try await GIFConverter.convert(input, to: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func request(type: String = "animated_gif", format: String = "auto") throws -> MediaDownloadRequest {
        try MediaDownloadRequest(message: [
            "type": "download", "url": "https://video.twimg.com/a.mp4", "postId": "123", "author": "example",
            "mediaIndex": 1, "mediaType": type, "format": format
        ])
    }

    func testGIFSuccessAndDuplicateName() async throws {
        let folder = try directory(), input = folder.appendingPathComponent("input.mp4")
        try await makeVideo(input)
        let save = MediaSave(request: try request(), directory: folder)
        let name0 = try await save.finish(input)
        XCTAssertEqual(name0, "example-123-1.gif")
        let name1 = try await save.finish(input)
        XCTAssertEqual(name1, "example-123-1 2.gif")
        let name2 = try await save.finish(input)
        XCTAssertEqual(name2, "example-123-1 3.gif")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("example-123-1.mp4").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".xma-") })
    }

    func testFailurePreservesMP4AndMP4ModeSkipsConversion() async throws {
        let folder = try directory(), input = folder.appendingPathComponent("input.mp4")
        let data = Data("test source preserved".utf8)
        try data.write(to: input)
        var called = 0
        let convert: (URL, URL, GIFConversionOptions) async throws -> Void = { _, output, _ in
            called += 1
            try Data("partial GIF".utf8).write(to: output)
            throw GIFConversionError.encoding
        }
        let save = MediaSave(request: try request(), directory: folder, convert: convert)
        let name3 = try await save.finish(input)
        XCTAssertEqual(name3, "example-123-1.mp4")
        XCTAssertEqual(called, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("example-123-1.mp4")), data)
        for request in [try request(type: "video"), try request(format: "mp4")] {
            _ = try await MediaSave(request: request, directory: folder, convert: convert).finish(input)
        }
        XCTAssertEqual(called, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".xma-") })
        XCTAssertThrowsError(try request(format: "invalid"))
    }
}

private final class GIFDownloadFixture: URLProtocol {
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/mp4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension GIFConversionTests {
    func assertGIFTiming(_ output: URL, selected: [Double], duration: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil), file: file, line: line)
        let count = CGImageSourceGetCount(source)
        XCTAssertEqual(count, selected.count, file: file, line: line)
        var elapsed = 0.0
        for index in 0..<min(count, selected.count) {
            // GIF quantizes timestamps to centiseconds. Check cumulative timing so
            // repeated rounding or minimum-delay padding cannot hide duration drift.
            XCTAssertEqual(elapsed, selected[index], accuracy: 0.0051, file: file, line: line)
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any], file: file, line: line)
            let gif = try XCTUnwrap(props[kCGImagePropertyGIFDictionary as String] as? [String: Any], file: file, line: line)
            let delay = try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, file: file, line: line)
            XCTAssertGreaterThanOrEqual(delay, 0.02, file: file, line: line)
            elapsed += delay
        }
        XCTAssertEqual(elapsed, max(0.02, duration), accuracy: 0.0051, file: file, line: line)
    }

    func testVariableFrameTimingAndSingleFrame() async throws {
        for (times, fps, selected, duration) in [
            ([0.0, 0.04, 0.17, 0.21], 30.0, [0.0, 0.04, 0.17, 0.21], 0.35),
            ([0.0, 0.04, 0.17, 0.21], 20.0, [0.0, 0.17, 0.21], 0.35),
            ([0.0, 0.099, 0.101, 0.122, 0.15, 0.999], 20.0, [0.0, 0.099, 0.122, 0.15], 1.0),
            ([0.0, 0.1, 2.099, 2.101, 2.13], 20.0, [0.0, 0.1, 2.099, 2.13], 3.0),
            ([0.0, 0.1, 0.201], 20.0, [0.0, 0.1], 0.21),
            ([0.0], 20.0, [0.0], 0.35),
            ([0.0], 20.0, [0.0], 0.01)
        ] {
            let folder = try directory(), input = folder.appendingPathComponent("vfr.mp4"), output = folder.appendingPathComponent("vfr.gif")
            try await makeVideo(input, times: times, duration: duration)
            try await GIFConverter.convert(input, to: output, options: options(fps: fps))
            try assertGIFTiming(output, selected: selected, duration: duration)
        }
    }

    func testRealEncoderCapsThirtyFPSWithoutRetimingFrames() async throws {
        let folder = try directory(), input = folder.appendingPathComponent("thirty.mp4")
        let times = (0..<30).map { Double($0) / 30 }
        try await makeVideo(input, times: times, duration: 1)
        for cap in [15.0, 20, 25, 30] {
            let output = folder.appendingPathComponent("\(cap).gif")
            let selected = try GIFConverter.selectedTimes(times, duration: 1, options: options(fps: cap), maximumFrames: 1500)
            XCTAssertEqual(selected.count, Int(cap))
            try await GIFConverter.convert(input, to: output, options: options(fps: cap))
            try assertGIFTiming(output, selected: selected, duration: 1)
        }
    }

    func testDownloadConvertPublishAndFallbackResponse() async throws {
        let fixture = try directory().appendingPathComponent("fixture.mp4")
        try await makeVideo(fixture)
        GIFDownloadFixture.body = try Data(contentsOf: fixture)
        defer { GIFDownloadFixture.body = Data() }
        let failures: [String: Error] = [
            "unsupported": GIFConversionError.unsupported, "limit": GIFConversionError.limit,
            "encoding": GIFConversionError.encoding, "timeout": GIFConversionError.timedOut,
            "busy": GIFConversionError.busy, "failed": MediaDownloadError.writeFailed
        ]
        for mode in ["success", "mp4"] + failures.keys.sorted() {
            let folder = try directory()
            let done = expectation(description: mode)
            var response: Result<MediaSaveResult, Error>?
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [GIFDownloadFixture.self]
            let converter: (URL, URL, GIFConversionOptions) async throws -> Void = { input, output, options in
                // Yield after the URLSession completion callback returns. The input
                // must remain available throughout asynchronous conversion.
                try await Task.sleep(nanoseconds: 20_000_000)
                XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
                if let failure = failures[mode] { throw failure }
                try await GIFConverter.convert(input, to: output, options: options)
            }
            MediaSave(request: try request(format: mode == "mp4" ? "mp4" : "auto"), directory: folder, convert: converter).start(configuration: config) {
                response = $0
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 10)
            let saved = try XCTUnwrap(response).get()
            XCTAssertEqual(saved.filename, "example-123-1." + (mode == "success" ? "gif" : "mp4"))
            XCTAssertEqual(saved.warning != nil, failures[mode] != nil, saved.warning ?? "")
            XCTAssertEqual(saved.message["warning"] as? String, saved.warning)
            XCTAssertEqual(saved.message["warningCode"] as? String, failures[mode] == nil ? nil : "gif_" + mode)
            XCTAssertEqual(saved.message["ok"] as? Bool, true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [saved.filename])
            if mode != "success" { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(saved.filename)), GIFDownloadFixture.body) }
        }
    }
}
