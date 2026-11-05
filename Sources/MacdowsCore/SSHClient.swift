import Foundation

/// SSH machines without an FTP server. Uses the ssh, sftp and scp tools that ship with macOS:
/// SFTP when the server offers it, otherwise shell commands plus the legacy SCP protocol.
public final class SSHClient: FileSource {
    public enum Transport { case sftp, scp }

    public let isRemote = true
    private let site: Site
    private let password: String
    private let identityFile: String?
    private let lock = NSLock()
    private var detected: Transport?
    private let controlDir: String
    private let askpassPath: String?

    private let knownHostsFile: String?

    /// A server to pass through. It has its own login, which may differ from the target's.
    public struct Hop {
        public let site: Site
        public let password: String

        public init(site: Site, password: String) {
            self.site = site
            self.password = password
        }
    }

    private let hops: [Hop]

    public init(site: Site, password: String, identityFile: String? = nil, knownHostsFile: String? = nil, hops: [Hop] = []) {
        self.site = site
        self.password = password
        self.identityFile = identityFile ?? site.keyFile.flatMap(Self.usableKeyPath)
        self.knownHostsFile = knownHostsFile
        self.hops = hops
        // Socket paths are limited to about 100 characters, so this stays short and outside the app container.
        controlDir = "/tmp/mc-ssh-\(getuid())"
        try? FileManager.default.createDirectory(atPath: controlDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if password.isEmpty, hops.allSatisfy({ $0.password.isEmpty }) {
            // Nothing saved: in a terminal ssh asks by itself.
            askpassPath = nil
        } else {
            // The helper only reads environment variables: passwords are never written to disk.
            let path = NSTemporaryDirectory() + "mc-askpass-\(UUID().uuidString).sh"
            FileManager.default.createFile(atPath: path, contents: Data(Self.askpassScript.utf8), attributes: [.posixPermissions: 0o700])
            askpassPath = path
        }
    }

    /// Answers each prompt with the password of the server it names, and the target's when it names none.
    static let askpassScript = """
    #!/bin/sh
    i=0
    while :; do
      eval "wanted=\\${MC_SSH_MATCH_$i-}"
      [ -z "$wanted" ] && break
      case "$1" in
        *"$wanted"*) eval "printf '%s\\n' \\"\\$MC_SSH_PASS_$i\\""; exit 0 ;;
      esac
      i=$((i + 1))
    done
    printf '%s\\n' "$MC_SSH_PASSWORD"

    """

    /// ssh names the server in its prompts: `user@host's password:`, `(user@host) Password:`
    /// and, for a locked key, `Enter passphrase for key '/path':`.
    var passwordEnvironment: [String: String] {
        guard let askpassPath else { return [:] }
        var environment = ["SSH_ASKPASS": askpassPath, "SSH_ASKPASS_REQUIRE": "force", "MC_SSH_PASSWORD": password]
        var index = 0
        for hop in hops where !hop.password.isEmpty {
            let name = hop.site.user.isEmpty ? "@\(hop.site.host)" : "\(hop.site.user)@\(hop.site.host)"
            var patterns = ["\(name)'", "\(name))"]
            if let key = hop.site.keyFile.flatMap(Self.usableKeyPath) { patterns.append("key '\(key)'") }
            for pattern in patterns {
                environment["MC_SSH_MATCH_\(index)"] = pattern
                environment["MC_SSH_PASS_\(index)"] = hop.password
                index += 1
            }
        }
        return environment
    }

    /// Expands `~`, and fixes permissions: ssh refuses a key others can read, which is how downloaded .pem files arrive.
    static func usableKeyPath(_ path: String) -> String? {
        let expanded = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        if let mode = (try? FileManager.default.attributesOfItem(atPath: expanded))?[.posixPermissions] as? Int, mode & 0o077 != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expanded)
        }
        return expanded
    }

    /// `ssh -W` through each hop, nearest to the target first in `hops`. ProxyJump can't do this,
    /// because it can't give a hop its own key file. `batch` makes a hop fail instead of waiting for an answer.
    func proxyCommand(_ hops: ArraySlice<Hop>, batch: Bool) -> String? {
        guard let hop = hops.first else { return nil }
        var parts = [
            "/usr/bin/ssh", "-W", "%h:%p", "-p", String(hop.site.port),
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ConnectTimeout=20", "-o", "StrictHostKeyChecking=accept-new",
        ]
        if batch { parts += ["-o", "BatchMode=yes"] }
        if !hop.password.isEmpty { parts += ["-o", "NumberOfPasswordPrompts=1"] }
        if let key = hop.site.keyFile.flatMap(Self.usableKeyPath) { parts += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        if let knownHostsFile { parts += ["-o", "UserKnownHostsFile=\(knownHostsFile)"] }
        // The outer ssh expands % once, and the %h of a further hop is that hop's own.
        if let further = proxyCommand(hops.dropFirst(), batch: batch) {
            parts += ["-o", "ProxyCommand=\(further.replacingOccurrences(of: "%", with: "%%"))"]
        }
        parts.append(hop.site.user.isEmpty ? hop.site.host : "\(hop.site.user)@\(hop.site.host)")
        return parts.map { $0 == "%h:%p" ? $0 : Self.shellQuote($0) }.joined(separator: " ")
    }

    private func connectionOptions(batch: Bool) -> [String] {
        var options: [String] = []
        if let identityFile { options += ["-i", identityFile, "-o", "IdentitiesOnly=yes"] }
        if let knownHostsFile { options += ["-o", "UserKnownHostsFile=\(knownHostsFile)"] }
        if let proxy = proxyCommand(hops[...], batch: batch) { options += ["-o", "ProxyCommand=\(proxy)"] }
        // A saved password that is wrong must not be retried until the server bans this address.
        if askpassPath != nil { options += ["-o", "NumberOfPasswordPrompts=1"] }
        return options
    }

    deinit {
        // The port is part of the socket's name: without it this would miss the connection and leave it open.
        _ = try? run("/usr/bin/ssh", commonOptions() + ["-p", String(site.port), "-O", "exit", target])
        if let askpassPath { try? FileManager.default.removeItem(atPath: askpassPath) }
    }

    private var target: String { site.user.isEmpty ? site.host : "\(site.user)@\(site.host)" }

    private func commonOptions() -> [String] {
        var options = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDir)/%C",
            "-o", "ControlPersist=120",
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=30",
            // First connection trusts and remembers the host key; a changed key is refused.
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        options += connectionOptions(batch: askpassPath == nil)
        return options
    }

    // MARK: Interactive shell

    public struct ShellInvocation {
        public let arguments: [String]
        public let environment: [String: String]
    }

    /// How to run an interactive shell on this server, in `directory` or else the home folder.
    /// It gets its own connection: closing the shared master when a panel disconnects would kill the shell.
    public func shellInvocation(directory: String?) -> ShellInvocation {
        var arguments = [
            "-t", "-p", String(site.port),
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=30",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        arguments += connectionOptions(batch: false)
        arguments.append(target)
        if let directory { arguments.append("cd \(Self.shellQuote(directory)); exec \"$SHELL\" -l") }
        return ShellInvocation(arguments: arguments, environment: passwordEnvironment)
    }

    // MARK: Process running

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    /// Output goes to files instead of pipes: the backgrounded ControlPersist master would keep a pipe open forever.
    @discardableResult
    private func run(_ tool: String, _ arguments: [String], input: String? = nil, poll: (() -> Bool)? = nil) throws -> Output {
        let temp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let outURL = temp.appendingPathComponent("mc-\(id).out")
        let errURL = temp.appendingPathComponent("mc-\(id).err")
        let inURL = temp.appendingPathComponent("mc-\(id).in")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        FileManager.default.createFile(atPath: inURL.path, contents: Data((input ?? "").utf8))
        defer {
            [outURL, errURL, inURL].forEach { try? FileManager.default.removeItem(at: $0) }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)
        process.standardInput = try FileHandle(forReadingFrom: inURL)
        var environment = ProcessInfo.processInfo.environment
        passwordEnvironment.forEach { environment[$0.key] = $0.value }
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()

        var cancelled = false
        while process.isRunning {
            usleep(50_000)
            if let poll, !cancelled, !poll() {
                cancelled = true
                process.terminate()
            }
        }
        process.waitUntilExit()
        if cancelled { throw MCError("Cancelled", isCancelled: true) }
        return Output(
            status: process.terminationStatus,
            stdout: (try? Data(contentsOf: outURL)) ?? Data(),
            stderr: String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func ensureMaster() throws {
        let port = ["-p", String(site.port)]
        let check = try run("/usr/bin/ssh", commonOptions() + port + ["-O", "check", target])
        if check.status == 0 { return }
        var options = commonOptions() + port + ["-f", "-N"]
        // Without a password nothing can answer a prompt, so fail instead of hanging.
        if askpassPath == nil { options += ["-o", "BatchMode=yes"] }
        let result = try run("/usr/bin/ssh", options + [target])
        if result.status != 0 { throw MCError(result.stderr.isEmpty ? "SSH connection failed" : result.stderr) }
    }

    /// Which way this server can be used. Checked once per connection.
    public func transport() throws -> Transport {
        lock.lock()
        if let detected { lock.unlock(); return detected }
        lock.unlock()
        try ensureMaster()
        let probe = try sftpRun(["pwd"])
        let found: Transport = probe.status == 0 ? .sftp : .scp
        lock.lock(); detected = found; lock.unlock()
        return found
    }

    private func sftpRun(_ commands: [String], poll: (() -> Bool)? = nil) throws -> Output {
        let options = commonOptions() + ["-P", String(site.port), "-b", "-", target]
        return try run("/usr/bin/sftp", options, input: commands.joined(separator: "\n") + "\n", poll: poll)
    }

    private func shellRun(_ command: String) throws -> Output {
        try run("/usr/bin/ssh", commonOptions() + ["-p", String(site.port), target, command])
    }

    private func sftpQuote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func failure(_ output: Output, _ fallback: String) -> MCError {
        // sftp prints its own banner and echo on stderr, the last line holds the reason.
        let last = output.stderr.split(separator: "\n").last.map(String.init)
        return MCError(last ?? fallback)
    }

    private func runCommand(sftp: String, shell: String) throws {
        let output: Output
        switch try transport() {
        case .sftp: output = try sftpRun([sftp])
        case .scp: output = try shellRun("LC_ALL=C " + shell)
        }
        if output.status != 0 { throw failure(output, "Command failed") }
    }

    // MARK: FileSource

    public func list(_ path: String) throws -> [FileEntry] {
        let output: Output
        switch try transport() {
        case .sftp:
            output = try sftpRun(["ls -la \(sftpQuote(path))"])
        case .scp:
            output = try shellRun("LC_ALL=C ls -la -- \(SSHClient.shellQuote(path))")
        }
        if output.status != 0 { throw failure(output, "Cannot list \(path)") }
        let text = String(decoding: output.stdout, as: UTF8.self)
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return ListingParser.parse(text).compactMap { entry in
            // sftp prints names with their folder in front.
            var clean = entry
            if clean.name.hasPrefix(prefix) { clean.name = String(clean.name.dropFirst(prefix.count)) }
            return clean.name == "." || clean.name == ".." ? nil : clean
        }
    }

    public func makeDirectory(_ path: String) throws {
        try runCommand(sftp: "mkdir \(sftpQuote(path))", shell: "mkdir -- \(SSHClient.shellQuote(path))")
    }

    public func removeFile(_ path: String) throws {
        try runCommand(sftp: "rm \(sftpQuote(path))", shell: "rm -- \(SSHClient.shellQuote(path))")
    }

    public func removeEmptyDirectory(_ path: String) throws {
        try runCommand(sftp: "rmdir \(sftpQuote(path))", shell: "rmdir -- \(SSHClient.shellQuote(path))")
    }

    public func rename(from: String, to: String) throws {
        try runCommand(sftp: "rename \(sftpQuote(from)) \(sftpQuote(to))", shell: "mv -- \(SSHClient.shellQuote(from)) \(SSHClient.shellQuote(to))")
    }

    private func scpOptions() -> [String] {
        // -O selects the classic SCP protocol, the one that works when the SFTP subsystem is off.
        // -T: quoting the remote path makes scp think the name differs from the request.
        commonOptions() + ["-O", "-q", "-T", "-P", String(site.port)]
    }

    public func download(_ path: String, to local: URL, progress: @escaping ProgressHandler) throws {
        try? FileManager.default.removeItem(at: local)
        let poll: () -> Bool = {
            let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
            return progress(size)
        }
        let output: Output
        switch try transport() {
        case .sftp:
            output = try sftpRun(["get \(sftpQuote(path)) \(sftpQuote(local.path))"], poll: poll)
        case .scp:
            output = try run("/usr/bin/scp", scpOptions() + ["\(target):\(SSHClient.shellQuote(path))", local.path], poll: poll)
        }
        if output.status != 0 { throw failure(output, "Download failed") }
    }

    public func upload(_ local: URL, to path: String, progress: @escaping ProgressHandler) throws {
        // These tools report no upload progress to us, so the bar moves when the file is done.
        let poll: () -> Bool = { progress(0) }
        let output: Output
        switch try transport() {
        case .sftp:
            output = try sftpRun(["put \(sftpQuote(local.path)) \(sftpQuote(path))"], poll: poll)
        case .scp:
            output = try run("/usr/bin/scp", scpOptions() + [local.path, "\(target):\(SSHClient.shellQuote(path))"], poll: poll)
        }
        if output.status != 0 { throw failure(output, "Upload failed") }
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
        _ = progress(size)
    }
}
