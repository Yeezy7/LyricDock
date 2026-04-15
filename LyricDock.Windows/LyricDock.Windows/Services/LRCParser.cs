using System.Text.RegularExpressions;
using LyricDock.Windows.Models;

namespace LyricDock.Windows.Services;

public static class LRCParser
{
    private static readonly Regex TimestampPattern = new(
        @"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]",
        RegexOptions.Compiled);

    public static List<LyricLine> Parse(string rawValue)
    {
        return rawValue
            .Split('\n')
            .SelectMany(ParseLine)
            .OrderBy(l => l.Time)
            .ToList();
    }

    public static string StripTimestamps(string rawValue)
    {
        return string.Join("\n",
            rawValue.Split('\n')
                .Select(line => TimestampPattern.Replace(line, "").Trim())
                .Where(line => !string.IsNullOrEmpty(line)));
    }

    private static IEnumerable<LyricLine> ParseLine(string line)
    {
        var matches = TimestampPattern.Matches(line);
        if (matches.Count == 0) yield break;

        string text = TimestampPattern.Replace(line, "").Trim();
        if (string.IsNullOrEmpty(text)) yield break;

        foreach (Match match in matches)
        {
            if (!double.TryParse(match.Groups[1].Value, out double minutes)) continue;
            if (!double.TryParse(match.Groups[2].Value, out double seconds)) continue;

            double fraction = 0;
            if (match.Groups[3].Success)
            {
                string rawFraction = match.Groups[3].Value;
                fraction = rawFraction.Length switch
                {
                    3 => (double.TryParse(rawFraction, out double f3) ? f3 : 0) / 1000,
                    2 => (double.TryParse(rawFraction, out double f2) ? f2 : 0) / 100,
                    _ => (double.TryParse(rawFraction, out double f1) ? f1 : 0) / 10
                };
            }

            yield return new LyricLine
            {
                Time = minutes * 60 + seconds + fraction,
                Text = text
            };
        }
    }
}
