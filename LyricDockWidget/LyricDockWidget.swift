import SwiftUI
import WidgetKit

struct LyricDockEntry: TimelineEntry {
    let date: Date
    let snapshot: PlaybackSnapshot
    let preferences: AppearancePreferences
}

struct LyricDockTimelineProvider: TimelineProvider {
    private let store = SharedSnapshotStore()
    private let appearanceStore = SharedAppearanceStore()

    func placeholder(in context: Context) -> LyricDockEntry {
        LyricDockEntry(date: .now, snapshot: .empty, preferences: .default)
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricDockEntry) -> Void) {
        completion(LyricDockEntry(
            date: .now,
            snapshot: store.load() ?? .empty,
            preferences: appearanceStore.load(),
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricDockEntry>) -> Void) {
        let snapshot = store.load() ?? .empty
        let preferences = appearanceStore.load()
        let dates = snapshot.timelineDates(from: .now)
        let entries = dates.map { LyricDockEntry(date: $0, snapshot: snapshot, preferences: preferences) }
        let nextRefresh = dates.last?.addingTimeInterval(3) ?? Date().addingTimeInterval(60)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }
}

struct LyricDockWidgetView: View {
    var entry: LyricDockTimelineProvider.Entry

    var body: some View {
        let lyricWindow = entry.snapshot.lyricWindow(at: entry.date)
        let palette = entry.preferences.theme.palette

        VStack(alignment: .leading, spacing: 10) {
            Text(entry.snapshot.track?.title ?? "LyricDock")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)

            Text(lyricWindow.current)
                .font(.system(
                    size: 20 * entry.preferences.lyricScale,
                    weight: .bold,
                    design: .rounded,
                ))
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .foregroundStyle(palette.primaryText)

            if entry.preferences.showNextLine, let next = lyricWindow.next {
                Text(next)
                    .font(.system(
                        size: 14 * entry.preferences.lyricScale,
                        weight: .medium,
                        design: .rounded,
                    ))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack {
                Image(systemName: entry.snapshot.state == .playing ? "music.note" : "pause.circle")
                Text(lyricWindow.caption)
            }
            .font(.caption2)
            .foregroundStyle(palette.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(palette.cardGradient, for: .widget)
    }
}

struct LyricDockWidget: Widget {
    let kind: String = SharedConfig.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LyricDockTimelineProvider()) { entry in
            LyricDockWidgetView(entry: entry)
        }
        .configurationDisplayName("桌面歌词")
        .description("显示当前歌词和下一句，跟随主应用同步。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct LyricDockWidgets: WidgetBundle {
    var body: some Widget {
        LyricDockWidget()
    }
}
