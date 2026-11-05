import Foundation

public struct SearchOptions {
    /// Empty matches every file. "*.php;*.html" lists patterns; a word without wildcards matches inside the name.
    public var namePattern: String
    /// Empty searches by name only.
    public var content: String
    public var caseSensitive: Bool
    public var includeHidden: Bool
    /// Over this size a file on a server is not fetched for a content search.
    public var remoteContentLimit: Int64

    public init(namePattern: String = "", content: String = "", caseSensitive: Bool = false, includeHidden: Bool = true, remoteContentLimit: Int64 = 20 * 1024 * 1024) {
        self.namePattern = namePattern
        self.content = content
        self.caseSensitive = caseSensitive
        self.includeHidden = includeHidden
        self.remoteContentLimit = remoteContentLimit
    }
}

public struct SearchHit {
    public var directory: String
    public var entry: FileEntry
    public var line: Int?
    public var snippet: String?
    public var path: String { PathUtil.join(directory, entry.name) }
}

public struct SearchSummary {
    public var folders = 0
    public var files = 0
    public var hits = 0
    public var skippedBinary = 0
    public var skippedLarge = 0
    public var unreadable = 0
    public var cancelled = false
    public init() {}
}

/// Matches file names against the pattern list.
struct NameMatcher {
    private let patterns: [String]
    private let caseSensitive: Bool

    init(_ text: String, caseSensitive: Bool) {
        self.caseSensitive = caseSensitive
        patterns = text.split(whereSeparator: { ";,".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { pattern in
                let wrapped = pattern.contains(where: { "*?[".contains($0) }) ? pattern : "*\(pattern)*"
                return Self.fold(wrapped, caseSensitive: caseSensitive)
            }
    }

    private static func fold(_ text: String, caseSensitive: Bool) -> String {
        // macOS stores "ö" in two parts, a keyboard types it in one.
        let composed = text.precomposedStringWithCanonicalMapping
        return caseSensitive ? composed : ContentMatcher.foldTurkish(composed)
    }

    func matches(_ name: String) -> Bool {
        guard !patterns.isEmpty else { return true }
        let candidate = Self.fold(name, caseSensitive: caseSensitive)
        return patterns.contains { fnmatch($0, candidate, 0) == 0 }
    }
}

/// Byte search that finds the text in UTF-8 and in the old Turkish encoding, which many server files still use.
public struct ContentMatcher {
    public struct Match: Equatable {
        public var line: Int
        public var snippet: String
    }

    /// One pattern per encoding; each position lists the byte sequences accepted there.
    private let patterns: [[[[UInt8]]]]
    private static let latin5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin5.rawValue)))

    static func foldTurkish(_ text: String) -> String {
        text.replacingOccurrences(of: "İ", with: "i").replacingOccurrences(of: "I", with: "i").replacingOccurrences(of: "ı", with: "i").lowercased()
    }

    public init(_ text: String, caseSensitive: Bool) {
        let composed = text.precomposedStringWithCanonicalMapping
        var built: [[[[UInt8]]]] = []
        for encoding in [String.Encoding.utf8, Self.latin5] {
            var pattern: [[[UInt8]]] = []
            var usable = true
            for character in composed {
                var forms: [String] = [String(character)]
                if !caseSensitive {
                    if "iIıİ".contains(character) {
                        forms = ["i", "I", "ı", "İ"]
                    } else {
                        forms += [String(character).lowercased(), String(character).uppercased()]
                    }
                }
                let bytes = Set(forms.compactMap { $0.data(using: encoding).map { [UInt8]($0) } })
                if bytes.isEmpty { usable = false; break }
                pattern.append(Array(bytes))
            }
            if usable && !pattern.isEmpty && !built.contains(pattern) { built.append(pattern) }
        }
        patterns = built
    }

    /// Finds the first match. Returns nil when there is none.
    public func firstMatch(in data: Data) -> Match? {
        var earliest: Int?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            for pattern in patterns {
                if let found = Self.search(bytes, pattern, limit: earliest ?? bytes.count), found < (earliest ?? Int.max) {
                    earliest = found
                }
            }
        }
        guard let earliest else { return nil }
        return Self.describe(data, at: earliest)
    }

    private static func search(_ bytes: UnsafeBufferPointer<UInt8>, _ pattern: [[[UInt8]]], limit: Int) -> Int? {
        guard let first = pattern.first else { return nil }
        var starts = [Bool](repeating: false, count: 256)
        for form in first { starts[Int(form[0])] = true }
        var position = 0
        while position < limit && position < bytes.count {
            if starts[Int(bytes[position])], matches(bytes, pattern, at: position) { return position }
            position += 1
        }
        return nil
    }

    private static func matches(_ bytes: UnsafeBufferPointer<UInt8>, _ pattern: [[[UInt8]]], at start: Int) -> Bool {
        var position = start
        for forms in pattern {
            var advanced = false
            for form in forms where position + form.count <= bytes.count {
                if form.indices.allSatisfy({ bytes[position + $0] == form[$0] }) {
                    position += form.count
                    advanced = true
                    break
                }
            }
            if !advanced { return false }
        }
        return true
    }

    private static func describe(_ data: Data, at offset: Int) -> Match {
        let newline = UInt8(ascii: "\n")
        let head = data.startIndex + offset
        let line = 1 + data[data.startIndex..<head].reduce(0) { $0 + ($1 == newline ? 1 : 0) }
        let start = data[data.startIndex..<head].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
        let end = data[head...].firstIndex(of: newline) ?? data.endIndex
        let slice = Data(data[start..<min(end, start + 400)])
        let text = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: latin5) ?? ""
        return Match(line: line, snippet: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
    }
}

public enum FileSearcher {
    /// Walks `root` on any source. Calls `onHit` as files are found and `onFolder` as it enters a folder.
    @discardableResult
    public static func run(source: FileSource, root: String, options: SearchOptions, isCancelled: @escaping () -> Bool, onFolder: (String) -> Void = { _ in }, onHit: (SearchHit) -> Void) -> SearchSummary {
        var summary = SearchSummary()
        let names = NameMatcher(options.namePattern, caseSensitive: options.caseSensitive)
        let content = options.content.isEmpty ? nil : ContentMatcher(options.content, caseSensitive: options.caseSensitive)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mc-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }

        var pending = [root]
        while let directory = pending.popLast() {
            if isCancelled() { summary.cancelled = true; break }
            onFolder(directory)
            guard let entries = try? source.list(directory) else {
                summary.unreadable += 1
                continue
            }
            summary.folders += 1
            let ordered = entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for entry in ordered {
                if isCancelled() { summary.cancelled = true; break }
                if !options.includeHidden && entry.isHidden { continue }
                if entry.isDirectory {
                    // Links are not followed: they can loop, or lead out of the folder being searched.
                    if !entry.isSymlink { pending.append(PathUtil.join(directory, entry.name)) }
                    // Without a content search, folders can match by name too.
                    if content == nil, !options.namePattern.isEmpty, names.matches(entry.name) {
                        summary.hits += 1
                        onHit(SearchHit(directory: directory, entry: entry, line: nil, snippet: nil))
                    }
                    continue
                }
                guard names.matches(entry.name) else { continue }
                summary.files += 1
                guard let content else {
                    summary.hits += 1
                    onHit(SearchHit(directory: directory, entry: entry, line: nil, snippet: nil))
                    continue
                }
                if entry.isSymlink { continue }
                let path = PathUtil.join(directory, entry.name)
                if source.isRemote && entry.size > options.remoteContentLimit {
                    summary.skippedLarge += 1
                    continue
                }
                guard let data = read(path, source: source, work: work, isCancelled: isCancelled) else {
                    summary.unreadable += 1
                    continue
                }
                if data.prefix(8192).contains(0) {
                    summary.skippedBinary += 1
                    continue
                }
                if let match = content.firstMatch(in: data) {
                    summary.hits += 1
                    onHit(SearchHit(directory: directory, entry: entry, line: match.line, snippet: match.snippet))
                }
            }
        }
        return summary
    }

    private static func read(_ path: String, source: FileSource, work: URL, isCancelled: @escaping () -> Bool) -> Data? {
        guard source.isRemote else {
            return try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        }
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let local = work.appendingPathComponent("file")
        defer { try? FileManager.default.removeItem(at: local) }
        guard (try? source.download(path, to: local, progress: { _ in !isCancelled() })) != nil else { return nil }
        return try? Data(contentsOf: local)
    }
}
