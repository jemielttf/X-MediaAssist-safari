import Foundation

/// AppKit and the bundled WKWebView follow the containing app's language.
enum AppLocalization {
    static var language: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("ja") == true ? "ja" : "en"
    }

    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    // The whole compiled table for the selected language, so web keys need no Swift list.
    static var webPayload: [String: Any] {
        let table = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language)
            .flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        return ["language": language, "messages": table]
    }
}
