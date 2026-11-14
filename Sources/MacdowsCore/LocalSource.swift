import Foundation

public final class LocalSource: FileSource {
    public let isRemote = false
    private var ownerCache: [uid_t: String] = [:]

    public init() {}

    public func list(_ path: String) throws -> [FileEntry] {
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        return names.compactMap { entry(name: $0, directory: path) }
    }

    private func entry(name: String, directory: String) -> FileEntry? {
        let full = PathUtil.join(directory, name)
        var link = stat()
        guard lstat(full, &link) == 0 else { return nil }
        let isLink = (link.st_mode & S_IFMT) == S_IFLNK
        var info = link
        if isLink, stat(full, &info) != 0 { info = link }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        var result = FileEntry(
            name: name,
            isDirectory: isDirectory,
            isSymlink: isLink,
            size: isDirectory ? 0 : Int64(info.st_size),
            date: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
            permissions: LocalSource.permissionString(link.st_mode),
            owner: ownerName(link.st_uid)
        )
        result.tags = FileTag.read(path: full)
        return result
    }

    private func ownerName(_ uid: uid_t) -> String {
        if let known = ownerCache[uid] { return known }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        ownerCache[uid] = name
        return name
    }

    static func permissionString(_ mode: mode_t) -> String {
        let type: Character
        switch mode & S_IFMT {
        case S_IFDIR: type = "d"
        case S_IFLNK: type = "l"
        default: type = "-"
        }
        var text = String(type)
        let flags: [(mode_t, Character)] = [
            (S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"),
            (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"),
            (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x"),
        ]
        for (flag, letter) in flags { text.append(mode & flag != 0 ? letter : "-") }
        return text
    }

    public func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    public func removeFile(_ path: String) throws { try FileManager.default.removeItem(atPath: path) }

    public func removeEmptyDirectory(_ path: String) throws {
        if rmdir(path) != 0 { throw MCError(String(cString: strerror(errno))) }
    }

    public func rename(from: String, to: String) throws {
        if Darwin.rename(from, to) != 0 { throw MCError(String(cString: strerror(errno))) }
    }

    /// F8 on the local disk goes to the Trash so it can be undone.
    public func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    private func copyBytes(from source: String, to destination: String, progress: ProgressHandler) throws {
        guard let input = fopen(source, "rb") else { throw MCError("Cannot read \(source)") }
        defer { fclose(input) }
        guard let output = fopen(destination, "wb") else { throw MCError("Cannot write \(destination)") }
        defer { fclose(output) }
        let capacity = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        while true {
            let count = fread(buffer, 1, capacity, input)
            if count == 0 { break }
            if fwrite(buffer, 1, count, output) != count { throw MCError("Cannot write \(destination)") }
            total += Int64(count)
            if !progress(total) { throw MCError("Cancelled", isCancelled: true) }
        }
        if ferror(input) != 0 { throw MCError("Cannot read \(source)") }
    }

    public func download(_ path: String, to local: URL, progress: @escaping ProgressHandler) throws {
        try copyBytes(from: path, to: local.path, progress: progress)
    }

    public func upload(_ local: URL, to path: String, progress: @escaping ProgressHandler) throws {
        try copyBytes(from: local.path, to: path, progress: progress)
    }
}
