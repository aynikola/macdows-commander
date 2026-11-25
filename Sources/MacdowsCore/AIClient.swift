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
    public let needsKey: Bool
    /// One line for the settings: what it costs and where to get a key.
    public let note: String
    public let keyPage: String?
}

public enum AIProviders {
    public static let all: [AIProvider] = [
        AIProvider(id: "ollama", name: "Ollama (free, on this Mac)", kind: .openAI, baseURL: "http://localhost:11434/v1", defaultModel: "llama3.2", needsKey: false,
                   note: "Free and private: runs on this Mac. Install Ollama, then run: ollama pull llama3.2", keyPage: "https://ollama.com/download"),
        AIProvider(id: "openrouter", name: "OpenRouter (free models)", kind: .openAI, baseURL: "https://openrouter.ai/api/v1", defaultModel: "meta-llama/llama-3.3-70b-instruct:free", needsKey: true,
                   note: "Models ending in :free cost nothing. A free key is needed.", keyPage: "https://openrouter.ai/keys"),
        AIProvider(id: "groq", name: "Groq (free tier)", kind: .openAI, baseURL: "https://api.groq.com/openai/v1", defaultModel: "llama-3.3-70b-versatile", needsKey: true,
                   note: "Fast, with a free tier. A free key is needed.", keyPage: "https://console.groq.com/keys"),
        AIProvider(id: "gemini", name: "Google Gemini (free tier)", kind: .openAI, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-2.0-flash", needsKey: true,
                   note: "Has a free tier. A key from Google AI Studio is needed.", keyPage: "https://aistudio.google.com/apikey"),
        AIProvider(id: "anthropic", name: "Claude (Anthropic, paid)", kind: .anthropic, baseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-5-5", needsKey: true,
                   note: "Paid, by use. An API key is needed.", keyPage: "https://console.anthropic.com/settings/keys"),
        AIProvider(id: "custom", name: "Other (OpenAI compatible)", kind: .openAI, baseURL: "http://localhost:1234/v1", defaultModel: "", needsKey: false,
                   note: "Any server with the OpenAI chat API, such as LM Studio. A key is optional.", keyPage: nil),
    ]

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
        let id = defaults.string(forKey: "ai.provider") ?? "ollama"
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

    func chatRequest(_ messages: [AIMessage], stream: Bool) throws -> URLRequest {
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
        case .anthropic:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            if !system.isEmpty { body["system"] = system }
            body["messages"] = messages.filter { $0.role != .system }.map { ["role": $0.role.rawValue, "content": $0.content] }
            body["max_tokens"] = 4096
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
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return "\(message) (\(status))" }
            if let error = json["error"] as? String { return "\(error) (\(status))" }
            if let message = json["message"] as? String { return "\(message) (\(status))" }
        }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The service answered with error \(status)." : "\(text) (\(status))"
    }

    private func friendly(_ error: Error) -> Error {
        let code = (error as NSError).code
        guard (error as NSError).domain == NSURLErrorDomain else { return error }
        switch code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
            let local = base.contains("localhost") || base.contains("127.0.0.1")
            return AIError(local ? "Could not reach \(base). Is the server running? For Ollama, start the app or run: ollama serve" : "Could not reach \(base). Check the address and your connection.")
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

    /// The models the service offers, for the settings list.
    public func models() async throws -> [String] {
        do {
            let (data, response) = try await session.data(for: try modelsRequest())
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw AIError(Self.errorMessage(status: http.statusCode, body: data))
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let list = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            return list.sorted()
        } catch {
            throw friendly(error)
        }
    }
}
