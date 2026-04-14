import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppearanceSettings: ObservableObject {
    @Published private(set) var preferences: AppearancePreferences

    private let store = SharedAppearanceStore()

    init() {
        preferences = store.load()
    }

    func updateTheme(_ value: LyricTheme) {
        preferences.theme = value
        persist()
    }

    func updatePanelOpacity(_ value: Double) {
        preferences.panelOpacity = value
        persist()
    }

    func updateLyricScale(_ value: Double) {
        preferences.lyricScale = value
        persist()
    }

    func updateShowNextLine(_ value: Bool) {
        preferences.showNextLine = value
        persist()
    }

    func updateMenuBarPreferLyrics(_ value: Bool) {
        preferences.menuBarPreferLyrics = value
        persist()
    }

    func updateMenuBarWidth(_ value: Double) {
        preferences.menuBarWidth = value
        persist()
    }

    func updateMenuBarTextLimit(_ value: Double) {
        preferences.menuBarTextLimit = value
        persist()
    }

    func updateAutomaticallyChecksForUpdates(_ value: Bool) {
        preferences.automaticallyChecksForUpdates = value
        persist()
    }

    func updatePanelLocked(_ value: Bool) {
        preferences.panelLocked = value
        persist()
    }

    func updateCustomPanelOrigin(_ point: CGPoint) {
        preferences.customPanelOrigin = PanelOrigin(point: point)
        persist()
    }

    func resetPanelPosition() {
        preferences.customPanelOrigin = nil
        persist()
    }

    func reset() {
        preferences = .default
        persist()
    }

    private func persist() {
        store.save(preferences)
    }
}
