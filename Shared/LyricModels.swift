import Foundation

enum SharedConfig {
    static let appGroup = "group.com.ikun.LyricDock"
    static let snapshotKey = "playbackSnapshot"
    static let appearanceKey = "appearancePreferences"
    static let widgetKind = "LyricDockWidget"
}

enum PlaybackState: String, Codable, Sendable {
    case playing
    case paused
    case stopped

    var displayName: String {
        switch self {
        case .playing:
            return "播放中"
        case .paused:
            return "已暂停"
        case .stopped:
            return "未播放"
        }
    }

    var isPlaying: Bool {
        self == .playing
    }
}

struct TrackMetadata: Codable, Hashable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    var normalizedIdentity: String {
        [title, artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }

    var subtitle: String {
        [artist, album]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var displayText: String {
        if artist.isEmpty {
            return title
        }

        return "\(title) · \(artist)"
    }
}

struct LyricLine: Codable, Hashable, Identifiable, Sendable {
    let time: TimeInterval
    let text: String

    var id: String {
        "\(Int(time * 1000))-\(text)"
    }
}

struct LyricWindow: Equatable, Sendable {
    let current: String
    let next: String?
    let caption: String
}

struct PlaybackSnapshot: Codable, Equatable, Sendable {
    let track: TrackMetadata?
    let state: PlaybackState
    let position: TimeInterval
    let updatedAt: Date
    let sourceBundleIdentifier: String?
    let lyrics: [LyricLine]
    let plainLyrics: String?
    let lyricSource: String
    private static let lyricLeadTime: TimeInterval = 0.36

    static let empty = PlaybackSnapshot(
        track: nil,
        state: .stopped,
        position: 0,
        updatedAt: .distantPast,
        sourceBundleIdentifier: nil,
        lyrics: [],
        plainLyrics: nil,
        lyricSource: "等待播放器",
    )

    func playbackTime(at date: Date) -> TimeInterval {
        let rawValue: TimeInterval
        if state.isPlaying {
            rawValue = position + max(0, date.timeIntervalSince(updatedAt))
        } else {
            rawValue = position
        }

        guard let track, track.duration > 0 else {
            return max(0, rawValue)
        }
        return min(max(0, rawValue), track.duration)
    }

    func lyricWindow(at date: Date) -> LyricWindow {
        guard let track else {
            return LyricWindow(
                current: "等待播放器开始播放",
                next: "LyricDock 会在这里显示实时歌词",
                caption: "未连接到播放内容",
            )
        }

        let progress = playbackTime(at: date)
        let lyricProgress = lyricPlaybackTime(at: date)

        if let index = activeLyricIndex(at: date) {
            let currentLine = lyrics[index]
            let nextLine = lyrics.indices.contains(index + 1) ? lyrics[index + 1].text : nil
            return LyricWindow(
                current: currentLine.text,
                next: nextLine,
                caption: "\(track.title) · \(formatted(progress))/\(formatted(track.duration))",
            )
        }

        if let firstLine = lyrics.first, lyricProgress < firstLine.time {
            let nextLine = lyrics.indices.contains(1) ? lyrics[1].text : nil
            let countdown = max(0, firstLine.time - lyricProgress)
            return LyricWindow(
                current: firstLine.text,
                next: nextLine,
                caption: "前奏中 · \(formatted(countdown)) 后进入首句",
            )
        }

        if let plainLyrics, !plainLyrics.isEmpty {
            let lines = plainLyrics
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let current = lines.first ?? "歌词已加载"
            let next = lines.dropFirst().first
            return LyricWindow(
                current: current,
                next: next,
                caption: "\(track.title) · 非逐字同步歌词",
            )
        }

        let currentText: String
        if lyricSource == "正在查找歌词…" {
            currentText = track.title
        } else if lyricSource.contains("暂未命中") {
            currentText = "暂未找到歌词"
        } else if lyricSource.contains("纯音乐") {
            currentText = "纯音乐"
        } else if lyricSource.hasPrefix("歌词加载失败") {
            currentText = "歌词加载失败"
        } else {
            currentText = track.title
        }

        return LyricWindow(
            current: currentText,
            next: track.subtitle.isEmpty ? nil : track.subtitle,
            caption: lyricSource,
        )
    }

    func activeLyricIndex(at date: Date) -> Int? {
        guard !lyrics.isEmpty else {
            return nil
        }

        let currentTime = lyricPlaybackTime(at: date)
        return lyrics.lastIndex { $0.time <= currentTime }
    }

    func timelineDates(from date: Date, limit: Int = 40) -> [Date] {
        guard state.isPlaying, !lyrics.isEmpty else {
            return [date]
        }

        let currentTime = lyricPlaybackTime(at: date)
        let futureDates = lyrics
            .filter { $0.time >= currentTime }
            .prefix(limit)
            .map { date.addingTimeInterval($0.time - currentTime) }

        return futureDates.isEmpty ? [date] : [date] + futureDates
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else {
            return "0:00"
        }

        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func lyricPlaybackTime(at date: Date) -> TimeInterval {
        let baseTime = playbackTime(at: date)
        guard state.isPlaying else {
            return baseTime
        }

        guard let track, track.duration > 0 else {
            return max(0, baseTime + Self.lyricLeadTime)
        }

        return min(track.duration, max(0, baseTime + Self.lyricLeadTime))
    }
}

struct LyricsPayload: Codable, Equatable, Sendable {
    let syncedLines: [LyricLine]
    let plainText: String?
    let source: String

    var hasRenderableLyrics: Bool {
        if !syncedLines.isEmpty {
            return true
        }

        guard let plainText else {
            return false
        }

        return !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
