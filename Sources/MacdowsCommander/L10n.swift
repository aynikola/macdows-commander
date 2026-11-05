import Foundation

extension Notification.Name {
    static let languageChanged = Notification.Name("MacdowsLanguageChanged")
}

/// Language files live in Resources/<code>.lproj/Localizable.strings. English is the base:
/// a key missing from another language shows its English text.
enum L10n {
    private static let key = "language"
    private static var tables: [String: [String: String]] = [:]

    static var available: [(code: String, name: String)] { [("en", "English"), ("tr", "Türkçe")] }

    static var language: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: key) { return saved }
            return Locale.preferredLanguages.first?.hasPrefix("tr") == true ? "tr" : "en"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }

    private static func table(_ code: String) -> [String: String] {
        if let loaded = tables[code] { return loaded }
        var loaded: [String: String] = [:]
        if let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: code),
           let values = NSDictionary(contentsOfFile: path) as? [String: String] {
            loaded = values
        }
        tables[code] = loaded
        return loaded
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = table(language)[key] ?? table("en")[key] ?? key
        return args.isEmpty ? format : String(format: format, arguments: args)
    }
}

enum Format {
    static func size(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: L10n.language)
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let number = { (value: Double) in formatter.string(from: NSNumber(value: value)) ?? String(value) }
        if bytes >= 1 << 30 { return number(Double(bytes) / Double(1 << 30)) + " GB" }
        if bytes >= 1 << 20 { return number(Double(bytes) / Double(1 << 20)) + " MB" }
        if bytes >= 1 << 10 { return number(Double(bytes) / Double(1 << 10)) + " KB" }
        return "\(bytes) B"
    }

    static func exact(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: L10n.language)
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: bytes)) ?? String(bytes)
    }

    private static let english: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let turkish: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        return (L10n.language == "tr" ? turkish : english).string(from: date)
    }
}
