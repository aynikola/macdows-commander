import XCTest
@testable import MacdowsCore

final class SSHLoginTests: XCTestCase {
    func testServersSavedBeforeKeysAndHopsStillLoad() throws {
        let saved = #"[{"id":"7F0B1D3A-3C55-4D6B-9D07-2A9D3E1C0A11","name":"eski","proto":"ssh","host":"h","port":22,"user":"u","path":"/","mode":"auto","encoding":"auto","parallel":2,"verifyTLS":true}]"#
        let sites = try JSONDecoder().decode([Site].self, from: Data(saved.utf8))
        XCTAssertEqual(sites.first?.name, "eski")
        XCTAssertNil(sites.first?.keyFile)
        XCTAssertNil(sites.first?.jumpSiteID)
    }

    func testHopChainStopsAtALoop() {
        let name = "mc-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SiteStore(defaults: defaults)
        var a = Site(name: "a", proto: .ssh, host: "a")
        var b = Site(name: "b", proto: .ssh, host: "b")
        a.jumpSiteID = b.id
        b.jumpSiteID = a.id
        store.save([a, b])
        XCTAssertEqual(store.hops(for: a).map(\.site.name), ["b"])
    }

    private func answer(_ client: SSHClient, prompt: String) throws -> String {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("mc-ask-\(UUID().uuidString).sh")
        try SSHClient.askpassScript.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, prompt]
        process.environment = client.passwordEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testEachPromptGetsTheRightPassword() throws {
        let hop = Site(name: "hop", proto: .ssh, host: "gate.example.com", user: "ali", keyFile: "/tmp/hop key.pem")
        let target = Site(name: "hedef", proto: .ssh, host: "hacettepe.example", user: "veli")
        let tricky = #"p'a"ss $HOME `x` \n"#
        let client = SSHClient(site: target, password: "hedef-sifre", hops: [SSHClient.Hop(site: hop, password: tricky)])
        XCTAssertEqual(try answer(client, prompt: "ali@gate.example.com's password: "), tricky + "\n")
        XCTAssertEqual(try answer(client, prompt: "(ali@gate.example.com) Password: "), tricky + "\n")
        XCTAssertEqual(try answer(client, prompt: "Enter passphrase for key '/tmp/hop key.pem': "), tricky + "\n")
        XCTAssertEqual(try answer(client, prompt: "veli@hacettepe.example's password: "), "hedef-sifre\n")
        XCTAssertEqual(try answer(client, prompt: "(veli@hacettepe.example) Password: "), "hedef-sifre\n")
    }

    func testAPasswordlessServerLetsTheTerminalAsk() {
        let client = SSHClient(site: Site(name: "x", proto: .ssh, host: "h"), password: "")
        XCTAssertEqual(client.passwordEnvironment, [:])
        XCTAssertNil(client.shellInvocation(directory: nil).arguments.firstIndex(of: "NumberOfPasswordPrompts=1"))
        XCTAssertEqual(client.shellInvocation(directory: nil).arguments.last, "h", "no remote command: the home folder")
    }

    func testKeyFilePermissionsAreTightened() throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString).pem")
        try Data("k".utf8).write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
        let client = SSHClient(site: Site(name: "x", proto: .ssh, host: "h", keyFile: key.path), password: "")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(client.shellInvocation(directory: "/x").arguments.contains(key.path))
    }

    func testNestedHopsEscapeTokens() {
        let near = Site(name: "n", proto: .ssh, host: "near", user: "a")
        let far = Site(name: "f", proto: .ssh, host: "far", user: "b")
        let client = SSHClient(site: Site(name: "t", proto: .ssh, host: "t"), password: "")
        let command = client.proxyCommand([SSHClient.Hop(site: near, password: ""), SSHClient.Hop(site: far, password: "")][...], batch: false)!
        XCTAssertTrue(command.hasPrefix("'/usr/bin/ssh' '-W'") || command.contains(" %h:%p "), command)
        XCTAssertTrue(command.contains("%%h:%%p"), "the far hop's tokens survive one expansion: \(command)")
        XCTAssertTrue(command.hasSuffix("'a@near'"))
    }
}
