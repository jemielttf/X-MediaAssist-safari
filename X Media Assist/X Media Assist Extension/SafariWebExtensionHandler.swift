import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let lock = NSLock()
    private static var activeRequests = Set<String>()

    func beginRequest(with context: NSExtensionContext) {
        func respond(_ payload: [String: Any]) {
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: payload]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
        do {
            guard let item = context.inputItems.first as? NSExtensionItem,
                  let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
                throw MediaDownloadError.invalidRequest
            }
            if message["type"] as? String == "ping" {
                respond(["ok": true, "protocolVersion": 3, "gifOptions": try GIFPreferences.appGroup().options.message])
                return
            }
            let request = try MediaDownloadRequest(message: message, defaultGIFOptions: try GIFPreferences.appGroup().options)
            let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            Self.lock.lock()
            let accepted = Self.activeRequests.count < 3 && !Self.activeRequests.contains(request.basename)
            if accepted { Self.activeRequests.insert(request.basename) }
            Self.lock.unlock()
            guard accepted else { throw MediaDownloadError.busy }
            MediaSave(request: request, directory: directory).start { result in
                Self.lock.lock()
                Self.activeRequests.remove(request.basename)
                Self.lock.unlock()
                switch result {
                case .success(let saved): respond(saved.message)
                case .failure(let error):
                    let description: String
                    if let known = error as? MediaDownloadError { description = known.localizedDescription }
                    else if (error as NSError).domain == NSURLErrorDomain { description = "動画の取得に失敗しました。通信状態を確認して再試行してください。" }
                    else { description = MediaDownloadError.writeFailed.localizedDescription }
                    respond(["ok": false, "error": description])
                }
            }
        } catch {
            respond(["ok": false, "error": (error as? MediaDownloadError)?.localizedDescription ?? MediaDownloadError.writeFailed.localizedDescription])
        }
    }
}
