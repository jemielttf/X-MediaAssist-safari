// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreFoundation

/// Only allowlisted values can enter the converter, including through native IPC.
public struct GIFConversionOptions: Equatable, Sendable {
    public let quality: Int
    public let maximumFrameRate: Double
    public let scale: Double

    public static let defaults = GIFConversionOptions()
    private init() { quality = 90; maximumFrameRate = 20; scale = 1 }

    public enum ValidationError: Error { case invalidOptions }

    public init(message: Any) throws {
        guard let values = message as? [String: Any],
              Set(values.keys) == Set(["quality", "maximumFrameRate", "scale"]) else {
            throw ValidationError.invalidOptions
        }
        func number(_ key: String, allowed: [Double]) throws -> Double {
            guard let value = values[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  allowed.contains(value.doubleValue) else { throw ValidationError.invalidOptions }
            return value.doubleValue
        }
        quality = Int(try number("quality", allowed: [90, 75, 50]))
        maximumFrameRate = try number("maximumFrameRate", allowed: [30, 25, 20, 15])
        scale = try number("scale", allowed: [1, 0.75, 0.5])
    }

    public var message: [String: Any] {
        ["quality": quality, "maximumFrameRate": maximumFrameRate, "scale": scale]
    }
}

/// The host and sandboxed extension share only GIF defaults through an App Group.
public struct GIFPreferences {
    private let defaults: UserDefaults
    private static let key = "gifConversionOptions"
    public init(defaults: UserDefaults) { self.defaults = defaults }

    public static func appGroup(bundle: Bundle = .main) throws -> GIFPreferences {
        guard let suite = bundle.object(forInfoDictionaryKey: "GIFPreferencesSuite") as? String,
              !suite.isEmpty, !suite.contains("$("),
              let defaults = UserDefaults(suiteName: suite) else {
            throw GIFConversionOptions.ValidationError.invalidOptions
        }
        return GIFPreferences(defaults: defaults)
    }

    public var options: GIFConversionOptions {
        get {
            guard let stored = defaults.object(forKey: Self.key),
                  let options = try? GIFConversionOptions(message: stored) else { return .defaults }
            return options
        }
        nonmutating set { defaults.set(newValue.message, forKey: Self.key) }
    }
}
