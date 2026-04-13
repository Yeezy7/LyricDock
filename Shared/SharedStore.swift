import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

struct SharedSnapshotStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? SharedStorageResolver.sharedDefaults()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> PlaybackSnapshot? {
        guard let data = defaults.data(forKey: SharedConfig.snapshotKey) else {
            return nil
        }
        return try? decoder.decode(PlaybackSnapshot.self, from: data)
    }

    func save(_ snapshot: PlaybackSnapshot, reloadWidgets: Bool = true) {
        guard let data = try? encoder.encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: SharedConfig.snapshotKey)
        #if canImport(WidgetKit)
        if reloadWidgets {
            WidgetCenter.shared.reloadTimelines(ofKind: SharedConfig.widgetKind)
        }
        #endif
    }
}
