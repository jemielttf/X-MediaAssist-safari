// SPDX-License-Identifier: AGPL-3.0-or-later
#if SWIFT_PACKAGE
import XMediaAssistPreferences
#endif
import Foundation

/// The reply for one saved file. A warning means a GIF fell back to MP4.
struct MediaSaveResult {
    let filename: String
    let warning: String?
    var warningCode: String? = nil

    var message: [String: Any] {
        var value: [String: Any] = ["ok": true, "filename": filename]
        if let warning {
            value["warning"] = warning
            if let warningCode { value["warningCode"] = warningCode }
        }
        return value
    }
}

/// One save per transfer. Conversion completes before publication and the response.
final class MediaSave {
    typealias Converter = (URL, URL, GIFConversionOptions) async throws -> Void

    private let request: MediaDownloadRequest
    private let directory: URL
    private let convert: Converter
    private var warning: String?
    private var warningCode: String?

    init(request: MediaDownloadRequest, directory: URL,
         convert: @escaping Converter = { try await GIFConverter.convert($0, to: $1, options: $2) }) {
        self.request = request
        self.directory = directory
        self.convert = convert
    }

    func start(configuration: URLSessionConfiguration = .ephemeral,
               completion: @escaping (Result<MediaSaveResult, Error>) -> Void) {
        MediaDownload(request: request, directory: directory, finishFile: { temporary in
            try await self.finish(temporary)
        }) { result in
            completion(result.map {
                MediaSaveResult(filename: $0, warning: self.warning, warningCode: self.warningCode)
            })
        }.start(configuration: configuration)
    }

    /// Publishes the downloaded MP4, or a GIF converted from it. If conversion fails,
    /// the MP4 is kept and the reason is recorded as a warning; the save still succeeds.
    func finish(_ temporary: URL) async throws -> String {
        if request.convertsGIF {
            let gif = directory.appendingPathComponent(".xma-\(UUID().uuidString).gif.part")
            defer { try? FileManager.default.removeItem(at: gif) }
            do {
                try await convert(temporary, gif, request.gifOptions)
                return try MediaFile.publish(gif, directory: directory, basename: request.basename,
                                             fileExtension: "gif").lastPathComponent
            } catch {
                let conversionError = error as? GIFConversionError
                let reason = conversionError?.localizedDescription ?? "GIFの生成または保存に失敗しました。"
                warning = "GIF変換に失敗したためMP4を保存しました。\(reason)"
                warningCode = conversionError?.warningCode ?? "gif_failed"
            }
        }
        return try MediaFile.publish(temporary, directory: directory,
                                     basename: request.basename).lastPathComponent
    }
}
