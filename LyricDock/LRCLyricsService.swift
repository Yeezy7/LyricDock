import Foundation

actor LRCLyricsService {
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLyrics(for track: TrackMetadata) async throws -> LyricsPayload {
        let candidates = lookupCandidates(for: track)

        for candidate in candidates {
            if let response = try await requestExactMatch(for: candidate) {
                return makePayload(from: response)
            }
        }

        if let response = try await requestSearchFallback(for: track, candidates: candidates) {
            return makePayload(from: response)
        }

        return LyricsPayload(
            syncedLines: [],
            plainText: nil,
            source: "外部歌词库暂未命中",
        )
    }

    private func requestExactMatch(for track: TrackMetadata) async throws -> LRCLIBResponse? {
        guard var components = URLComponents(string: "https://lrclib.net/api/get") else {
            throw LyricsServiceError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album.isEmpty ? nil : track.album),
            URLQueryItem(name: "duration", value: track.duration > 0 ? String(Int(track.duration.rounded())) : nil),
        ].compactMap { $0 }

        guard let url = components.url else {
            throw LyricsServiceError.invalidURL
        }

        return try await fetch(url: url, as: LRCLIBResponse.self)
    }

    private func requestSearchFallback(for track: TrackMetadata, candidates: [TrackMetadata]) async throws -> LRCLIBResponse? {
        var collectedMatches: [LRCLIBResponse] = []

        for query in searchQueries(for: candidates) {
            guard var components = URLComponents(string: "https://lrclib.net/api/search") else {
                throw LyricsServiceError.invalidURL
            }

            components.queryItems = [
                URLQueryItem(name: "q", value: query),
            ]

            guard let url = components.url else {
                throw LyricsServiceError.invalidURL
            }

            let matches = try await fetch(url: url, as: [LRCLIBResponse].self) ?? []
            collectedMatches.append(contentsOf: matches)

            let uniqueMatches = uniqueResponses(from: collectedMatches)
            if let bestMatch = bestMatch(in: uniqueMatches, for: track) {
                if score(for: bestMatch, track: track) >= 120 {
                    return bestMatch
                }
            }
        }

        return bestMatch(in: uniqueResponses(from: collectedMatches), for: track)
    }

    private func fetch<T: Decodable>(url: URL, as type: T.Type) async throws -> T? {
        var request = URLRequest(url: url)
        request.setValue("LyricDock/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LyricsServiceError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            return nil
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LyricsServiceError.serverError(httpResponse.statusCode)
        }

        return try decoder.decode(type, from: data)
    }

    private func makePayload(from response: LRCLIBResponse) -> LyricsPayload {
        let syncedRawText = simplifyChinese(response.syncedLyrics ?? response.plainLyrics ?? "")
        let syncedLines = LRCParser.parse(syncedRawText)
        let plainCandidate = simplifyChinese(response.plainLyrics ?? response.syncedLyrics ?? "")
        let plainText = LRCParser
            .stripTimestamps(from: plainCandidate)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let source: String
        if response.instrumental == true {
            source = "这首歌被标记为纯音乐"
        } else if !syncedLines.isEmpty {
            source = "LRCLIB 同步歌词"
        } else if !plainText.isEmpty {
            source = "LRCLIB 普通歌词"
        } else {
            source = "外部歌词库暂未命中"
        }

        return LyricsPayload(
            syncedLines: syncedLines,
            plainText: plainText.isEmpty ? nil : plainText,
            source: source,
        )
    }

    private func uniqueResponses(from responses: [LRCLIBResponse]) -> [LRCLIBResponse] {
        var seen: Set<String> = []
        return responses.filter { response in
            let identifier = [
                response.trackName ?? "",
                response.artistName ?? "",
                response.albumName ?? "",
                response.duration.map { String($0) } ?? "",
            ].joined(separator: "|")

            return seen.insert(identifier).inserted
        }
    }

    private func bestMatch(in responses: [LRCLIBResponse], for track: TrackMetadata) -> LRCLIBResponse? {
        responses.max { left, right in
            score(for: left, track: track) < score(for: right, track: track)
        }
    }

    private func lookupCandidates(for track: TrackMetadata) -> [TrackMetadata] {
        let baseTitle = simplifyChinese(track.title)
        let baseArtist = simplifyChinese(track.artist)
        let baseAlbum = simplifyChinese(track.album)
        let artistCandidates = primaryArtistCandidates(from: baseArtist)
        let titleCandidates = titleCandidates(from: baseTitle)
        let albumCandidates = [baseAlbum, cleanupLookupText(baseAlbum)].filter { !$0.isEmpty }

        var candidates: [TrackMetadata] = []
        for artist in artistCandidates {
            for title in titleCandidates {
                candidates.append(
                    TrackMetadata(
                        title: title,
                        artist: artist,
                        album: baseAlbum,
                        duration: track.duration
                    )
                )

                for album in albumCandidates {
                    candidates.append(
                        TrackMetadata(
                            title: cleanupTrackTitle(title),
                            artist: cleanupLookupText(artist),
                            album: album,
                            duration: track.duration
                        )
                    )
                }
            }
        }

        var seen: Set<String> = []
        return candidates
            .map {
                TrackMetadata(
                    title: cleanupLookupText($0.title),
                    artist: cleanupLookupText($0.artist),
                    album: cleanupLookupText($0.album),
                    duration: $0.duration
                )
            }
            .filter { !$0.title.isEmpty }
            .filter { seen.insert($0.normalizedIdentity).inserted }
    }

    private func searchQueries(for candidates: [TrackMetadata]) -> [String] {
        var queries: [String] = []
        for candidate in candidates {
            queries.append("\(candidate.artist) \(candidate.title)".trimmingCharacters(in: .whitespaces))
            queries.append("\(candidate.title) \(candidate.artist)".trimmingCharacters(in: .whitespaces))
            queries.append(candidate.title)
            if !candidate.album.isEmpty {
                queries.append("\(candidate.artist) \(candidate.title) \(candidate.album)".trimmingCharacters(in: .whitespaces))
            }
        }

        var seen: Set<String> = []
        return queries
            .map { cleanupLookupText($0) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func score(for response: LRCLIBResponse, track: TrackMetadata) -> Int {
        var total = 0

        let targetTitle = normalized(response.trackName)
        let targetArtist = normalized(response.artistName)
        let targetAlbum = normalized(response.albumName)
        let sourceTitle = normalized(track.title)
        let sourceArtist = normalized(track.artist)
        let sourceAlbum = normalized(track.album)

        if targetTitle == sourceTitle {
            total += 80
        } else if targetTitle.contains(sourceTitle) || sourceTitle.contains(targetTitle) {
            total += 40
        }

        if targetArtist == sourceArtist {
            total += 70
        } else if targetArtist.contains(sourceArtist) || sourceArtist.contains(targetArtist) {
            total += 35
        }

        if !sourceAlbum.isEmpty {
            if targetAlbum == sourceAlbum {
                total += 30
            } else if targetAlbum.contains(sourceAlbum) || sourceAlbum.contains(targetAlbum) {
                total += 15
            }
        }

        if let duration = response.duration, track.duration > 0 {
            let delta = abs(duration - track.duration)
            if delta < 1 {
                total += 24
            } else if delta < 3 {
                total += 16
            } else if delta < 6 {
                total += 8
            }
        }

        if response.instrumental == true {
            total -= 120
        }

        if response.syncedLyrics != nil {
            total += 18
        } else if response.plainLyrics != nil {
            total += 8
        }

        return total
    }

    private func normalized(_ value: String?) -> String {
        simplifyChinese(value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\b(feat|ft|with)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[（(][^）)]*[）)]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    private func cleanupLookupText(_ value: String) -> String {
        simplifyChinese(value)
            .replacingOccurrences(of: #"\b(feat|ft|with)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*[-–—]\s*(feat|ft|with)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[（(][^）)]*[）)]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanupTrackTitle(_ value: String) -> String {
        cleanupLookupText(value)
            .replacingOccurrences(of: #"\s*(ver|version|live|mix|edit|remaster(ed)?|karaoke|伴奏)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func primaryArtistCandidates(from value: String) -> [String] {
        let cleaned = cleanupLookupText(value)
        let separators = ["&", "、", "/", " x ", " X ", " feat. ", " feat ", " ft. ", " ft "]

        var candidates = [cleaned]
        for separator in separators {
            if let first = cleaned.components(separatedBy: separator).first {
                candidates.append(cleanupLookupText(first))
            }
        }

        var seen: Set<String> = []
        return candidates.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func titleCandidates(from value: String) -> [String] {
        let cleaned = cleanupTrackTitle(value)
        let separators = [" - ", " / ", "：", ":"]

        var candidates = [cleaned]
        for separator in separators {
            if let first = cleaned.components(separatedBy: separator).first {
                candidates.append(cleanupTrackTitle(first))
            }
        }

        var seen: Set<String> = []
        return candidates.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func simplifyChinese(_ value: String) -> String {
        let mutable = NSMutableString(string: value)
        let transform = "Traditional-Simplified" as CFString
        CFStringTransform(mutable, nil, transform, false)
        return mutable as String
    }
}

private struct LRCLIBResponse: Decodable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trackName = "trackName"
        case artistName = "artistName"
        case albumName = "albumName"
        case duration
        case instrumental
        case plainLyrics
        case syncedLyrics
    }
}

enum LyricsServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "歌词请求地址无效"
        case .invalidResponse:
            return "歌词服务返回了无法识别的响应"
        case let .serverError(code):
            return "歌词服务请求失败（HTTP \(code)）"
        }
    }
}
