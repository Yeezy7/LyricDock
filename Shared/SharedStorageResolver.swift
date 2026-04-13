import Foundation

enum SharedStorageMode: Sendable {
    case appGroup
    case localFallback

    var displayName: String {
        switch self {
        case .appGroup:
            return "App Group 共享"
        case .localFallback:
            return "本地模式"
        }
    }

    var detail: String {
        switch self {
        case .appGroup:
            return "主应用、菜单栏与 Widget 会共享播放快照和外观设置。"
        case .localFallback:
            return "当前优先保证主应用与菜单栏稳定运行，Widget 共享需后续重新配置 App Group。"
        }
    }
}

enum SharedStorageResolver {
    static func sharedDefaults() -> UserDefaults {
        guard hasAppGroupAccess() else {
            return .standard
        }

        return UserDefaults(suiteName: SharedConfig.appGroup) ?? .standard
    }

    static func sharedContainerURL(fileManager: FileManager = .default) -> URL? {
        guard hasAppGroupAccess(fileManager: fileManager) else {
            return nil
        }

        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedConfig.appGroup)
    }

    static var storageMode: SharedStorageMode {
        hasAppGroupAccess() ? .appGroup : .localFallback
    }

    private static func hasAppGroupAccess(fileManager: FileManager = .default) -> Bool {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedConfig.appGroup) != nil
    }
}
