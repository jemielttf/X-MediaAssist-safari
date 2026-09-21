import Foundation
import Darwin

enum MediaDownloadError: LocalizedError {
    case invalidRequest, invalidResponse, tooLarge, invalidMP4, busy, writeFailed
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "保存リクエストが正しくありません。"
        case .invalidResponse: return "MP4配信サーバーからの応答が正しくありません。"
        case .tooLarge: return "MVPの保存上限（1 GiB）を超えています。"
        case .invalidMP4: return "取得したファイルはMP4として確認できませんでした。"
        case .busy: return "保存処理中です。完了してから再試行してください。"
        case .writeFailed: return "ファイルを保存できません。空き容量とダウンロードフォルダへのアクセスを確認してください。"
        case .http(let code): return "MP4を取得できませんでした（HTTP \(code)）。"
        }
    }
}

struct MediaDownloadRequest {
    let url: URL
    let postId: String
    let author: String
    let mediaIndex: Int
    let mediaType: String
    var basename: String { "\(author)-\(postId)-\(mediaIndex)" }

    init(message: [String: Any]) throws {
        guard message["type"] as? String == "download",
              let rawURL = message["url"] as? String, rawURL.count <= 4096,
              let url = URL(string: rawURL), Self.isAllowedURL(url),
              let postId = message["postId"] as? String,
              postId.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil,
              let author = message["author"] as? String,
              author.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil,
              let mediaIndex = message["mediaIndex"] as? Int, (1...4).contains(mediaIndex),
              let mediaType = message["mediaType"] as? String,
              ["video", "animated_gif"].contains(mediaType) else { throw MediaDownloadError.invalidRequest }
        self.url = url
        self.postId = postId
        self.author = author
        self.mediaIndex = mediaIndex
        self.mediaType = mediaType
    }

    static func isAllowedURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "video.twimg.com" &&
        (url.port == nil || url.port == 443) && url.user == nil && url.password == nil &&
        url.fragment == nil && url.path.hasSuffix(".mp4")
    }
}

enum MediaFile {
    static func validate(_ file: URL, byteCount: Int64) throws {
        guard byteCount >= 12 else { throw MediaDownloadError.invalidMP4 }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        guard prefix.count == 12, String(data: prefix[4..<8], encoding: .ascii) == "ftyp" else {
            throw MediaDownloadError.invalidMP4
        }
    }

    // link(2) publishes a complete file atomically, failing if the name exists.
    // Temporary and final files are in the same directory/filesystem.
    static func publish(_ temporary: URL, directory: URL, basename: String) throws -> URL {
        for suffix in 1...1000 {
            let name = basename + (suffix == 1 ? "" : " \(suffix)") + ".mp4"
            let destination = directory.appendingPathComponent(name)
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in Darwin.link(source!, target!) }
            }
            if result == 0 { return destination }
            if errno != EEXIST { throw MediaDownloadError.writeFailed }
        }
        throw MediaDownloadError.writeFailed
    }
}

/// One instance per transfer. Mutable state stays on the serial URLSession delegate queue.
final class MediaDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes: Int64 = 1_073_741_824
    private let request: MediaDownloadRequest
    private let directory: URL
    private let maximumBytes: Int64
    private let completion: (Result<String, Error>) -> Void
    private var temporary: URL?
    private var file: FileHandle?
    private var bytes: Int64 = 0
    private var expectedBytes: Int64 = -1
    private var failure: Error?
    private var redirects = 0

    init(request: MediaDownloadRequest, directory: URL, maximumBytes: Int64 = MediaDownload.maximumBytes,
         completion: @escaping (Result<String, Error>) -> Void) {
        self.request = request
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.completion = completion
    }

    func start(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var httpRequest = URLRequest(url: request.url)
        httpRequest.setValue("video/mp4", forHTTPHeaderField: "Accept")
        // URLSession retains its delegate until finishTasksAndInvalidate below.
        session.dataTask(with: httpRequest).resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, let url = newRequest.url, MediaDownloadRequest.isAllowedURL(url) else {
            failure = MediaDownloadError.invalidResponse
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(newRequest)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, let url = http.url,
                  MediaDownloadRequest.isAllowedURL(url) else { throw MediaDownloadError.invalidResponse }
            guard http.statusCode == 200 else { throw MediaDownloadError.http(http.statusCode) }
            guard ["video/mp4", "application/octet-stream"].contains(http.mimeType?.lowercased() ?? "") else {
                throw MediaDownloadError.invalidMP4
            }
            expectedBytes = http.expectedContentLength
            guard expectedBytes <= maximumBytes else { throw MediaDownloadError.tooLarge }
            let temporaryURL = directory.appendingPathComponent(".xma-\(UUID().uuidString).part")
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw MediaDownloadError.writeFailed
            }
            temporary = temporaryURL
            file = try FileHandle(forWritingTo: temporaryURL)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            bytes += Int64(data.count)
            guard bytes <= maximumBytes else { throw MediaDownloadError.tooLarge }
            guard let file else { throw MediaDownloadError.writeFailed }
            try file.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<String, Error>
        do {
            if let failure { throw failure }
            if let error { throw error }
            guard let temporary, let file else { throw MediaDownloadError.invalidResponse }
            guard expectedBytes < 0 || bytes == expectedBytes else { throw MediaDownloadError.invalidResponse }
            try file.synchronize()
            try file.close()
            self.file = nil
            try MediaFile.validate(temporary, byteCount: bytes)
            let saved = try MediaFile.publish(temporary, directory: directory, basename: request.basename)
            result = .success(saved.lastPathComponent)
        } catch { result = .failure(error) }
        try? file?.close()
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        session.finishTasksAndInvalidate()
        completion(result)
    }
}
