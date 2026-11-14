import AppKit

/// Option+F1. The text lives in Resources/<language>.lproj/Manual.txt, so translating it needs no code.
/// Lines starting with "# " and "## " are headings, and "keys | meaning" lines form a two-column table.
final class HelpWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: HelpWindowController?

    static func show() {
        let controller = shared ?? HelpWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private final class EscapeWindow: NSWindow {
        override func cancelOperation(_ sender: Any?) { close() }
    }

    private init() {
        let window = EscapeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L10n.t("help.title")
        window.center()
        Theme.apply(to: window)
        super.init(window: window)
        window.delegate = self

        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.backgroundColor = Theme.background
            text.textContainerInset = NSSize(width: 18, height: 14)
            text.textStorage?.setAttributedString(Self.render(Self.manualText()))
            window.makeFirstResponder(text)
        }
        window.contentView = scroll
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func windowWillClose(_ notification: Notification) {
        // The next opening picks up a changed language or text size.
        Self.shared = nil
    }

    static func manualText() -> String {
        for code in [L10n.language, "en"] {
            if let path = Bundle.main.path(forResource: "Manual", ofType: "txt", inDirectory: nil, forLocalization: code),
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                return text
            }
        }
        return ""
    }

    static func render(_ manual: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let size = AppFont.size
        let keyWidth: CGFloat = size * 15
        let body = AppFont.interface(size)
        for line in manual.components(separatedBy: "\n") {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            if line.hasPrefix("## ") {
                style.paragraphSpacingBefore = 12
                result.append(NSAttributedString(string: line.dropFirst(3) + "\n", attributes: [.font: AppFont.interface(size + 2, bold: true), .foregroundColor: Theme.text, .paragraphStyle: style]))
            } else if line.hasPrefix("# ") {
                style.paragraphSpacingBefore = 18
                result.append(NSAttributedString(string: line.dropFirst(2) + "\n", attributes: [.font: AppFont.interface(size + 7, bold: true), .foregroundColor: Theme.text, .paragraphStyle: style]))
            } else if let separator = line.range(of: " | ") {
                style.tabStops = [NSTextTab(textAlignment: .left, location: keyWidth)]
                style.headIndent = keyWidth
                result.append(NSAttributedString(string: String(line[..<separator.lowerBound]), attributes: [.font: NSFont(name: AppFont.monoFamily, size: size - 1) ?? .monospacedSystemFont(ofSize: size - 1, weight: .regular), .foregroundColor: Theme.accent, .paragraphStyle: style]))
                result.append(NSAttributedString(string: "\t" + line[separator.upperBound...] + "\n", attributes: [.font: body, .foregroundColor: Theme.text, .paragraphStyle: style]))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let text = NSMutableAttributedString(string: line + "\n", attributes: [.font: body, .foregroundColor: Theme.text, .paragraphStyle: style])
                // Addresses in the manual open in the browser.
                if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                    for match in detector.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                        guard let url = match.url else { continue }
                        text.addAttributes([.link: url, .foregroundColor: Theme.accent], range: match.range)
                    }
                }
                result.append(text)
            }
        }
        return result
    }
}
