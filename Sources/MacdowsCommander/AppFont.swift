import AppKit

extension Notification.Name {
    static let appFontChanged = Notification.Name("MacdowsFontChanged")
}

/// The reading size and typeface, shared by the file lists, the terminal and the editor.
enum AppFont {
    private static let sizeKey = "font.size"
    private static let familyKey = "font.family"
    static let defaultSize: CGFloat = 14
    static let systemFamily = "system"
    /// All of these come with every Mac.
    static let families = ["Verdana", "Tahoma", "Lucida Grande", "Arial", "Helvetica Neue", "Menlo", systemFamily]
    /// San Francisco looks thin and pale on a dark list, so the default is a plainer, wider face.
    static let defaultFamily = "Verdana"
    static let monoFamily = "Menlo"

    static var size: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: sizeKey)
            return saved > 0 ? CGFloat(saved) : defaultSize
        }
        set {
            UserDefaults.standard.set(Double(min(26, max(10, newValue))), forKey: sizeKey)
            NotificationCenter.default.post(name: .appFontChanged, object: nil)
        }
    }

    static var family: String {
        get { UserDefaults.standard.string(forKey: familyKey) ?? defaultFamily }
        set {
            UserDefaults.standard.set(newValue, forKey: familyKey)
            NotificationCenter.default.post(name: .appFontChanged, object: nil)
        }
    }

    /// File names.
    static func list(bold: Bool = false) -> NSFont {
        if family == systemFamily { return .systemFont(ofSize: size, weight: bold ? .bold : .regular) }
        guard let font = NSFont(name: family, size: size) else { return .systemFont(ofSize: size) }
        return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    /// Sizes and dates, which line up better with equal-width digits.
    static var digits: NSFont {
        if family == systemFamily { return .monospacedDigitSystemFont(ofSize: size - 1, weight: .regular) }
        return NSFont(name: family, size: size - 1) ?? .monospacedDigitSystemFont(ofSize: size - 1, weight: .regular)
    }

    /// Code and terminal text.
    static var mono: NSFont { NSFont(name: monoFamily, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular) }

    /// Status lines, labels and buttons, in the same face as the lists.
    static func interface(_ points: CGFloat, bold: Bool = false) -> NSFont {
        if family == systemFamily { return .systemFont(ofSize: points, weight: bold ? .semibold : .regular) }
        guard let font = NSFont(name: family, size: points) else { return .systemFont(ofSize: points) }
        return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    static var rowHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: list())) + 4 }
}
