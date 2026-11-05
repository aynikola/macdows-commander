import Foundation
import CCurlShim

/// FTP and FTPS through the libcurl that ships with macOS.
public final class FTPClient: FileSource {
    public let isRemote = true
    private let site: Site
    private let password: String
    private let lock = NSLock()
    private var idleHandles: [UnsafeMutableRawPointer] = []
    private var effectiveMode: ConnectionMode
    private var detectedEncoding: String.Encoding

    private static let globalInit: Void = { curl_global_init(Int(CURL_GLOBAL_ALL)) }()

    public init(site: Site, password: String) {
        _ = FTPClient.globalInit
        self.site = site
        self.password = password
        self.effectiveMode = site.mode
        self.detectedEncoding = site.encoding.stringEncoding
    }

    deinit {
        idleHandles.forEach { curl_easy_cleanup($0) }
    }

    /// The mode that actually worked, for showing in the UI.
    public var currentMode: ConnectionMode {
        lock.lock(); defer { lock.unlock() }
        return effectiveMode
    }

    // MARK: Paths

    private var encoding: String.Encoding {
        lock.lock(); defer { lock.unlock() }
        return detectedEncoding
    }

    private func bytes(_ text: String) -> Data {
        text.data(using: encoding, allowLossyConversion: true) ?? Data(text.utf8)
    }

    func url(for path: String) -> String {
        let scheme = site.proto == .ftpsImplicit ? "ftps" : "ftp"
        var encoded = ""
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/".utf8)
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        for byte in bytes(trimmed) {
            if unreserved.contains(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        // %2F makes the path absolute instead of relative to the login folder.
        return "\(scheme)://\(site.host):\(site.port)/%2F\(encoded)"
    }

    private func decode(_ data: Data) -> String {
        if site.encoding == .latin5 { return String(data: data, encoding: NameEncoding.latin5Encoding) ?? "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Auto: the server is not sending UTF-8, so names are most likely in the Turkish legacy encoding.
        if site.encoding == .auto {
            lock.lock()
            detectedEncoding = NameEncoding.latin5Encoding
            lock.unlock()
            return String(data: data, encoding: NameEncoding.latin5Encoding) ?? ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Handles

    private func borrowHandle() throws -> UnsafeMutableRawPointer {
        lock.lock()
        let handle = idleHandles.popLast()
        lock.unlock()
        if let handle { return handle }
        guard let fresh = curl_easy_init() else { throw MCError("Could not start libcurl") }
        return fresh
    }

    private func returnHandle(_ handle: UnsafeMutableRawPointer) {
        lock.lock()
        idleHandles.append(handle)
        lock.unlock()
    }

    private func configure(_ handle: UnsafeMutableRawPointer, url: String, mode: ConnectionMode, errorBuffer: UnsafeMutablePointer<CChar>) {
        // curl_easy_reset keeps open connections, so the login is reused between operations.
        curl_easy_reset(handle)
        mc_set_pointer(handle, CURLOPT_ERRORBUFFER, errorBuffer)
        mc_set_string(handle, CURLOPT_URL, url)
        mc_set_string(handle, CURLOPT_USERNAME, site.user.isEmpty ? "anonymous" : site.user)
        mc_set_string(handle, CURLOPT_PASSWORD, password)
        mc_set_long(handle, CURLOPT_NOSIGNAL, 1)
        mc_set_long(handle, CURLOPT_CONNECTTIMEOUT, 20)
        mc_set_long(handle, CURLOPT_SERVER_RESPONSE_TIMEOUT, 30)
        mc_set_long(handle, CURLOPT_ACCEPTTIMEOUT_MS, 15000)
        // A connection that moves nothing for 45 seconds has stalled.
        mc_set_long(handle, CURLOPT_LOW_SPEED_LIMIT, 1)
        mc_set_long(handle, CURLOPT_LOW_SPEED_TIME, 45)
        mc_set_long(handle, CURLOPT_TCP_KEEPALIVE, 1)
        // Routers often make servers announce a private address in passive mode: use the address we already reached.
        mc_set_long(handle, CURLOPT_FTP_SKIP_PASV_IP, 1)
        if mode == .active { mc_set_string(handle, CURLOPT_FTPPORT, "-") }
        if site.proto != .ftp {
            mc_set_long(handle, CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue))
            mc_set_long(handle, CURLOPT_SSL_VERIFYPEER, site.verifyTLS ? 1 : 0)
            mc_set_long(handle, CURLOPT_SSL_VERIFYHOST, site.verifyTLS ? 2 : 0)
        }
    }

    /// Runs one libcurl operation. In auto mode a failed data connection is retried once in the other mode.
    private func perform(url: String, setup: (UnsafeMutableRawPointer) throws -> Void) throws {
        let handle = try borrowHandle()
        defer { returnHandle(handle) }
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(CURL_ERROR_SIZE))
        defer { errorBuffer.deallocate() }

        lock.lock()
        let firstMode: ConnectionMode = effectiveMode == .auto ? .passive : effectiveMode
        let canFallBack = site.mode == .auto
        lock.unlock()

        var mode = firstMode
        var attempt = 0
        while true {
            errorBuffer.pointee = 0
            configure(handle, url: url, mode: mode, errorBuffer: errorBuffer)
            try setup(handle)
            let code = curl_easy_perform(handle)
            if code == CURLE_OK {
                if canFallBack {
                    lock.lock(); effectiveMode = mode; lock.unlock()
                }
                return
            }
            if code == CURLE_ABORTED_BY_CALLBACK { throw MCError("Cancelled", isCancelled: true) }
            attempt += 1
            if canFallBack, attempt == 1, FTPClient.isDataConnectionFailure(code) {
                mode = mode == .passive ? .active : .passive
                continue
            }
            let detail = String(cString: errorBuffer)
            throw MCError(detail.isEmpty ? String(cString: curl_easy_strerror(code)) : detail)
        }
    }

    private static func isDataConnectionFailure(_ code: CURLcode) -> Bool {
        [CURLE_FTP_WEIRD_PASV_REPLY, CURLE_FTP_WEIRD_227_FORMAT, CURLE_FTP_CANT_GET_HOST,
         CURLE_FTP_PORT_FAILED, CURLE_FTP_ACCEPT_FAILED, CURLE_FTP_ACCEPT_TIMEOUT,
         CURLE_OPERATION_TIMEDOUT, CURLE_COULDNT_CONNECT].contains(code)
    }

    // MARK: Callback contexts

    private final class WriteContext {
        var data = Data()
        var file: UnsafeMutablePointer<FILE>?
    }

    private final class ProgressContext {
        let handler: ProgressHandler
        init(_ handler: @escaping ProgressHandler) { self.handler = handler }
    }

    private static let writeCallback: mc_data_cb = { buffer, size, count, user in
        let context = Unmanaged<WriteContext>.fromOpaque(user!).takeUnretainedValue()
        let total = size * count
        if let file = context.file { return fwrite(buffer, size, count, file) * size }
        context.data.append(UnsafeBufferPointer(start: UnsafePointer(OpaquePointer(buffer)), count: total) as UnsafeBufferPointer<UInt8>)
        return total
    }

    private static let readCallback: mc_data_cb = { buffer, size, count, user in
        fread(buffer, size, count, user!.assumingMemoryBound(to: FILE.self)) * size
    }

    private static let downloadProgress: mc_progress_cb = { user, _, now, _, _ in
        Unmanaged<ProgressContext>.fromOpaque(user!).takeUnretainedValue().handler(Int64(now)) ? 0 : 1
    }

    private static let uploadProgress: mc_progress_cb = { user, _, _, _, now in
        Unmanaged<ProgressContext>.fromOpaque(user!).takeUnretainedValue().handler(Int64(now)) ? 0 : 1
    }

    // MARK: FileSource

    public func list(_ path: String) throws -> [FileEntry] {
        let directoryURL = url(for: path.hasSuffix("/") ? path : path + "/")
        // Many servers hide dot files unless they get -a. Servers that dislike the flag fall back to plain LIST.
        if let withHidden = try? fetchListing(url: directoryURL, command: "LIST -a"), !withHidden.isEmpty {
            return withHidden
        }
        return try fetchListing(url: directoryURL, command: nil)
    }

    private func fetchListing(url: String, command: String?) throws -> [FileEntry] {
        let context = WriteContext()
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        try perform(url: url) { handle in
            context.data = Data()
            mc_set_write(handle, FTPClient.writeCallback, unmanaged.toOpaque())
            if let command { mc_set_string(handle, CURLOPT_CUSTOMREQUEST, command) }
        }
        return ListingParser.parse(decode(context.data))
    }

    public func download(_ path: String, to local: URL, progress: @escaping ProgressHandler) throws {
        let context = WriteContext()
        let unmanaged = Unmanaged.passRetained(context)
        let progressContext = Unmanaged.passRetained(ProgressContext(progress))
        defer { unmanaged.release(); progressContext.release() }
        defer { if let file = context.file { fclose(file) } }
        try perform(url: url(for: path)) { handle in
            if let file = context.file { fclose(file); context.file = nil }
            guard let file = fopen(local.path, "wb") else { throw MCError("Cannot write \(local.path)") }
            context.file = file
            mc_set_write(handle, FTPClient.writeCallback, unmanaged.toOpaque())
            mc_set_progress(handle, FTPClient.downloadProgress, progressContext.toOpaque())
        }
    }

    public func upload(_ local: URL, to path: String, progress: @escaping ProgressHandler) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var file: UnsafeMutablePointer<FILE>?
        let progressContext = Unmanaged.passRetained(ProgressContext(progress))
        defer { progressContext.release() }
        defer { if let file { fclose(file) } }
        try perform(url: url(for: path)) { handle in
            if let open = file { fclose(open); file = nil }
            guard let opened = fopen(local.path, "rb") else { throw MCError("Cannot read \(local.path)") }
            file = opened
            mc_set_long(handle, CURLOPT_UPLOAD, 1)
            mc_set_offset(handle, CURLOPT_INFILESIZE_LARGE, curl_off_t(size))
            mc_set_read(handle, FTPClient.readCallback, opened)
            mc_set_progress(handle, FTPClient.uploadProgress, progressContext.toOpaque())
        }
    }

    private func command(_ lines: [String]) throws {
        var list: UnsafeMutablePointer<curl_slist>?
        for line in lines {
            var data = bytes(line)
            data.append(0)
            list = data.withUnsafeBytes { curl_slist_append(list, $0.bindMemory(to: CChar.self).baseAddress) }
        }
        defer { curl_slist_free_all(list) }
        try perform(url: url(for: "/")) { handle in
            mc_set_long(handle, CURLOPT_NOBODY, 1)
            mc_set_pointer(handle, CURLOPT_QUOTE, list)
        }
    }

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }

    public func makeDirectory(_ path: String) throws { try command(["MKD \(absolute(path))"]) }
    public func removeFile(_ path: String) throws { try command(["DELE \(absolute(path))"]) }
    public func removeEmptyDirectory(_ path: String) throws { try command(["RMD \(absolute(path))"]) }
    public func rename(from: String, to: String) throws { try command(["RNFR \(absolute(from))", "RNTO \(absolute(to))"]) }
}
