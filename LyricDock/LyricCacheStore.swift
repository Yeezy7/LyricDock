import Foundation

actor LyricCacheStore {
    private struct CachedLyricsEntry: Codable, Sendable {
        let payload: LyricsPayload
        let cachedAt: Date
    }

    private let cacheLifetime: TimeInterval = 60 * 60 * 24 * 14
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cacheURL: URL
    private var cache: [String: CachedLyricsEntry]

    init() {
        cacheURL = LyricCacheStore.makeCacheURL(fileManager: fileManager)
        cache = LyricCacheStore.loadCache(at: cacheURL, decoder: decoder)
    }

    func cachedPayload(for key: String) -> LyricsPayload? {
        purgeExpiredEntriesIfNeeded()
        guard let entry = cache[key] else {
            return nil
        }
        return entry.payload
    }

    func save(_ payload: LyricsPayload, for key: String) {
        cache[key] = CachedLyricsEntry(payload: payload, cachedAt: Date())
        persist()
    }

    private func purgeExpiredEntriesIfNeeded() {
        let now = Date()
        let originalCount = cache.count
        cache = cache.filter { now.timeIntervalSince($0.value.cachedAt) < cacheLifetime }
        if cache.count != originalCount {
            persist()
        }
    }

    private func persist() {
        let directory = cacheURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        guard let data = try? encoder.encode(cache) else {
            return
        }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func makeCacheURL(fileManager: FileManager) -> URL {
        if let groupURL = SharedStorageResolver.sharedContainerURL(fileManager: fileManager) {
            return groupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("LyricDock", isDirectory: true)
                .appendingPathComponent("lyrics-cache.json", isDirectory: false)
        }

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return baseURL
            .appendingPathComponent("LyricDock", isDirectory: true)
            .appendingPathComponent("lyrics-cache.json", isDirectory: false)
    }

    private static func loadCache(at url: URL, decoder: JSONDecoder) -> [String: CachedLyricsEntry] {
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? decoder.decode([String: CachedLyricsEntry].self, from: data)
        else {
            return [:]
        }
        return decoded
    }
}
