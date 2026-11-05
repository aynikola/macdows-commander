import XCTest
import MacdowsCore
@testable import MacdowsCommander

/// Runs real shells in an off-screen terminal view; nothing appears on screen.
final class TerminalSessionTests: XCTestCase {
    private var folder: String!
    private var testRoot: URL?
    private var lastScreen = ""

    override func tearDown() {
        if let testRoot { try? FileManager.default.removeItem(at: testRoot) }
    }

    override func setUpWithError() throws {
        // Short, so the path fits on one terminal line and can be searched for on screen.
        let base = URL(fileURLWithPath: "/tmp/mc-\(UUID().uuidString.prefix(6))")
        testRoot = base
        let url = base.appendingPathComponent("klasör adı")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url.resolvingSymlinksInPath().path
    }

    private func screen(_ session: TerminalSession) -> String {
        let terminal = session.view.getTerminal()
        // macOS paths hold "ö" as two code points; the provider is what returns such cells whole.
        lastScreen = (0..<terminal.rows).compactMap {
            terminal.getLine(row: $0)?.translateToString(trimRight: true, characterProvider: { terminal.getCharacter(for: $0) })
        }.joined(separator: "\n").precomposedStringWithCanonicalMapping
        return lastScreen
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, until: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if until() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out: \(what)\n\(lastScreen)")
    }

    func testLocalShellStartsInFolderFollowsCdAndEnds() throws {
        let session = TerminalSession(target: .local, directory: folder)
        var ended = false
        session.onTerminated = { _ in ended = true }
        session.startLocal()
        wait("shell at prompt") { session.isLocalShellIdle }
        session.view.send(txt: "pwd\r")
        wait("pwd output") { self.screen(session).contains(self.folder.precomposedStringWithCanonicalMapping) }

        // cd must arrive quoted, and half-typed text must not run with it.
        let other = (folder as NSString).deletingLastPathComponent
        session.view.send(txt: "half typed")
        session.changeDirectory(other)
        session.view.send(txt: "pwd > \(SSHClient.shellQuote(folder + "/out.txt"))\r")
        wait("cd result") { FileManager.default.fileExists(atPath: self.folder + "/out.txt") }
        let written = try String(contentsOfFile: folder + "/out.txt", encoding: .utf8)
        XCTAssertEqual(written.trimmingCharacters(in: .whitespacesAndNewlines), other)
        XCTAssertFalse(screen(session).contains("command not found"))

        // A running program means the shell is not idle, so nothing gets typed into it.
        session.view.send(txt: "sleep 2\r")
        wait("sleep in foreground") { !session.isLocalShellIdle }
        wait("back at prompt") { session.isLocalShellIdle }

        session.stop()
        wait("session ended") { ended }
        XCTAssertFalse(session.isRunning)
    }

    func testFullScreenProgramIsNotTypedInto() {
        let session = TerminalSession(target: .local, directory: folder)
        session.startLocal()
        wait("shell at prompt") { session.isLocalShellIdle }
        session.view.send(txt: "printf '\\033[?1049h'; sleep 3\r")
        wait("alternate screen") { session.view.getTerminal().isCurrentBufferAlternate }
        let before = session.directory
        session.changeDirectory("/tmp")
        XCTAssertEqual(session.directory, before)
        session.stop()
    }

    /// Uses the SSH test server from scripts/test-servers.sh.
    func testSSHShellOpensInRemoteFolder() throws {
        guard let dir = ProcessInfo.processInfo.environment["MC_TEST_DIR"] else { throw XCTSkip("MC_TEST_DIR is not set") }
        let site = Site(name: "t", proto: .ssh, host: "127.0.0.1", port: 2222, user: NSUserName(), mode: .auto, verifyTLS: false)
        let client = SSHClient(site: site, password: "", identityFile: dir + "/ssh/id_ed25519", knownHostsFile: dir + "/ssh/known_hosts")
        let session = TerminalSession(target: .site(site.id), directory: folder)
        session.startSSH(client.shellInvocation(directory: folder))
        wait("remote shell", timeout: 20) { self.screen(session).contains("%") || self.screen(session).contains("$") }
        session.view.send(txt: "echo MARK-$PWD-MARK\r")
        wait("remote pwd") { self.screen(session).contains("MARK-\(self.folder!)-MARK".precomposedStringWithCanonicalMapping) }
        session.stop()
    }
}
