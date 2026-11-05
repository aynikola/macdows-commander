import AppKit

extension Notification.Name {
    static let themeChanged = Notification.Name("MacdowsThemeChanged")
}

/// The app's colors. Each one follows the window's appearance, so changing the theme needs no restart.
enum Theme {
    enum Choice: String, CaseIterable {
        case defaultDark, light, cream, norton

        var titleKey: String { "menu.theme.\(rawValue)" }

        fileprivate var appearance: NSAppearance? {
            switch self {
            case .cream, .light: return NSAppearance(named: .aqua)
            case .defaultDark, .norton: return NSAppearance(named: .darkAqua)
            }
        }

        /// Reads what was saved, including the names older versions used.
        fileprivate init(saved: String?) {
            switch saved {
            case "dark", "original", "system": self = .defaultDark
            default: self = saved.flatMap(Choice.init(rawValue:)) ?? .cream
            }
        }
    }

    private static let choiceKey = "theme"

    /// Colors ask for this on every draw, so it stays in memory.
    private static var current = Choice(saved: UserDefaults.standard.string(forKey: choiceKey))

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
        NSApp.appearance = current.appearance
    }

    private static func rgb(_ value: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
    }

    /// Fixed colors, not system ones: a system color inside these can come out for the wrong appearance.
    private static func colors(_ cream: Int, _ light: Int, _ dark: Int, _ norton: Int, alpha: CGFloat = 1) -> NSColor {
        let values = (rgb(cream, alpha: alpha), rgb(light, alpha: alpha), rgb(dark, alpha: alpha), rgb(norton, alpha: alpha))
        return NSColor(name: nil) { _ in
            switch current {
            case .cream: return values.0
            case .light: return values.1
            case .defaultDark: return values.2
            case .norton: return values.3
            }
        }
    }

    /// A code color. Cream and light share one, since both are pale backgrounds.
    static func token(_ pale: Int, dark: Int, norton: Int) -> NSColor { colors(pale, pale, dark, norton) }

    static let background = colors(0xF6F2E7, 0xFFFFFF, 0x2B2B2B, 0x0000AA)
    static let surface = colors(0xECE7D9, 0xF2F2F2, 0x1E1E1E, 0x000080)
    static let selectionMuted = colors(0xE2DCCB, 0xDCDCDC, 0x464646, 0x000080)
    static let border = colors(0xD6D0BE, 0xD0D0D0, 0x4A4A4A, 0x5555FF)
    static let text = colors(0x1F1E1C, 0x111111, 0xFFFFFF, 0x55FFFF)
    static let secondaryText = colors(0x55544F, 0x5A5A5A, 0xA6A6A6, 0xC0C0FF)
    static let hiddenText = colors(0x75736B, 0x8A8A8A, 0xA8A8A8, 0x9999FF)
    static let accent = colors(0xC6613F, 0x0A63D6, 0x0A84FF, 0x00AAAA)
    static let onAccent = colors(0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0x000000)
    static let marked = colors(0xB5401A, 0xC4320A, 0xFF9F0A, 0xFFFF55)
    static let markedOnAccent = colors(0xFFE3B8, 0xFFE3B8, 0xFFD98F, 0x0000AA)
    static let error = colors(0xC62F2F, 0xC62F2F, 0xFF5C5C, 0xFF5555)
    static let success = colors(0x2F7D4F, 0x1E7B3E, 0x32D74B, 0x55FF55)
    static let warning = colors(0xC6613F, 0xB8650A, 0xFF9F0A, 0xFFFF55)
    /// A message over the panels stands out by being the opposite of the window.
    static let toastBackground = colors(0x1F1E1C, 0x222222, 0x292929, 0x00AAAA)
    static let toastText = colors(0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0x000000)

    static let diffRemoved = colors(0xF6D5CC, 0xFBDAD6, 0x5A2E2E, 0x800000)
    static let diffAdded = colors(0xD5E8C8, 0xD4F0D8, 0x2C4A32, 0x006000)
    static let diffChanged = colors(0xF5E7B5, 0xFFF3C2, 0x46402A, 0x505000)
    static let diffWord = colors(0xEBCB6E, 0xF5D76E, 0x7A6A2E, 0x808000)
    static let diffEmpty = colors(0xE2DCCB, 0xEBEBEB, 0x262626, 0x000060)

    static let terminalBackground = colors(0xF6F2E7, 0xFFFFFF, 0x171717, 0x000000)
    static let terminalText = colors(0x1F1E1C, 0x111111, 0xE6E6E6, 0xC0C0C0)

    static let editorBackground = colors(0xF6F2E7, 0xFFFFFF, 0x1F1F1F, 0x0000AA)
    static let editorText = colors(0x1F1E1C, 0x111111, 0xE0E0E0, 0xFFFFFF)
    static let editorCaret = colors(0x1F1E1C, 0x111111, 0xFFFFFF, 0xFFFF55)
    static let gutter = colors(0xECE7D9, 0xF2F2F2, 0x262626, 0x000080)
    static let gutterText = colors(0x75736B, 0x8A8A8A, 0x808080, 0x9999FF)
    static let gutterCurrent = colors(0x1F1E1C, 0x111111, 0xE6E6E6, 0xFFFFFF)
    static let textSelection = colors(0xF5D1B8, 0xBBD6FB, 0x335C99, 0x008080)
    static let match = colors(0xF2C759, 0xFFE27A, 0xF2BF33, 0xAAAA00, alpha: 0.45)
    static let currentMatch = colors(0xF59A4D, 0xFFB454, 0xB5602A, 0xAA5500)

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
