import Foundation

/// The version comes from the app's Info.plist, which scripts/build-app.sh writes.
enum AppVersion {
    static var short: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    /// Where the code, the downloads and the issue list are.
    static let repository = URL(string: "https://github.com/aynikola/macdows-commander")!
    static let releases = URL(string: "https://github.com/aynikola/macdows-commander/releases/latest")!

    static var windowTitle: String {
        short.map { "Macdows Commander v\($0)" } ?? "Macdows Commander"
    }
}
