import AppKit

extension Notification.Name {
    static let themeChanged = Notification.Name("MacdowsThemeChanged")
}

/// The app's colors. Each one follows the window's appearance, so changing the theme needs no restart.
enum Theme {
    enum Choice: String, CaseIterable {
        case cream, dark, original, system

        var titleKey: String {
            switch self {
            case .cream: return "menu.themeCream"
            case .dark: return "menu.themeDark"
            case .original: return "menu.themeOriginal"
            case .system: return "menu.themeSystem"
            }
        }

        fileprivate var appearance: NSAppearance? {
            switch self {
            case .cream: return NSAppearance(named: .aqua)
            case .dark, .original: return NSAppearance(named: .darkAqua)
            case .system: return nil
            }
        }
    }

    private static let choiceKey = "theme"

    /// Colors ask for this on every draw, so it stays in memory.
    private static var current = UserDefaults.standard.string(forKey: choiceKey).flatMap(Choice.init(rawValue:)) ?? .cream

    /// Fixed colors, not system ones: a system color inside these can come out for the wrong appearance.
    static var choice: Choice {
        get { current }
        set {
            current = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: choiceKey)
            activate()
            NotificationCenter.default.post(name: .themeChanged, object: nil)
        }
    }

    /// Windows have no appearance of their own, so they all follow this.
    static func activate() {
        NSApp.appearance = choice.appearance
    }

    private static func rgb(_ value: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
    }

    /// The colors for cream, dark, and the app's original look.
    static func colors(_ light: NSColor, _ dark: NSColor, original: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if choice == .original { return original }
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ light: Int, _ dark: Int, original: Int) -> NSColor {
        colors(rgb(light), rgb(dark), original: rgb(original))
    }

    private static func white(_ value: CGFloat, alpha: CGFloat = 1) -> NSColor { NSColor(white: value, alpha: alpha) }

    static let background = colors(rgb(0xF6F2E7), rgb(0x262624), original: rgb(0x2B2B2B))
    static let surface = colors(rgb(0xECE7D9), rgb(0x30302E), original: rgb(0x1E1E1E))
    static let selectionMuted = colors(rgb(0xE2DCCB), rgb(0x3D3D3A), original: rgb(0x464646))
    static let border = colors(rgb(0xD6D0BE), rgb(0x4A4A46), original: rgb(0x4A4A4A))
    static let text = colors(rgb(0x3D3D3A), rgb(0xECEAE2), original: .white)
    static let secondaryText = colors(rgb(0x73726C), rgb(0xB0AEA5), original: rgb(0xA6A6A6))
    static let hiddenText = colors(rgb(0x8F8D84), rgb(0x8A8880), original: white(1, alpha: 0.65))
    static let accent = colors(rgb(0xC6613F), rgb(0xD97757), original: rgb(0x0A84FF))
    static let onAccent = colors(rgb(0xFFFFFF), rgb(0x1F1E1D), original: .white)
    static let marked = colors(rgb(0xB5401A), rgb(0xFF9A6B), original: rgb(0xFF9F0A))
    static let markedOnAccent = colors(rgb(0xFFE3B8), rgb(0x3A0E00), original: NSColor(red: 1, green: 0.85, blue: 0.56, alpha: 1))
    static let error = colors(rgb(0xC62F2F), rgb(0xFF7B72), original: NSColor(red: 1, green: 0.36, blue: 0.36, alpha: 1))
    static let success = colors(rgb(0x2F7D4F), rgb(0x7FCB9A), original: rgb(0x32D74B))
    static let warning = colors(rgb(0xC6613F), rgb(0xD97757), original: rgb(0xFF9F0A))
    /// A message over the panels stands out by being the opposite of the window.
    static let toastBackground = colors(rgb(0x3D3D3A), rgb(0xECEAE2), original: white(0.16, alpha: 0.97))
    static let toastText = colors(rgb(0xFFFFFF), rgb(0x1F1E1D), original: .white)

    static let terminalBackground = colors(rgb(0xF6F2E7), rgb(0x262624), original: white(0.09))
    static let terminalText = colors(rgb(0x3D3D3A), rgb(0xECEAE2), original: white(0.9))

    static let editorBackground = colors(rgb(0xF6F2E7), rgb(0x262624), original: white(0.12))
    static let editorText = colors(rgb(0x3D3D3A), rgb(0xECEAE2), original: white(0.88))
    static let editorCaret = colors(rgb(0x3D3D3A), rgb(0xECEAE2), original: .white)
    static let gutter = colors(rgb(0xECE7D9), rgb(0x30302E), original: white(0.15))
    static let gutterText = colors(rgb(0x8F8D84), rgb(0x8A8880), original: white(0.5))
    static let gutterCurrent = colors(rgb(0x3D3D3A), rgb(0xECEAE2), original: white(0.9))
    static let textSelection = colors(rgb(0xF5D1B8), rgb(0x5A4033), original: NSColor(red: 0.2, green: 0.36, blue: 0.6, alpha: 1))
    static let match = colors(NSColor(srgbRed: 0.95, green: 0.78, blue: 0.35, alpha: 0.45), rgb(0xB5892A, alpha: 0.45), original: NSColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 0.3))
    static let currentMatch = colors(rgb(0xF59A4D), rgb(0xB5602A), original: NSColor(red: 1, green: 0.6, blue: 0.1, alpha: 0.75))

    /// Layers and the terminal keep one fixed color, so they get the theme's color at this moment.
    static func resolved(_ color: NSColor) -> NSColor {
        var result = color
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let fixed = color.usingColorSpace(.sRGB) { result = fixed }
        }
        return result
    }

    static func apply(to window: NSWindow?) {
        window?.appearance = nil
        window?.backgroundColor = background
    }
}
