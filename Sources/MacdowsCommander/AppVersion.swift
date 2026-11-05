import Foundation

/// The version comes from the app's Info.plist, which scripts/build-app.sh writes.
enum AppVersion {
    static var short: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    static var windowTitle: String {
        short.map { "Macdows Commander v\($0)" } ?? "Macdows Commander"
    }
}
