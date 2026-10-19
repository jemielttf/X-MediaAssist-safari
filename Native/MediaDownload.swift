#if SWIFT_PACKAGE
import XMediaAssistPreferences
#endif
import Foundation
import Darwin

/// Failures reported to the extension. `messageCode` is the stable protocol value;
/// the extension maps it to a localized message (NATIVE_ERRORS in core.js).
enum MediaDownloadError: LocalizedError {
    case invalidRequest, invalidResponse, tooLarge, invalidMP4, busy, writeFailed, notFound
    case http(Int)

    var messageCode: String {
        switch self {
        case .invalidRequest: return "invalid_request"
        case .invalidResponse: return "invalid_response"
        case .tooLarge: return "too_large"
        case .invalidMP4: return "invalid_mp4"
        case .busy: return "busy"
        case .writeFailed: return "write_failed"
        case .notFound: return "not_found"
        case .http: return "http"
        }
    }

    // Additive protocol fields let the extension localize known failures. Keep
    // the legacy text for an older extension and never expose raw system errors.
    static func response(for error: Error) -> [String: Any] {
        if (error as NSError).domain == NSURLErrorDomain {
            return ["ok": false, "errorCode": "network",
                    "error": "動画の取得に失敗しました。通信状態を確認して再試行してください。"]
        }
        let known = error as? MediaDownloadError ?? .writeFailed
        var response: [String: Any] = [
            "ok": false, "errorCode": known.messageCode, "error": known.localizedDescription
        ]
        if case .http(let status) = known { response["httpStatus"] = status }
        return response
    }

    // Legacy Japanese text, sent as the "error" fallback field.
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "保存リクエストが正しくありません。"
        case .invalidResponse: return "動画配信サーバーからの応答が正しくありません。"
        case .tooLarge: return "保存できるファイルサイズの上限を超えています。"
        case .invalidMP4: return "取得したファイルはMP4として確認できませんでした。"
        case .busy: return "保存処理中です。完了してから再試行してください。"
        case .writeFailed:
            return "ファイルを保存できません。空き容量とダウンロードフォルダへのアクセスを確認してください。"
        case .notFound: return "保存したファイルが見つかりません。移動または削除された可能性があります。"
        case .http(let code): return "動画を取得できませんでした（HTTP \(code)）。"
        }
    }
}

/// A validated "download" message from the extension. Every field that reaches the
/// network or the file name is checked here, independently of the JavaScript side.
struct MediaDownloadRequest {
    let url: URL
    let postId: String
    let author: String
    let mediaIndex: Int
    let mediaType: String
    let gifOptions: GIFConversionOptions
    let format: String
    /// "mp4" format saves animated GIFs as MP4 without conversion.
    var convertsGIF: Bool { mediaType == "animated_gif" && format == "auto" }
    /// File name without extension, e.g. "example-123-1".
    var basename: String { "\(author)-\(postId)-\(mediaIndex)" }
    /// Media URL, then the post, in the order Safari records "Where from" for downloads.
    var whereFroms: [String] { [url.absoluteString, "https://x.com/\(author)/status/\(postId)"] }

    init(message: [String: Any], defaultGIFOptions: GIFConversionOptions = .defaults) throws {
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
        let format = message["format"] as? String ?? "auto"
        guard ["auto", "mp4"].contains(format) else { throw MediaDownloadError.invalidRequest }
        self.format = format
        do {
            gifOptions = try message["gifOptions"].map { try GIFConversionOptions(message: $0) } ?? defaultGIFOptions
        } catch { throw MediaDownloadError.invalidRequest }
    }

    /// Same boundary as isMP4URL in core.js; also applied to every redirect and response.
    static func isAllowedURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "video.twimg.com" &&
        (url.port == nil || url.port == 443) && url.user == nil && url.password == nil &&
        url.fragment == nil && url.path.hasSuffix(".mp4")
    }
}

/// File-system steps shared by MP4 and GIF saves.
enum MediaFile {
    /// Cheap container check: an MP4 has "ftyp" at bytes 4..<8. Not a full decode.
    static func validate(_ file: URL, byteCount: Int64) throws {
        guard byteCount >= 12 else { throw MediaDownloadError.invalidMP4 }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        guard prefix.count == 12, String(data: prefix[4..<8], encoding: .ascii) == "ftyp" else {
            throw MediaDownloadError.invalidMP4
        }
    }

    /// Finder's "Where from" / Spotlight's kMDItemWhereFroms: a binary plist of strings.
    static func setWhereFroms(_ sources: [String], on file: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: sources, format: .binary, options: 0)
        let result = file.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeBytes { bytes in
                setxattr(path!, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
        }
        guard result == 0 else { throw MediaDownloadError.writeFailed }
    }

    // link(2) publishes a complete file atomically, failing if the name exists.
    // Temporary and final files are in the same directory/filesystem.
    static func publish(_ temporary: URL, directory: URL, basename: String,
                        fileExtension: String = "mp4", whereFroms: [String] = []) throws -> URL {
        guard ["mp4", "gif"].contains(fileExtension) else { throw MediaDownloadError.invalidRequest }
        // Set before linking: the hard link shares the inode, so the file never appears
        // without it. Provenance is informational; a volume without xattrs must not fail the save.
        if !whereFroms.isEmpty { try? setWhereFroms(whereFroms, on: temporary) }
        // "name.mp4", then "name 2.mp4", "name 3.mp4", ... like Finder duplicates.
        for suffix in 1...1000 {
            let name = basename + (suffix == 1 ? "" : " \(suffix)") + "." + fileExtension
            let destination = directory.appendingPathComponent(name)
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in Darwin.link(source!, target!) }
            }
            if result == 0 { return destination }
            if errno != EEXIST { throw MediaDownloadError.writeFailed }
        }
        throw MediaDownloadError.writeFailed
    }

    /// Exactly the names `publish` creates: "author-postID-index.ext" or "author-postID-index N.ext".
    private static let savedName = "^[A-Za-z0-9_]{1,15}-[1-9][0-9]{0,19}-[1-4]( [1-9][0-9]{0,3})?\\.(mp4|gif)$"

    static func isSavedName(_ name: String) -> Bool {
        name.range(of: savedName, options: .regularExpression) != nil
    }

    /// Validates a "reveal" request: 1...4 saved file names. Returns those still present in
    /// `directory`. Paths, other names and symbolic links are rejected, so the extension
    /// cannot point Finder anywhere else.
    static func savedFiles(_ value: Any?, in directory: URL) throws -> [URL] {
        guard let names = value as? [String], (1...4).contains(names.count), names.allSatisfy(isSavedName)
        else { throw MediaDownloadError.invalidRequest }
        let files = names.map { directory.appendingPathComponent($0) }.filter { file in
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink == false
        }
        guard !files.isEmpty else { throw MediaDownloadError.notFound }
        return files
    }

    // A killed extension process (e.g. Safari quit mid-transfer) leaves its hidden
    // partial files behind. Only sweep while idle: wall-clock changes can make
    // an active transfer's file appear old even though its timeout has not elapsed.
    static let staleTemporaryAge: TimeInterval = 60 * 60
    /// Exactly the names created by MediaDownload (".part.mp4") and MediaSave (".gif.part").
    private static let temporaryName =
        "^\\.xma-[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}\\.(part\\.mp4|gif\\.part)$"

    static func removeStaleTemporaries(in directory: URL, now: Date = Date()) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        for file in files where file.lastPathComponent.range(of: temporaryName, options: .regularExpression) != nil {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= staleTemporaryAge else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Re-checks for orphaned partial files at most once per interval. A file skipped as
/// too new (Safari restarted right after a crash) is removed by a later check, even
/// if this extension process lives for hours. The last check time is per process only:
/// a new process always checks on its first ping.
final class StaleTemporarySweeper: @unchecked Sendable {
    static let interval: TimeInterval = 15 * 60
    private let lock = NSLock()
    private var lastSweep: Date?
    private let directory: () -> URL?
    private let now: () -> Date

    // Wall-clock time, matching file modification dates; system uptime stops during sleep.
    init(directory: @escaping () -> URL?, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    // The caller must keep save admission excluded until this method returns.
    func sweepIfDue(hasActiveRequests: Bool = false) {
        guard !hasActiveRequests else { return }
        let current = now()
        lock.lock()
        // A clock moved backwards also counts as due, so a sweep is never suppressed for long.
        let due = lastSweep.map { current.timeIntervalSince($0) >= Self.interval || current < $0 } ?? true
        if due { lastSweep = current }
        lock.unlock()
        guard due, let directory = directory() else { return }
        MediaFile.removeStaleTemporaries(in: directory, now: current)
    }
}

/// A validated "notify" message: the save result of one post, already localized by the
/// extension. When files were saved, it carries their names and the title of a
/// "Show in Finder" button; otherwise it has no button.
struct SaveNotification: Equatable {
    let title: String
    let body: String
    /// Saved file names (empty: no button). Checked again against Downloads on click.
    let filenames: [String]
    let revealTitle: String?

    init(message: [String: Any]) throws {
        guard let title = message["title"] as? String, (1...200).contains(title.count),
              let body = message["body"] as? String, body.count <= 2000
        else { throw MediaDownloadError.invalidRequest }
        self.title = title
        self.body = body
        if message["filenames"] == nil {
            filenames = []
            revealTitle = nil
            return
        }
        guard let filenames = message["filenames"] as? [String], (1...4).contains(filenames.count),
              filenames.allSatisfy(MediaFile.isSavedName),
              let revealTitle = message["revealTitle"] as? String, (1...50).contains(revealTitle.count)
        else { throw MediaDownloadError.invalidRequest }
        self.filenames = filenames
        self.revealTitle = revealTitle
    }
}

/// Progress of the saves in this extension process, keyed by basename, for the "progress"
/// message. Only entries opened with `begin` are updated, so a late callback after `end`
/// cannot leave a stale entry behind.
final class SaveProgress: @unchecked Sendable {
    static let shared = SaveProgress()

    struct Snapshot: Equatable {
        enum Phase: String { case downloading, converting }
        var phase = Phase.downloading
        var receivedBytes: Int64 = 0
        /// -1 until the server sends a Content-Length.
        var expectedBytes: Int64 = -1
        var encodedFrames = 0
        /// 0 until the GIF frames to encode are selected.
        var totalFrames = 0

        var message: [String: Any] {
            ["phase": phase.rawValue, "receivedBytes": receivedBytes, "expectedBytes": expectedBytes,
             "encodedFrames": encodedFrames, "totalFrames": totalFrames]
        }
    }

    private let lock = NSLock()
    private var entries = [String: Snapshot]()

    /// The basename of a "progress" message, in the same form as MediaDownloadRequest.basename.
    static func basename(of message: [String: Any]) throws -> String {
        guard let basename = message["basename"] as? String,
              basename.range(of: "^[A-Za-z0-9_]{1,15}-[1-9][0-9]{0,19}-[1-4]$", options: .regularExpression) != nil
        else { throw MediaDownloadError.invalidRequest }
        return basename
    }

    func begin(_ basename: String) {
        lock.lock(); entries[basename] = Snapshot(); lock.unlock()
    }
    func end(_ basename: String) {
        lock.lock(); entries[basename] = nil; lock.unlock()
    }
    func update(_ basename: String, _ change: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var snapshot = entries[basename] else { return }
        change(&snapshot)
        entries[basename] = snapshot
    }
    func snapshot(_ basename: String) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return entries[basename]
    }
}

/// Streams one MP4 into a hidden temporary file next to its destination, validates it,
/// then either publishes it or hands it to `finishFile` (GIF conversion in MediaSave).
/// One instance per transfer. Mutable state stays on the serial URLSession delegate queue.
final class MediaDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes: Int64 = 1_073_741_824
    private let request: MediaDownloadRequest
    private let directory: URL
    private let maximumBytes: Int64
    private let completion: (Result<String, Error>) -> Void
    private let finishFile: ((URL) async throws -> String)?
    private let progress: SaveProgress?
    private var temporary: URL?
    private var file: FileHandle?
    private var bytes: Int64 = 0
    private var expectedBytes: Int64 = -1
    private var failure: Error?
    private var redirects = 0

    init(request: MediaDownloadRequest, directory: URL, maximumBytes: Int64 = MediaDownload.maximumBytes,
         progress: SaveProgress? = nil, finishFile: ((URL) async throws -> String)? = nil,
         completion: @escaping (Result<String, Error>) -> Void) {
        self.request = request
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.completion = completion
        self.finishFile = finishFile
        self.progress = progress
    }

    func start(configuration: URLSessionConfiguration = .ephemeral) {
        // No cookies, credentials or cache: the CDN needs none, and nothing should persist.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        // A GIF also needs up to 120 s to convert; both stay under the extension's 650 s wait.
        configuration.timeoutIntervalForResource = request.convertsGIF ? 480 : 600
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
            progress?.update(request.basename) { [expectedBytes] in $0.expectedBytes = expectedBytes }
            // AVFoundation needs the container extension when opening a local file.
            let temporaryURL = directory.appendingPathComponent(".xma-\(UUID().uuidString).part.mp4")
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600])
            else { throw MediaDownloadError.writeFailed }
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
            progress?.update(request.basename) { [bytes] in $0.receivedBytes = bytes }
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
            // -1 means the server sent no Content-Length; otherwise the body must be complete.
            guard expectedBytes < 0 || bytes == expectedBytes else { throw MediaDownloadError.invalidResponse }
            try file.synchronize()
            try file.close()
            self.file = nil
            try MediaFile.validate(temporary, byteCount: bytes)
            if let finishFile {
                // Download callbacks have finished. Hold the file until asynchronous
                // conversion completes, then return cleanup to the delegate queue.
                Task { @concurrent in
                    let converted: Result<String, Error>
                    do { converted = .success(try await finishFile(temporary)) }
                    catch { converted = .failure(error) }
                    session.delegateQueue.addOperation {
                        self.complete(converted, session: session)
                    }
                }
                return
            }
            let saved = try MediaFile.publish(temporary, directory: directory, basename: request.basename,
                                              whereFroms: request.whereFroms)
            result = .success(saved.lastPathComponent)
        } catch { result = .failure(error) }
        complete(result, session: session)
    }

    // Always removes the temporary file: a published file is a separate hard link.
    private func complete(_ result: Result<String, Error>, session: URLSession) {
        try? file?.close()
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        session.finishTasksAndInvalidate()
        completion(result)
    }
}
