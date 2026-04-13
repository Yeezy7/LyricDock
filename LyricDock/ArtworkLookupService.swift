import AppKit
import Foundation

actor ArtworkLookupService {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var cache: [String: Data?] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func artworkData(for track: TrackMetadata) async -> Data? {
        let cacheKey = track.normalizedIdentity
        if let cached = cache[cacheKey] {
            return cached
        }

        for query in searchTerms(for: track) {
            guard let artworkURL = await lookupArtworkURL(for: query, track: track) else {
                continue
            }

            if let data = await downloadArtwork(from: artworkURL) {
                cache[cacheKey] = data
                return data
            }
        }

        cache[cacheKey] = nil
        return nil
    }

    private func lookupArtworkURL(for query: String, track: TrackMetadata) async -> URL? {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "country", value: storefrontCountryCode(for: track)),
            URLQueryItem(name: "lang", value: "zh_CN"),
        ]

        guard let url = components.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("LyricDock/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let payload = try decoder.decode(ITunesSearchResponse.self, from: data)
            return bestArtworkURL(in: payload.results, for: track)
        } catch {
            return nil
        }
    }

    private func bestArtworkURL(in results: [ITunesSongResult], for track: TrackMetadata) -> URL? {
        let bestResult = results.max { left, right in
            score(left, for: track) < score(right, for: track)
        }

        guard let artworkURLString = bestResult?.artworkURLString else {
            return nil
        }

        let upgradedURLString = artworkURLString
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            .replacingOccurrences(of: "60x60bb", with: "600x600bb")

        return URL(string: upgradedURLString)
    }

    private func downloadArtwork(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func searchTerms(for track: TrackMetadata) -> [String] {
        let artistCandidates = primaryArtistCandidates(from: track.artist)
        let titleCandidates = titleCandidates(from: track.title)
        let albumCandidate = cleanupLookupText(track.album)

        var terms: [String] = []
        for artist in artistCandidates {
            for title in titleCandidates {
                terms.append("\(artist) \(title)")
                if !albumCandidate.isEmpty {
                    terms.append("\(artist) \(title) \(albumCandidate)")
                }
            }
        }

        terms.append(contentsOf: titleCandidates)

        var seen: Set<String> = []
        return terms
            .map(cleanupLookupText)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
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

    private func score(_ result: ITunesSongResult, for track: TrackMetadata) -> Int {
        var total = 0

        let sourceTitle = normalized(track.title)
        let sourceArtist = normalized(track.artist)
        let sourceAlbum = normalized(track.album)
        let targetTitle = normalized(result.trackName)
        let targetArtist = normalized(result.artistName)
        let targetAlbum = normalized(result.collectionName)

        if targetTitle == sourceTitle {
            total += 90
        } else if targetTitle.contains(sourceTitle) || sourceTitle.contains(targetTitle) {
            total += 45
        }

        if targetArtist == sourceArtist {
            total += 80
        } else if targetArtist.contains(sourceArtist) || sourceArtist.contains(targetArtist) {
            total += 36
        }

        if !sourceAlbum.isEmpty {
            if targetAlbum == sourceAlbum {
                total += 26
            } else if targetAlbum.contains(sourceAlbum) || sourceAlbum.contains(targetAlbum) {
                total += 12
            }
        }

        if let millis = result.trackTimeMillis, track.duration > 0 {
            let delta = abs((Double(millis) / 1000) - track.duration)
            if delta < 1 {
                total += 24
            } else if delta < 4 {
                total += 12
            }
        }

        return total
    }

    private func storefrontCountryCode(for track: TrackMetadata) -> String {
        let joined = [track.title, track.artist, track.album].joined(separator: " ")
        return joined.containsChineseCharacters ? "cn" : "us"
    }

    private func normalized(_ value: String?) -> String {
        cleanupLookupText(value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    private func cleanupTrackTitle(_ value: String) -> String {
        cleanupLookupText(value)
            .replacingOccurrences(of: #"\s*(ver|version|live|mix|edit|remaster(ed)?|karaoke)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanupLookupText(_ value: String) -> String {
        let mutable = NSMutableString(string: value)
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)

        return (mutable as String)
            .replacingOccurrences(of: #"\b(feat|ft|with)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[（(][^）)]*[）)]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesSongResult]
}

private struct ITunesSongResult: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let trackTimeMillis: Int?
    let artworkUrl100: String?
    let artworkUrl60: String?

    var artworkURLString: String? {
        artworkUrl100 ?? artworkUrl60
    }
}

private extension String {
    var containsChineseCharacters: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}
