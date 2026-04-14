import Foundation
import CoreGraphics
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

enum LyricTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case sunrise
    case tide
    case ember

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sunrise:
            return "晨曦"
        case .tide:
            return "海潮"
        case .ember:
            return "余烬"
        }
    }

    var palette: LyricThemePalette {
        switch self {
        case .sunrise:
            return LyricThemePalette(
                backgroundTop: Color(red: 0.98, green: 0.63, blue: 0.42),
                backgroundBottom: Color(red: 0.94, green: 0.87, blue: 0.74),
                cardTop: Color(red: 0.49, green: 0.19, blue: 0.16),
                cardBottom: Color(red: 0.78, green: 0.39, blue: 0.24),
                accent: Color(red: 1.00, green: 0.91, blue: 0.74),
                primaryText: Color.white,
                secondaryText: Color.white.opacity(0.78),
                chrome: Color.black.opacity(0.18),
            )
        case .tide:
            return LyricThemePalette(
                backgroundTop: Color(red: 0.19, green: 0.42, blue: 0.57),
                backgroundBottom: Color(red: 0.75, green: 0.88, blue: 0.88),
                cardTop: Color(red: 0.08, green: 0.20, blue: 0.29),
                cardBottom: Color(red: 0.16, green: 0.42, blue: 0.49),
                accent: Color(red: 0.76, green: 0.95, blue: 0.94),
                primaryText: Color.white,
                secondaryText: Color.white.opacity(0.75),
                chrome: Color.black.opacity(0.22),
            )
        case .ember:
            return LyricThemePalette(
                backgroundTop: Color(red: 0.21, green: 0.10, blue: 0.12),
                backgroundBottom: Color(red: 0.71, green: 0.26, blue: 0.17),
                cardTop: Color(red: 0.14, green: 0.08, blue: 0.08),
                cardBottom: Color(red: 0.35, green: 0.13, blue: 0.09),
                accent: Color(red: 1.00, green: 0.76, blue: 0.54),
                primaryText: Color.white,
                secondaryText: Color.white.opacity(0.72),
                chrome: Color.white.opacity(0.14),
            )
        }
    }
}

struct LyricThemePalette {
    let backgroundTop: Color
    let backgroundBottom: Color
    let cardTop: Color
    let cardBottom: Color
    let accent: Color
    let primaryText: Color
    let secondaryText: Color
    let chrome: Color

    var backgroundGradient: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var cardGradient: LinearGradient {
        LinearGradient(colors: [cardTop, cardBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct PanelOrigin: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct AppearancePreferences: Codable, Equatable, Sendable {
    var theme: LyricTheme
    var panelOpacity: Double
    var lyricScale: Double
    var showNextLine: Bool
    var menuBarPreferLyrics: Bool
    var menuBarWidth: Double
    var menuBarTextLimit: Double
    var automaticallyChecksForUpdates: Bool
    var panelLocked: Bool
    var customPanelOrigin: PanelOrigin?

    static let `default` = AppearancePreferences(
        theme: .sunrise,
        panelOpacity: 0.92,
        lyricScale: 1.0,
        showNextLine: true,
        menuBarPreferLyrics: true,
        menuBarWidth: 360,
        menuBarTextLimit: 18,
        automaticallyChecksForUpdates: false,
        panelLocked: false,
        customPanelOrigin: nil,
    )

    enum CodingKeys: String, CodingKey {
        case theme
        case panelOpacity
        case lyricScale
        case showNextLine
        case menuBarPreferLyrics
        case menuBarWidth
        case menuBarTextLimit
        case automaticallyChecksForUpdates
        case panelLocked
        case customPanelOrigin
    }

    init(
        theme: LyricTheme,
        panelOpacity: Double,
        lyricScale: Double,
        showNextLine: Bool,
        menuBarPreferLyrics: Bool,
        menuBarWidth: Double,
        menuBarTextLimit: Double,
        automaticallyChecksForUpdates: Bool,
        panelLocked: Bool,
        customPanelOrigin: PanelOrigin?
    ) {
        self.theme = theme
        self.panelOpacity = panelOpacity
        self.lyricScale = lyricScale
        self.showNextLine = showNextLine
        self.menuBarPreferLyrics = menuBarPreferLyrics
        self.menuBarWidth = menuBarWidth
        self.menuBarTextLimit = menuBarTextLimit
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.panelLocked = panelLocked
        self.customPanelOrigin = customPanelOrigin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(LyricTheme.self, forKey: .theme) ?? .sunrise
        panelOpacity = try container.decodeIfPresent(Double.self, forKey: .panelOpacity) ?? 0.92
        lyricScale = try container.decodeIfPresent(Double.self, forKey: .lyricScale) ?? 1.0
        showNextLine = try container.decodeIfPresent(Bool.self, forKey: .showNextLine) ?? true
        menuBarPreferLyrics = try container.decodeIfPresent(Bool.self, forKey: .menuBarPreferLyrics) ?? true
        menuBarWidth = try container.decodeIfPresent(Double.self, forKey: .menuBarWidth) ?? 360
        menuBarTextLimit = try container.decodeIfPresent(Double.self, forKey: .menuBarTextLimit) ?? 18
        automaticallyChecksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates) ?? false
        panelLocked = try container.decodeIfPresent(Bool.self, forKey: .panelLocked) ?? false
        customPanelOrigin = try container.decodeIfPresent(PanelOrigin.self, forKey: .customPanelOrigin)
    }
}

struct SharedAppearanceStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? SharedStorageResolver.sharedDefaults()
    }

    func load() -> AppearancePreferences {
        guard let data = defaults.data(forKey: SharedConfig.appearanceKey) else {
            return .default
        }
        return (try? decoder.decode(AppearancePreferences.self, from: data)) ?? .default
    }

    func save(_ preferences: AppearancePreferences, reloadWidgets: Bool = true) {
        guard let data = try? encoder.encode(preferences) else {
            return
        }
        defaults.set(data, forKey: SharedConfig.appearanceKey)
        #if canImport(WidgetKit)
        if reloadWidgets {
            WidgetCenter.shared.reloadTimelines(ofKind: SharedConfig.widgetKind)
        }
        #endif
    }
}
