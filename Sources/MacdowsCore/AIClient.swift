import Foundation
import Security

/// How a service wants its requests: most use the OpenAI chat format, Claude has its own.
public enum AIKind: String, Codable {
    case openAI, anthropic
}

public struct AIProvider: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: AIKind
    public let baseURL: String
    public let defaultModel: String
    /// Models worth offering before the service's own list has been fetched. Names change, so the live list wins.
    public let suggestedModels: [String]
    public let needsKey: Bool
    /// One line for the settings: what it costs and where to get a key.
    public let note: String
    public let keyPage: String?
}

public enum AIProviders {
    public static let all: [AIProvider] = [
        AIProvider(id: "gemini", name: "Google Gemini (free tier)", kind: .openAI, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-3.5-flash-lite", suggestedModels: ["gemini-3.5-flash-lite", "gemini-3.5-flash", "gemini-2.5-flash", "gemini-2.0-flash", "gemini-2.0-flash-lite"], needsKey: true,
                   note: "Free tier, no card needed. Get a key in Google AI Studio and paste it here.", keyPage: "https://aistudio.google.com/apikey"),
        AIProvider(id: "groq", name: "Groq (free tier, very fast)", kind: .openAI, baseURL: "https://api.groq.com/openai/v1", defaultModel: "llama-3.3-70b-versatile", suggestedModels: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3-32b"], needsKey: true,
                   note: "Free tier. Get a free key from the Groq console.", keyPage: "https://console.groq.com/keys"),
        AIProvider(id: "openrouter", name: "OpenRouter (free models)", kind: .openAI, baseURL: "https://openrouter.ai/api/v1", defaultModel: "meta-llama/llama-3.3-70b-instruct:free", suggestedModels: ["meta-llama/llama-3.3-70b-instruct:free", "google/gemma-3-27b-it:free", "deepseek/deepseek-r1:free", "qwen/qwen3-235b-a22b:free", "mistralai/mistral-small-3.2-24b-instruct:free"], needsKey: true,
                   note: "Models whose name ends in :free cost nothing. Get a free key from OpenRouter.", keyPage: "https://openrouter.ai/keys"),
        AIProvider(id: "cerebras", name: "Cerebras (free tier, very fast)", kind: .openAI, baseURL: "https://api.cerebras.ai/v1", defaultModel: "llama-3.3-70b", suggestedModels: ["llama-3.3-70b", "llama3.1-8b", "qwen-3-32b", "gpt-oss-120b"], needsKey: true,
                   note: "Free tier. Get a free key from Cerebras.", keyPage: "https://cloud.cerebras.ai"),
        AIProvider(id: "mistral", name: "Mistral (free plan)", kind: .openAI, baseURL: "https://api.mistral.ai/v1", defaultModel: "mistral-small-latest", suggestedModels: ["mistral-small-latest", "mistral-medium-latest", "mistral-large-latest", "open-mistral-nemo", "codestral-latest"], needsKey: true,
                   note: "The free Experiment plan is enough. Get a key from the Mistral console.", keyPage: "https://console.mistral.ai/api-keys"),
        AIProvider(id: "github", name: "GitHub Models (free with GitHub)", kind: .openAI, baseURL: "https://models.github.ai/inference", defaultModel: "openai/gpt-4o-mini", suggestedModels: ["openai/gpt-4o-mini", "openai/gpt-4o", "openai/gpt-4.1", "meta/Llama-3.3-70B-Instruct", "deepseek/DeepSeek-R1"], needsKey: true,
                   note: "Free with a GitHub account. Create a token with the Models permission and paste it as the key.", keyPage: "https://github.com/settings/personal-access-tokens"),
        AIProvider(id: "xai", name: "Grok (xAI)", kind: .openAI, baseURL: "https://api.x.ai/v1", defaultModel: "grok-3-mini", suggestedModels: ["grok-3-mini", "grok-3", "grok-4"], needsKey: true,
                   note: "Paid by use, though xAI may give some starting credit. Get a key from the xAI console.", keyPage: "https://console.x.ai"),
        AIProvider(id: "anthropic", name: "Claude (Anthropic, paid)", kind: .anthropic, baseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-5-5", suggestedModels: ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-fable-5-1"], needsKey: true,
                   note: "Paid, by use. An API key is needed.", keyPage: "https://console.anthropic.com/settings/keys"),
        AIProvider(id: "custom", name: "Other (OpenAI compatible)", kind: .openAI, baseURL: "http://localhost:1234/v1", defaultModel: "", suggestedModels: [], needsKey: false,
                   note: "Any server with the OpenAI chat API, such as LM Studio or a company server. A key is optional.", keyPage: nil),
    ]

    /// What the model box offers: the one in use, then the service's own list if it was fetched, then the suggestions.
    /// Models that were tried and answered come first and alone; failing that the service's own list, cleaned up;
    /// failing that the suggestions. The one in use is always shown so the menu never disagrees with the settings.
    public static func choices(for config: AIConfig, fetched: [String], working: [String] = []) -> [String] {
        let listed = AIClient.chatModels(fetched, provider: config.providerID)
        let base = !working.isEmpty ? working : (!listed.isEmpty ? listed : config.provider.suggestedModels)
        var seen = Set<String>()
        return ([config.model] + base).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Which working model to switch to when the one in use does not answer: a lite one first, they have the widest free limits.
    public static func preferred(from working: [String]) -> String? {
        working.first { $0.contains("lite") } ?? working.first { $0.contains("flash") || $0.contains("-mini") || $0.contains("-small") || $0.contains("instant") } ?? working.first
    }

    public static func provider(id: String) -> AIProvider {
        all.first { $0.id == id } ?? all[0]
    }
}

public struct AIMessage: Equatable {
    public enum Role: String { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// What to talk to: the chosen service, its address and model, and the key if it needs one.
public struct AIConfig: Equatable {
    public var providerID: String
    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(providerID: String, baseURL: String, model: String, apiKey: String) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public var provider: AIProvider { AIProviders.provider(id: providerID) }

    /// True when a request can be tried: a model is named and the key is there if the service wants one.
    public var isReady: Bool { !model.isEmpty && (!provider.needsKey || !apiKey.isEmpty) }
}

/// Provider, address and model live in UserDefaults; keys live in the Keychain, one per service.
public final class AISettingsStore {
    private static let service = "Macdows Commander AI"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AIConfig {
        let id = defaults.string(forKey: "ai.provider") ?? "gemini"
        let provider = AIProviders.provider(id: id)
        return AIConfig(providerID: provider.id,
                        baseURL: defaults.string(forKey: "ai.baseURL.\(provider.id)") ?? provider.baseURL,
                        model: defaults.string(forKey: "ai.model.\(provider.id)") ?? provider.defaultModel,
                        apiKey: key(for: provider.id))
    }

    public func save(_ config: AIConfig) {
        defaults.set(config.providerID, forKey: "ai.provider")
        defaults.set(config.baseURL, forKey: "ai.baseURL.\(config.providerID)")
        defaults.set(config.model, forKey: "ai.model.\(config.providerID)")
        setKey(config.apiKey, for: config.providerID)
    }

    /// The models a service listed the last time they were fetched.
    public func fetchedModels(for providerID: String) -> [String] {
        defaults.stringArray(forKey: "ai.models.\(providerID)") ?? []
    }

    public func setFetchedModels(_ models: [String], for providerID: String) {
        defaults.set(models, forKey: "ai.models.\(providerID)")
    }

    /// The models that answered the last time they were tried.
    public func workingModels(for providerID: String) -> [String] {
        defaults.stringArray(forKey: "ai.working.\(providerID)") ?? []
    }

    public func setWorkingModels(_ models: [String], for providerID: String) {
        defaults.set(models, forKey: "ai.working.\(providerID)")
    }

    /// The config a service would start with, as if it was just picked.
    public func config(for providerID: String) -> AIConfig {
        let provider = AIProviders.provider(id: providerID)
        return AIConfig(providerID: provider.id,
                        baseURL: defaults.string(forKey: "ai.baseURL.\(provider.id)") ?? provider.baseURL,
                        model: defaults.string(forKey: "ai.model.\(provider.id)") ?? provider.defaultModel,
                        apiKey: key(for: provider.id))
    }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: id]
    }

    func key(for id: String) -> String {
        var search = query(id)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func setKey(_ key: String, for id: String) {
        SecItemDelete(query(id) as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query(id)
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

public struct AIError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Talks to a chat service and hands back the answer piece by piece as it is written.
public final class AIClient {
    private let config: AIConfig
    private let session: URLSession

    public init(config: AIConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private var base: String {
        var text = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: Requests

    func chatRequest(_ messages: [AIMessage], stream: Bool, maxTokens: Int? = nil) throws -> URLRequest {
        let kind = config.provider.kind
        let path = kind == .anthropic ? "/v1/messages" : "/chat/completions"
        guard let url = URL(string: base + path), url.scheme != nil else { throw AIError("The address is not valid: \(config.baseURL)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": config.model, "stream": stream]
        switch kind {
        case .openAI:
            if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
            body["messages"] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
            if let maxTokens { body["max_tokens"] = maxTokens }
        case .anthropic:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            if !system.isEmpty { body["system"] = system }
            body["messages"] = messages.filter { $0.role != .system }.map { ["role": $0.role.rawValue, "content": $0.content] }
            body["max_tokens"] = maxTokens ?? 4096
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func modelsRequest() throws -> URLRequest {
        let path = config.provider.kind == .anthropic ? "/v1/models" : "/models"
        guard let url = URL(string: base + path), url.scheme != nil else { throw AIError("The address is not valid: \(config.baseURL)") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        switch config.provider.kind {
        case .openAI:
            if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    // MARK: Reading answers

    /// The text a streamed line adds, or nil for lines that carry none (comments, other events, the end marker).
    public static func delta(fromLine line: String, kind: AIKind) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        switch kind {
        case .openAI:
            let choices = json["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            return delta?["content"] as? String
        case .anthropic:
            guard json["type"] as? String == "content_block_delta" else { return nil }
            return (json["delta"] as? [String: Any])?["text"] as? String
        }
    }

    /// The message a service gives for an error, in its own words when it sent one.
    static func errorMessage(status: Int, body: Data) -> String {
        let parsed = try? JSONSerialization.jsonObject(with: body)
        // Gemini wraps its error in a list, the others send the object itself.
        let json = (parsed as? [String: Any]) ?? (parsed as? [[String: Any]])?.first
        var message: String?
        if let json {
            if let error = json["error"] as? [String: Any] { message = error["message"] as? String }
            else if let error = json["error"] as? String { message = error }
            else { message = json["message"] as? String }
        }
        if message == nil {
            let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            message = text.isEmpty ? "The service answered with error \(status)." : text
        }
        // The first line says it; the rest is usually links and a table of limits.
        var short = message?.components(separatedBy: "\n").first ?? ""
        if short.count > 240 { short = String(short.prefix(240)) + "…" }
        var text = "\(short) (\(status))"
        if status == 429 { text += "\nThe limit for this model is used up, or the free tier does not include it for your key. Try another model (Settings, Load list) or another service." }
        if status == 401 || status == 403 { text += "\nCheck the key in Settings." }
        if status == 404 { text += "\nThe model may have been retired. Pick a current one in Settings with Load list." }
        return text
    }

    private func friendly(_ error: Error) -> Error {
        let code = (error as NSError).code
        guard (error as NSError).domain == NSURLErrorDomain else { return error }
        switch code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
            let local = base.contains("localhost") || base.contains("127.0.0.1")
            return AIError(local ? "Could not reach \(base). Is the server running?" : "Could not reach \(base). Check the address and your connection.")
        case NSURLErrorTimedOut:
            return AIError("The service did not answer in time.")
        case NSURLErrorNotConnectedToInternet:
            return AIError("There is no internet connection.")
        case NSURLErrorCancelled:
            return CancellationError()
        default:
            return error
        }
    }

    /// The answer, as it arrives. Cancelling the task stops the request.
    public func stream(_ messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try chatRequest(messages, stream: true)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 4000 { break } }
                        throw AIError(Self.errorMessage(status: http.statusCode, body: body))
                    }
                    let kind = config.provider.kind
                    for try await line in bytes.lines {
                        if let piece = Self.delta(fromLine: line, kind: kind) { continuation.yield(piece) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole answer at once, for short jobs like a test.
    public func complete(_ messages: [AIMessage]) async throws -> String {
        var text = ""
        for try await piece in stream(messages) { text += piece }
        return text
    }

    /// Only models that can chat, named the way a request wants them: Gemini lists "models/gemini-…" but takes "gemini-…".
    public static func chatModels(_ ids: [String], provider: String = "") -> [String] {
        let skip = ["embed", "tts", "whisper", "imagen", "veo", "guard", "moderation", "aqa", "transcribe", "dall-e", "image", "audio",
                    "live", "lyria", "robotics", "deep-research", "computer-use", "omni", "nano-banana", "genie", "antigravity", "customtools"]
        var names = ids.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        names = names.filter { name in !skip.contains { name.lowercased().contains($0) } }
        switch provider {
        case "gemini":
            // Google lists music, robotics, voice and test models next to the chat ones: only gemini-N-flash/pro, the -latest names and Gemma stay.
            let chat = #"^(gemini-\d+(\.\d+)?-(flash|pro)(-lite)?(-preview)?|gemini-(flash|pro)(-lite)?-latest|gemma-[\w.-]+-it)$"#
            names = names.filter { $0.range(of: chat, options: .regularExpression) != nil }
        case "openrouter":
            names = names.filter { $0.hasSuffix(":free") }
        default:
            break
        }
        return Array(Set(names)).sorted()
    }

    /// The models the service offers, for the settings list.
    public func models() async throws -> [String] {
        do {
            let (data, response) = try await session.data(for: try modelsRequest())
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw AIError(Self.errorMessage(status: http.statusCode, body: data))
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let list = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            return Self.chatModels(list, provider: config.providerID)
        } catch {
            throw friendly(error)
        }
    }

    // MARK: Trying models

    /// True when the service answers a tiny request with this model, so quota and retired names show up before they get in the way.
    public func answers() async -> Bool {
        do {
            var request = try chatRequest([AIMessage(.user, "Reply with OK")], stream: false, maxTokens: 16)
            request.timeoutInterval = 25
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// The models among `candidates` that answer, in the order given. Four are tried at a time.
    public static func working(among candidates: [String], config: AIConfig, session: URLSession = .shared, limit: Int = 24, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [String] {
        let tried = Array(candidates.prefix(limit))
        var works: [String: Bool] = [:]
        var done = 0
        var index = 0
        while index < tried.count {
            let batch = Array(tried[index..<min(index + 4, tried.count)])
            index += batch.count
            await withTaskGroup(of: (String, Bool).self) { group in
                for model in batch {
                    var copy = config
                    copy.model = model
                    group.addTask { (model, await AIClient(config: copy, session: session).answers()) }
                }
                for await (model, ok) in group {
                    works[model] = ok
                    done += 1
                    progress?(done, tried.count)
                }
            }
        }
        return tried.filter { works[$0] == true }
    }
}
