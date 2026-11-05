import XCTest
@testable import MacdowsCore

/// Runs against the throwaway servers from scripts/test-servers.sh. Skipped when MC_TEST_DIR is not set.
final class LiveServerTests: XCTestCase {
    private var serverRoot: URL!
    private var work: URL!
    private var testDir: String!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["MC_TEST_DIR"] else {
            throw XCTSkip("MC_TEST_DIR is not set")
        }
        testDir = dir
        serverRoot = URL(fileURLWithPath: dir).appendingPathComponent("root")
        work = FileManager.default.temporaryDirectory.appendingPathComponent("mc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func ftpSite(port: Int, mode: ConnectionMode, proto: SiteProtocol = .ftp) -> Site {
        Site(name: "test", proto: proto, host: "127.0.0.1", port: port, user: "tester", mode: mode, verifyTLS: false)
    }

    /// Full round trip: mkdir, upload, list with attributes and hidden files, download, rename, delete.
    private func exercise(_ client: FileSource, folder: String) throws {
        let base = "/" + folder
        try? client.removeTree(base, isDirectory: true)
        try client.makeDirectory(base)
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        let local = work.appendingPathComponent("up load.bin")
        try payload.write(to: local)

        try client.upload(local, to: base + "/up load.bin") { _ in true }
        try client.upload(local, to: base + "/.hidden") { _ in true }
        // Binary mode check: a byte changed in transit would break the comparison below.
        let listed = try client.list(base)
        let file = try XCTUnwrap(listed.first { $0.name == "up load.bin" })
        XCTAssertEqual(file.size, Int64(payload.count))
        XCTAssertNotNil(file.permissions)
        XCTAssertNotNil(file.owner)
        XCTAssertTrue(listed.contains { $0.name == ".hidden" }, "hidden files must be listed: \(listed.map(\.name))")

        let back = work.appendingPathComponent("back.bin")
        try client.download(base + "/up load.bin", to: back) { _ in true }
        XCTAssertEqual(try Data(contentsOf: back), payload)

        try client.rename(from: base + "/up load.bin", to: base + "/renamed.bin")
        XCTAssertTrue(try client.list(base).contains { $0.name == "renamed.bin" })

        // Uploading over an existing file replaces it.
        let shorter = work.appendingPathComponent("short.bin")
        try Data("short".utf8).write(to: shorter)
        try client.upload(shorter, to: base + "/renamed.bin") { _ in true }
        XCTAssertEqual(try client.list(base).first { $0.name == "renamed.bin" }?.size, 5)

        try client.removeTree(base, isDirectory: true)
        XCTAssertFalse(try client.list("/").contains { $0.name == folder })
    }

    func testPassive() throws {
        try exercise(FTPClient(site: ftpSite(port: 2121, mode: .passive), password: "secret"), folder: "passive")
    }

    func testActive() throws {
        try exercise(FTPClient(site: ftpSite(port: 2121, mode: .active), password: "secret"), folder: "active")
    }

    func testAutoFallsBackToActiveWhenServerRefusesPassive() throws {
        let client = FTPClient(site: ftpSite(port: 2122, mode: .auto), password: "secret")
        try exercise(client, folder: "fallback")
        XCTAssertEqual(client.currentMode, .active)
    }

    func testForcedPassiveFailsWhenServerRefusesIt() throws {
        let client = FTPClient(site: ftpSite(port: 2122, mode: .passive), password: "secret")
        XCTAssertThrowsError(try client.list("/"))
    }

    func testExplicitFTPS() throws {
        try exercise(FTPClient(site: ftpSite(port: 2123, mode: .auto, proto: .ftpsExplicit), password: "secret"), folder: "ftps")
    }

    func testWrongPasswordIsReported() throws {
        let client = FTPClient(site: ftpSite(port: 2121, mode: .auto), password: "wrong")
        XCTAssertThrowsError(try client.list("/"))
    }

    func testTurkishNamesInUTF8() throws {
        let client = FTPClient(site: ftpSite(port: 2121, mode: .auto), password: "secret")
        let base = "/şehir ğüİ"
        try? client.removeTree(base, isDirectory: true)
        try client.makeDirectory(base)
        XCTAssertTrue(try client.list("/").contains { $0.name == "şehir ğüİ" })
        try client.removeTree(base, isDirectory: true)
    }

    private func sshClient(port: Int) -> SSHClient {
        let site = Site(name: "ssh", proto: .ssh, host: "127.0.0.1", port: port, user: NSUserName())
        return SSHClient(site: site, password: "", identityFile: testDir + "/ssh/id_ed25519", knownHostsFile: testDir + "/ssh/known_hosts")
    }

    /// Reaches 2223 only through 2222, with the key given on the hop's own saved server.
    func testConnectingThroughAHop() throws {
        var hop = Site(name: "hop", proto: .ssh, host: "127.0.0.1", port: 2299, user: NSUserName())
        hop.keyFile = testDir + "/ssh/id_ed25519"
        // "localhost" gets its own shared connection, so nothing from the other tests can answer for it.
        let target = Site(name: "hedef", proto: .ssh, host: "localhost", port: 2223, user: NSUserName())
        let make = { SSHClient(site: target, password: "", identityFile: self.testDir + "/ssh/id_ed25519", knownHostsFile: self.testDir + "/ssh/known_hosts", hops: [SSHClient.Hop(site: hop, password: "")]) }
        // Nothing listens on 2299, so this failing shows the connection really goes through the hop.
        XCTAssertThrowsError(try make().list("/tmp"))
        hop.port = 2222
        XCTAssertFalse(try make().list("/tmp").isEmpty)
    }

    private func sshExercise(_ client: SSHClient, folder: String) throws {
        // ssh sees the real disk, so the test works in its own folder inside the server root.
        let base = serverRoot.path + "/" + folder
        try? client.removeTree(base, isDirectory: true)
        try client.makeDirectory(base)
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        let local = work.appendingPathComponent("up load.bin")
        try payload.write(to: local)
        try client.upload(local, to: base + "/it's up load.bin") { _ in true }
        try client.upload(local, to: base + "/.hidden") { _ in true }
        let listed = try client.list(base)
        XCTAssertEqual(listed.first { $0.name == "it's up load.bin" }?.size, Int64(payload.count), "\(listed.map(\.name))")
        XCTAssertTrue(listed.contains { $0.name == ".hidden" })
        XCTAssertNotNil(listed.first?.owner)
        let back = work.appendingPathComponent("back.bin")
        try client.download(base + "/it's up load.bin", to: back) { _ in true }
        XCTAssertEqual(try Data(contentsOf: back), payload)
        try client.rename(from: base + "/.hidden", to: base + "/visible")
        try client.removeTree(base, isDirectory: true)
    }

    func testSSHUsesSFTPWhenAvailable() throws {
        let client = sshClient(port: 2222)
        XCTAssertEqual(try client.transport(), .sftp)
        try sshExercise(client, folder: "ssh-sftp")
    }

    func testSSHFallsBackToSCPWithoutSFTP() throws {
        let client = sshClient(port: 2223)
        XCTAssertEqual(try client.transport(), .scp)
        try sshExercise(client, folder: "ssh-scp")
    }

    // MARK: Transfer planning: the "never overwrite without asking" rule.

    func testPlanFindsConflictsInsideFoldersAndPolicies() throws {
        let local = LocalSource()
        let src = work.appendingPathComponent("src")
        let dst = work.appendingPathComponent("dst")
        for dir in [src, dst] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        }
        try Data("new".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data("new".utf8).write(to: src.appendingPathComponent("sub/b.txt"))
        try Data("fresh".utf8).write(to: src.appendingPathComponent("sub/c.txt"))
        try Data("old-a".utf8).write(to: dst.appendingPathComponent("a.txt"))
        try Data("old-b".utf8).write(to: dst.appendingPathComponent("sub/b.txt"))
        try Data("keep".utf8).write(to: dst.appendingPathComponent("sub/keep.txt"))
        let selection = try local.list(src.path)

        var plan = try TransferPlanner.plan(selection: selection, from: local, sourceDirectory: src.path, to: local, destinationDirectory: dst.path)
        XCTAssertEqual(Set(plan.conflicts.map(\.relative)), ["a.txt", "sub/b.txt"])

        plan.applyPolicy(.skip)
        let engine = TransferEngine()
        let done = expectation(description: "transfer")
        engine.onBatchFinished = { _ in done.fulfill() }
        engine.start(plan: plan, title: "t", source: local, destination: local, move: false, parallel: 2)
        wait(for: [done], timeout: 10)

        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a.txt")), "old-a")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("sub/b.txt")), "old-b")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("sub/c.txt")), "fresh")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("sub/keep.txt")), "keep", "folders merge, they are not replaced")
    }

    func testMoveKeepsSkippedFilesAtSource() throws {
        let local = LocalSource()
        let src = work.appendingPathComponent("msrc")
        let dst = work.appendingPathComponent("mdst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src.appendingPathComponent("skip.txt"))
        try Data("y".utf8).write(to: src.appendingPathComponent("go.txt"))
        try Data("z".utf8).write(to: dst.appendingPathComponent("skip.txt"))
        var plan = try TransferPlanner.plan(selection: local.list(src.path), from: local, sourceDirectory: src.path, to: local, destinationDirectory: dst.path)
        plan.applyPolicy(.skip)
        let engine = TransferEngine()
        let done = expectation(description: "transfer")
        engine.onBatchFinished = { _ in done.fulfill() }
        engine.start(plan: plan, title: "t", source: local, destination: local, move: true, parallel: 1)
        wait(for: [done], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("skip.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("go.txt").path))
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("skip.txt")), "z")
    }

    func testFTPTransferThroughEngine() throws {
        let local = LocalSource()
        let client = FTPClient(site: ftpSite(port: 2121, mode: .auto), password: "secret")
        let src = work.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("deep/er"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: src.appendingPathComponent("one.txt"))
        try Data("22".utf8).write(to: src.appendingPathComponent("deep/er/two.txt"))
        try? client.removeTree("/engine", isDirectory: true)

        let selection = try local.list(work.path).filter { $0.name == "engine" }
        let plan = try TransferPlanner.plan(selection: selection, from: local, sourceDirectory: work.path, to: client, destinationDirectory: "/")
        XCTAssertTrue(plan.conflicts.isEmpty)
        let engine = TransferEngine()
        let done = expectation(description: "upload")
        var result: BatchSnapshot?
        engine.onBatchFinished = { result = $0; done.fulfill() }
        engine.start(plan: plan, title: "t", source: local, destination: client, move: false, parallel: 2)
        wait(for: [done], timeout: 20)
        XCTAssertEqual(result?.failures ?? ["none"], [])
        XCTAssertEqual(try client.list("/engine/deep/er").first?.name, "two.txt")

        // A second upload now reports both files as conflicts instead of replacing them.
        let again = try TransferPlanner.plan(selection: selection, from: local, sourceDirectory: work.path, to: client, destinationDirectory: "/")
        XCTAssertEqual(Set(again.conflicts.map(\.relative)), ["engine/one.txt", "engine/deep/er/two.txt"])

        try client.removeTree("/engine", isDirectory: true)
    }

    /// Compress and send: from a server into an archive, and an archive onto a server, then a content search there.
    func testPackFromFTPAndSearchOnServer() throws {
        let client = FTPClient(site: ftpSite(port: 2121, mode: .auto), password: "secret")
        let base = "/pack-test"
        try? client.removeTree(base, isDirectory: true)
        try client.makeDirectory(base)
        try client.makeDirectory(base + "/alt")
        let text = work.appendingPathComponent("t.txt")
        try Data("aranan kelime burada\n".utf8).write(to: text)
        try client.upload(text, to: base + "/alt/t.txt") { _ in true }

        let packed = try ArchiveCreator.pack(selection: [FileEntry(name: "alt", isDirectory: true)], from: client, directory: base, format: .zip, name: "alt.zip", workFolder: work.appendingPathComponent("p"), isCancelled: { false })
        let archive = ArchiveSource(file: packed, kind: .tarLike)
        XCTAssertEqual(try archive.list("/alt").map(\.name), ["t.txt"])

        try client.upload(packed, to: base + "/alt.zip") { _ in true }
        XCTAssertTrue(try client.list(base).contains { $0.name == "alt.zip" && $0.size > 0 })

        var hits: [SearchHit] = []
        FileSearcher.run(source: client, root: base, options: SearchOptions(namePattern: "*.txt", content: "KELİME"), isCancelled: { false }) { hits.append($0) }
        XCTAssertEqual(hits.map(\.path), [base + "/alt/t.txt"])
        XCTAssertEqual(hits.first?.line, 1)
        try? client.removeTree(base, isDirectory: true)
    }
}
