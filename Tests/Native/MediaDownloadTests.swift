import XCTest
import XMediaAssistPreferences
@testable import XMediaAssistCore

private let mp4 = Data([0, 0, 0, 24]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 20)

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.url!.deletingPathExtension().lastPathComponent
        var body = mp4
        var headers = ["Content-Type": "video/mp4"]
        if scenario == "html" { body = Data("<html>not a video</html>".utf8) }
        if scenario == "mime" { headers["Content-Type"] = "text/html" }
        if scenario == "empty" { body = Data() }
        if scenario == "huge" { headers["Content-Length"] = "1073741825" }
        if scenario == "truncated" { headers["Content-Length"] = "1000" }
        let response = HTTPURLResponse(url: request.url!, statusCode: scenario == "http" ? 403 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if scenario == "interrupted" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

final class MediaDownloadTests: XCTestCase {
    func testLocalizedErrorCodesPreserveLegacyResponses() throws {
        let cases: [(MediaDownloadError, String)] = [
            (.invalidRequest, "invalid_request"), (.invalidResponse, "invalid_response"),
            (.tooLarge, "too_large"), (.invalidMP4, "invalid_mp4"), (.busy, "busy"),
            (.writeFailed, "write_failed"), (.http(403), "http")
        ]
        for (error, code) in cases {
            let response = MediaDownloadError.response(for: error)
            XCTAssertEqual(response["ok"] as? Bool, false)
            XCTAssertEqual(response["errorCode"] as? String, code)
            XCTAssertEqual(response["error"] as? String, error.localizedDescription)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(response))
        }
        XCTAssertEqual(MediaDownloadError.response(for: MediaDownloadError.http(403))["httpStatus"] as? Int, 403)
        XCTAssertEqual(MediaDownloadError.response(for: URLError(.timedOut))["errorCode"] as? String, "network")
        let unknown = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private filesystem path"])
        let response = MediaDownloadError.response(for: unknown)
        XCTAssertEqual(response["errorCode"] as? String, "write_failed")
        XCTAssertEqual(response["error"] as? String, MediaDownloadError.writeFailed.localizedDescription)
    }

    private func message(_ scenario: String = "ok") -> [String: Any] {
        // The URL's file name selects the FixtureProtocol scenario.
        ["type": "download", "url": "https://video.twimg.com/\(scenario).mp4", "postId": "719944021058060289",
         "author": "example", "mediaIndex": 1, "mediaType": "video"]
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xma-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func download(_ scenario: String, into directory: URL, limit: Int64 = MediaDownload.maximumBytes) throws -> Result<String, Error> {
        let done = expectation(description: "download completes")
        var result: Result<String, Error>?
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        MediaDownload(request: try MediaDownloadRequest(message: message(scenario)), directory: directory, maximumBytes: limit) {
            result = $0
            done.fulfill()
        }.start(configuration: configuration)
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(result)
    }

    func testGIFOptionsAllowlistAndDefaults() throws {
        XCTAssertEqual(GIFConversionOptions.defaults.quality, 95)
        XCTAssertEqual(try MediaDownloadRequest(message: message()).gifOptions, .defaults)
        for quality in [95, 85, 70] {
            for fps in [15, 20, 25, 30] {
                for scale in [1.0, 0.75, 0.5] {
                    var values = message()
                    values["gifOptions"] = ["quality": quality, "maximumFrameRate": fps, "scale": scale]
                    let options = try MediaDownloadRequest(message: values).gifOptions
                    XCTAssertEqual(options.quality, quality)
                    XCTAssertEqual(options.maximumFrameRate, Double(fps))
                    XCTAssertEqual(options.scale, scale)
                }
            }
        }
        for (key, invalid) in [("quality", [0, 90, 75, 50, 96, 70.5, "95", true, NSNull()] as [Any]),
                               ("maximumFrameRate", [0, 50, 20.5, "20", true, Double.nan, Double.infinity]),
                               ("scale", [0, 2, 0.8, "1", true, NSNull()])] {
            for value in invalid {
                var raw = GIFConversionOptions.defaults.message
                raw[key] = value
                var values = message(); values["gifOptions"] = raw
                XCTAssertThrowsError(try MediaDownloadRequest(message: values), "\(key): \(value)")
            }
        }
        for invalid: Any in [NSNull(), "options", [:] as [String: Any], ["quality": 95]] {
            var values = message(); values["gifOptions"] = invalid
            XCTAssertThrowsError(try MediaDownloadRequest(message: values))
        }
    }

    func testSharedPreferencesAndPerDownloadPrecedence() throws {
        let suite = "XMediaAssist.Tests.GIF.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = GIFPreferences(defaults: defaults)
        let native = GIFPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(native.options, .defaults)
        let base = try GIFConversionOptions(message: ["quality": 85, "maximumFrameRate": 15, "scale": 0.75])
        host.options = base
        XCTAssertEqual(native.options, base)
        XCTAssertEqual(try MediaDownloadRequest(message: message(), defaultGIFOptions: native.options).gifOptions, base)
        var values = message()
        values["gifOptions"] = GIFConversionOptions.defaults.message
        XCTAssertEqual(try MediaDownloadRequest(message: values, defaultGIFOptions: native.options).gifOptions, .defaults)
        XCTAssertEqual(native.options, base, "An override must not persist")
        defaults.set(["quality": 999], forKey: "gifConversionOptions")
        XCTAssertEqual(native.options, .defaults)
    }

    func testRequestKeepsExactIDAndGIFType() throws {
        var values = message()
        values["mediaType"] = "animated_gif"
        let request = try MediaDownloadRequest(message: values)
        XCTAssertEqual(request.basename, "example-719944021058060289-1")
        XCTAssertEqual(request.mediaType, "animated_gif")
    }
    func testRejectsUntrustedURLsAndFileNames() {
        for url in ["file:///tmp/test.mp4", "http://video.twimg.com/a.mp4", "https://video.twimg.com.evil/a.mp4",
                    "https://user@video.twimg.com/a.mp4", "https://video.twimg.com:8443/a.mp4",
                    "https://video.twimg.com/a.m3u8", "https://127.0.0.1/a.mp4"] {
            var values = message(); values["url"] = url
            XCTAssertThrowsError(try MediaDownloadRequest(message: values), url)
        }
        for (key, value) in [("author", "../../escape"), ("postId", "1e15"), ("mediaType", "photo"), ("type", "other")] {
            var values = message(); values[key] = value
            XCTAssertThrowsError(try MediaDownloadRequest(message: values))
        }
        var values = message(); values["mediaIndex"] = 5
        XCTAssertThrowsError(try MediaDownloadRequest(message: values))
    }
    func testSuccessfulDownloadMatchesBytesAndCleansTemporaryFile() throws {
        let folder = try directory()
        let name = try download("ok", into: folder).get()
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), mp4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [name])
    }
    func testDuplicateSavePreservesExistingFile() throws {
        let folder = try directory()
        let existing = folder.appendingPathComponent("example-719944021058060289-1.mp4")
        let original = Data("existing content".utf8)
        try original.write(to: existing)
        let name = try download("ok", into: folder).get()
        XCTAssertEqual(name, "example-719944021058060289-1 2.mp4")
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), mp4)
        let thirdName = try download("ok", into: folder).get()
        XCTAssertEqual(thirdName, "example-719944021058060289-1 3.mp4")
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), mp4)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(thirdName)), mp4)
    }
    func testFailuresPublishNothingAndCleanTemporaryFiles() throws {
        for scenario in ["http", "html", "mime", "empty", "huge", "truncated", "interrupted"] {
            let folder = try directory()
            XCTAssertThrowsError(try download(scenario, into: folder).get(), scenario)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], scenario)
        }
    }
    func testRemovesOnlyStaleTemporaryFiles() throws {
        let folder = try directory()
        let now = Date()
        func file(_ name: String, age: TimeInterval) throws -> String {
            let url = folder.appendingPathComponent(name)
            try Data("partial".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return name
        }
        let staleMP4 = try file(".xma-\(UUID().uuidString).part.mp4", age: 7200)
        let staleGIF = try file(".xma-\(UUID().uuidString).gif.part", age: 3600)
        let active = try file(".xma-\(UUID().uuidString).part.mp4", age: 600)
        let kept = [active,
                    try file("example-719944021058060289-1.mp4", age: 7200),
                    try file(".xma-notes.part.mp4", age: 7200),
                    try file(".xma-\(UUID().uuidString).mp4", age: 7200)]
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".xma-\(UUID().uuidString).gif.part"), withIntermediateDirectories: false)
        MediaFile.removeStaleTemporaries(in: folder, now: now)
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertFalse(remaining.contains(staleMP4))
        XCTAssertFalse(remaining.contains(staleGIF))
        XCTAssertTrue(remaining.isSuperset(of: kept))
        XCTAssertEqual(remaining.count, kept.count + 1, "A directory with a matching name is not removed")
    }
    func testPeriodicSweepRemovesLeftoverSkippedAsTooNew() throws {
        let folder = try directory()
        let start = Date()
        var clock = start
        let sweeper = StaleTemporarySweeper(directory: { folder }, now: { clock })
        func leftover(modified: Date) throws -> URL {
            let url = folder.appendingPathComponent(".xma-\(UUID().uuidString).part.mp4")
            try Data("partial".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        // Safari restarted one minute after a crash: the first ping keeps the new leftover.
        let crashed = try leftover(modified: start.addingTimeInterval(-60))
        sweeper.sweepIfDue()
        XCTAssertTrue(exists(crashed))

        // Within the interval, pings do not rescan, even for an already stale file.
        clock = start.addingTimeInterval(StaleTemporarySweeper.interval - 1)
        let stale = try leftover(modified: start.addingTimeInterval(-7200))
        sweeper.sweepIfDue()
        XCTAssertTrue(exists(stale))

        // Hours later in the same process, a ping removes both leftovers.
        clock = start.addingTimeInterval(7200)
        sweeper.sweepIfDue()
        XCTAssertFalse(exists(crashed))
        XCTAssertFalse(exists(stale))

        // A clock moved backwards does not suppress the next check.
        clock = start.addingTimeInterval(3600)
        let afterClockChange = try leftover(modified: start.addingTimeInterval(-7200))
        sweeper.sweepIfDue()
        XCTAssertFalse(exists(afterClockChange))
    }
    func testSweepDefersWhileSavingAfterClockAdvances() throws {
        let folder = try directory()
        let start = Date()
        var clock = start
        let sweeper = StaleTemporarySweeper(directory: { folder }, now: { clock })
        sweeper.sweepIfDue()

        // Created at `start`, but the clock jumps ahead so it looks two hours old.
        let active = folder.appendingPathComponent(".xma-\(UUID().uuidString).part.mp4")
        try mp4.write(to: active)
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: active.path)
        let orphan = folder.appendingPathComponent(".xma-\(UUID().uuidString).gif.part")
        try Data("orphan".utf8).write(to: orphan)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-7200)], ofItemAtPath: orphan.path)

        clock = start.addingTimeInterval(7200)
        sweeper.sweepIfDue(hasActiveRequests: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        // The transfer ends and removes its own temporary file. Deferral must not advance
        // lastSweep: the next idle ping at the same time cleans up the orphan.
        try FileManager.default.removeItem(at: active)
        sweeper.sweepIfDue(hasActiveRequests: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
    func testUnknownLengthBodyStillEnforcesSizeLimit() throws {
        let folder = try directory()
        XCTAssertThrowsError(try download("ok", into: folder, limit: 16).get())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
    func testWriteFailureDoesNotReportSuccess() throws {
        let folder = try directory().appendingPathComponent("missing-directory")
        XCTAssertThrowsError(try download("ok", into: folder).get())
    }
    func testRedirectBoundaryRejectsDifferentHostAndExcessHops() throws {
        let downloader = MediaDownload(request: try MediaDownloadRequest(message: message()), directory: try directory()) { _ in }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://video.twimg.com/a.mp4")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for index in 1...4 {
            downloader.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: task.originalRequest!) { request in
                XCTAssertEqual(request != nil, index <= 3)
            }
        }
        let offHost = URLRequest(url: URL(string: "https://evil.test/a.mp4")!)
        downloader.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: offHost) {
            XCTAssertNil($0)
        }
    }
}
