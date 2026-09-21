import XCTest
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
    private func message(_ scenario: String = "ok") -> [String: Any] {
        ["type": "download", "url": "https://video.twimg.com/\(scenario).mp4", "postId": "719944021058060289", "author": "example", "mediaIndex": 1, "mediaType": "video"]
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

    func testRequestKeepsExactIDAndGIFType() throws {
        var values = message()
        values["mediaType"] = "animated_gif"
        let request = try MediaDownloadRequest(message: values)
        XCTAssertEqual(request.basename, "example-719944021058060289-1")
        XCTAssertEqual(request.mediaType, "animated_gif")
    }
    func testRejectsUntrustedURLsAndFileNames() {
        for url in ["file:///tmp/test.mp4", "http://video.twimg.com/a.mp4", "https://video.twimg.com.evil/a.mp4", "https://user@video.twimg.com/a.mp4", "https://video.twimg.com:8443/a.mp4", "https://video.twimg.com/a.m3u8", "https://127.0.0.1/a.mp4"] {
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
        downloader.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://evil.test/a.mp4")!)) { XCTAssertNil($0) }
    }
}
