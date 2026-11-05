import Foundation

public enum CodeLanguage: String {
    case html = "HTML"
    case php = "PHP"
    case javascript = "JavaScript"
    /// Colored like JavaScript, but the built-in parser would reject its syntax.
    case typedScript = "JS/TS"
    case json = "JSON"
    case css = "CSS"
    case plain = "Text"

    public static func detect(fileName: String) -> CodeLanguage {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "html", "htm", "xhtml", "shtml", "vue", "svelte": return .html
        case "php", "phtml", "php3", "php4", "php5", "php7", "php8", "inc": return .php
        case "js", "mjs", "cjs": return .javascript
        case "jsx", "ts", "tsx": return .typedScript
        case "json", "map": return .json
        case "css", "scss", "less": return .css
        default: return .plain
        }
    }
}

public enum TokenKind {
    case comment, string, keyword, number, tag, attribute, variable, function, meta, regex
}

public struct SyntaxToken: Equatable {
    public let range: NSRange
    public let kind: TokenKind
}

/// A `<script>` block whose content can go through the JavaScript parser.
public struct ScriptBlock: Equatable {
    public let range: NSRange
    public let isModule: Bool
    public let containsPHP: Bool
}

public struct SyntaxAnalysis {
    /// Sorted and never overlapping.
    public var tokens: [SyntaxToken] = []
    public var scripts: [ScriptBlock] = []
}

/// A small hand-written scanner over UTF-16 units, so ranges line up with NSTextView.
/// It colors code and is deliberately forgiving: finding mistakes is SyntaxChecker's job.
public enum SyntaxHighlighter {
    public static func analyze(_ text: String, language: CodeLanguage) -> SyntaxAnalysis {
        var lexer = Lexer(Array(text.utf16))
        return lexer.run(language)
    }
}

private func unit(_ character: Unicode.Scalar) -> UInt16 { UInt16(character.value) }

private let newline = unit("\n"), carriage = unit("\r"), space = unit(" "), tab = unit("\t")
private let slash = unit("/"), star = unit("*"), backslash = unit("\\"), hash = unit("#")
private let singleQuote = unit("'"), doubleQuote = unit("\""), backtick = unit("`")
private let less = unit("<"), greater = unit(">"), question = unit("?"), equals = unit("="), bang = unit("!")
private let dollar = unit("$"), openBrace = unit("{"), closeBrace = unit("}"), openParen = unit("("), closeParen = unit(")")
private let openBracket = unit("["), closeBracket = unit("]"), dot = unit("."), minus = unit("-"), colon = unit(":"), at = unit("@"), semicolon = unit(";")

private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
private func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
private func isWordStart(_ c: UInt16) -> Bool { isLetter(c) || c == 95 || c >= 0x80 }
private func isWord(_ c: UInt16) -> Bool { isWordStart(c) || isDigit(c) }
private func isSpace(_ c: UInt16) -> Bool { c == space || c == tab || c == newline || c == carriage || c == 12 }
private func lower(_ c: UInt16) -> UInt16 { c >= 65 && c <= 90 ? c + 32 : c }

private let jsKeywords: Set<String> = [
    "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
    "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof",
    "interface", "let", "new", "null", "of", "return", "set", "static", "super", "switch", "this", "throw", "true", "try",
    "type", "typeof", "undefined", "var", "void", "while", "with", "yield", "enum", "NaN", "Infinity",
]

/// After these words a slash starts a regular expression; after a value word it divides.
private let jsValueKeywords: Set<String> = ["this", "super", "true", "false", "null", "undefined", "NaN", "Infinity"]

private let phpKeywords: Set<String> = [
    "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare",
    "default", "die", "do", "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch",
    "endwhile", "enum", "eval", "exit", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global",
    "goto", "if", "implements", "include", "include_once", "instanceof", "insteadof", "interface", "isset", "list", "match",
    "namespace", "new", "null", "or", "print", "private", "protected", "public", "readonly", "require", "require_once",
    "return", "self", "static", "switch", "throw", "trait", "true", "try", "unset", "use", "var", "while", "xor", "yield",
]

private struct Lexer {
    let source: [UInt16]
    /// `source` with PHP blanked out, so the HTML and JavaScript around it read as ordinary text.
    var s: [UInt16]
    var tokens: [SyntaxToken] = []
    var scripts: [(range: NSRange, isModule: Bool)] = []

    init(_ source: [UInt16]) {
        self.source = source
        self.s = source
    }

    private mutating func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        if end > start { tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)) }
    }

    private func word(_ start: Int, _ end: Int, lowercase: Bool = false) -> String {
        String(decoding: s[start..<end].map { lowercase ? lower($0) : $0 }, as: UTF16.self)
    }

    private func matches(_ text: String, at index: Int, ignoringCase: Bool = false) -> Bool {
        var position = index
        for c in text.utf16 {
            guard position < s.count else { return false }
            if (ignoringCase ? lower(s[position]) : s[position]) != c { return false }
            position += 1
        }
        return true
    }

    private func nextNonSpace(_ index: Int, _ end: Int) -> UInt16? {
        var i = index
        while i < end {
            if !isSpace(s[i]) { return s[i] }
            i += 1
        }
        return nil
    }

    mutating func run(_ language: CodeLanguage) -> SyntaxAnalysis {
        var islands: [NSRange] = []
        var phpTokens: [SyntaxToken] = []
        if language == .php {
            islands = lexPHPIslands(into: &phpTokens)
        }
        switch language {
        case .html, .php: lexHTML(0, s.count)
        case .javascript, .typedScript, .json: _ = lexJS(0, s.count, nested: false)
        case .css: lexCSS(0, s.count)
        case .plain: break
        }
        var analysis = SyntaxAnalysis()
        analysis.tokens = (Self.subtract(tokens, islands) + phpTokens).sorted { $0.range.location < $1.range.location }
        analysis.scripts = scripts.map { script in
            ScriptBlock(range: script.range, isModule: script.isModule, containsPHP: islands.contains { NSIntersectionRange($0, script.range).length > 0 })
        }
        return analysis
    }

    /// Cuts the PHP parts out of tokens that span them, such as an attribute value holding `<?= $x ?>`.
    private static func subtract(_ tokens: [SyntaxToken], _ islands: [NSRange]) -> [SyntaxToken] {
        guard !islands.isEmpty else { return tokens }
        var result: [SyntaxToken] = []
        result.reserveCapacity(tokens.count)
        var first = 0
        for token in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            while first < islands.count, NSMaxRange(islands[first]) <= token.range.location { first += 1 }
            var start = token.range.location
            let end = NSMaxRange(token.range)
            var index = first
            while index < islands.count, islands[index].location < end {
                if islands[index].location > start {
                    result.append(SyntaxToken(range: NSRange(location: start, length: islands[index].location - start), kind: token.kind))
                }
                start = max(start, NSMaxRange(islands[index]))
                index += 1
            }
            if end > start { result.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: token.kind)) }
        }
        return result
    }

    // MARK: PHP

    private mutating func lexPHPIslands(into phpTokens: inout [SyntaxToken]) -> [NSRange] {
        var islands: [NSRange] = []
        let outer = tokens
        tokens = []
        var i = 0
        while i + 1 < s.count {
            guard s[i] == less, s[i + 1] == question else { i += 1; continue }
            var open = 0
            if matches("<?php", at: i, ignoringCase: true), i + 5 >= s.count || !isWord(s[i + 5]) {
                open = 5
            } else if matches("<?=", at: i) {
                open = 3
            } else if i + 2 < s.count, isSpace(s[i + 2]) {
                open = 2 // Short tag. `<?xml` stays text.
            }
            guard open > 0 else { i += 1; continue }
            add(i, i + open, .meta)
            let end = lexPHP(i + open)
            islands.append(NSRange(location: i, length: end - i))
            i = end
        }
        phpTokens = tokens
        tokens = outer
        for island in islands {
            for position in island.location..<NSMaxRange(island) where s[position] != newline && s[position] != carriage {
                s[position] = unit("x")
            }
        }
        return islands
    }

    /// Scans PHP code up to and including `?>`. An unclosed block runs to the end, which is valid PHP.
    private mutating func lexPHP(_ from: Int) -> Int {
        var i = from
        let end = s.count
        while i < end {
            let c = s[i]
            let next = i + 1 < end ? s[i + 1] : 0
            if c == question, next == greater {
                add(i, i + 2, .meta)
                return i + 2
            } else if (c == slash && next == slash) || (c == hash && next != openBracket) {
                var j = i
                // `?>` ends a line comment too.
                while j < end, s[j] != newline, s[j] != carriage, !(s[j] == question && j + 1 < end && s[j + 1] == greater) { j += 1 }
                add(i, j, .comment)
                i = j
            } else if c == slash, next == star {
                var j = i + 2
                while j < end, !(s[j] == star && j + 1 < end && s[j + 1] == slash) { j += 1 }
                j = min(end, j + 2)
                add(i, j, .comment)
                i = j
            } else if c == singleQuote || c == backtick {
                let j = skipString(i, end, quote: c, multiline: true)
                add(i, j, .string)
                i = j
            } else if c == doubleQuote {
                i = lexInterpolated(i, end)
            } else if c == less, matches("<<<", at: i), let j = lexHeredoc(i, end) {
                i = j
            } else if c == dollar, isWordStart(next) {
                var j = i + 1
                while j < end, isWord(s[j]) { j += 1 }
                add(i, j, .variable)
                i = j
            } else if isDigit(c) {
                let j = skipNumber(i, end)
                add(i, j, .number)
                i = j
            } else if isWordStart(c) {
                var j = i
                while j < end, isWord(s[j]) { j += 1 }
                let member = i >= 2 && ((s[i - 2] == minus && s[i - 1] == greater) || (s[i - 2] == colon && s[i - 1] == colon))
                if !member, phpKeywords.contains(word(i, j, lowercase: true)) {
                    add(i, j, .keyword)
                } else if nextNonSpace(j, end) == openParen {
                    add(i, j, .function)
                }
                i = j
            } else {
                i += 1
            }
        }
        return end
    }

    private mutating func lexInterpolated(_ start: Int, _ end: Int) -> Int {
        var i = start + 1
        var segment = start
        while i < end {
            if s[i] == backslash {
                i += 2
            } else if s[i] == doubleQuote {
                add(segment, i + 1, .string)
                return i + 1
            } else if s[i] == dollar, i + 1 < end, isWordStart(s[i + 1]) {
                add(segment, i, .string)
                var j = i + 1
                while j < end, isWord(s[j]) { j += 1 }
                add(i, j, .variable)
                segment = j
                i = j
            } else {
                i += 1
            }
        }
        add(segment, end, .string)
        return end
    }

    /// `<<<NAME`, `<<<"NAME"` and `<<<'NAME'`. Returns nil when this is not a heredoc after all.
    private mutating func lexHeredoc(_ start: Int, _ end: Int) -> Int? {
        var i = start + 3
        while i < end, s[i] == space || s[i] == tab { i += 1 }
        let quote: UInt16? = i < end && (s[i] == singleQuote || s[i] == doubleQuote) ? s[i] : nil
        if quote != nil { i += 1 }
        let nameStart = i
        while i < end, isWord(s[i]) { i += 1 }
        let name = Array(s[nameStart..<i])
        guard !name.isEmpty else { return nil }
        if quote != nil { i += 1 }
        while i < end {
            guard s[i] == newline else { i += 1; continue }
            var j = i + 1
            while j < end, s[j] == space || s[j] == tab { j += 1 }
            if j + name.count <= end, Array(s[j..<(j + name.count)]) == name, j + name.count == end || !isWord(s[j + name.count]) {
                add(start, j + name.count, .string)
                return j + name.count
            }
            i += 1
        }
        add(start, end, .string)
        return end
    }

    private func skipString(_ start: Int, _ end: Int, quote: UInt16, multiline: Bool) -> Int {
        var i = start + 1
        while i < end {
            if s[i] == backslash {
                i += 2
            } else if s[i] == quote {
                return i + 1
            } else if !multiline, s[i] == newline {
                return i
            } else {
                i += 1
            }
        }
        return end
    }

    private func skipNumber(_ start: Int, _ end: Int) -> Int {
        var i = start
        while i < end, isWord(s[i]) || (s[i] == dot && i + 1 < end && isDigit(s[i + 1])) { i += 1 }
        return i
    }

    // MARK: JavaScript

    /// With `nested` true it stops after the `}` closing a template's `${`.
    private mutating func lexJS(_ from: Int, _ end: Int, nested: Bool) -> Int {
        var i = from
        var depth = 0
        var regexAllowed = true
        while i < end {
            let c = s[i]
            let next = i + 1 < end ? s[i + 1] : 0
            if isSpace(c) {
                i += 1
            } else if c == slash, next == slash {
                var j = i
                while j < end, s[j] != newline, s[j] != carriage { j += 1 }
                add(i, j, .comment)
                i = j
            } else if c == slash, next == star {
                var j = i + 2
                while j < end, !(s[j] == star && j + 1 < end && s[j + 1] == slash) { j += 1 }
                j = min(end, j + 2)
                add(i, j, .comment)
                i = j
            } else if c == singleQuote || c == doubleQuote {
                let j = skipString(i, end, quote: c, multiline: false)
                add(i, j, .string)
                i = j
                regexAllowed = false
            } else if c == backtick {
                i = lexTemplate(i, end)
                regexAllowed = false
            } else if c == slash, regexAllowed, let j = skipRegex(i, end) {
                add(i, j, .regex)
                i = j
                regexAllowed = false
            } else if isDigit(c) {
                let j = skipNumber(i, end)
                add(i, j, .number)
                i = j
                regexAllowed = false
            } else if isWordStart(c) || c == dollar {
                var j = i + 1
                while j < end, isWord(s[j]) || s[j] == dollar { j += 1 }
                let text = word(i, j)
                let member = i > 0 && s[i - 1] == dot
                if !member, jsKeywords.contains(text) {
                    add(i, j, .keyword)
                    regexAllowed = !jsValueKeywords.contains(text)
                } else {
                    if nextNonSpace(j, end) == openParen { add(i, j, .function) }
                    regexAllowed = false
                }
                i = j
            } else {
                if nested {
                    if c == openBrace {
                        depth += 1
                    } else if c == closeBrace {
                        if depth == 0 { return i + 1 }
                        depth -= 1
                    }
                }
                regexAllowed = c != closeParen && c != closeBracket && c != closeBrace
                i += 1
            }
        }
        return end
    }

    private mutating func lexTemplate(_ start: Int, _ end: Int) -> Int {
        var i = start + 1
        var segment = start
        while i < end {
            if s[i] == backslash {
                i += 2
            } else if s[i] == backtick {
                add(segment, i + 1, .string)
                return i + 1
            } else if s[i] == dollar, i + 1 < end, s[i + 1] == openBrace {
                add(segment, i + 2, .string)
                i = lexJS(i + 2, end, nested: true)
                segment = i - 1
            } else {
                i += 1
            }
        }
        add(segment, end, .string)
        return end
    }

    private func skipRegex(_ start: Int, _ end: Int) -> Int? {
        var i = start + 1
        var inClass = false
        while i < end {
            let c = s[i]
            if c == newline || c == carriage { return nil }
            if c == backslash {
                i += 2
                continue
            }
            if c == openBracket { inClass = true }
            if c == closeBracket { inClass = false }
            if c == slash, !inClass {
                i += 1
                while i < end, isLetter(s[i]) { i += 1 }
                return i
            }
            i += 1
        }
        return nil
    }

    // MARK: CSS

    private mutating func lexCSS(_ from: Int, _ end: Int) {
        var i = from
        var depth = 0
        while i < end {
            let c = s[i]
            if c == slash, i + 1 < end, s[i + 1] == star {
                var j = i + 2
                while j < end, !(s[j] == star && j + 1 < end && s[j + 1] == slash) { j += 1 }
                j = min(end, j + 2)
                add(i, j, .comment)
                i = j
            } else if c == singleQuote || c == doubleQuote {
                let j = skipString(i, end, quote: c, multiline: false)
                add(i, j, .string)
                i = j
            } else if c == openBrace {
                depth += 1
                i += 1
            } else if c == closeBrace {
                depth = max(0, depth - 1)
                i += 1
            } else if c == at {
                var j = i + 1
                while j < end, isWord(s[j]) || s[j] == minus { j += 1 }
                add(i, j, .keyword)
                i = j
            } else if depth > 0, c == hash || isDigit(c) || (c == dot && i + 1 < end && isDigit(s[i + 1])) {
                var j = i + 1
                while j < end, isWord(s[j]) || s[j] == dot || s[j] == unit("%") { j += 1 }
                add(i, j, .number)
                i = j
            } else if isWordStart(c) || c == minus {
                var j = i + 1
                while j < end, isWord(s[j]) || s[j] == minus { j += 1 }
                if depth > 0 {
                    if nextNonSpace(j, end) == colon { add(i, j, .attribute) }
                } else {
                    add(i, j, .tag)
                }
                i = j
            } else {
                i += 1
            }
        }
    }

    // MARK: HTML

    private mutating func lexHTML(_ from: Int, _ end: Int) {
        var i = from
        while i < end {
            guard s[i] == less, i + 1 < end else { i += 1; continue }
            if matches("<!--", at: i) {
                var j = i + 4
                while j < end, !matches("-->", at: j) { j += 1 }
                j = min(end, j + 3)
                add(i, j, .comment)
                i = j
            } else if s[i + 1] == bang {
                var j = i
                while j < end, s[j] != greater { j += 1 }
                j = min(end, j + 1)
                add(i, j, .meta)
                i = j
            } else if isLetter(s[i + 1]) || (s[i + 1] == slash && i + 2 < end && isLetter(s[i + 2])) {
                i = lexTag(i, end)
            } else {
                i += 1
            }
        }
    }

    private mutating func lexTag(_ start: Int, _ end: Int) -> Int {
        let closing = s[start + 1] == slash
        var i = start + (closing ? 2 : 1)
        let nameStart = i
        while i < end, isWord(s[i]) || s[i] == minus || s[i] == colon { i += 1 }
        let name = word(nameStart, i, lowercase: true)
        add(start, i, .tag)
        var typeValue: String?
        while i < end {
            let c = s[i]
            if isSpace(c) {
                i += 1
            } else if c == greater || (c == slash && i + 1 < end && s[i + 1] == greater) {
                let selfClosing = c == slash
                let tagEnd = i + (selfClosing ? 2 : 1)
                add(i, tagEnd, .tag)
                i = tagEnd
                if !closing, !selfClosing, name == "script" || name == "style" {
                    i = lexRawContent(i, end, name: name, type: typeValue)
                }
                return i
            } else if c == less {
                return i // A broken tag: let the next one take over.
            } else {
                let attributeStart = i
                while i < end, !isSpace(s[i]), s[i] != equals, s[i] != greater, s[i] != less, !(s[i] == slash && i + 1 < end && s[i + 1] == greater) { i += 1 }
                if i == attributeStart { i += 1; continue }
                add(attributeStart, i, .attribute)
                let attribute = word(attributeStart, i, lowercase: true)
                var j = i
                while j < end, isSpace(s[j]) { j += 1 }
                guard j < end, s[j] == equals else { continue }
                j += 1
                while j < end, isSpace(s[j]) { j += 1 }
                guard j < end else { return end }
                let valueStart = j
                if s[j] == singleQuote || s[j] == doubleQuote {
                    let quote = s[j]
                    j += 1
                    while j < end, s[j] != quote { j += 1 }
                    j = min(end, j + 1)
                } else {
                    while j < end, !isSpace(s[j]), s[j] != greater { j += 1 }
                }
                add(valueStart, j, .string)
                if attribute == "type" {
                    typeValue = word(valueStart, j, lowercase: true).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                }
                i = j
            }
        }
        return end
    }

    private mutating func lexRawContent(_ start: Int, _ end: Int, name: String, type: String?) -> Int {
        var close = start
        while close < end, !matches("</\(name)", at: close, ignoringCase: true) { close += 1 }
        if name == "style" {
            lexCSS(start, close)
        } else {
            let isJavaScript = type == nil || type == "" || type == "module" || type!.contains("javascript") || type!.contains("ecmascript")
            let isTyped = type?.contains("babel") == true || type?.contains("typescript") == true || type?.contains("jsx") == true
            if isJavaScript || isTyped { _ = lexJS(start, close, nested: false) }
            if isJavaScript, close > start {
                scripts.append((NSRange(location: start, length: close - start), type == "module"))
            }
        }
        return close
    }
}
