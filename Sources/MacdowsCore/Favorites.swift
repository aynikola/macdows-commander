import Foundation

/// A favorite folder: local when `siteID` is nil, otherwise on a saved server.
public struct FavoriteFolder: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var path: String
    public var siteID: UUID?

    public init(name: String, path: String, siteID: UUID?) {
        self.name = name
        self.path = path
        self.siteID = siteID
    }
}

/// Saved in UserDefaults, read again on every use so all open app instances see the same list.
public final class FavoritesStore {
    private static let key = "favorites.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [FavoriteFolder] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([FavoriteFolder].self, from: data)) ?? []
    }

    private func save(_ favorites: [FavoriteFolder]) {
        if let data = try? JSONEncoder().encode(favorites) { defaults.set(data, forKey: Self.key) }
    }

    public func find(path: String, siteID: UUID?) -> FavoriteFolder? {
        load().first { $0.path == path && $0.siteID == siteID }
    }

    /// Named after the folder. Adding a folder twice keeps the one entry.
    @discardableResult
    public func add(path: String, siteID: UUID?) -> FavoriteFolder {
        if let existing = find(path: path, siteID: siteID) { return existing }
        let last = (path as NSString).lastPathComponent
        let favorite = FavoriteFolder(name: last.isEmpty ? path : last, path: path, siteID: siteID)
        save(load() + [favorite])
        return favorite
    }

    public func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }
}
