import Foundation
import AVFoundation

/// Manual integration smoke test. Writes only to the supplied test directory.
@main struct SmokeDownload {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: smoke-download request.json test-directory\n", stderr)
            exit(2)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let request = try MediaDownloadRequest(message: message)
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name: String = try await withCheckedThrowingContinuation { continuation in
            MediaDownload(request: request, directory: directory) { continuation.resume(with: $0) }.start()
        }
        let asset = AVURLAsset(url: directory.appendingPathComponent(name))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty, duration > 0 else { throw MediaDownloadError.invalidMP4 }
        print("Saved playable MP4: \(name); duration: \(duration)s")
    }
}
