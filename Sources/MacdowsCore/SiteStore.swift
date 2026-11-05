import Foundation
import Security

/// Saved servers. Settings live in UserDefaults; passwords live only in the Keychain.
public final class SiteStore {
    private static let key = "sites.v1"
    private static let service = "Macdows Commander"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [Site] {
        guard let data = defaults.data(forKey: SiteStore.key) else { return [] }
        return (try? JSONDecoder().decode([Site].self, from: data)) ?? []
    }

    public func save(_ sites: [Site]) {
        if let data = try? JSONEncoder().encode(sites) { defaults.set(data, forKey: SiteStore.key) }
    }

    /// The servers to pass through on the way to `site`, nearest to it first. A loop stops instead of hanging.
    public func hops(for site: Site) -> [SSHClient.Hop] {
        let sites = load()
        var result: [SSHClient.Hop] = []
        var seen = [site.id]
        var next = site.jumpSiteID
        while let id = next, !seen.contains(id), let hop = sites.first(where: { $0.id == id }), hop.proto == .ssh {
            result.append(SSHClient.Hop(site: hop, password: password(for: id)))
            seen.append(id)
            next = hop.jumpSiteID
        }
        return result
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: SiteStore.service,
         kSecAttrAccount as String: id.uuidString]
    }

    public func password(for id: UUID) -> String {
        var search = query(id)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func setPassword(_ password: String, for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        guard !password.isEmpty else { return }
        var add = query(id)
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
