import Foundation

/// AppKit and the bundled WKWebView follow the containing app's language.
enum AppLocalization {
    static var language: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("ja") == true ? "ja" : "en"
    }

    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    static var webPayload: [String: Any] {
        let keys = [
            "app_tagline", "extension_enable_hint", "extension_enabled", "extension_disabled",
            "how_to_use", "step_enable", "step_access", "step_save",
            "open_preferences", "preferences_error", "gif_settings", "default_settings",
            "gif_loading", "gif_ready", "gif_error", "quality",
            "quality_high", "quality_medium", "quality_low", "max_frame_rate",
            "output_size", "notes_title", "note_formats", "note_popup",
            "note_menu", "no_warranty", "open_licenses"
        ]
        return ["language": language, "messages": Dictionary(uniqueKeysWithValues: keys.map { ($0, string($0)) })]
    }
}
