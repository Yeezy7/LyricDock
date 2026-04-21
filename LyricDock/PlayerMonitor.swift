import AppKit
import Foundation

private final class LyricsPayloadCacheWrapper: NSObject {
    let payload: LyricsPayload
    init(payload: LyricsPayload) {
        self.payload = payload
    }
}

private final class LyricsPayloadCache {
    private let cache = NSCache<NSString, LyricsPayloadCacheWrapper>()

    init() {
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    func payload(forKey key: String) -> LyricsPayload? {
        cache.object(forKey: key as NSString)?.payload
    }

    func setPayload(_ payload: LyricsPayload, forKey key: String) {
        cache.setObject(LyricsPayloadCacheWrapper(payload: payload), forKey: key as NSString)
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }
}

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
    private let lyricCache = LyricsPayloadCache()
    private var lyricLoadTask: Task<Void, Never>?
    private var lyricLoadIdentity: String?
    private var latestRefreshID: UInt64 = 0
    private var hasActivePlayer: Bool = false
    private var isPlaying: Bool = false
    private let activePlayerPlayingRefreshInterval: TimeInterval = 0.5
    private let activePlayerPausedRefreshInterval: TimeInterval = 2.0
    private let idleRefreshInterval: TimeInterval = 5.0
    private var lastPlaybackState: PlaybackState?
    private var lastTrackIdentity: String?

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

        setupRefreshTimer()
        scheduleRefreshBurst(reason: "启动")
    }
    
    private func setupRefreshTimer() {
        refreshTimer?.invalidate()
        let interval: TimeInterval
        if hasActivePlayer {
            interval = isPlaying ? activePlayerPlayingRefreshInterval : activePlayerPausedRefreshInterval
        } else {
            interval = idleRefreshInterval
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh(reason: "兜底同步") }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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

        // 检查是否需要更新 UI，只有在状态或曲目变化时才更新
        let trackIdentity = playback.track?.normalizedIdentity
        let stateChanged = playback.state != lastPlaybackState
        let trackChanged = trackIdentity != lastTrackIdentity
        
        if stateChanged || trackChanged {
            snapshot = newSnapshot
            statusMessage = statusText(for: newSnapshot, reason: reason)
            sharedStore.save(newSnapshot)
            
            lastPlaybackState = playback.state
            lastTrackIdentity = trackIdentity
        } else if abs(playback.position - snapshot.position) > 1.0
                    || abs(playback.updatedAt.timeIntervalSince(snapshot.updatedAt)) > 2.0 {
            snapshot = PlaybackSnapshot(
                track: snapshot.track,
                state: snapshot.state,
                position: playback.position,
                updatedAt: playback.updatedAt,
                sourceBundleIdentifier: snapshot.sourceBundleIdentifier,
                lyrics: snapshot.lyrics,
                plainLyrics: snapshot.plainLyrics,
                lyricSource: snapshot.lyricSource,
            )
        }
        
        // 检测是否有活动播放器并更新定时器频率
        let currentHasActivePlayer = playback.track != nil && !isUnavailableTrackPlaceholder(playback.track!)
        let currentIsPlaying = playback.state.isPlaying
        
        // 如果播放状态或活动播放器状态发生变化，更新定时器
        if currentHasActivePlayer != hasActivePlayer || currentIsPlaying != isPlaying {
            hasActivePlayer = currentHasActivePlayer
            isPlaying = currentIsPlaying
            setupRefreshTimer()
            
            // 当没有活动播放器时，清理内存缓存，减少内存占用
            if !hasActivePlayer {
                clearMemoryCache()
            }
        }

        guard let track = playback.track else {
            return
        }

        guard !isUnavailableTrackPlaceholder(track) else {
            return
        }

        let currentTrackIdentity = track.normalizedIdentity
        if forceLyricReload || lyricLoadIdentity != currentTrackIdentity {
            lyricLoadTask?.cancel()
            lyricLoadTask = nil
            lyricLoadIdentity = nil
        }

        let shouldFetchLyrics = forceLyricReload || !hasResolvedLyrics(for: track)
        guard shouldFetchLyrics else {
            return
        }

        if lyricLoadIdentity == currentTrackIdentity, lyricLoadTask != nil {
            return
        }

        lyricLoadIdentity = currentTrackIdentity

        lyricLoadTask = Task { [weak self] in
            guard let self else {
                return
            }

            let payload = await self.resolveLyrics(for: track, forceReload: forceLyricReload)
            await MainActor.run {
                defer {
                    if self.lyricLoadIdentity == currentTrackIdentity {
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
        if !forceReload, let cached = lyricCache.payload(forKey: cacheKey) {
            return cached
        }

        if !forceReload, let cachedFromDisk = await lyricCacheStore.cachedPayload(for: cacheKey) {
            addToMemoryCache(key: cacheKey, payload: cachedFromDisk)
            return cachedFromDisk
        }

        do {
            let payload = try await lyricsService.fetchLyrics(for: track)
            addToMemoryCache(key: cacheKey, payload: payload)
            await lyricCacheStore.save(payload, for: cacheKey)
            return payload
        } catch {
            let failurePayload = LyricsPayload(
                syncedLines: [],
                plainText: nil,
                source: "歌词加载失败：\(error.localizedDescription)",
            )
            addToMemoryCache(key: cacheKey, payload: failurePayload)
            return failurePayload
        }
    }
    
    private func addToMemoryCache(key: String, payload: LyricsPayload) {
        lyricCache.setPayload(payload, forKey: key)
    }
    
    private func clearMemoryCache() {
        lyricCache.removeAllObjects()
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

        if !forceReload, let cached = lyricCache.payload(forKey: track.normalizedIdentity) {
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

        guard let cached = lyricCache.payload(forKey: track.normalizedIdentity) else {
            return false
        }
        return cached.hasRenderableLyrics || cached.source != "正在查找歌词…"
    }

    private func isUnavailableTrackPlaceholder(_ track: TrackMetadata) -> Bool {
        track.artist == AppleMusicScriptBridge.unavailableTrackArtist
    }
}
