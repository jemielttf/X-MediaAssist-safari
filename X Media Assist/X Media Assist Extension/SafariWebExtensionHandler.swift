import AppKit
import os
import SafariServices
import UserNotifications

/// Receives `browser.runtime.sendNativeMessage` calls from background.js.
///
/// - "ping": reports the protocol version and the base GIF settings.
/// - "download": saves one media item to ~/Downloads and replies when it is published.
/// - "progress": reports the bytes received and GIF frames encoded for a save in progress.
/// - "reveal": selects previously saved files in Finder.
/// - "notify": shows the result of a post's save as a notification, with a "Show in Finder"
///   button when files were saved.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    /// Guards `activeRequests` and keeps sweeping and save admission mutually exclusive.
    private static let lock = NSLock()
    /// Basenames being saved by this process; at most 3, one per file name.
    private static var activeRequests = Set<String>()
    // Every save starts with a ping, so orphaned partial files are re-checked periodically.
    private static let sweeper = StaleTemporarySweeper(directory: { try? downloadsDirectory(create: false) })

    private static func downloadsDirectory(create: Bool) throws -> URL {
        try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
    }

    fileprivate static let log = Logger(subsystem: "com.jemielttf.XMediaAssist", category: "notification")
    private static let savedCategory = "xma.saved"
    fileprivate static let revealAction = "xma.reveal"

    // Button clicks reach this process, the one that posted the notification. Install the
    // delegate on the first request, before macOS delivers a click that waited for it.
    private static let installNotificationDelegate: Void = {
        UNUserNotificationCenter.current().delegate = NotificationResponder.shared
    }()

    // The first call asks for permission. A denied permission is not an error for the
    // caller: the notification is informational and the save has already finished.
    private static func post(_ notification: SaveNotification, completion: @escaping (Error?) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { log.error("notification authorization failed: \(String(describing: error), privacy: .public)") }
            guard granted else { return completion(nil) }
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            if let revealTitle = notification.revealTitle {
                // No .foreground option: the button does not bring the app forward.
                // Registered on each post so the title follows the extension's language.
                let action = UNNotificationAction(identifier: revealAction, title: revealTitle, options: [])
                center.setNotificationCategories([
                    UNNotificationCategory(identifier: savedCategory, actions: [action], intentIdentifiers: [])
                ])
                content.categoryIdentifier = savedCategory
                content.userInfo = ["filenames": notification.filenames]
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error { log.error("notification not added: \(String(describing: error), privacy: .public)") }
                completion(error)
            }
        }
    }

    func beginRequest(with context: NSExtensionContext) {
        _ = Self.installNotificationDelegate
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
                // Keep the same lock as save admission throughout the sweep so
                // a new transfer cannot start between the idle check and deletion.
                Self.lock.lock()
                Self.sweeper.sweepIfDue(hasActiveRequests: !Self.activeRequests.isEmpty)
                Self.lock.unlock()
                // Must match NATIVE_PROTOCOL in Extension/core.js.
                respond(["ok": true, "protocolVersion": 3, "gifOptions": try GIFPreferences.appGroup().options.message])
                return
            }
            if message["type"] as? String == "progress" {
                let snapshot = SaveProgress.shared.snapshot(try SaveProgress.basename(of: message))
                respond(["ok": true, "progress": snapshot?.message ?? NSNull()])
                return
            }
            if message["type"] as? String == "notify" {
                let notification = try SaveNotification(message: message)
                // The extension does not act on the reply; failures are only logged.
                Self.post(notification) { respond(["ok": $0 == nil]) }
                return
            }
            if message["type"] as? String == "reveal" {
                let files = try MediaFile.savedFiles(message["filenames"],
                                                     in: try Self.downloadsDirectory(create: false))
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting(files)
                    respond(["ok": true])
                }
                return
            }

            let request = try MediaDownloadRequest(message: message,
                                                   defaultGIFOptions: try GIFPreferences.appGroup().options)
            let directory = try Self.downloadsDirectory(create: true)

            Self.lock.lock()
            let accepted = Self.activeRequests.count < 3 && !Self.activeRequests.contains(request.basename)
            if accepted { Self.activeRequests.insert(request.basename) }
            Self.lock.unlock()
            guard accepted else { throw MediaDownloadError.busy }

            SaveProgress.shared.begin(request.basename)
            MediaSave(request: request, directory: directory, progress: .shared).start { result in
                SaveProgress.shared.end(request.basename)
                Self.lock.lock()
                Self.activeRequests.remove(request.basename)
                Self.lock.unlock()
                switch result {
                case .success(let saved): respond(saved.message)
                case .failure(let error): respond(MediaDownloadError.response(for: error))
                }
            }
        } catch {
            respond(MediaDownloadError.response(for: error))
        }
    }
}

/// Handles the notification's "Show in Finder" button. Clicking the notification itself is
/// left to macOS, which brings the app forward; it is not handled here.
private final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationResponder()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == SafariWebExtensionHandler.revealAction else { return completionHandler() }
        do {
            // Same checks as the "reveal" message: saved names that still exist in Downloads.
            let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: false)
            let files = try MediaFile.savedFiles(response.notification.request.content.userInfo["filenames"],
                                                 in: directory)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting(files)
                completionHandler()
            }
        } catch {
            SafariWebExtensionHandler.log.notice("notification files not revealed: \(String(describing: error), privacy: .public)")
            completionHandler()
        }
    }

    // Show the banner even if this process counts as frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
