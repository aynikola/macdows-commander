import Foundation

/// Archive types that can be browsed. Detected from the file name.
public enum ArchiveKind: Equatable {
    case tarLike, gzip

    public static func detect(_ name: String) -> ArchiveKind? {
        let lower = name.lowercased()
        let tarLike = [".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz"]
        if tarLike.contains(where: lower.hasSuffix) { return .tarLike }
        return lower.hasSuffix(".gz") && lower != ".gz" ? .gzip : nil
    }
}

/// Formats that can be created.
public enum ArchiveFormat: String, CaseIterable {
    case zip, tar, tarGz, gzip

    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tar: return "tar"
        case .tarGz: return "tar.gz"
        case .gzip: return "gz"
        }
    }

    public var title: String {
        switch self {
        case .zip: return "ZIP (.zip)"
        case .tar: return "TAR (.tar)"
        case .tarGz: return "TAR + GZIP (.tar.gz)"
        case .gzip: return "GZIP (.gz)"
        }
    }

    /// Gzip compresses one file; folders and several files need a tar around them.
    public func supports(_ selection: [FileEntry]) -> Bool {
        self != .gzip || (selection.count == 1 && !selection[0].isDirectory)
    }
}

enum ArchiveTool {
    struct Output {
        var status: Int32
        var text: String
        var error: String
    }

    /// Output goes to files, so a large listing can't fill a pipe and stall the tool. `poll` returning false stops it.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], directory: String? = nil, stdout target: URL? = nil, poll: (() -> Bool)? = nil) throws -> Output {
        let temp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let outURL = target ?? temp.appendingPathComponent("mc-arc-\(id).out")
        let errURL = temp.appendingPathComponent("mc-arc-\(id).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            if target == nil { try? FileManager.default.removeItem(at: outURL) }
            try? FileManager.default.removeItem(at: errURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        // Without this macOS tar adds "._name" files that show up as junk on servers.
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        try process.run()
        var cancelled = false
        while process.isRunning {
            usleep(20_000)
            if let poll, !cancelled, !poll() {
                cancelled = true
                process.terminate()
            }
        }
        process.waitUntilExit()
        if cancelled { throw MCError("Cancelled", isCancelled: true) }
        let text = target == nil ? String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self) : ""
        let error = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Output(status: process.terminationStatus, text: text, error: error)
    }
}

/// Reads one line of `tar -tv`, which looks the same for zip and tar files:
/// -rw-r--r--  0 user group 1234 Nov  4 14:09 folder/file name.txt
enum ArchiveListing {
    struct Item {
        var member: String
        var path: [String]
        var entry: FileEntry
    }

    private static let line = try! NSRegularExpression(pattern: #"^(\S{10})\S?\s+\d+\s+(\S*)\s+(\S*)\s+(\d+)\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.*)$"#)
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func parse(_ text: String, now: Date = Date()) -> [Item] {
        var items: [Item] = []
        text.enumerateLines { row, _ in
            let range = NSRange(row.startIndex..., in: row)
            guard let match = line.firstMatch(in: row, range: range) else { return }
            let part = { (index: Int) in String(row[Range(match.range(at: index), in: row)!]) }
            let permissions = part(1)
            var name = part(8)
            let type = permissions.first
            if type == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if type == "h", let link = name.range(of: " link to ") { name = String(name[..<link.lowerBound]) }
            // Names that climb out of the archive never appear in the listing.
            let components = name.split(separator: "/").map(String.init).filter { $0 != "." }
            guard !components.isEmpty, !components.contains("..") else { return }
            let entry = FileEntry(
                name: components[components.count - 1],
                isDirectory: type == "d" || name.hasSuffix("/"),
                isSymlink: type == "l",
                size: Int64(part(4)) ?? 0,
                date: date(month: part(5), day: part(6), timeOrYear: part(7), now: now),
                permissions: permissions,
                owner: part(2).isEmpty ? nil : part(2)
            )
            items.append(Item(member: name, path: components, entry: entry))
        }
        return items
    }

    /// Recent entries show a time and no year, so the year comes from today's date.
    private static func date(month: String, day: String, timeOrYear: String, now: Date) -> Date? {
        guard let monthIndex = months.firstIndex(of: month), let dayNumber = Int(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var parts = DateComponents(month: monthIndex + 1, day: dayNumber)
        if timeOrYear.contains(":") {
            let time = timeOrYear.split(separator: ":")
            parts.hour = Int(time[0])
            parts.minute = Int(time[1])
            parts.year = calendar.component(.year, from: now)
            if let result = calendar.date(from: parts), result > now.addingTimeInterval(86_400) {
                parts.year = parts.year! - 1
            }
        } else {
            parts.year = Int(timeOrYear)
        }
        return calendar.date(from: parts)
    }
}

/// An archive shown as a read-only folder tree. Reports itself as remote, so viewers and copies
/// fetch files through `download` the same way they do from a server.
public final class ArchiveSource: FileSource {
    public let isRemote = true
    public let file: URL
    private let kind: ArchiveKind
    private let lock = NSLock()
    private var children: [String: [String: FileEntry]]?
    private var members: [String: String] = [:]
    private var singleExtractions = 0
    private var extractedRoot: URL?

    /// Past this many single files, unpacking everything once is faster than reading a compressed tar again per file.
    private static let singleExtractionLimit = 8

    public init(file: URL, kind: ArchiveKind) {
        self.file = file
        self.kind = kind
    }

    deinit {
        if let extractedRoot { try? FileManager.default.removeItem(at: extractedRoot) }
    }

    private func index() throws -> [String: [String: FileEntry]] {
        lock.lock(); defer { lock.unlock() }
        if let children { return children }
        let built = kind == .gzip ? try buildGzipIndex() : try buildTarIndex()
        children = built
        return built
    }

    private func buildTarIndex() throws -> [String: [String: FileEntry]] {
        let output = try ArchiveTool.run("/usr/bin/tar", ["-tvf", file.path])
        guard output.status == 0 else { throw MCError(output.error.isEmpty ? "Cannot read archive" : output.error) }
        var tree: [String: [String: FileEntry]] = ["/": [:]]
        for item in ArchiveListing.parse(output.text) {
            var directory = "/"
            for name in item.path.dropLast() {
                // Many archives never list their folders, only the files inside.
                if tree[directory]?[name] == nil {
                    tree[directory, default: [:]][name] = FileEntry(name: name, isDirectory: true)
                }
                directory = PathUtil.join(directory, name)
                if tree[directory] == nil { tree[directory] = [:] }
            }
            tree[directory, default: [:]][item.entry.name] = item.entry
            let full = PathUtil.join(directory, item.entry.name)
            if item.entry.isDirectory {
                if tree[full] == nil { tree[full] = [:] }
            } else {
                members[full] = item.member
            }
        }
        return tree
    }

    private func buildGzipIndex() throws -> [String: [String: FileEntry]] {
        let name = String(file.lastPathComponent.dropLast(3))
        let output = try ArchiveTool.run("/usr/bin/gzip", ["-l", file.path])
        guard output.status == 0 else { throw MCError(output.error.isEmpty ? "Cannot read archive" : output.error) }
        let numbers = output.text.split(separator: "\n").dropFirst().first?.split(separator: " ") ?? []
        let size = numbers.count > 1 ? Int64(numbers[1]) ?? 0 : 0
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let entry = FileEntry(name: name, isDirectory: false, size: size, date: date)
        members[PathUtil.join("/", name)] = name
        return ["/": [name: entry]]
    }

    public func list(_ path: String) throws -> [FileEntry] {
        guard let found = try index()[path] else { throw MCError("Not in this archive: \(path)") }
        return Array(found.values)
    }

    public func download(_ path: String, to local: URL, progress: @escaping ProgressHandler) throws {
        _ = try index()
        lock.lock()
        let member = members[path]
        singleExtractions += 1
        let extractAll = kind != .gzip && singleExtractions > Self.singleExtractionLimit
        lock.unlock()
        guard let member else { throw MCError("Not in this archive: \(path)") }
        let poll = { progress(0) }
        if extractAll {
            let root = try extractEverything(poll: poll)
            let extracted = root.appendingPathComponent(String(path.dropFirst()))
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.copyItem(at: extracted, to: local)
        } else {
            let arguments = kind == .gzip
                ? ("/usr/bin/gzip", ["-dc", file.path])
                : ("/usr/bin/tar", ["-xOqf", file.path, "--", Self.escapePattern(member)])
            let output = try ArchiveTool.run(arguments.0, arguments.1, stdout: local, poll: poll)
            guard output.status == 0 else { throw MCError(output.error.isEmpty ? "Cannot extract \(path)" : output.error) }
        }
        let size = (try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        _ = progress(Int64(size))
    }

    /// tar treats member names as patterns, so a file called a[1].txt needs escaping.
    static func escapePattern(_ name: String) -> String {
        var result = ""
        for character in name {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private func extractEverything(poll: @escaping () -> Bool) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let extractedRoot { return extractedRoot }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mc-arc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Without -P, tar refuses absolute paths, ".." and writing through symlinks.
        let output = try ArchiveTool.run("/usr/bin/tar", ["-xf", file.path, "-C", root.path], poll: poll)
        guard output.status == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw MCError(output.error.isEmpty ? "Cannot extract archive" : output.error)
        }
        extractedRoot = root
        return root
    }

    private func readOnly() -> MCError { MCError("Archives are read-only") }
    public func makeDirectory(_ path: String) throws { throw readOnly() }
    public func removeFile(_ path: String) throws { throw readOnly() }
    public func removeEmptyDirectory(_ path: String) throws { throw readOnly() }
    public func rename(from: String, to: String) throws { throw readOnly() }
    public func upload(_ local: URL, to path: String, progress: @escaping ProgressHandler) throws { throw readOnly() }
}

public enum ArchiveCreator {
    /// Compresses `names` from `directory` into `output`.
    public static func create(format: ArchiveFormat, names: [String], in directory: String, output: URL, isCancelled: @escaping () -> Bool) throws {
        let poll = { !isCancelled() }
        // "./" keeps names that start with "-" or "@" from being read as options.
        let inputs = names.map { "./" + $0 }
        let result: ArchiveTool.Output
        switch format {
        case .zip:
            result = try ArchiveTool.run("/usr/bin/zip", ["-r", "-y", "-q", output.path] + inputs, directory: directory, poll: poll)
        case .tar:
            result = try ArchiveTool.run("/usr/bin/tar", ["-cf", output.path, "--no-mac-metadata", "--"] + inputs, directory: directory, poll: poll)
        case .tarGz:
            result = try ArchiveTool.run("/usr/bin/tar", ["-czf", output.path, "--no-mac-metadata", "--"] + inputs, directory: directory, poll: poll)
        case .gzip:
            guard inputs.count == 1 else { throw MCError("Gzip takes one file") }
            result = try ArchiveTool.run("/usr/bin/gzip", ["-c", inputs[0]], directory: directory, stdout: output, poll: poll)
        }
        if result.status != 0 {
            try? FileManager.default.removeItem(at: output)
            throw MCError(result.error.isEmpty ? "Compression failed" : result.error)
        }
    }

    /// Compresses a selection from any source. Files on a server are fetched into `workFolder` first.
    /// Returns the archive, which stays inside `workFolder`.
    public static func pack(selection: [FileEntry], from source: FileSource, directory: String, format: ArchiveFormat, name: String, workFolder: URL, isCancelled: @escaping () -> Bool) throws -> URL {
        let outputFolder = workFolder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        var inputFolder = directory
        if source.isRemote {
            let stage = workFolder.appendingPathComponent("stage")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let plan = try TransferPlanner.plan(selection: selection, from: source, sourceDirectory: directory, to: LocalSource(), destinationDirectory: stage.path)
            for folder in plan.directoriesToCreate { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            for file in plan.files {
                if isCancelled() { throw MCError("Cancelled", isCancelled: true) }
                try source.download(file.source, to: URL(fileURLWithPath: file.destination)) { _ in !isCancelled() }
            }
            inputFolder = stage.path
        }
        let output = outputFolder.appendingPathComponent(name)
        try create(format: format, names: selection.map(\.name), in: inputFolder, output: output, isCancelled: isCancelled)
        return output
    }
}
