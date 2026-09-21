import XCTest
import AVFoundation
import ImageIO
@testable import XMediaAssistCore

final class GIFConversionTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xma-gif-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func makeVideo(_ url: URL, rotated: Bool = false, times: [Double] = [0, 0.1, 0.2, 0.3], duration: Double = 0.4) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
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
            for y in 0..<32 { for x in 0..<64 {
                let n = y * stride + x * 4
                bytes[n] = frame % 2 == 0 ? 0 : 255
                bytes[n + 1] = 0
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
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
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
        limits = .init(); limits.maximumSeconds = 0; cases.append(limits)
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
        try MediaDownloadRequest(message: ["type": "download", "url": "https://video.twimg.com/a.mp4", "postId": "123", "author": "example", "mediaIndex": 1, "mediaType": type, "format": format])
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
        let convert: (URL, URL) async throws -> Void = { _, output in
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
    func testVariableFrameTimingAndSingleFrame() async throws {
        for times in [[0.0, 0.04, 0.17, 0.21], [0.0]] {
            let folder = try directory(), input = folder.appendingPathComponent("vfr.mp4"), output = folder.appendingPathComponent("vfr.gif")
            try await makeVideo(input, times: times, duration: 0.35)
            try await GIFConverter.convert(input, to: output)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), times.count)
            var elapsed = 0.0
            for index in times.indices {
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
                let gif = try XCTUnwrap(props[kCGImagePropertyGIFDictionary as String] as? [String: Any])
                let delay = try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
                let expected = (index + 1 < times.count ? times[index + 1] : 0.35) - times[index]
                XCTAssertEqual(delay, expected, accuracy: 0.015)
                elapsed += delay
            }
            XCTAssertEqual(elapsed, 0.35, accuracy: 0.02)
        }
    }

    func testDownloadConvertPublishAndFallbackResponse() async throws {
        let fixture = try directory().appendingPathComponent("fixture.mp4")
        try await makeVideo(fixture)
        GIFDownloadFixture.body = try Data(contentsOf: fixture)
        defer { GIFDownloadFixture.body = Data() }
        for mode in ["success", "failure", "mp4"] {
            let folder = try directory()
            let done = expectation(description: mode)
            var response: Result<MediaSaveResult, Error>?
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [GIFDownloadFixture.self]
            let converter: (URL, URL) async throws -> Void = { input, output in
                // Yield after the URLSession completion callback returns. The input
                // must remain available throughout asynchronous conversion.
                try await Task.sleep(nanoseconds: 20_000_000)
                XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
                if mode == "failure" { throw GIFConversionError.limit }
                try await GIFConverter.convert(input, to: output)
            }
            MediaSave(request: try request(format: mode == "mp4" ? "mp4" : "auto"), directory: folder, convert: converter).start(configuration: config) {
                response = $0
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 10)
            let saved = try XCTUnwrap(response).get()
            XCTAssertEqual(saved.filename, "example-123-1." + (mode == "success" ? "gif" : "mp4"))
            XCTAssertEqual(saved.warning != nil, mode == "failure", saved.warning ?? "")
            XCTAssertEqual(saved.message["ok"] as? Bool, true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [saved.filename])
            if mode != "success" { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(saved.filename)), GIFDownloadFixture.body) }
        }
    }
}
