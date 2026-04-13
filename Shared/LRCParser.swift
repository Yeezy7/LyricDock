import Foundation

enum LRCParser {
    private static let timestampExpression = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#,
    )

    static func parse(_ rawValue: String) -> [LyricLine] {
        rawValue
            .components(separatedBy: .newlines)
            .flatMap(parseLine)
            .sorted { $0.time < $1.time }
    }

    static func stripTimestamps(from rawValue: String) -> String {
        rawValue
            .components(separatedBy: .newlines)
            .map { line in
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                return timestampExpression
                    .stringByReplacingMatches(in: line, range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func parseLine(_ line: String) -> [LyricLine] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = timestampExpression.matches(in: line, range: range)

        guard !matches.isEmpty else {
            return []
        }

        let text = timestampExpression
            .stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return []
        }

        return matches.compactMap { match in
            guard
                let minuteRange = Range(match.range(at: 1), in: line),
                let secondRange = Range(match.range(at: 2), in: line)
            else {
                return nil
            }

            let minutes = Double(line[minuteRange]) ?? 0
            let seconds = Double(line[secondRange]) ?? 0

            let fraction: Double
            if let fractionRange = Range(match.range(at: 3), in: line) {
                let rawFraction = String(line[fractionRange])
                switch rawFraction.count {
                case 3:
                    fraction = (Double(rawFraction) ?? 0) / 1000
                case 2:
                    fraction = (Double(rawFraction) ?? 0) / 100
                default:
                    fraction = (Double(rawFraction) ?? 0) / 10
                }
            } else {
                fraction = 0
            }

            return LyricLine(
                time: minutes * 60 + seconds + fraction,
                text: text,
            )
        }
    }
}
