import AppKit
import XCTest
@testable import MacdowsCommander

@MainActor
final class ThemeTests: XCTestCase {
    private var savedAppearance: NSAppearance?

    override func setUp() {
        _ = NSApplication.shared
        savedAppearance = NSApp.appearance
    }

    override func tearDown() {
        Theme.choice = .cream
        UserDefaults.standard.removeObject(forKey: "theme")
        NSApp.appearance = savedAppearance
    }

    private func components(_ color: NSColor) -> [CGFloat] {
        let fixed = Theme.resolved(color)
        return [fixed.redComponent, fixed.greenComponent, fixed.blueComponent]
    }

    func testChoosingAThemeChangesColorsAndIsRemembered() {
        Theme.choice = .defaultDark
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "theme"), "defaultDark")
        XCTAssertLessThan(components(Theme.background)[0], 0.3)
        XCTAssertEqual(components(Theme.text), [1, 1, 1])

        Theme.choice = .light
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        XCTAssertEqual(components(Theme.background), [1, 1, 1])

        Theme.choice = .cream
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        XCTAssertGreaterThan(components(Theme.background)[0], 0.9)
        XCTAssertLessThan(components(Theme.text)[0], 0.15, "darker than it was")

        Theme.choice = .norton
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        XCTAssertEqual(components(Theme.background)[2], 170.0 / 255, accuracy: 0.01)
        XCTAssertEqual(components(Theme.terminalBackground), [0, 0, 0])
    }

    func testThemeListIsTheFourAskedFor() {
        XCTAssertEqual(Theme.Choice.allCases, [.defaultDark, .light, .cream, .norton])
    }

    func testEveryThemeKeepsTextReadable() {
        func luminance(_ c: [CGFloat]) -> CGFloat {
            let linear = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
            let x = luminance(components(a)), y = luminance(components(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for choice in Theme.Choice.allCases {
            Theme.choice = choice
            XCTAssertGreaterThan(contrast(Theme.text, Theme.background), 7, "\(choice)")
            XCTAssertGreaterThan(contrast(Theme.secondaryText, Theme.background), 4, "\(choice)")
            XCTAssertGreaterThan(contrast(Theme.onAccent, Theme.accent), 3.5, "\(choice)")
            XCTAssertGreaterThan(contrast(Theme.marked, Theme.background), 4, "\(choice)")
            XCTAssertGreaterThan(contrast(Theme.editorText, Theme.editorBackground), 7, "\(choice)")
            XCTAssertGreaterThan(contrast(Theme.terminalText, Theme.terminalBackground), 7, "\(choice)")
            XCTAssertGreaterThan(contrast(Theme.toastText, Theme.toastBackground), 7, "\(choice)")
        }
    }
}
