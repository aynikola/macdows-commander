import XCTest
@testable import MacdowsCore

/// Answers every request from a list the test sets, so no real service is needed.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    /// Requests for these models answer 404.
    nonisolated(unsafe) static var failing = Set<String>()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var seen = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            seen.httpBody = data
        }
        Self.lastRequest = seen
        var status = Self.status
        if let body = seen.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let model = json["model"] as? String, Self.failing.contains(model) { status = 404 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AIClientTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func config(_ id: String, key: String = "k") -> AIConfig {
        let provider = AIProviders.provider(id: id)
        return AIConfig(providerID: id, baseURL: provider.baseURL, model: provider.defaultModel, apiKey: key)
    }

    func testOpenAIStreamLines() {
        XCTAssertEqual(AIClient.delta(fromLine: #"data: {"choices":[{"delta":{"content":"Mer"}}]}"#, kind: .openAI), "Mer")
        XCTAssertNil(AIClient.delta(fromLine: "data: [DONE]", kind: .openAI))
        XCTAssertNil(AIClient.delta(fromLine: ": keep-alive", kind: .openAI))
        XCTAssertNil(AIClient.delta(fromLine: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#, kind: .openAI))
    }

    func testClaudeStreamLines() {
        XCTAssertEqual(AIClient.delta(fromLine: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ha"}}"#, kind: .anthropic), "ha")
        XCTAssertNil(AIClient.delta(fromLine: #"data: {"type":"message_start"}"#, kind: .anthropic))
        XCTAssertNil(AIClient.delta(fromLine: "event: content_block_delta", kind: .anthropic))
    }

    func testRequestsFollowEachServicesFormat() throws {
        let messages = [AIMessage(.system, "Kisa yaz"), AIMessage(.user, "Selam")]
        let openAI = try AIClient(config: config("groq")).chatRequest(messages, stream: true)
        XCTAssertEqual(openAI.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let openBody = try JSONSerialization.jsonObject(with: openAI.httpBody!) as! [String: Any]
        XCTAssertEqual((openBody["messages"] as! [[String: String]]).first?["role"], "system")

        let claude = try AIClient(config: config("anthropic")).chatRequest(messages, stream: true)
        XCTAssertEqual(claude.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNotNil(claude.value(forHTTPHeaderField: "anthropic-version"))
        let claudeBody = try JSONSerialization.jsonObject(with: claude.httpBody!) as! [String: Any]
        XCTAssertEqual(claudeBody["system"] as? String, "Kisa yaz")
        XCTAssertEqual((claudeBody["messages"] as! [[String: String]]).map { $0["role"] }, ["user"], "the system text is not a message for Claude")
        XCTAssertNotNil(claudeBody["max_tokens"])

        let local = try AIClient(config: config("custom", key: "")).chatRequest(messages, stream: true)
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"), "no key, no header")
    }

    func testAnswerArrivesInPieces() async throws {
        StubProtocol.status = 200
        StubProtocol.body = Data("""
        data: {"choices":[{"delta":{"content":"Mer"}}]}

        data: {"choices":[{"delta":{"content":"haba"}}]}

        data: [DONE]

        """.utf8)
        var pieces: [String] = []
        for try await piece in AIClient(config: config("custom", key: ""), session: session()).stream([AIMessage(.user, "x")]) { pieces.append(piece) }
        XCTAssertEqual(pieces, ["Mer", "haba"])
    }

    func testServiceErrorsShowTheServicesOwnWords() async {
        StubProtocol.status = 401
        StubProtocol.body = Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
        do {
            _ = try await AIClient(config: config("groq"), session: session()).complete([AIMessage(.user, "x")])
            XCTFail("should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Invalid API key (401)"), error.localizedDescription)
        }
    }

    func testAServerThatIsNotRunningGetsAHelpfulMessage() async {
        let config = AIConfig(providerID: "custom", baseURL: "http://127.0.0.1:1/v1", model: "m", apiKey: "")
        do {
            _ = try await AIClient(config: config).complete([AIMessage(.user, "x")])
            XCTFail("nothing listens there")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not reach"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Is the server running"), error.localizedDescription)
        }
    }

    func testGeminiStyleErrorListsAreReadAndQuotaGetsAdvice() {
        let body = Data(#"[{"error":{"code":429,"message":"You exceeded your current quota, please check your plan.\n* Quota exceeded for metric: x, limit: 0\nPlease retry in 3s."}}]"#.utf8)
        let text = AIClient.errorMessage(status: 429, body: body)
        XCTAssertTrue(text.hasPrefix("You exceeded your current quota, please check your plan. (429)"), text)
        XCTAssertFalse(text.contains("metric"), "only the first line of the service's message")
        XCTAssertTrue(text.contains("Try another model"))
        XCTAssertTrue(AIClient.errorMessage(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8)).contains("Check the key"))
        XCTAssertTrue(AIClient.errorMessage(status: 404, body: Data(#"[{"error":{"message":"This model is no longer available."}}]"#.utf8)).contains("Load list"), "a retired model points to the list")
    }

    func testModelChoicesPutTheCurrentOneFirstAndPreferWhatWasTried() {
        let config = AIConfig(providerID: "gemini", baseURL: "x", model: "gemini-2.0-flash", apiKey: "k")
        let fetched = AIProviders.choices(for: config, fetched: ["gemini-9-flash", "gemini-2.0-flash", "antigravity-preview-latest"])
        XCTAssertEqual(fetched, ["gemini-2.0-flash", "gemini-9-flash"], "the service's list, cleaned, with the current one first and no repeats")
        let suggested = AIProviders.choices(for: config, fetched: [])
        XCTAssertTrue(suggested.contains("gemini-3.5-flash-lite"), "without a fetched list the suggestions stand in")
        XCTAssertEqual(AIProviders.choices(for: config, fetched: ["gemini-9-flash"], working: ["gemini-3.5-flash"]), ["gemini-2.0-flash", "gemini-3.5-flash"], "what answered wins over everything else")
        for provider in AIProviders.all where provider.id != "custom" { XCTAssertFalse(provider.suggestedModels.isEmpty, provider.id) }
        XCTAssertTrue(AIProviders.provider(id: "gemini").suggestedModels.contains(AIProviders.provider(id: "gemini").defaultModel), "the default is one of the suggestions")
    }

    func testOnlyFourModelsAreOfferedBestFirst() {
        let many = ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-3-flash-preview", "gemini-pro-latest", "gemini-3.1-pro-preview", "gemma-4-31b-it"]
        XCTAssertEqual(AIProviders.top(many), ["gemini-3.5-flash-lite", "gemini-2.5-flash-lite", "gemini-3.5-flash", "gemini-2.5-flash"], "lite and newer first, previews and -latest last")
        let config = AIConfig(providerID: "gemini", baseURL: "x", model: "gemini-2.5-pro", apiKey: "k")
        let choices = AIProviders.choices(for: config, fetched: many)
        XCTAssertEqual(choices.count, 4)
        XCTAssertEqual(choices.first, "gemini-2.5-pro", "the one in use stays on top even when it is not among the best")
        XCTAssertEqual(AIProviders.choices(for: config, fetched: [], working: Array(repeating: "x", count: 1) + many).count, 4, "a long working list is cut too")
        XCTAssertLessThanOrEqual(AIProviders.choices(for: config, fetched: []).count, 4, "so are the suggestions")
    }

    func testGoogleListsKeepOnlyTheChatModels() {
        let listed = ["antigravity-preview-latest", "deep-research-preview-04-2026", "gemini-2.5-computer-use-preview-10-2025", "gemini-2.5-flash", "gemini-2.5-flash-lite",
                      "gemini-3-flash-preview", "gemini-3.1-flash-live-preview", "gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools", "gemini-3.5-flash-lite",
                      "gemini-3.8-live", "gemini-4-argon", "gemini-decision-1", "gemini-flash-latest", "gemini-nano-banana-2.1", "gemini-omni-1.1-flash",
                      "gemini-robotics-er-2-preview", "gemma-4-31b-it", "genie-4", "lyria-3.5", "models/gemini-pro-latest", "models/text-embedding-004"]
        XCTAssertEqual(AIClient.chatModels(listed, provider: "gemini"),
                       ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-3-flash-preview", "gemini-3.1-pro-preview", "gemini-3.5-flash-lite", "gemini-flash-latest", "gemini-pro-latest", "gemma-4-31b-it"])
        XCTAssertEqual(AIClient.chatModels(["a:free", "b", "c:free"], provider: "openrouter"), ["a:free", "c:free"], "OpenRouter shows only the free ones")
    }

    func testOnlyModelsThatAnswerAreKept() async {
        StubProtocol.status = 200
        StubProtocol.body = Data("{}".utf8)
        StubProtocol.failing = ["retired", "nokta"]
        defer { StubProtocol.failing = [] }
        let config = AIConfig(providerID: "custom", baseURL: "http://h/v1", model: "x", apiKey: "")
        let working = await AIClient.working(among: ["good-1", "retired", "good-2", "nokta", "good-3", "good-4", "good-5"], config: config, session: session())
        XCTAssertEqual(working, ["good-1", "good-2", "good-3", "good-4", "good-5"], "in the order given, the failing ones left out")
        let none = await AIClient.working(among: ["retired"], config: config, session: session())
        XCTAssertEqual(none, [])
        let progress = ProgressCounter()
        _ = await AIClient.working(among: ["a", "b", "c"], config: config, session: session()) { done, total in progress.add(done, total) }
        XCTAssertEqual(progress.last?.1, 3)
        XCTAssertEqual(progress.last?.0, 3)
    }

    func testTheReplacementForADeadModelIsALiteOneIfThereIsOne() {
        XCTAssertEqual(AIProviders.preferred(from: ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"]), "gemini-2.5-flash-lite")
        XCTAssertEqual(AIProviders.preferred(from: ["gemini-2.5-pro", "gemini-2.5-flash"]), "gemini-2.5-flash")
        XCTAssertEqual(AIProviders.preferred(from: ["big-model"]), "big-model")
        XCTAssertNil(AIProviders.preferred(from: []))
    }

    func testWorkingModelsAreRemembered() {
        let suite = "ai-working-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(defaults: defaults)
        XCTAssertEqual(store.workingModels(for: "gemini"), [])
        store.setWorkingModels(["m1"], for: "gemini")
        XCTAssertEqual(store.workingModels(for: "gemini"), ["m1"])
        XCTAssertEqual(store.workingModels(for: "groq"), [])
    }

    func testFetchedListsDropModelsThatCannotChatAndTheModelsPrefix() {
        XCTAssertEqual(AIClient.chatModels(["models/gemini-3.5-flash", "models/text-embedding-004", "whisper-large-v3", "llama-3.3-70b", "models/gemini-3.5-flash", "playai-tts"]),
                       ["gemini-3.5-flash", "llama-3.3-70b"])
    }

    func testFetchedModelsAreRemembered() {
        let suite = "ai-models-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(defaults: defaults)
        XCTAssertEqual(store.fetchedModels(for: "groq"), [])
        store.setFetchedModels(["a", "b"], for: "groq")
        XCTAssertEqual(store.fetchedModels(for: "groq"), ["a", "b"])
        XCTAssertEqual(store.fetchedModels(for: "gemini"), [], "each service has its own")
    }

    func testModelsAreListedSorted() async throws {
        StubProtocol.status = 200
        StubProtocol.body = Data(#"{"data":[{"id":"zeta"},{"id":"alfa"}]}"#.utf8)
        let models = try await AIClient(config: config("custom", key: ""), session: session()).models()
        XCTAssertEqual(models, ["alfa", "zeta"])
    }

    func testTheFreeServicesAndGrokAreListedAndOllamaIsNot() {
        let ids = AIProviders.all.map(\.id)
        for wanted in ["gemini", "groq", "openrouter", "cerebras", "mistral", "github", "xai", "anthropic", "custom"] { XCTAssertTrue(ids.contains(wanted), wanted) }
        XCTAssertFalse(ids.contains("ollama"))
        XCTAssertEqual(AIProviders.all.first?.id, "gemini", "the first one is the default")
        for provider in AIProviders.all where provider.id != "custom" {
            XCTAssertNotNil(URL(string: provider.baseURL), provider.id)
            XCTAssertTrue(provider.baseURL.hasPrefix("https://"), "\(provider.id) is reached over https")
            XCTAssertFalse(provider.defaultModel.isEmpty, provider.id)
            XCTAssertTrue(provider.needsKey, provider.id)
        }
        XCTAssertEqual(AIClient.delta(fromLine: #"data: {"choices":[{"delta":{"content":"x"}}]}"#, kind: AIProviders.provider(id: "xai").kind), "x", "Grok speaks the OpenAI format")
    }

    func testKeysStayOutOfDefaultsAndReadinessNeedsThem() {
        let suite = "ai-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AIConfig(providerID: "custom", baseURL: "http://localhost:1234/v1", model: "m", apiKey: "").isReady, "a local server needs no key")
        XCTAssertFalse(AIConfig(providerID: "groq", baseURL: "x", model: "m", apiKey: "").isReady)
        XCTAssertFalse(AIConfig(providerID: "custom", baseURL: "x", model: "", apiKey: "").isReady, "a model must be named")
        let store = AISettingsStore(defaults: defaults)
        XCTAssertEqual(store.load().providerID, "gemini", "it starts on a service with a free tier")
        store.save(AIConfig(providerID: "custom", baseURL: "http://h:1/v1", model: "m", apiKey: ""))
        XCTAssertEqual(store.load().baseURL, "http://h:1/v1")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "secret-key" })
    }
}

private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func add(_ done: Int, _ total: Int) { lock.lock(); values.append((done, total)); lock.unlock() }
    var last: (Int, Int)? { lock.lock(); defer { lock.unlock() }; return values.max { $0.0 < $1.0 } }
}
