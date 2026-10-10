import Cocoa
import SafariServices
import WebKit

let extensionBundleIdentifier = "com.jemielttf.XMediaAssist.Extension"

/// Hosts the bundled Main.html. The page talks to Swift through the "controller"
/// message handler; Swift calls back into Script.js functions (show, showGIFOptions, ...).
class ViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let preferences = AppPreferences()
    @IBOutlet var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "controller")
        guard let page = Bundle.main.url(forResource: "Main", withExtension: "html"),
              let resources = Bundle.main.resourceURL else { return }
        // Localized strings must exist before Script.js runs.
        if let data = try? JSONSerialization.data(withJSONObject: AppLocalization.webPayload),
           let json = String(data: data, encoding: .utf8) {
            webView.configuration.userContentController.addUserScript(WKUserScript(
                source: "globalThis.XMAStrings = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.loadFileURL(page, allowingReadAccessTo: resources)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        do {
            let data = try JSONSerialization.data(withJSONObject: preferences.gifOptions().message)
            if let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("showGIFOptions(\(json))")
            }
        } catch { webView.evaluateJavaScript("showGIFError()") }

        SFSafariExtensionManager.getStateOfSafariExtension(
            withIdentifier: extensionBundleIdentifier
        ) { [weak self] state, _ in
            DispatchQueue.main.async {
                guard let state else { return }
                self?.webView.evaluateJavaScript("show(\(state.isEnabled))")
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // Accept messages only from our own bundled page.
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true else { return }

        if let value = message.body as? [String: Any], value["type"] as? String == "set-gif-options" {
            do {
                guard let raw = value["gifOptions"] else { throw GIFConversionOptions.ValidationError.invalidOptions }
                try preferences.setGIFOptions(GIFConversionOptions(message: raw))
            } catch { webView.evaluateJavaScript("showGIFError()") }
            return
        }

        switch message.body as? String {
        case "open-licenses":
            let page = AppLocalization.language == "ja" ? "Licenses/index.html" : "Licenses/index-en.html"
            if let url = Bundle.main.resourceURL?.appendingPathComponent(page) {
                NSWorkspace.shared.open(url)
            }
        case "open-preferences":
            SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { [weak self] error in
                DispatchQueue.main.async {
                    if error != nil { self?.webView.evaluateJavaScript("showError()") }
                }
            }
        default:
            break
        }
    }
}
