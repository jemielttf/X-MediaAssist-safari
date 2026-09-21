// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

struct MediaSaveResult {
    let filename: String
    let warning: String?
    var message: [String: Any] {
        var value: [String: Any] = ["ok": true, "filename": filename]
        if let warning { value["warning"] = warning }
        return value
    }
}

/// Runs on the download's serial delegate queue. No UI or persistent job store.
final class MediaSave {
    private let request: MediaDownloadRequest
    private let directory: URL
    private let convert: (URL, URL) throws -> Void
    private var warning: String?

    init(request: MediaDownloadRequest, directory: URL,
         convert: @escaping (URL, URL) throws -> Void = { try GIFConverter.convert($0, to: $1) }) {
        self.request = request
        self.directory = directory
        self.convert = convert
    }

    func start(configuration: URLSessionConfiguration = .ephemeral, completion: @escaping (Result<MediaSaveResult, Error>) -> Void) {
        MediaDownload(request: request, directory: directory, finishFile: { temporary in
            try self.finish(temporary)
        }) { result in
            completion(result.map { MediaSaveResult(filename: $0, warning: self.warning) })
        }.start(configuration: configuration)
    }

    func finish(_ temporary: URL) throws -> String {
        if request.convertsGIF {
            let gif = directory.appendingPathComponent(".xma-\(UUID().uuidString).gif.part")
            defer { try? FileManager.default.removeItem(at: gif) }
            do {
                try convert(temporary, gif)
                return try MediaFile.publish(gif, directory: directory, basename: request.basename, fileExtension: "gif").lastPathComponent
            } catch {
                let reason = (error as? GIFConversionError)?.localizedDescription ?? "GIFの生成または保存に失敗しました。"
                warning = "GIF変換に失敗したためMP4を保存しました。\(reason)"
            }
        }
        return try MediaFile.publish(temporary, directory: directory, basename: request.basename).lastPathComponent
    }
}
