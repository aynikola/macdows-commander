import Foundation

/// Turns Markdown into HTML for the F3 viewer: the common parts of CommonMark and GitHub's tables, task lists and strikethrough.
public enum Markdown {
    public static func html(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return blocks(normalized.components(separatedBy: "\n"))
    }

    /// A settings block at the very top, between --- lines, kept apart from the text.
    public static func splitFrontMatter(_ text: String) -> (front: String, body: String) {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return ("", text) }
        let ns = text as NSString
        let close = ns.range(of: "\n---", options: [], range: NSRange(location: 3, length: ns.length - 3))
        guard close.location != NSNotFound else { return ("", text) }
        var end = NSMaxRange(close)
        guard end == ns.length || ns.character(at: end) == 10 || ns.character(at: end) == 13 else { return ("", text) }
        while end < ns.length, ns.character(at: end) == 10 || ns.character(at: end) == 13 { end += 1 }
        return (ns.substring(to: end), ns.substring(from: end))
    }

    public static func page(_ text: String) -> String {
        RichDocument.balmyTemplate + "\n" + html(text) + RichDocument.closing
    }

    // MARK: Blocks

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are fixed text, so a failure here is a programming mistake.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func groups(_ pattern: NSRegularExpression, _ text: String) -> [String]? {
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
    }

    private static let heading = regex(#"^ {0,3}(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$"#)
    private static let rule = regex(#"^ {0,3}([-*_])[ \t]*(?:\1[ \t]*){2,}$"#)
    private static let fence = regex(#"^ {0,3}(`{3,}|~{3,})[ \t]*([^\s`]*).*$"#)
    private static let quote = regex(#"^ {0,3}> ?(.*)$"#)
    private static let bullet = regex(#"^( *)([-*+])[ \t]+(.*)$"#)
    private static let number = regex(#"^( *)(\d{1,9})[.)][ \t]+(.*)$"#)
    private static let setextOne = regex(#"^ {0,3}=+[ \t]*$"#)
    private static let setextTwo = regex(#"^ {0,3}-+[ \t]*$"#)
    private static let tableDivider = regex(#"^ *\|? *:?-+:? *(\| *:?-+:? *)*\|? *$"#)
    private static let htmlBlock = regex(#"^ {0,3}</?(address|article|aside|blockquote|center|details|dialog|div|dl|fieldset|figure|footer|form|h[1-6]|header|hr|main|nav|ol|p|pre|section|summary|table|ul|img|!--)\b"#, [.caseInsensitive])

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, start: String, rest: String)? {
        if matches(rule, line) { return nil }
        if let parts = groups(bullet, line) { return (parts[1].count, false, "", parts[3]) }
        if let parts = groups(number, line) { return (parts[1].count, true, parts[2], parts[3]) }
        return nil
    }

    private static func startsBlock(_ line: String) -> Bool {
        matches(heading, line) || matches(rule, line) || matches(fence, line) || matches(quote, line) || listMarker(line) != nil || matches(htmlBlock, line)
    }

    private static func blocks(_ lines: [String]) -> String {
        var output = ""
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
            } else if let parts = groups(fence, line) {
                let marker = parts[1]
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let current = lines[i].trimmingCharacters(in: .whitespaces)
                    if current.hasPrefix(marker), current.allSatisfy({ $0 == marker.first }) { break }
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                let language = parts[2].isEmpty ? "" : " class=\"language-\(escape(parts[2]))\""
                output += "<pre><code\(language)>\(escape(code.joined(separator: "\n")))\n</code></pre>\n"
            } else if let parts = groups(heading, line) {
                let level = parts[1].count
                output += "<h\(level)>\(inline(parts[2]))</h\(level)>\n"
                i += 1
            } else if matches(rule, line) {
                output += "<hr>\n"
                i += 1
            } else if matches(quote, line) {
                var inner: [String] = []
                while i < lines.count, !isBlank(lines[i]) {
                    if let parts = groups(quote, lines[i]) {
                        inner.append(parts[1])
                    } else if startsBlock(lines[i]) {
                        break
                    } else {
                        inner.append(lines[i])
                    }
                    i += 1
                }
                output += "<blockquote>\n\(blocks(inner))</blockquote>\n"
            } else if let marker = listMarker(line) {
                let (html, next) = list(lines, from: i, marker: marker)
                output += html
                i = next
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                var code: [String] = []
                while i < lines.count, lines[i].hasPrefix("    ") || lines[i].hasPrefix("\t") || isBlank(lines[i]) {
                    code.append(lines[i].hasPrefix("\t") ? String(lines[i].dropFirst()) : String(lines[i].dropFirst(4)))
                    i += 1
                }
                while code.last.map(isBlank) == true { code.removeLast() }
                output += "<pre><code>\(escape(code.joined(separator: "\n")))\n</code></pre>\n"
            } else if matches(htmlBlock, line) {
                // Pages opened by the viewer never run scripts, so HTML in Markdown is safe to show as it is.
                while i < lines.count, !isBlank(lines[i]) {
                    output += lines[i] + "\n"
                    i += 1
                }
            } else if line.contains("|"), i + 1 < lines.count, lines[i + 1].contains("-"), matches(tableDivider, lines[i + 1]), cells(line).count == cells(lines[i + 1]).count {
                let (html, next) = table(lines, from: i)
                output += html
                i = next
            } else {
                var paragraph: [String] = []
                var level = 0
                while i < lines.count, !isBlank(lines[i]) {
                    if !paragraph.isEmpty {
                        if matches(setextOne, lines[i]) { level = 1; i += 1; break }
                        if matches(setextTwo, lines[i]) { level = 2; i += 1; break }
                        if startsBlock(lines[i]) { break }
                    }
                    paragraph.append(lines[i])
                    i += 1
                }
                if level > 0 {
                    output += "<h\(level)>\(inline(paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")))</h\(level)>\n"
                } else {
                    output += "<p>\(paragraphText(paragraph))</p>\n"
                }
            }
        }
        return output
    }

    private static func paragraphText(_ lines: [String]) -> String {
        var parts: [String] = []
        for (index, line) in lines.enumerated() {
            let hardBreak = index < lines.count - 1 && (line.hasSuffix("  ") || line.hasSuffix("\\"))
            var content = line.trimmingCharacters(in: .whitespaces)
            if hardBreak, content.hasSuffix("\\") { content.removeLast() }
            parts.append(content + (hardBreak ? "\u{E002}" : ""))
        }
        return inline(parts.joined(separator: "\n")).replacingOccurrences(of: "\u{E002}", with: "<br>")
    }

    private static func list(_ lines: [String], from start: Int, marker first: (indent: Int, ordered: Bool, start: String, rest: String)) -> (String, Int) {
        var i = start
        var items: [String] = []
        var loose = false
        while i < lines.count {
            guard let marker = listMarker(lines[i]), marker.ordered == first.ordered, marker.indent < first.indent + 2, marker.indent >= first.indent else { break }
            let contentIndent = marker.indent + 2
            var body = [marker.rest]
            i += 1
            var sawBlank = false
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    sawBlank = true
                    body.append("")
                    i += 1
                    continue
                }
                let indent = line.prefix { $0 == " " }.count + line.prefix { $0 == "\t" }.count * 4
                if indent >= contentIndent {
                    if sawBlank { loose = true }
                    sawBlank = false
                    let dropped = line.hasPrefix("\t") ? String(line.dropFirst()) : String(line.dropFirst(min(contentIndent, indent)))
                    body.append(dropped)
                    i += 1
                } else if !sawBlank, listMarker(line) == nil, !startsBlock(line) {
                    body.append(line.trimmingCharacters(in: .whitespaces))
                    i += 1
                } else {
                    break
                }
            }
            if sawBlank, i < lines.count, let next = listMarker(lines[i]), next.ordered == first.ordered, next.indent >= first.indent, next.indent < first.indent + 2 { loose = true }
            while body.last.map(isBlank) == true { body.removeLast() }
            items.append(listItem(body))
        }
        let opening = first.ordered ? (first.start == "1" ? "<ol>" : "<ol start=\"\(Int(first.start) ?? 1)\">") : "<ul>"
        let closing = first.ordered ? "</ol>" : "</ul>"
        let content = items.map { item -> String in
            var html = item
            if !loose {
                // A tight list has no paragraphs in its items.
                html = html.replacingOccurrences(of: "<p>", with: "").replacingOccurrences(of: "</p>\n", with: "\n")
            }
            return "<li>\(html.trimmingCharacters(in: .whitespacesAndNewlines))</li>\n"
        }.joined()
        return ("\(opening)\n\(content)\(closing)\n", i)
    }

    private static let task = regex(#"^\[( |x|X)\][ \t]+(.*)$"#)

    private static func listItem(_ body: [String]) -> String {
        var lines = body
        var box = ""
        if let first = lines.first, let parts = groups(task, first) {
            box = "<input type=\"checkbox\" disabled\(parts[1] == " " ? "" : " checked")> "
            lines[0] = parts[2]
        }
        let html = blocks(lines)
        guard !box.isEmpty else { return html }
        return html.hasPrefix("<p>") ? "<p>" + box + html.dropFirst(3) : box + html
    }

    private static func cells(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|"), !content.hasSuffix("\\|") { content.removeLast() }
        var result: [String] = [""]
        var previous: Character = " "
        var inCode = false
        for character in content {
            if character == "`" { inCode.toggle() }
            if character == "|", previous != "\\", !inCode {
                result.append("")
            } else if character == "|", previous == "\\" {
                result[result.count - 1].removeLast()
                result[result.count - 1].append("|")
            } else {
                result[result.count - 1].append(character)
            }
            previous = character
        }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func table(_ lines: [String], from start: Int) -> (String, Int) {
        let aligns = cells(lines[start + 1]).map { cell -> String in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return " style=\"text-align:center\""
            case (false, true): return " style=\"text-align:right\""
            case (true, false): return " style=\"text-align:left\""
            default: return ""
            }
        }
        func row(_ line: String, tag: String) -> String {
            let values = cells(line)
            let columns = aligns.indices.map { index in
                "<\(tag)\(aligns[index])>\(index < values.count ? inline(values[index]) : "")</\(tag)>"
            }
            return "<tr>\(columns.joined())</tr>\n"
        }
        var output = "<div class=\"table-wrapper\"><table>\n<thead>\n\(row(lines[start], tag: "th"))</thead>\n"
        var i = start + 2
        var body = ""
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|"), !startsBlock(lines[i]) {
            body += row(lines[i], tag: "td")
            i += 1
        }
        if !body.isEmpty { output += "<tbody>\n\(body)</tbody>\n" }
        return (output + "</table></div>\n", i)
    }

    // MARK: Inside a line

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let codeSpan = regex(#"(`+)(.+?)\1"#, [.dotMatchesLineSeparators])
    private static let backslash = regex(#"\\([\\`*_{}\[\]()#+\-.!|~<>])"#)
    private static let image = regex(#"!\[([^\]]*)\]\(\s*<?([^\s)>]*)>?(?:\s+"([^"]*)")?\s*\)"#)
    private static let link = regex(#"\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*<?([^\s)>]*)>?(?:\s+"([^"]*)")?\s*\)"#)
    private static let autolink = regex(#"<((?:https?|mailto|ftp):[^\s>]+)>"#)
    private static let rawHTML = regex(#"</?[a-zA-Z][^<>]*>|<!--.*?-->"#, [.dotMatchesLineSeparators])
    private static let bareURL = regex(#"(?<![\w"'=/])https?://[^\s<>]+"#)
    private static let bold = [regex(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, [.dotMatchesLineSeparators]), regex(#"(?<![\p{L}\p{N}])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}])"#, [.dotMatchesLineSeparators])]
    private static let italic = [regex(#"\*(?=[^\s*])(.+?)(?<=[^\s*])\*"#, [.dotMatchesLineSeparators]), regex(#"(?<![\p{L}\p{N}])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\p{L}\p{N}])"#, [.dotMatchesLineSeparators])]
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#, [.dotMatchesLineSeparators])

    private static func safeURL(_ url: String) -> String {
        let lower = url.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text") { return "#" }
        return escape(url)
    }

    /// Finished HTML is put aside behind a placeholder, so later steps can't change what is inside it.
    private static func inline(_ text: String) -> String {
        var stash: [String] = []
        func keep(_ html: String) -> String {
            stash.append(html)
            return "\u{E000}\(stash.count - 1)\u{E001}"
        }
        func replace(_ pattern: NSRegularExpression, in source: String, with build: ([String]) -> String) -> String {
            let ns = source as NSString
            var output = ""
            var position = 0
            for match in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: position, length: match.range.location - position))
                let parts = (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
                output += build(parts)
                position = NSMaxRange(match.range)
            }
            return output + ns.substring(from: position)
        }
        var line = text
        line = replace(codeSpan, in: line) { parts in
            var code = parts[2]
            if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2, code.contains(where: { $0 != " " }) { code = String(code.dropFirst().dropLast()) }
            return keep("<code>\(escape(code))</code>")
        }
        line = replace(backslash, in: line) { keep(escape($0[1])) }
        line = replace(autolink, in: line) { keep("<a href=\"\(safeURL($0[1]))\">\(escape($0[1]))</a>") }
        line = replace(image, in: line) { parts in
            let title = parts[3].isEmpty ? "" : " title=\"\(escape(parts[3]))\""
            return keep("<img src=\"\(safeURL(parts[2]))\" alt=\"\(escape(parts[1]))\"\(title)>")
        }
        line = replace(link, in: line) { parts in
            let title = parts[3].isEmpty ? "" : " title=\"\(escape(parts[3]))\""
            let opening = keep("<a href=\"\(safeURL(parts[2]))\"\(title)>")
            return opening + parts[1] + keep("</a>")
        }
        line = replace(rawHTML, in: line) { keep($0[0]) }
        line = replace(bareURL, in: line) { parts in
            var url = parts[0]
            var tail = ""
            while let last = url.last, ".,;:!?)".contains(last) {
                tail.insert(last, at: tail.startIndex)
                url.removeLast()
            }
            return keep("<a href=\"\(safeURL(url))\">\(escape(url))</a>") + tail
        }
        line = line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for pattern in bold { line = replace(pattern, in: line) { "<strong>\($0[1])</strong>" } }
        for pattern in italic { line = replace(pattern, in: line) { "<em>\($0[1])</em>" } }
        line = replace(strike, in: line) { "<del>\($0[1])</del>" }
        // Stashed pieces can hold others, as a link's text holds code.
        let placeholder = regex("\u{E000}(\\d+)\u{E001}")
        while placeholder.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
            line = replace(placeholder, in: line) { stash[Int($0[1]) ?? 0] }
        }
        return line
    }
}

/// The kinds of file Shift+F7 makes.
public enum NewFileKind: String, CaseIterable {
    case txt, html, md

    /// The name to create: what was typed, with this kind's extension unless it already has one.
    public func fileName(typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return (name as NSString).pathExtension.isEmpty ? "\(name).\(rawValue)" : name
    }

    /// What a new file starts with. `title` comes from the file's name.
    public func content(title: String) -> String {
        switch self {
        case .txt: return ""
        case .md: return "# \(title)\n\n"
        case .html:
            return """
            <!doctype html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>\(Markdown.escape(title))</title>
            </head>
            <body>

            </body>
            </html>

            """
        }
    }
}
