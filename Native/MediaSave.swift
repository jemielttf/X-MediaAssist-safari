// SPDX-License-Identifier: AGPL-3.0-or-later
#if SWIFT_PACKAGE
import XMediaAssistPreferences
#endif
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

/// One save per transfer. Conversion completes before publication and the response.
final class MediaSave {
    private let request: MediaDownloadRequest
    private let directory: URL
    private let convert: (URL, URL, GIFConversionOptions) async throws -> Void
    private var warning: String?

    init(request: MediaDownloadRequest, directory: URL,
         convert: @escaping (URL, URL, GIFConversionOptions) async throws -> Void = { try await GIFConverter.convert($0, to: $1, options: $2) }) {
        self.request = request
        self.directory = directory
        self.convert = convert
    }

    func start(configuration: URLSessionConfiguration = .ephemeral, completion: @escaping (Result<MediaSaveResult, Error>) -> Void) {
        MediaDownload(request: request, directory: directory, finishFile: { temporary in
            try await self.finish(temporary)
        }) { result in
            completion(result.map { MediaSaveResult(filename: $0, warning: self.warning) })
        }.start(configuration: configuration)
    }

    func finish(_ temporary: URL) async throws -> String {
        if request.convertsGIF {
            let gif = directory.appendingPathComponent(".xma-\(UUID().uuidString).gif.part")
            defer { try? FileManager.default.removeItem(at: gif) }
            do {
                try await convert(temporary, gif, request.gifOptions)
                return try MediaFile.publish(gif, directory: directory, basename: request.basename, fileExtension: "gif").lastPathComponent
            } catch {
                let reason = (error as? GIFConversionError)?.localizedDescription ?? "GIFの生成または保存に失敗しました。"
                warning = "GIF変換に失敗したためMP4を保存しました。\(reason)"
            }
        }
        return try MediaFile.publish(temporary, directory: directory, basename: request.basename).lastPathComponent
    }
}
