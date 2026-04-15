import Foundation

actor MediaRemoteAdapterController {
    nonisolated static let didUpdateNotification = Notification.Name("LyricDockMediaRemoteAdapterDidUpdate")

    private struct StreamEnvelope: Decodable {
        let type: String?
        let diff: Bool?
        let payload: Payload
    }

    private struct Payload: Decodable {
        let bundleIdentifier: String?
        let parentApplicationBundleIdentifier: String?
        let playing: Bool?
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsedTime: Double?
        let timestamp: String?
        let artworkData: String?
    }

    enum AdapterError: LocalizedError {
        case missingScript
        case missingFramework
        case launchFailed(String)
        case commandFailed(String)
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .missingScript:
                return "未找到 mediaremote-adapter.pl"
            case .missingFramework:
                return "未找到 MediaRemoteAdapter.framework"
            case let .launchFailed(message):
                return "MediaRemoteAdapter 启动失败：\(message)"
            case let .commandFailed(message):
                return "MediaRemoteAdapter 执行失败：\(message)"
            case .invalidPayload:
                return "MediaRemoteAdapter 返回了无效数据"
            }
        }
    }

    private let decoder = JSONDecoder()
    private var process: Process?
    private var streamTask: Task<Void, Never>?
    private var currentPlayback: AppleMusicPlayback?
    private var lastErrorDescription: String?
    private var preparedFrameworkURL: URL?

    func startIfNeeded() async throws {
        guard process == nil else {
            return
        }

        let urls = try resourceURLs()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [urls.script.path, urls.framework.path, "stream", "--no-diff"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw AdapterError.launchFailed(error.localizedDescription)
        }

        self.process = process

        streamTask = Task { [weak process] in
            let outputHandle = outputPipe.fileHandleForReading
            let errorHandle = errorPipe.fileHandleForReading

            async let stderr = String(decoding: errorHandle.readDataToEndOfFile(), as: UTF8.self)

            do {
                for try await line in outputHandle.bytes.lines {
                    self.consume(line: line)
                }
            } catch {
                self.recordError("读取 MediaRemoteAdapter stream 失败：\(error.localizedDescription)")
            }

            let stderrText = await stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderrText.isEmpty {
                self.recordError(stderrText)
            }

            self.handleStreamExit(terminationStatus: process?.terminationStatus ?? 0)
        }
    }

    func fetchNowPlaying() async throws -> AppleMusicPlayback? {
        try await startIfNeeded()

        if let currentPlayback {
            return currentPlayback
        }

        guard let payload = try await runGetPayload() else {
            return nil
        }

        let playback = playback(from: payload)
        currentPlayback = playback
        return playback
    }

    func fetchArtworkData() async throws -> Data? {
        if let artworkData = currentPlayback?.artworkData {
            return artworkData
        }

        return try await fetchNowPlaying()?.artworkData
    }

    func send(_ command: AppleMusicTransportCommand) async throws {
        _ = try await runCommand(arguments: ["send", String(commandID(for: command))])
    }

    func latestErrorDescription() -> String? {
        lastErrorDescription
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        process?.terminate()
        process = nil
        currentPlayback = nil
        lastErrorDescription = nil
    }

    nonisolated func makeObservation(
        on queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) -> AppleMusicPlaybackObservation {
        Task {
            try? await startIfNeeded()
        }

        let token = NotificationCenter.default.addObserver(
            forName: Self.didUpdateNotification,
            object: nil,
            queue: nil
        ) { _ in
            queue.async {
                handler()
            }
        }

        return AppleMusicPlaybackObservation {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func runGetPayload() async throws -> Payload? {
        let output = try await runCommand(arguments: ["get"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, trimmed != "null" else {
            return nil
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw AdapterError.invalidPayload
        }

        return try decoder.decode(Payload.self, from: data)
    }

    private func runCommand(arguments: [String]) async throws -> String {
        let urls = try resourceURLs()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [urls.script.path, urls.framework.path] + arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw AdapterError.launchFailed(error.localizedDescription)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: AdapterError.commandFailed(error.isEmpty ? output : error))
                    return
                }

                continuation.resume(returning: output)
            }
        }
    }

    private func consume(line: String) {
        guard let data = line.data(using: .utf8) else {
            return
        }

        do {
            let envelope = try decoder.decode(StreamEnvelope.self, from: data)
            guard envelope.type == nil || envelope.type == "data" else {
                return
            }

            let playback = playback(from: envelope.payload)
            currentPlayback = playback
            lastErrorDescription = nil

            Task { @MainActor in
                NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
            }
        } catch {
            lastErrorDescription = "解析 MediaRemoteAdapter 数据失败：\(error.localizedDescription)"
        }
    }

    private func handleStreamExit(terminationStatus: Int32) {
        process = nil
        streamTask = nil

        guard terminationStatus != 0 else {
            return
        }

        if lastErrorDescription == nil {
            lastErrorDescription = "MediaRemoteAdapter stream 已退出（状态码 \(terminationStatus)）"
        }
    }

    private func recordError(_ errorDescription: String) {
        lastErrorDescription = errorDescription
    }

    private func playback(from payload: Payload) -> AppleMusicPlayback {
        let title = sanitize(payload.title)
        let artist = sanitize(payload.artist)
        let album = sanitize(payload.album)
        let duration = max(0, payload.duration ?? 0)
        let elapsedTime = max(0, payload.elapsedTime ?? 0)
        let sourceBundleIdentifier = resolveBundleIdentifier(from: payload)
        let artworkData = decodeArtworkData(payload.artworkData)

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

        let state: PlaybackState
        if track == nil {
            state = .stopped
        } else if payload.playing == true {
            state = .playing
        } else {
            state = .paused
        }

        return AppleMusicPlayback(
            track: track,
            state: state,
            position: duration > 0 ? min(elapsedTime, duration) : elapsedTime,
            updatedAt: parseTimestamp(payload.timestamp) ?? Date(),
            artworkData: artworkData,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
    }

    private func sanitize(_ value: String?) -> String {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            return ""
        }

        let mutable = NSMutableString(string: raw)
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)

        return (mutable as String)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeArtworkData(_ encoded: String?) -> Data? {
        guard
            let encoded,
            !encoded.isEmpty
        else {
            return nil
        }

        return Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractionalSeconds.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func resolveBundleIdentifier(from payload: Payload) -> String? {
        let preferred = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier
        guard let preferred, !preferred.isEmpty else {
            return nil
        }
        return preferred
    }

    private func resourceURLs() throws -> (script: URL, framework: URL) {
        guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl") else {
            throw AdapterError.missingScript
        }

        if let preparedFrameworkURL,
           FileManager.default.fileExists(atPath: preparedFrameworkURL.path) {
            return (scriptURL, preparedFrameworkURL)
        }

        guard let supportURL = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapterSupport") else {
            throw AdapterError.missingFramework
        }

        guard FileManager.default.fileExists(atPath: supportURL.path) else {
            throw AdapterError.missingFramework
        }

        let frameworkURL = try materializeFramework(from: supportURL)
        preparedFrameworkURL = frameworkURL
        return (scriptURL, frameworkURL)
    }

    private func materializeFramework(from supportURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("LyricDockMediaRemoteAdapter", isDirectory: true)
        let frameworkURL = rootURL.appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
        let resourcesURL = frameworkURL.appendingPathComponent("Resources", isDirectory: true)
        let binaryURL = frameworkURL.appendingPathComponent("MediaRemoteAdapter")
        let sourceBinaryURL = supportURL.appendingPathComponent("MediaRemoteAdapter")
        let sourceInfoPlistURL = supportURL.appendingPathComponent("Resources/Info.plist")
        let infoPlistURL = resourcesURL.appendingPathComponent("Info.plist")

        try? fileManager.removeItem(at: frameworkURL)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceBinaryURL, to: binaryURL)

        if fileManager.fileExists(atPath: sourceInfoPlistURL.path) {
            try fileManager.copyItem(at: sourceInfoPlistURL, to: infoPlistURL)
        }

        return frameworkURL
    }

    private func commandID(for command: AppleMusicTransportCommand) -> Int {
        switch command {
        case .playPause:
            return 2
        case .nextTrack:
            return 4
        case .previousTrack:
            return 5
        }
    }
}
