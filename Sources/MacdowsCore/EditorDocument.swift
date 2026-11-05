import Foundation

/// What a file looked like on disk, so saving writes back the same encoding and line endings.
public struct EditorDocument {
    public enum Encoding: Equatable {
        case utf8, utf8BOM, windows1254, latin5

        public var title: String {
            switch self {
            case .utf8: return "UTF-8"
            case .utf8BOM: return "UTF-8 BOM"
            case .windows1254: return "Windows-1254"
            case .latin5: return "ISO-8859-9"
            }
        }

        var foundation: String.Encoding {
            switch self {
            case .utf8, .utf8BOM: return .utf8
            case .windows1254: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsLatin5.rawValue)))
            case .latin5: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin5.rawValue)))
            }
        }
    }

    public var text: String
    public var encoding: Encoding
    /// True when every line ended in CRLF. The editor then works with plain LF and saving restores CRLF.
    public var usesCRLF: Bool

    public init(text: String, encoding: Encoding, usesCRLF: Bool) {
        self.text = text
        self.encoding = encoding
        self.usesCRLF = usesCRLF
    }

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Nil for anything that could not be saved back byte for byte: binary files and unknown encodings.
    public static func decode(_ data: Data) -> EditorDocument? {
        if data.contains(0) { return nil }
        var encoding = Encoding.utf8
        var body = data
        if data.starts(with: bom) {
            encoding = .utf8BOM
            body = data.dropFirst(3)
        }
        var text = String(data: body, encoding: .utf8)
        if text == nil {
            for candidate in [Encoding.windows1254, .latin5] {
                if let decoded = String(data: body, encoding: candidate.foundation), decoded.data(using: candidate.foundation) == body {
                    text = decoded
                    encoding = candidate
                    break
                }
            }
        }
        guard var text else { return nil }
        var usesCRLF = false
        var feeds = 0, returns = 0, pairs = 0
        var previous: UInt8 = 0
        for byte in body {
            if byte == 10 {
                feeds += 1
                if previous == 13 { pairs += 1 }
            } else if byte == 13 {
                returns += 1
            }
            previous = byte
        }
        if pairs > 0, pairs == feeds, pairs == returns {
            usesCRLF = true
            text = text.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
        }
        return EditorDocument(text: text, encoding: encoding, usesCRLF: usesCRLF)
    }

    /// Nil when the text holds a character this encoding cannot store.
    public func encode(_ newText: String) -> Data? {
        var output = newText
        if usesCRLF {
            output = output.replacingOccurrences(of: "\r\n", with: "\n", options: .literal).replacingOccurrences(of: "\n", with: "\r\n", options: .literal)
        }
        guard let data = output.data(using: encoding.foundation) else { return nil }
        return encoding == .utf8BOM ? Data(Self.bom) + data : data
    }
}

/// A change to apply to the text, and where the selection goes afterwards.
public struct TextChange: Equatable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

public enum LineEdits {
    /// The whole lines a selection touches. A selection ending right after a line break leaves out the next line.
    private static func lines(_ text: NSString, _ selection: NSRange) -> NSRange {
        var covered = selection
        if covered.length > 0, text.character(at: NSMaxRange(covered) - 1) == 10 { covered.length -= 1 }
        return text.lineRange(for: covered)
    }

    private static func endsInBreak(_ text: NSString, _ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        let last = text.character(at: NSMaxRange(range) - 1)
        return last == 10 || last == 13
    }

    public static func duplicate(in text: NSString, selection: NSRange) -> TextChange {
        let range = lines(text, selection)
        let block = text.substring(with: range)
        if endsInBreak(text, range) {
            return TextChange(range: NSRange(location: NSMaxRange(range), length: 0), replacement: block,
                              selection: NSRange(location: selection.location + range.length, length: selection.length))
        }
        return TextChange(range: NSRange(location: NSMaxRange(range), length: 0), replacement: "\n" + block,
                          selection: NSRange(location: selection.location + range.length + 1, length: selection.length))
    }

    public static func delete(in text: NSString, selection: NSRange) -> TextChange {
        var range = lines(text, selection)
        var caret = range.location
        if !endsInBreak(text, range), range.location > 0 {
            // The last line has no break of its own, so the one before it goes.
            let before = text.character(at: range.location - 1)
            let width = before == 10 && range.location > 1 && text.character(at: range.location - 2) == 13 ? 2 : 1
            range = NSRange(location: range.location - width, length: range.length + width)
            caret = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        }
        return TextChange(range: range, replacement: "", selection: NSRange(location: caret, length: 0))
    }
}

public enum TextMatcher {
    /// One-to-one case folding, so positions in the folded text are positions in the original.
    /// Turkish İ, I, ı and i all count as the same letter, as in file search.
    private static func fold(_ c: UInt16) -> UInt16 {
        if c < 0x80 { return c >= 65 && c <= 90 ? c + 32 : c }
        if c == 0x130 || c == 0x131 { return 105 }
        guard let scalar = Unicode.Scalar(c) else { return c }
        let mapped = Array(scalar.properties.lowercaseMapping.utf16)
        return mapped.count == 1 ? mapped[0] : c
    }

    /// Case-insensitive, with Turkish letters and macOS's decomposed file names handled.
    public static func hasPrefix(_ name: String, _ prefix: String) -> Bool {
        name.precomposedStringWithCanonicalMapping.utf16.map(fold).starts(with: prefix.precomposedStringWithCanonicalMapping.utf16.map(fold))
    }

    public static func find(_ query: String, in text: String, caseSensitive: Bool) -> [NSRange] {
        var needle = Array(query.utf16)
        var haystack = Array(text.utf16)
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        if !caseSensitive {
            needle = needle.map(fold)
            haystack = haystack.map(fold)
        }
        var results: [NSRange] = []
        let first = needle[0]
        let last = haystack.count - needle.count
        var i = 0
        haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { need in
                while i <= last {
                    if hay[i] == first {
                        var j = 1
                        while j < need.count, hay[i + j] == need[j] { j += 1 }
                        if j == need.count {
                            results.append(NSRange(location: i, length: need.count))
                            i += need.count
                            continue
                        }
                    }
                    i += 1
                }
            }
        }
        return results
    }
}
