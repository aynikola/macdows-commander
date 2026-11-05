import Foundation
import JavaScriptCore

public struct SyntaxIssue: Equatable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

public struct SyntaxReport: Equatable {
    public var issues: [SyntaxIssue] = []
    /// False for languages with no checker, where the editor shows no verdict at all.
    public var didCheck = false
    public var phpMissing = false
    /// Script blocks with PHP inside: what PHP prints into them is unknown, so they would give false alarms.
    public var skippedScripts = 0

    public init() {}
}

/// Parses code without ever running it: JavaScriptCore's syntax check and `php -l`.
public enum SyntaxChecker {
    public static func canCheck(_ language: CodeLanguage) -> Bool {
        language == .php || language == .javascript || language == .html
    }

    public static func check(_ text: String, language: CodeLanguage, fileName: String) -> SyntaxReport {
        var report = SyntaxReport()
        guard canCheck(language) else { return report }
        report.didCheck = true
        if language == .javascript {
            let module = (fileName as NSString).pathExtension.lowercased() == "mjs"
            if let issue = javaScriptIssue(text, startLine: 1, isModule: module) { report.issues.append(issue) }
            return report
        }
        if language == .php {
            if let php = phpExecutable {
                if let issue = phpIssue(text, executable: php) { report.issues.append(issue) }
            } else {
                report.phpMissing = true
            }
        }
        let units = text.utf16
        for script in SyntaxHighlighter.analyze(text, language: language).scripts {
            if script.containsPHP {
                report.skippedScripts += 1
                continue
            }
            let lower = units.index(units.startIndex, offsetBy: script.range.location)
            let upper = units.index(lower, offsetBy: script.range.length)
            let code = String(text[lower..<upper])
            let line = lineNumber(of: script.range.location, in: units)
            if let issue = javaScriptIssue(code, startLine: line, isModule: script.isModule) { report.issues.append(issue) }
        }
        report.issues.sort { $0.line < $1.line }
        return report
    }

    private static func lineNumber(of offset: Int, in units: String.UTF16View) -> Int {
        var line = 1
        var previous: UInt16 = 0
        for c in units.prefix(offset) {
            if c == 10, previous != 13 { line += 1 } else if c == 13 { line += 1 }
            previous = c
        }
        return line
    }

    // MARK: JavaScript

    public static func javaScriptIssue(_ code: String, startLine: Int, isModule: Bool) -> SyntaxIssue? {
        var prepared = code
        if prepared.hasPrefix("#!") { prepared = "//" + prepared.dropFirst(2) }
        if isModule || looksLikeModule(prepared) { prepared = moduleAsScript(prepared) }
        guard let context = JSContext() else { return nil }
        let script = JSStringCreateWithCFString(prepared as CFString)
        defer { JSStringRelease(script) }
        var exception: JSValueRef?
        if JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, Int32(startLine), &exception) { return nil }
        guard let exception, let value = JSValue(jsValueRef: exception, in: context) else {
            return SyntaxIssue(line: startLine, message: "Syntax error")
        }
        let line = value.objectForKeyedSubscript("line")?.toInt32() ?? Int32(startLine)
        let message = value.objectForKeyedSubscript("message")?.toString() ?? "Syntax error"
        return SyntaxIssue(line: Int(line), message: message)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed text, so a failure here is a programming mistake.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let moduleMarker = regex(#"^[ \t]*(import[\s{*'"]|export[\s{*])"#)
    private static let moduleBlanks = [
        regex(#"^[ \t]*import\s+[^'";]*?\bfrom\s*['"][^'"\n]*['"][^;\n]*;?"#),
        regex(#"^[ \t]*import\s*['"][^'"\n]*['"][ \t]*;?"#),
        regex(#"^[ \t]*export\s*\*[^;\n]*;?"#),
        regex(#"^[ \t]*export\s*\{[^}]*\}[^;\n]*;?"#),
        regex(#"\bexport\s+(?=(const|let|var|function|class|async)\b)"#),
    ]
    private static let exportDefault = regex(#"\bexport\s+default\b"#)
    private static let importMeta = regex(#"\bimport\.meta\b"#)

    private static func looksLikeModule(_ code: String) -> Bool {
        moduleMarker.firstMatch(in: code, range: NSRange(location: 0, length: (code as NSString).length)) != nil
    }

    /// JavaScriptCore's syntax check only knows plain scripts. Removing the module-only syntax keeps
    /// every line where it was, and the wrapper allows top-level await.
    private static func moduleAsScript(_ code: String) -> String {
        let text = NSMutableString(string: code)
        for pattern in moduleBlanks {
            for match in pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)).reversed() {
                let newlines = text.substring(with: match.range).filter(\.isNewline).count
                text.replaceCharacters(in: match.range, with: String(repeating: "\n", count: newlines))
            }
        }
        exportDefault.replaceMatches(in: text, range: NSRange(location: 0, length: text.length), withTemplate: "void")
        importMeta.replaceMatches(in: text, range: NSRange(location: 0, length: text.length), withTemplate: "globalThis")
        return "(async function(){" + (text as String) + "\n})"
    }

    // MARK: PHP

    /// macOS ships no PHP, so this looks where web developers keep it. MAMP's newest version comes first.
    public static let phpExecutable: String? = {
        let manager = FileManager.default
        let mamp = "/Applications/MAMP/bin/php"
        let versions = ((try? manager.contentsOfDirectory(atPath: mamp)) ?? []).compactMap { folder -> (version: [Int], path: String)? in
            guard folder.lowercased().contains("php"), let range = folder.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
            return (folder[range].split(separator: ".").compactMap { Int($0) }, "\(mamp)/\(folder)/bin/php")
        }
        let sorted = versions.sorted { $0.version.lexicographicallyPrecedes($1.version) }.reversed().map(\.path)
        return (sorted + ["/opt/homebrew/bin/php", "/usr/local/bin/php", "/usr/bin/php"]).first { manager.isExecutableFile(atPath: $0) }
    }()

    private static let phpError = try! NSRegularExpression(pattern: #"(?:Parse|Fatal) error:\s*(.*?) in .*? on line (\d+)"#)

    public static func phpIssue(_ text: String, executable: String) -> SyntaxIssue? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macdows-lint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("code.php")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        } catch {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // -l only parses. -n skips php.ini, whose settings could hide the message or print unrelated warnings.
        process.arguments = ["-n", "-d", "display_errors=1", "-d", "log_errors=0", "-d", "error_reporting=E_ALL", "-l", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let output = String(decoding: data, as: UTF8.self)
        let nsOutput = output as NSString
        guard let match = phpError.firstMatch(in: output, range: NSRange(location: 0, length: nsOutput.length)),
              let line = Int(nsOutput.substring(with: match.range(at: 2))) else { return nil }
        return SyntaxIssue(line: line, message: nsOutput.substring(with: match.range(at: 1)))
    }
}
