import AppKit
import Foundation

@MainActor
final class PlayerMonitor: ObservableObject {
    @Published private(set) var snapshot: PlaybackSnapshot
    @Published private(set) var statusMessage: String

    private let sharedStore = SharedSnapshotStore()
    private let lyricsService = LRCLyricsService()
    private let lyricCacheStore = LyricCacheStore()
    private var distributedNotificationObserver: Any?
    private var mediaRemoteObservation: AppleMusicPlaybackObservation?
    private var workspaceObservers: [Any] = []
    private var refreshTimer: Timer?
    private var lyricCache: [String: LyricsPayload] = [:]
    private var lyricLoadTask: Task<Void, Never>?
    private var lyricLoadIdentity: String?
    private var latestRefreshID: UInt64 = 0

    init() {
        snapshot = sharedStore.load() ?? .empty
        statusMessage = "等待连接到系统正在播放内容"
    }

    func start() {
        guard distributedNotificationObserver == nil else {
            return
        }

        distributedNotificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.iTunes.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefreshBurst(reason: "播放器状态变化")
            }
        }

        mediaRemoteObservation = try? AppleMusicScriptBridge.observeNowPlayingChanges { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefreshBurst(reason: "系统媒体状态变化")
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefreshBurst(reason: "应用切换")
                }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefreshBurst(reason: "应用启动")
                }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefreshBurst(reason: "应用退出")
                }
            },
        ]

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { await self?.refresh(reason: "兜底同步") }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        scheduleRefreshBurst(reason: "启动")
    }

    func stop() {
        if let distributedNotificationObserver {
            DistributedNotificationCenter.default().removeObserver(distributedNotificationObserver)
            self.distributedNotificationObserver = nil
        }
        mediaRemoteObservation?.stop()
        mediaRemoteObservation = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        lyricLoadTask?.cancel()
        lyricLoadTask = nil
        lyricLoadIdentity = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func manualRefresh() {
        Task { await refresh(reason: "手动刷新", forceLyricReload: true) }
    }

    func previousTrack() {
        performTransportCommand(.previousTrack, reason: "上一首")
    }

    func togglePlayPause() {
        performTransportCommand(.playPause, reason: "播放状态切换")
    }

    func nextTrack() {
        performTransportCommand(.nextTrack, reason: "下一首")
    }

    func openCurrentPlayerApp() {
        guard let bundleIdentifier = snapshot.sourceBundleIdentifier else {
            NSSound.beep()
            return
        }

        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            runningApp.activate(options: [.activateAllWindows])
            return
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    private func refresh(reason: String, forceLyricReload: Bool = false) async {
        latestRefreshID &+= 1
        let refreshID = latestRefreshID

        do {
            let playback = try await AppleMusicScriptBridge.fetchNowPlaying()
            await apply(playback: playback, reason: reason, forceLyricReload: forceLyricReload, refreshID: refreshID)
        } catch {
            guard refreshID == latestRefreshID else {
                return
            }
            statusMessage = "无法读取系统正在播放内容：\(error.localizedDescription)"
        }
    }

    private func apply(
        playback: AppleMusicPlayback,
        reason: String,
        forceLyricReload: Bool = false,
        refreshID: UInt64
    ) async {
        guard refreshID == latestRefreshID else {
            return
        }

        let immediatePayload = immediateLyricsPayload(for: playback.track, forceReload: forceLyricReload)
        let newSnapshot = PlaybackSnapshot(
            track: playback.track,
            state: playback.state,
            position: playback.position,
            updatedAt: playback.updatedAt,
            sourceBundleIdentifier: playback.sourceBundleIdentifier,
            lyrics: immediatePayload.syncedLines,
            plainLyrics: immediatePayload.plainText,
            lyricSource: immediatePayload.source,
        )

        snapshot = newSnapshot
        statusMessage = statusText(for: newSnapshot, reason: reason)
        sharedStore.save(newSnapshot)

        guard let track = playback.track else {
            return
        }

        guard !isUnavailableTrackPlaceholder(track) else {
            return
        }

        let trackIdentity = track.normalizedIdentity
        if forceLyricReload || lyricLoadIdentity != trackIdentity {
            lyricLoadTask?.cancel()
            lyricLoadTask = nil
            lyricLoadIdentity = nil
        }

        let shouldFetchLyrics = forceLyricReload || !hasResolvedLyrics(for: track)
        guard shouldFetchLyrics else {
            return
        }

        if lyricLoadIdentity == trackIdentity, lyricLoadTask != nil {
            return
        }

        lyricLoadIdentity = trackIdentity

        lyricLoadTask = Task { [weak self] in
            guard let self else {
                return
            }

            let payload = await self.resolveLyrics(for: track, forceReload: forceLyricReload)
            await MainActor.run {
                defer {
                    if self.lyricLoadIdentity == trackIdentity {
                        self.lyricLoadTask = nil
                        self.lyricLoadIdentity = nil
                    }
                }

                guard
                    self.snapshot.track?.normalizedIdentity == trackIdentity
                else {
                    return
                }

                let updatedSnapshot = PlaybackSnapshot(
                    track: self.snapshot.track,
                    state: self.snapshot.state,
                    position: self.snapshot.position,
                    updatedAt: self.snapshot.updatedAt,
                    sourceBundleIdentifier: self.snapshot.sourceBundleIdentifier,
                    lyrics: payload.syncedLines,
                    plainLyrics: payload.plainText,
                    lyricSource: payload.source,
                )

                self.snapshot = updatedSnapshot
                self.statusMessage = self.statusText(for: updatedSnapshot, reason: reason)
                self.sharedStore.save(updatedSnapshot)
            }
        }
    }

    private func resolveLyrics(for track: TrackMetadata?, forceReload: Bool = false) async -> LyricsPayload {
        guard let track else {
            return LyricsPayload(syncedLines: [], plainText: nil, source: "没有活动歌曲")
        }

        let cacheKey = track.normalizedIdentity
        if !forceReload, let cached = lyricCache[cacheKey] {
            return cached
        }

        if !forceReload, let cachedFromDisk = await lyricCacheStore.cachedPayload(for: cacheKey) {
            lyricCache[cacheKey] = cachedFromDisk
            return cachedFromDisk
        }

        do {
            let payload = try await lyricsService.fetchLyrics(for: track)
            lyricCache[cacheKey] = payload
            await lyricCacheStore.save(payload, for: cacheKey)
            return payload
        } catch {
            let failurePayload = LyricsPayload(
                syncedLines: [],
                plainText: nil,
                source: "歌词加载失败：\(error.localizedDescription)",
            )
            lyricCache[cacheKey] = failurePayload
            return failurePayload
        }
    }

    private func statusText(for snapshot: PlaybackSnapshot, reason: String) -> String {
        if let track = snapshot.track {
            if isUnavailableTrackPlaceholder(track) {
                return "\(reason)：\(track.title) · 当前播放器没有公开曲目信息"
            }

            let lyricState: String
            if !snapshot.lyrics.isEmpty {
                lyricState = "已载入 \(snapshot.lyrics.count) 行同步歌词"
            } else if let plainLyrics = snapshot.plainLyrics, !plainLyrics.isEmpty {
                lyricState = "已载入普通歌词"
            } else {
                lyricState = snapshot.lyricSource
            }

            return "\(reason)：\(track.title) - \(track.artist) · \(lyricState)"
        }

        return "\(reason)：等待系统开始播放"
    }

    private func performTransportCommand(_ command: AppleMusicTransportCommand, reason: String) {
        let preferredBundleIdentifier = snapshot.sourceBundleIdentifier
        applyOptimisticTransportState(command)

        Task {
            do {
                try await AppleMusicScriptBridge.send(command, preferredBundleIdentifier: preferredBundleIdentifier)
                scheduleRefreshBurst(reason: reason, delays: [0, 80_000_000, 220_000_000, 480_000_000])
            } catch {
                statusMessage = "播放控制失败：\(error.localizedDescription)"
                await refresh(reason: "回滚状态")
            }
        }
    }

    private func scheduleRefreshBurst(reason: String) {
        scheduleRefreshBurst(reason: reason, delays: [0, 80_000_000, 240_000_000, 520_000_000])
    }

    private func scheduleRefreshBurst(reason: String, delays: [UInt64]) {
        for delay in delays {
            Task { [weak self] in
                guard let self else {
                    return
                }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                await self.refresh(reason: reason)
            }
        }
    }

    private func applyOptimisticTransportState(_ command: AppleMusicTransportCommand) {
        switch command {
        case .playPause:
            statusMessage = snapshot.state == .playing ? "正在暂停…" : "正在播放…"
        case .nextTrack, .previousTrack:
            statusMessage = "正在切换歌曲…"
        }
    }

    private func immediateLyricsPayload(for track: TrackMetadata?, forceReload: Bool) -> LyricsPayload {
        guard let track else {
            return LyricsPayload(syncedLines: [], plainText: nil, source: "没有活动歌曲")
        }

        if isUnavailableTrackPlaceholder(track) {
            return LyricsPayload(
                syncedLines: [],
                plainText: nil,
                source: "当前播放器没有公开歌词与曲目信息"
            )
        }

        if !forceReload,
           snapshot.track?.normalizedIdentity == track.normalizedIdentity,
           (!snapshot.lyrics.isEmpty || !(snapshot.plainLyrics ?? "").isEmpty) {
            return LyricsPayload(
                syncedLines: snapshot.lyrics,
                plainText: snapshot.plainLyrics,
                source: snapshot.lyricSource
            )
        }

        if !forceReload, let cached = lyricCache[track.normalizedIdentity] {
            return cached
        }

        return LyricsPayload(syncedLines: [], plainText: nil, source: "正在查找歌词…")
    }

    private func hasResolvedLyrics(for track: TrackMetadata) -> Bool {
        if isUnavailableTrackPlaceholder(track) {
            return true
        }

        if snapshot.track?.normalizedIdentity == track.normalizedIdentity {
            return !snapshot.lyrics.isEmpty
                || !(snapshot.plainLyrics ?? "").isEmpty
                || snapshot.lyricSource != "正在查找歌词…"
        }

        guard let cached = lyricCache[track.normalizedIdentity] else {
            return false
        }
        return cached.hasRenderableLyrics || cached.source != "正在查找歌词…"
    }

    private func isUnavailableTrackPlaceholder(_ track: TrackMetadata) -> Bool {
        track.artist == AppleMusicScriptBridge.unavailableTrackArtist
    }
}
