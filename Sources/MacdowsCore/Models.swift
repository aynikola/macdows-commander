import Foundation

public struct FileEntry: Equatable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var date: Date?
    public var permissions: String?
    public var owner: String?
    /// Finder tags, on files of this Mac only.
    public var tags: [FileTag] = []

    public init(name: String, isDirectory: Bool, isSymlink: Bool = false, size: Int64 = 0, date: Date? = nil, permissions: String? = nil, owner: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.date = date
        self.permissions = permissions
        self.owner = owner
    }

    public var isHidden: Bool { name.hasPrefix(".") }
}

/// A Finder tag. `color` is Finder's label number: 0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
public struct FileTag: Equatable {
    public var name: String
    public var color: Int

    public init(name: String, color: Int) {
        self.name = name
        self.color = color
    }

    /// Finder keeps tags in an extended attribute: a property list of "Name\nColor" strings.
    public static let attribute = "com.apple.metadata:_kMDItemUserTags"

    public static func parse(_ data: Data) -> [FileTag] {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.compactMap { item in
            let parts = item.components(separatedBy: "\n")
            guard let name = parts.first, !name.isEmpty else { return nil }
            let color = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return FileTag(name: name, color: (0...7).contains(color) ? color : 0)
        }
    }

    /// Reads the tags of a file without following a link. Most files have none, and then this is one quick call.
    public static func read(path: String) -> [FileTag] {
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0 else { return [] }
        return parse(data.prefix(read))
    }
}

public enum SiteProtocol: String, Codable, CaseIterable {
    case ftp, ftpsExplicit, ftpsImplicit, ssh

    public var defaultPort: Int {
        switch self {
        case .ftp, .ftpsExplicit: return 21
        case .ftpsImplicit: return 990
        case .ssh: return 22
        }
    }

    public var title: String {
        switch self {
        case .ftp: return "FTP"
        case .ftpsExplicit: return "FTPS (explicit)"
        case .ftpsImplicit: return "FTPS (implicit)"
        case .ssh: return "SSH (SFTP/SCP)"
        }
    }

    public var badge: String {
        switch self {
        case .ftp: return "FTP"
        case .ftpsExplicit, .ftpsImplicit: return "FTPS"
        case .ssh: return "SSH"
        }
    }
}

public enum ConnectionMode: String, Codable, CaseIterable {
    case auto, passive, active
}

public enum NameEncoding: String, Codable, CaseIterable {
    case auto, utf8, latin5

    public var stringEncoding: String.Encoding {
        self == .latin5 ? NameEncoding.latin5Encoding : .utf8
    }

    static let latin5Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin5.rawValue)))
}

public struct Site: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var proto: SiteProtocol
    public var host: String
    public var port: Int
    public var user: String
    public var path: String
    public var mode: ConnectionMode
    public var encoding: NameEncoding
    public var parallel: Int
    public var verifyTLS: Bool
    /// SSH: private key on this Mac, such as a .pem file. Optional so servers saved earlier still load.
    public var keyFile: String?
    /// SSH: another saved server to pass through, for machines that only accept certain addresses.
    public var jumpSiteID: UUID?

    public init(id: UUID = UUID(), name: String, proto: SiteProtocol = .ftp, host: String = "", port: Int? = nil, user: String = "", path: String = "/", mode: ConnectionMode = .auto, encoding: NameEncoding = .auto, parallel: Int = 2, verifyTLS: Bool = true, keyFile: String? = nil, jumpSiteID: UUID? = nil) {
        self.id = id
        self.name = name
        self.proto = proto
        self.host = host
        self.port = port ?? proto.defaultPort
        self.user = user
        self.path = path
        self.mode = mode
        self.encoding = encoding
        self.parallel = parallel
        self.verifyTLS = verifyTLS
        self.keyFile = keyFile
        self.jumpSiteID = jumpSiteID
    }
}

public struct MCError: LocalizedError {
    public var message: String
    public var isCancelled: Bool

    public init(_ message: String, isCancelled: Bool = false) {
        self.message = message
        self.isCancelled = isCancelled
    }

    public var errorDescription: String? { message }
}

public enum PathUtil {
    public static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    public static func parent(_ path: String) -> String {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return "/" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    public static func lastComponent(_ path: String) -> String {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

public typealias ProgressHandler = (Int64) -> Bool

/// One side of a transfer. The same operations work on the local disk and on a server.
/// What was typed or pasted into Go to folder, as a plain path. Nil when there is nothing to go to.
public enum GoToPath {
    public static func clean(_ typed: String, home: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Finder's Copy as Pathname is plain, but paths from elsewhere come quoted or as file addresses.
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" { text = String(text.dropFirst().dropLast()) }
        if text.hasPrefix("file://"), let url = URL(string: text) { text = url.path }
        text = text.replacingOccurrences(of: "\\ ", with: " ")
        if text == "~" { return home }
        if text.hasPrefix("~/") { text = home + text.dropFirst(1) }
        guard text.hasPrefix("/") else { return text.isEmpty ? nil : text }
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

public protocol FileSource: AnyObject {
    var isRemote: Bool { get }
    func list(_ path: String) throws -> [FileEntry]
    func makeDirectory(_ path: String) throws
    func removeFile(_ path: String) throws
    func removeEmptyDirectory(_ path: String) throws
    func rename(from: String, to: String) throws
    /// Copies a file from this source to a local URL. `progress` gets bytes done and returns false to cancel.
    func download(_ path: String, to local: URL, progress: @escaping ProgressHandler) throws
    /// Copies a local file onto this source, replacing what is there.
    func upload(_ local: URL, to path: String, progress: @escaping ProgressHandler) throws
}

public extension FileSource {
    /// Removes a file or a whole folder tree.
    func removeTree(_ path: String, isDirectory: Bool) throws {
        guard isDirectory else { try removeFile(path); return }
        for entry in try list(path) {
            let child = PathUtil.join(path, entry.name)
            try removeTree(child, isDirectory: entry.isDirectory && !entry.isSymlink)
        }
        try removeEmptyDirectory(path)
    }
}
