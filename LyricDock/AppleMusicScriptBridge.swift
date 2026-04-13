import AppKit
import Foundation
import ScreenCaptureKit
import Vision

struct AppleMusicPlayback: Sendable {
    let track: TrackMetadata?
    let state: PlaybackState
    let position: TimeInterval
    let updatedAt: Date
    let artworkData: Data?
    let sourceBundleIdentifier: String?
}

enum AppleMusicTransportCommand: Sendable {
    case previousTrack
    case playPause
    case nextTrack
}

final class AppleMusicPlaybackObservation {
    private let stopHandler: () -> Void
    private var isActive = true

    init(stopHandler: @escaping () -> Void) {
        self.stopHandler = stopHandler
    }

    deinit {
        stop()
    }

    func stop() {
        guard isActive else {
            return
        }

        isActive = false
        stopHandler()
    }
}

enum AppleMusicScriptBridge {
    private static let mediaRemoteAdapter = MediaRemoteAdapterController()
    private static let mediaRemote = try? MediaRemoteController()
    private static let musicBundleIdentifier = "com.apple.Music"
    private static let spotifyBundleIdentifier = "com.spotify.client"
    private static let sodaMusicBundleIdentifier = "com.soda.music"
    private static let neteaseMusicBundleIdentifier = "com.netease.163music"
    private static let qqMusicBundleIdentifier = "com.tencent.QQMusicMac"
    static let unavailableTrackArtist = "当前播放器未公开曲目信息"
    private static let supportedBundleIdentifiers: Set<String> = [
        musicBundleIdentifier,
        spotifyBundleIdentifier,
        sodaMusicBundleIdentifier,
        neteaseMusicBundleIdentifier,
        qqMusicBundleIdentifier,
    ]
    private static let mediaRemotePreferredBundleIdentifiers: Set<String> = [
        sodaMusicBundleIdentifier,
        neteaseMusicBundleIdentifier,
        qqMusicBundleIdentifier,
    ]

    private enum PlaybackSource {
        case appleMusic
        case spotify
        case mediaRemote
    }

    private struct PlaybackCandidate {
        let source: PlaybackSource
        let playback: AppleMusicPlayback
    }

    static func fetchNowPlaying() async throws -> AppleMusicPlayback {
        if let candidate = await adapterPlaybackCandidate() {
            return candidate.playback
        }

        if let candidate = await preferredPlaybackCandidate() {
            return candidate.playback
        }

        throw AppleMusicScriptError.noSupportedPlayerRunning
    }

    static func send(_ command: AppleMusicTransportCommand) async throws {
        try await send(command, preferredBundleIdentifier: nil)
    }

    static func send(_ command: AppleMusicTransportCommand, preferredBundleIdentifier: String?) async throws {
        if let preferredSource = playbackSource(for: preferredBundleIdentifier) {
            switch preferredSource {
            case .appleMusic:
                try await sendViaAppleScript(command)
                return
            case .spotify:
                try await sendViaSpotifyAppleScript(command)
                return
            case .mediaRemote:
                do {
                    try await mediaRemoteAdapter.send(command)
                    return
                } catch {
                }

                if let mediaRemote {
                    try mediaRemote.send(command)
                    return
                }
            }
        }

        if let source = await preferredPlaybackCandidate()?.source {
            switch source {
            case .appleMusic:
                try await sendViaAppleScript(command)
            case .spotify:
                try await sendViaSpotifyAppleScript(command)
            case .mediaRemote:
                if let mediaRemote {
                    try mediaRemote.send(command)
                    return
                }
            }
            return
        }

        if let mediaRemote {
            do {
                try mediaRemote.send(command)
                return
            } catch {
            }
        }

        if let error = await fallbackSend(command) {
            throw error
        }
    }

    private static func playbackSource(for bundleIdentifier: String?) -> PlaybackSource? {
        switch bundleIdentifier {
        case musicBundleIdentifier:
            return .appleMusic
        case spotifyBundleIdentifier:
            return .spotify
        case .some:
            return .mediaRemote
        case .none:
            return nil
        }
    }

    static func fetchCurrentArtworkData() async throws -> Data? {
        if let adapterPlayback = try? await mediaRemoteAdapter.fetchNowPlaying(),
           isSupportedAdapterPlayback(adapterPlayback),
           let adapterArtworkData = adapterPlayback.artworkData,
           !adapterArtworkData.isEmpty {
            return adapterArtworkData
        }

        if let candidate = await preferredPlaybackCandidate() {
            if let embeddedArtworkData = candidate.playback.artworkData, !embeddedArtworkData.isEmpty {
                return embeddedArtworkData
            }

            let source = candidate.source
            switch source {
            case .appleMusic:
                return try await fetchArtworkDataFromAppleScript()
            case .spotify:
                return try await fetchSpotifyArtworkDataFromAppleScript()
            case .mediaRemote:
                let mediaRemoteArtwork = await mediaRemote?.fetchArtworkData()
                if let mediaRemoteArtwork, !mediaRemoteArtwork.isEmpty {
                    return mediaRemoteArtwork
                }

                if candidate.playback.sourceBundleIdentifier == sodaMusicBundleIdentifier {
                    return nil
                }

                return nil
            }
        }

        if let mediaRemote {
            return await mediaRemote.fetchArtworkData()
        }

        return nil
    }

    static func observeNowPlayingChanges(
        on queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) throws -> AppleMusicPlaybackObservation {
        let adapterObservation = mediaRemoteAdapter.makeObservation(on: queue, handler: handler)

        if let mediaRemote {
            let legacyObservation = try? mediaRemote.observeNowPlayingChanges(on: queue, handler: handler)
            return AppleMusicPlaybackObservation {
                adapterObservation.stop()
                legacyObservation?.stop()
            }
        }

        return adapterObservation
    }

    static func fetchNowPlayingFromAppleScript() async throws -> AppleMusicPlayback {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try executeScript())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func fetchArtworkDataFromAppleScript() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try executeArtworkExport())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func sendViaAppleScript(_ command: AppleMusicTransportCommand) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try executeTransportCommand(command)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func fetchSpotifyNowPlayingFromAppleScript() async throws -> AppleMusicPlayback {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try executeSpotifyScript())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func fetchNowPlayingFromJXAMediaRemote() async throws -> AppleMusicPlayback {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try executeJXAMediaRemoteScript())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func fetchSpotifyArtworkDataFromAppleScript() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try executeSpotifyArtworkLookup())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func sendViaSpotifyAppleScript(_ command: AppleMusicTransportCommand) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try executeSpotifyTransportCommand(command)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func preferredScriptedPlayback(activeBundleIdentifier: String?) async -> PlaybackCandidate? {
        let applePlayback = try? await fetchNowPlayingFromAppleScript()
        let spotifyPlayback = try? await fetchSpotifyNowPlayingFromAppleScript()

        let candidates = [
            applePlayback.map { PlaybackCandidate(source: .appleMusic, playback: $0) },
            spotifyPlayback.map { PlaybackCandidate(source: .spotify, playback: $0) },
        ]
        .compactMap { $0 }
        .filter { candidate in
            guard candidate.playback.track != nil || candidate.playback.state != .stopped else {
                return false
            }

            if let activeBundleIdentifier,
               mediaRemotePreferredBundleIdentifiers.contains(activeBundleIdentifier),
               candidate.playback.state != .playing,
               candidate.playback.sourceBundleIdentifier != activeBundleIdentifier {
                return false
            }

            return true
        }

        return candidates.max { left, right in
            playbackPriority(for: left, activeBundleIdentifier: activeBundleIdentifier)
                < playbackPriority(for: right, activeBundleIdentifier: activeBundleIdentifier)
        }
    }

    private static func adapterPlaybackCandidate() async -> PlaybackCandidate? {
        guard
            let playback = try? await mediaRemoteAdapter.fetchNowPlaying(),
            playback.track != nil || playback.state != .stopped,
            isSupportedAdapterPlayback(playback)
        else {
            return nil
        }

        return PlaybackCandidate(source: .mediaRemote, playback: playback)
    }

    private static func isSupportedAdapterPlayback(_ playback: AppleMusicPlayback) -> Bool {
        guard let bundleIdentifier = playback.sourceBundleIdentifier else {
            return false
        }

        return supportedBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func preferredPlaybackCandidate() async -> PlaybackCandidate? {
        let activeBundleIdentifier = await activeSupportedBundleIdentifier()

        async let scripted = preferredScriptedPlayback(activeBundleIdentifier: activeBundleIdentifier)
        async let mediaRemoteCandidate = mediaRemotePlaybackCandidate()
        async let jxaCandidate = jxaMediaRemotePlaybackCandidate()

        let resolvedScripted = await scripted
        let resolvedMediaRemoteCandidate = await mediaRemoteCandidate
        let resolvedJXACandidate = await jxaCandidate

        if let resolvedJXACandidate,
           mediaRemotePreferredBundleIdentifiers.contains(
               resolvedJXACandidate.playback.sourceBundleIdentifier ?? ""
           ) {
            return resolvedJXACandidate
        }

        if let resolvedMediaRemoteCandidate,
           mediaRemotePreferredBundleIdentifiers.contains(
               resolvedMediaRemoteCandidate.playback.sourceBundleIdentifier ?? ""
           ) {
            return resolvedMediaRemoteCandidate
        }

        let candidates = [
            resolvedScripted,
            resolvedMediaRemoteCandidate,
            resolvedJXACandidate,
        ].compactMap { $0 }

        if let activeBundleIdentifier,
           mediaRemotePreferredBundleIdentifiers.contains(activeBundleIdentifier),
           !candidates.contains(where: { $0.playback.sourceBundleIdentifier == activeBundleIdentifier }),
           let placeholderCandidate = placeholderPlaybackCandidate(for: activeBundleIdentifier) {
            return placeholderCandidate
        }

        return candidates.max { left, right in
            playbackPriority(for: left, activeBundleIdentifier: activeBundleIdentifier)
                < playbackPriority(for: right, activeBundleIdentifier: activeBundleIdentifier)
        }
    }

    private static func mediaRemotePlaybackCandidate() async -> PlaybackCandidate? {
        guard let mediaRemote, let playback = try? await mediaRemote.fetchNowPlaying(), playback.track != nil else {
            return nil
        }

        return PlaybackCandidate(source: .mediaRemote, playback: playback)
    }

    private static func jxaMediaRemotePlaybackCandidate() async -> PlaybackCandidate? {
        guard let playback = try? await fetchNowPlayingFromJXAMediaRemote(), playback.track != nil else {
            return nil
        }

        return PlaybackCandidate(source: .mediaRemote, playback: playback)
    }

    private static func playbackPriority(
        for candidate: PlaybackCandidate,
        activeBundleIdentifier: String?
    ) -> Int {
        let base: Int
        if candidate.playback.state.isPlaying {
            base = 30
        } else if candidate.playback.track != nil {
            base = 20
        } else {
            base = 0
        }

        let sourceBonus: Int
        switch candidate.source {
        case .appleMusic, .spotify:
            sourceBonus = 0
        case .mediaRemote:
            sourceBonus = 5
        }

        let identificationBonus = candidate.playback.sourceBundleIdentifier == nil ? 0 : 3
        let frontmostBundleIdentifier = frontmostSupportedBundleIdentifier()

        let activeBundleBonus: Int
        if candidate.playback.sourceBundleIdentifier == activeBundleIdentifier, activeBundleIdentifier != nil {
            activeBundleBonus = 28
        } else {
            activeBundleBonus = 0
        }

        let frontmostBonus: Int
        if candidate.playback.sourceBundleIdentifier == frontmostBundleIdentifier, frontmostBundleIdentifier != nil {
            frontmostBonus = 18
        } else {
            frontmostBonus = 0
        }

        let scriptedPenalty: Int
        if let activeBundleIdentifier,
           mediaRemotePreferredBundleIdentifiers.contains(activeBundleIdentifier),
           candidate.source != .mediaRemote,
           candidate.playback.state != .playing {
            scriptedPenalty = -20
        } else {
            scriptedPenalty = 0
        }

        return base + sourceBonus + identificationBonus + activeBundleBonus + frontmostBonus + scriptedPenalty
    }

    private static func activeSupportedBundleIdentifier() async -> String? {
        if let playback = try? await fetchNowPlayingFromJXAMediaRemote(),
           let bundleIdentifier = playback.sourceBundleIdentifier,
           supportedBundleIdentifiers.contains(bundleIdentifier) {
            return bundleIdentifier
        }

        if let mediaRemote,
           let bundleIdentifier = await mediaRemote.fetchActiveBundleIdentifier(),
           supportedBundleIdentifiers.contains(bundleIdentifier) {
            return bundleIdentifier
        }

        return frontmostSupportedBundleIdentifier()
    }

    private static func placeholderPlaybackCandidate(for bundleIdentifier: String) -> PlaybackCandidate? {
        let title = placeholderTitle(for: bundleIdentifier)
        guard !title.isEmpty else {
            return nil
        }

        return PlaybackCandidate(
            source: .mediaRemote,
            playback: AppleMusicPlayback(
                track: TrackMetadata(
                    title: title,
                    artist: unavailableTrackArtist,
                    album: "",
                    duration: 0
                ),
                state: .playing,
                position: 0,
                updatedAt: Date(),
                artworkData: nil,
                sourceBundleIdentifier: bundleIdentifier
            )
        )
    }

    private static func placeholderTitle(for bundleIdentifier: String) -> String {
        if let runningName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?
            .localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !runningName.isEmpty {
            return "\(runningName) 播放中"
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let appName = FileManager.default
                .displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !appName.isEmpty {
                return "\(appName) 播放中"
            }
        }

        return ""
    }

    private static func fallbackSend(_ command: AppleMusicTransportCommand) async -> Error? {
        do {
            try await sendViaAppleScript(command)
            return nil
        } catch let appleError {
            do {
                try await sendViaSpotifyAppleScript(command)
                return nil
            } catch {
                return appleError
            }
        }
    }

    fileprivate static func sanitizedTrackMetadataValue(_ value: String) -> String {
        let mutable = NSMutableString(string: value)
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)

        return (mutable as String)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[（(][^）)]*[）)]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor SodaMusicNowPlayingController {
    private struct RecognizedLine {
        let text: String
        let boundingBox: CGRect
    }

    private struct CachedResult {
        let playback: AppleMusicPlayback
        let artworkData: Data?
        let timestamp: Date
    }

    private var cachedResult: CachedResult?
    private let cacheLifetime: TimeInterval = 2

    func fetchNowPlaying() async -> AppleMusicPlayback? {
        if let cachedResult, Date().timeIntervalSince(cachedResult.timestamp) < cacheLifetime {
            return cachedResult.playback
        }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            return nil
        }

        guard let window = await targetWindow() else {
            return nil
        }

        guard let image = try? await captureImage(for: window) else {
            return nil
        }

        let artworkData = artworkData(from: image)
        let track = recognizeTrack(in: image)
        guard let track else {
            return nil
        }

        let playback = AppleMusicPlayback(
            track: track,
            state: .playing,
            position: 0,
            updatedAt: Date(),
            artworkData: artworkData,
            sourceBundleIdentifier: "com.soda.music"
        )

        cachedResult = CachedResult(playback: playback, artworkData: artworkData, timestamp: Date())
        return playback
    }

    func fetchArtworkData() async -> Data? {
        if let cachedResult, Date().timeIntervalSince(cachedResult.timestamp) < cacheLifetime {
            return cachedResult.artworkData
        }

        _ = await fetchNowPlaying()
        return cachedResult?.artworkData
    }

    private func targetWindow() async -> SCWindow? {
        guard let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.soda.music"
        ).first else {
            return nil
        }

        let shareableContent = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let windows = shareableContent?.windows ?? []
        return windows
            .filter { window in
                window.owningApplication?.processID == runningApp.processIdentifier
                    && window.frame.width > 500
                    && window.frame.height > 300
            }
            .max { left, right in
                (left.frame.width * left.frame.height) < (right.frame.width * right.frame.height)
            }
    }

    private func captureImage(for window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    private func recognizeTrack(in image: CGImage) -> TrackMetadata? {
        let cropRect = normalizedRect(
            x: 0.20,
            y: 0.24,
            width: 0.36,
            height: 0.42,
            in: image
        )

        guard let cropped = image.cropping(to: cropRect) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        try? handler.perform([request])

        let lines = (request.results ?? [])
            .compactMap { observation -> RecognizedLine? in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }

                let text = candidate.string
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "VIP", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard isMeaningfulTrackText(text) else {
                    return nil
                }

                return RecognizedLine(text: text, boundingBox: observation.boundingBox)
            }
            .sorted { left, right in
                if abs(left.boundingBox.midY - right.boundingBox.midY) > 0.03 {
                    return left.boundingBox.midY > right.boundingBox.midY
                }
                return left.boundingBox.height > right.boundingBox.height
            }

        guard let titleLine = lines.max(by: { left, right in
            left.boundingBox.height < right.boundingBox.height
        }) else {
            return nil
        }

        let artistLine = lines.first { line in
            line.text != titleLine.text
                && line.boundingBox.midY < titleLine.boundingBox.midY
                && abs(line.boundingBox.minX - titleLine.boundingBox.minX) < 0.25
        }

        return TrackMetadata(
            title: AppleMusicScriptBridge.sanitizedTrackMetadataValue(titleLine.text),
            artist: AppleMusicScriptBridge.sanitizedTrackMetadataValue(artistLine?.text ?? ""),
            album: "",
            duration: 0
        )
    }

    private func artworkData(from image: CGImage) -> Data? {
        let cropRect = normalizedRect(
            x: 0.22,
            y: 0.43,
            width: 0.20,
            height: 0.34,
            in: image
        )

        guard
            let cropped = image.cropping(to: cropRect),
            let data = NSBitmapImageRep(cgImage: cropped)
                .representation(using: .png, properties: [:])
        else {
            return nil
        }

        return data
    }

    private func normalizedRect(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        in image: CGImage
    ) -> CGRect {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        return CGRect(
            x: x * imageWidth,
            y: y * imageHeight,
            width: width * imageWidth,
            height: height * imageHeight
        ).integral
    }

    private func isMeaningfulTrackText(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 32 else {
            return false
        }

        let blacklist: Set<String> = [
            "汽水音乐",
            "推荐",
            "听歌模式",
            "我的音乐",
            "我喜欢的音乐",
            "历史播放",
            "创建的歌单",
            "低价续费会员",
            "Search",
            "歌手、歌曲或专辑名",
        ]

        if blacklist.contains(text) {
            return false
        }

        if text.contains("/") || text.contains(":") {
            return false
        }

        if text.allSatisfy({ $0.isNumber || $0.isWhitespace }) {
            return false
        }

        return true
    }
}

private final class MediaRemoteController: @unchecked Sendable {
    private typealias GetNowPlayingInfoCompletion = @convention(block) (CFDictionary?) -> Void
    private typealias GetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping GetNowPlayingInfoCompletion) -> Void
    private typealias GetNowPlayingApplicationPIDCompletion = @convention(block) (Int32) -> Void
    private typealias GetNowPlayingApplicationPIDFunction = @convention(c) (DispatchQueue, @escaping GetNowPlayingApplicationPIDCompletion) -> Void
    private typealias RegisterForNotificationsFunction = @convention(c) (DispatchQueue) -> Void
    private typealias SetWantsNowPlayingNotificationsFunction = @convention(c) (Bool) -> Void
    private typealias SendCommandFunction = @convention(c) (Int, NSDictionary?) -> Bool

    private enum Keys {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    }

    private enum Notifications {
        static let nowPlayingInfoDidChange = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
        static let nowPlayingApplicationDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
        static let nowPlayingApplicationIsPlayingDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
    }

    private struct NowPlayingInfoPayload: Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let elapsedTime: TimeInterval
        let playbackRate: Double
        let timestamp: Date?
        let artworkData: Data?
    }

    private let getNowPlayingInfo: GetNowPlayingInfoFunction
    private let getNowPlayingApplicationPID: GetNowPlayingApplicationPIDFunction
    private let registerForNotifications: RegisterForNotificationsFunction
    private let setWantsNowPlayingNotifications: SetWantsNowPlayingNotificationsFunction?
    private let sendCommand: SendCommandFunction

    init() throws {
        let bundleURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL) else {
            throw AppleMusicBridgeError.mediaRemoteUnavailable
        }

        guard CFBundleLoadExecutable(bundle) else {
            throw AppleMusicBridgeError.mediaRemoteUnavailable
        }

        guard
            let getNowPlayingInfoPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString),
            let getNowPlayingApplicationPIDPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationPID" as CFString),
            let registerForNotificationsPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString),
            let sendCommandPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
        else {
            throw AppleMusicBridgeError.mediaRemoteUnavailable
        }

        getNowPlayingInfo = unsafeBitCast(getNowPlayingInfoPointer, to: GetNowPlayingInfoFunction.self)
        getNowPlayingApplicationPID = unsafeBitCast(getNowPlayingApplicationPIDPointer, to: GetNowPlayingApplicationPIDFunction.self)
        registerForNotifications = unsafeBitCast(registerForNotificationsPointer, to: RegisterForNotificationsFunction.self)
        sendCommand = unsafeBitCast(sendCommandPointer, to: SendCommandFunction.self)

        if let setWantsNowPlayingNotificationsPointer = CFBundleGetFunctionPointerForName(
            bundle,
            "MRMediaRemoteSetWantsNowPlayingNotifications" as CFString
        ) {
            setWantsNowPlayingNotifications = unsafeBitCast(
                setWantsNowPlayingNotificationsPointer,
                to: SetWantsNowPlayingNotificationsFunction.self
            )
        } else {
            setWantsNowPlayingNotifications = nil
        }
    }

    func fetchNowPlaying() async throws -> AppleMusicPlayback {
        async let nowPlayingInfo = requestNowPlayingInfo()
        async let applicationPID = requestNowPlayingApplicationPID()

        let info = await nowPlayingInfo
        let pid = await applicationPID
        let bundleIdentifier = bundleIdentifier(for: pid)
        return parsePlayback(info: info, bundleIdentifier: bundleIdentifier)
    }

    func fetchArtworkData() async -> Data? {
        await requestNowPlayingInfo().artworkData
    }

    func fetchActiveBundleIdentifier() async -> String? {
        let pid = await requestNowPlayingApplicationPID()
        return bundleIdentifier(for: pid)
    }

    func send(_ command: AppleMusicTransportCommand) throws {
        let didSend = sendCommand(mediaRemoteCommand(for: command), nil)
        guard didSend else {
            throw AppleMusicBridgeError.transportFailed(command)
        }
    }

    func observeNowPlayingChanges(
        on queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) throws -> AppleMusicPlaybackObservation {
        registerForNotifications(queue)
        setWantsNowPlayingNotifications?(true)

        let center = NotificationCenter.default
        let names = [
            Notifications.nowPlayingInfoDidChange,
            Notifications.nowPlayingApplicationDidChange,
            Notifications.nowPlayingApplicationIsPlayingDidChange,
        ]

        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                handler()
            }
        }

        return AppleMusicPlaybackObservation { [weak center, weak self] in
            tokens.forEach { token in
                center?.removeObserver(token)
            }
            self?.setWantsNowPlayingNotifications?(false)
        }
    }

    private func requestNowPlayingInfo() async -> NowPlayingInfoPayload {
        await withCheckedContinuation { continuation in
            getNowPlayingInfo(.main) { dictionary in
                let rawInfo = dictionary as? [String: Any] ?? [:]
                let payload = NowPlayingInfoPayload(
                    title: self.stringValue(for: Keys.title, in: rawInfo),
                    artist: self.stringValue(for: Keys.artist, in: rawInfo),
                    album: self.stringValue(for: Keys.album, in: rawInfo),
                    duration: max(0, self.doubleValue(for: Keys.duration, in: rawInfo)),
                    elapsedTime: max(0, self.doubleValue(for: Keys.elapsedTime, in: rawInfo)),
                    playbackRate: self.doubleValue(for: Keys.playbackRate, in: rawInfo),
                    timestamp: self.dateValue(for: Keys.timestamp, in: rawInfo),
                    artworkData: rawInfo[Keys.artworkData] as? Data
                )
                continuation.resume(returning: payload)
            }
        }
    }

    private func requestNowPlayingApplicationPID() async -> Int32 {
        await withCheckedContinuation { continuation in
            getNowPlayingApplicationPID(.main) { pid in
                continuation.resume(returning: pid)
            }
        }
    }

    private func bundleIdentifier(for pid: Int32) -> String? {
        guard pid > 0 else {
            return nil
        }

        return NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
    }

    private func parsePlayback(info: NowPlayingInfoPayload, bundleIdentifier: String?) -> AppleMusicPlayback {
        let title = AppleMusicScriptBridge.sanitizedTrackMetadataValue(info.title)
        let artist = AppleMusicScriptBridge.sanitizedTrackMetadataValue(info.artist)
        let album = AppleMusicScriptBridge.sanitizedTrackMetadataValue(info.album)

        let track: TrackMetadata?
        if title.isEmpty {
            track = nil
        } else {
            track = TrackMetadata(
                title: title,
                artist: artist,
                album: album,
                duration: info.duration
            )
        }

        let state: PlaybackState
        if track == nil {
            state = .stopped
        } else if info.playbackRate > 0.0001 {
            state = .playing
        } else {
            state = .paused
        }

        let clampedPosition: TimeInterval
        if info.duration > 0 {
            clampedPosition = min(info.elapsedTime, info.duration)
        } else {
            clampedPosition = info.elapsedTime
        }

        let resolvedBundleIdentifier = AppleMusicScriptBridge.resolveActiveBundleIdentifier(
            current: bundleIdentifier,
            hasTrack: track != nil
        )

        return AppleMusicPlayback(
            track: track,
            state: state,
            position: clampedPosition,
            updatedAt: info.timestamp ?? Date(),
            artworkData: info.artworkData,
            sourceBundleIdentifier: resolvedBundleIdentifier
        )
    }

    private func mediaRemoteCommand(for command: AppleMusicTransportCommand) -> Int {
        switch command {
        case .playPause:
            return 2
        case .nextTrack:
            return 4
        case .previousTrack:
            return 5
        }
    }

    private func stringValue(for key: String, in dictionary: [String: Any]) -> String {
        if let value = dictionary[key] as? String {
            return value
        }

        return ""
    }

    private func doubleValue(for key: String, in dictionary: [String: Any]) -> Double {
        switch dictionary[key] {
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value) ?? 0
        default:
            return 0
        }
    }

    private func dateValue(for key: String, in dictionary: [String: Any]) -> Date? {
        switch dictionary[key] {
        case let value as Date:
            return value
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        default:
            return nil
        }
    }
}

private extension AppleMusicScriptBridge {
    static func executeScript() throws -> AppleMusicPlayback {
        guard let payload = try executeInlineScript(nowPlayingScriptSource), !payload.isEmpty else {
            throw AppleMusicScriptError.invalidPayload
        }

        return try parseAppleScriptPayload(payload, sourceBundleIdentifier: musicBundleIdentifier)
    }

    static func executeSpotifyScript() throws -> AppleMusicPlayback {
        guard let payload = try executeInlineScript(spotifyNowPlayingScriptSource), !payload.isEmpty else {
            throw AppleMusicScriptError.invalidPayload
        }

        return try parseAppleScriptPayload(payload, sourceBundleIdentifier: spotifyBundleIdentifier)
    }

    static func executeJXAMediaRemoteScript() throws -> AppleMusicPlayback {
        guard let payload = try executeJavaScript(jxaNowPlayingScriptSource), !payload.isEmpty else {
            throw AppleMusicScriptError.invalidPayload
        }

        return try parseJXAMediaRemotePayload(payload)
    }

    static func executeTransportCommand(_ command: AppleMusicTransportCommand) throws {
        let source: String
        switch command {
        case .previousTrack:
            source = """
            tell application id "com.apple.Music"
                if running then
                    previous track
                end if
            end tell
            """
        case .playPause:
            source = """
            tell application id "com.apple.Music"
                if running then
                    playpause
                end if
            end tell
            """
        case .nextTrack:
            source = """
            tell application id "com.apple.Music"
                if running then
                    next track
                end if
            end tell
            """
        }

        _ = try executeInlineScript(source)
    }

    static func executeSpotifyTransportCommand(_ command: AppleMusicTransportCommand) throws {
        let source: String
        switch command {
        case .previousTrack:
            source = """
            tell application id "com.spotify.client"
                if running then
                    previous track
                end if
            end tell
            """
        case .playPause:
            source = """
            tell application id "com.spotify.client"
                if running then
                    playpause
                end if
            end tell
            """
        case .nextTrack:
            source = """
            tell application id "com.spotify.client"
                if running then
                    next track
                end if
            end tell
            """
        }

        _ = try executeInlineScript(source)
    }

    static func executeArtworkExport() throws -> Data? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyricdock-artwork-\(UUID().uuidString)")

        let source = """
        tell application id "com.apple.Music"
            if not running then
                return ""
            end if

            if player state is stopped then
                return ""
            end if

            try
                if (count of artworks of current track) is 0 then
                    return ""
                end if

                set artworkData to raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell

        set outputFile to POSIX file "\(escapedAppleScriptString(outputURL.path))"

        try
            set fileHandle to open for access outputFile with write permission
            set eof of fileHandle to 0
            write artworkData to fileHandle
            close access fileHandle
            return "ok"
        on error
            try
                close access outputFile
            end try
            return ""
        end try
        """

        let result = try executeInlineScript(source)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard result == "ok" else {
            return nil
        }

        return try? Data(contentsOf: outputURL)
    }

    static func executeSpotifyArtworkLookup() throws -> Data? {
        guard
            let artworkURLString = try executeInlineScript(spotifyArtworkScriptSource),
            let artworkURL = URL(string: artworkURLString),
            !artworkURLString.isEmpty
        else {
            return nil
        }

        return try? Data(contentsOf: artworkURL)
    }

    static func executeJavaScript(_ source: String) throws -> String? {
        try runOsaScript(arguments: [
            "-l",
            "JavaScript",
            "-e",
            source,
        ])
    }

    static func executeInlineScript(_ source: String) throws -> String? {
        let lines = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }

        var arguments: [String] = []
        for line in lines {
            arguments.append("-e")
            arguments.append(line)
        }

        return try runOsaScript(arguments: arguments)
    }

    static func ensureAutomationPermissionIfNeeded() throws {
        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: musicBundleIdentifier)

        guard let targetAEDesc = targetDescriptor.aeDesc else {
            throw AppleMusicScriptError.permissionCheckFailed("无法创建 Music.app 的目标描述符")
        }

        let status = AEDeterminePermissionToAutomateTarget(
            targetAEDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            true
        )

        switch status {
        case noErr:
            return
        case OSStatus(procNotFound):
            throw AppleMusicScriptError.musicNotRunning
        case OSStatus(errAEEventNotPermitted):
            throw AppleMusicScriptError.permissionDenied
        case OSStatus(errAETargetAddressNotPermitted):
            throw AppleMusicScriptError.targetNotPermitted
        case OSStatus(errAEEventWouldRequireUserConsent):
            throw AppleMusicScriptError.permissionRequiresConsent
        default:
            throw AppleMusicScriptError.permissionCheckFailed("OSStatus \(status)")
        }
    }

    static func parseAppleScriptPayload(_ payload: String, sourceBundleIdentifier: String) throws -> AppleMusicPlayback {
        let separator = String(UnicodeScalar(31))
        let parts = payload.components(separatedBy: separator)

        guard parts.count >= 6 else {
            throw AppleMusicScriptError.invalidPayload
        }

        let state = normalizedPlaybackState(from: parts[0])
        let title = sanitizedTrackMetadataValue(parts[1])
        let artist = sanitizedTrackMetadataValue(parts[2])
        let album = sanitizedTrackMetadataValue(parts[3])
        let position = Double(parts[4]) ?? 0
        let duration = Double(parts[5]) ?? 0

        let track: TrackMetadata?
        if title.isEmpty {
            track = nil
        } else {
            track = TrackMetadata(
                title: title,
                artist: artist,
                album: album,
                duration: duration
            )
        }

        return AppleMusicPlayback(
            track: track,
            state: state,
            position: position,
            updatedAt: Date(),
            artworkData: nil,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
    }

    static func parseJXAMediaRemotePayload(_ payload: String) throws -> AppleMusicPlayback {
        let separator = String(UnicodeScalar(31))
        let parts = payload.components(separatedBy: separator)

        guard parts.count >= 8 else {
            throw AppleMusicScriptError.invalidPayload
        }

        let state = normalizedPlaybackState(from: parts[0])
        let title = sanitizedTrackMetadataValue(parts[1])
        let artist = sanitizedTrackMetadataValue(parts[2])
        let album = sanitizedTrackMetadataValue(parts[3])
        let position = Double(parts[4]) ?? 0
        let duration = Double(parts[5]) ?? 0
        let rawBundleIdentifier = parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = parts[7].trimmingCharacters(in: .whitespacesAndNewlines)

        let track: TrackMetadata?
        if title.isEmpty {
            track = nil
        } else {
            track = TrackMetadata(
                title: title,
                artist: artist,
                album: album,
                duration: duration
            )
        }

        let sourceBundleIdentifier = canonicalBundleIdentifier(
            rawBundleIdentifier.isEmpty ? nil : rawBundleIdentifier,
            displayName: displayName
        )
        let resolvedBundleIdentifier = resolveActiveBundleIdentifier(
            current: sourceBundleIdentifier,
            hasTrack: track != nil
        )

        return AppleMusicPlayback(
            track: track,
            state: track == nil ? .stopped : state,
            position: position,
            updatedAt: Date(),
            artworkData: nil,
            sourceBundleIdentifier: resolvedBundleIdentifier
        )
    }

    static func canonicalBundleIdentifier(_ bundleIdentifier: String?, displayName: String) -> String? {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        let normalizedName = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedName.contains("music") && normalizedName.contains("apple") {
            return musicBundleIdentifier
        }
        if normalizedName == "music" || normalizedName == "音乐" {
            return musicBundleIdentifier
        }
        if normalizedName.contains("spotify") {
            return spotifyBundleIdentifier
        }
        if normalizedName.contains("汽水") || normalizedName.contains("soda") {
            return sodaMusicBundleIdentifier
        }
        if normalizedName.contains("网易云") || normalizedName.contains("netease") {
            return neteaseMusicBundleIdentifier
        }
        if normalizedName.contains("qq音乐") || normalizedName.contains("qq music") {
            return qqMusicBundleIdentifier
        }

        return nil
    }

    static func frontmostSupportedBundleIdentifier() -> String? {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return nil
        }

        guard supportedBundleIdentifiers.contains(bundleIdentifier) else {
            return nil
        }

        return bundleIdentifier
    }

    static func resolveActiveBundleIdentifier(current: String?, hasTrack: Bool) -> String? {
        if let current, !current.isEmpty {
            return current
        }

        guard hasTrack else {
            return nil
        }

        return frontmostSupportedBundleIdentifier()
    }

    static func runOsaScript(arguments: [String]) throws -> String? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw AppleMusicScriptError.executeFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppleMusicScriptError.executeFailed(errorMessage ?? "osascript 返回了非 0 状态码")
        }

        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedPlaybackState(from rawValue: String) -> PlaybackState {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "playing" || normalized.contains("kpsp") {
            return .playing
        }
        if normalized == "paused" || normalized.contains("kpsa") {
            return .paused
        }
        return .stopped
    }

    static var nowPlayingScriptSource: String {
        """
        set itemDelimiter to (character id 31)

        tell application id "com.apple.Music"
            if not running then
                return "stopped" & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "0" & itemDelimiter & "0"
            end if

            if player state is playing then
                set playerState to "playing"
            else if player state is paused then
                set playerState to "paused"
            else
                set playerState to "stopped"
            end if

            if playerState is "stopped" then
                return playerState & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "0" & itemDelimiter & "0"
            end if

            set trackName to ""
            set artistName to ""
            set albumName to ""
            set trackDuration to 0
            set playheadPosition to 0

            try
                set trackName to (name of current track)
                set artistName to (artist of current track)
                set albumName to (album of current track)
                set trackDuration to (duration of current track)
            end try

            try
                set playheadPosition to (player position)
            end try

            return playerState & itemDelimiter & trackName & itemDelimiter & artistName & itemDelimiter & albumName & itemDelimiter & (playheadPosition as string) & itemDelimiter & (trackDuration as string)
        end tell
        """
    }

    static var spotifyNowPlayingScriptSource: String {
        """
        set itemDelimiter to (character id 31)

        tell application id "com.spotify.client"
            if not running then
                return "stopped" & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "0" & itemDelimiter & "0"
            end if

            if player state is playing then
                set playerState to "playing"
            else if player state is paused then
                set playerState to "paused"
            else
                set playerState to "stopped"
            end if

            if playerState is "stopped" then
                return playerState & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "" & itemDelimiter & "0" & itemDelimiter & "0"
            end if

            set trackName to name of current track
            set artistName to artist of current track
            set albumName to album of current track
            set trackDuration to ((duration of current track) / 1000)
            set playheadPosition to player position

            return playerState & itemDelimiter & trackName & itemDelimiter & artistName & itemDelimiter & albumName & itemDelimiter & (playheadPosition as string) & itemDelimiter & (trackDuration as string)
        end tell
        """
    }

    static var spotifyArtworkScriptSource: String {
        """
        tell application id "com.spotify.client"
            if not running then
                return ""
            end if

            if player state is stopped then
                return ""
            end if

            try
                return artwork url of current track
            on error
                return ""
            end try
        end tell
        """
    }

    static var jxaNowPlayingScriptSource: String {
        #"""
        ObjC.import("Foundation")

        const separator = "\u001f"
        $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/")

        function unwrapValue(value) {
            if (value === undefined || value === null) {
                return ""
            }

            try {
                if (value.js !== undefined && value.js !== null) {
                    return String(value.js)
                }
            } catch (error) {
            }

            try {
                const description = ObjC.unwrap(value.description)
                if (description !== undefined && description !== null) {
                    return String(description)
                }
            } catch (error) {
            }

            try {
                return String(ObjC.unwrap(value))
            } catch (error) {
                return ""
            }
        }

        function valueForKey(target, key) {
            if (!target) {
                return ""
            }

            try {
                return unwrapValue(target.valueForKey(key))
            } catch (error) {
                return ""
            }
        }

        function firstNonEmpty(values) {
            for (const value of values) {
                if (value && String(value).length > 0) {
                    return String(value)
                }
            }
            return ""
        }

        const request = $.NSClassFromString("MRNowPlayingRequest")
        if (!request) {
            ["stopped", "", "", "", "0", "0", "", ""].join(separator)
        } else {
            let playerPath = null
            let client = null
            let origin = null
            let parentApp = null
            let item = null
            let info = null

            try {
                playerPath = request.localNowPlayingPlayerPath
            } catch (error) {
            }

            try {
                item = request.localNowPlayingItem
            } catch (error) {
            }

            try {
                client = playerPath ? playerPath.client : null
            } catch (error) {
            }

            try {
                origin = playerPath ? playerPath.origin : null
            } catch (error) {
            }

            try {
                parentApp = playerPath ? playerPath.parentApplication : null
            } catch (error) {
            }

            try {
                info = item ? item.nowPlayingInfo : null
            } catch (error) {
            }

            const title = valueForKey(info, "kMRMediaRemoteNowPlayingInfoTitle")
            const artist = valueForKey(info, "kMRMediaRemoteNowPlayingInfoArtist")
            const album = valueForKey(info, "kMRMediaRemoteNowPlayingInfoAlbum")
            const duration = valueForKey(info, "kMRMediaRemoteNowPlayingInfoDuration") || "0"
            const elapsed = valueForKey(info, "kMRMediaRemoteNowPlayingInfoElapsedTime") || "0"
            const playbackRate = valueForKey(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
            const displayName = firstNonEmpty([
                valueForKey(parentApp, "displayName"),
                valueForKey(origin, "displayName"),
                valueForKey(client, "displayName"),
                valueForKey(playerPath, "displayName"),
                valueForKey(playerPath, "name")
            ])
            const bundleIdentifier = firstNonEmpty([
                valueForKey(parentApp, "bundleIdentifier"),
                valueForKey(parentApp, "bundleID"),
                valueForKey(origin, "bundleIdentifier"),
                valueForKey(origin, "bundleID"),
                valueForKey(client, "bundleIdentifier"),
                valueForKey(client, "bundleID"),
                valueForKey(playerPath, "bundleIdentifier"),
                valueForKey(playerPath, "bundleID")
            ])

            let state = "stopped"
            if (title.length > 0) {
                state = Number(playbackRate || "0") > 0.0001 ? "playing" : "paused"
            }

            [
                state,
                title,
                artist,
                album,
                elapsed,
                duration,
                bundleIdentifier,
                displayName
            ].join(separator)
        }
        """#
    }

    static func escapedAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum AppleMusicBridgeError: LocalizedError {
    case mediaRemoteUnavailable
    case transportFailed(AppleMusicTransportCommand)

    var errorDescription: String? {
        switch self {
        case .mediaRemoteUnavailable:
            return "当前系统无法加载 MediaRemote.framework，LyricDock 还不能读取系统级播放状态。"
        case let .transportFailed(command):
            return "MediaRemote 没有接受“\(command.displayName)”指令，请确认当前有活动播放器。"
        }
    }
}

enum AppleMusicScriptError: LocalizedError {
    case compileFailed(String)
    case executeFailed(String)
    case invalidPayload
    case noSupportedPlayerRunning
    case musicNotRunning
    case permissionDenied
    case permissionRequiresConsent
    case targetNotPermitted
    case permissionCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case let .compileFailed(message):
            return "AppleScript 编译失败：\(message)"
        case let .executeFailed(message):
            return "AppleScript 执行失败：\(message)"
        case .invalidPayload:
            return "Music.app 返回的数据格式无法解析"
        case .noSupportedPlayerRunning:
            return "当前没有检测到受支持的播放器正在播放。"
        case .musicNotRunning:
            return "Music.app 尚未启动。请先打开并播放一首歌后再试。"
        case .permissionDenied:
            return "没有获得控制 Music.app 的权限。请到“系统设置 > 隐私与安全性 > 自动化”里允许 LyricDock 控制 Music。"
        case .permissionRequiresConsent:
            return "需要用户授权控制 Music.app，但系统没有完成授权。请重新运行主应用后再试。"
        case .targetNotPermitted:
            return "当前应用没有有效的 Apple Events 权限声明，系统拒绝了对 Music.app 的访问。"
        case let .permissionCheckFailed(message):
            return "检查 Music.app 自动化权限失败：\(message)"
        }
    }
}

private extension AppleMusicTransportCommand {
    var displayName: String {
        switch self {
        case .previousTrack:
            return "上一首"
        case .playPause:
            return "播放/暂停"
        case .nextTrack:
            return "下一首"
        }
    }
}
