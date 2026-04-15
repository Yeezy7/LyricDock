using System.Text.Json;
using System.Text.Json.Serialization;
using LyricDock.Windows.Models;

namespace LyricDock.Windows.Services;

public class LRCLyricsService
{
    private readonly HttpClient _httpClient;

    public LRCLyricsService(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient();
        _httpClient.DefaultRequestHeaders.Add("User-Agent", "LyricDock/1.0");
        _httpClient.Timeout = TimeSpan.FromSeconds(12);
    }

    public async Task<LyricsPayload> FetchLyricsAsync(TrackMetadata track)
    {
        var candidates = LookupCandidates(track);

        foreach (var candidate in candidates)
        {
            var response = await RequestExactMatchAsync(candidate);
            if (response != null)
                return MakePayload(response);
        }

        var searchResponse = await RequestSearchFallbackAsync(track, candidates);
        if (searchResponse != null)
            return MakePayload(searchResponse);

        return new LyricsPayload
        {
            SyncedLines = [],
            PlainText = null,
            Source = "外部歌词库暂未命中"
        };
    }

    private async Task<LRCLIBResponse?> RequestExactMatchAsync(TrackMetadata track)
    {
        var queryParams = new List<string>();
        queryParams.Add($"track_name={Uri.EscapeDataString(track.Title)}");
        queryParams.Add($"artist_name={Uri.EscapeDataString(track.Artist)}");
        if (!string.IsNullOrWhiteSpace(track.Album))
            queryParams.Add($"album_name={Uri.EscapeDataString(track.Album)}");
        if (track.Duration > 0)
            queryParams.Add($"duration={Math.Round(track.Duration)}");

        var url = $"https://lrclib.net/api/get?{string.Join("&", queryParams)}";

        try
        {
            var response = await _httpClient.GetAsync(url);
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
                return null;
            if (!response.IsSuccessStatusCode)
                return null;

            var json = await response.Content.ReadAsStringAsync();
            return JsonSerializer.Deserialize<LRCLIBResponse>(json);
        }
        catch
        {
            return null;
        }
    }

    private async Task<LRCLIBResponse?> RequestSearchFallbackAsync(TrackMetadata track, List<TrackMetadata> candidates)
    {
        var collectedMatches = new List<LRCLIBResponse>();

        foreach (var query in SearchQueries(candidates))
        {
            var url = $"https://lrclib.net/api/search?q={Uri.EscapeDataString(query)}";

            try
            {
                var response = await _httpClient.GetAsync(url);
                if (!response.IsSuccessStatusCode) continue;

                var json = await response.Content.ReadAsStringAsync();
                var matches = JsonSerializer.Deserialize<List<LRCLIBResponse>>(json) ?? [];
                collectedMatches.AddRange(matches);

                var uniqueMatches = UniqueResponses(collectedMatches);
                var best = BestMatch(uniqueMatches, track);
                if (best != null && Score(best, track) >= 120)
                    return best;
            }
            catch
            {
                continue;
            }
        }

        return BestMatch(UniqueResponses(collectedMatches), track);
    }

    private LyricsPayload MakePayload(LRCLIBResponse response)
    {
        string syncedRawText = SimplifyChinese(response.SyncedLyrics ?? response.PlainLyrics ?? "");
        var syncedLines = LRCParser.Parse(syncedRawText);
        string plainCandidate = SimplifyChinese(response.PlainLyrics ?? response.SyncedLyrics ?? "");
        string plainText = LRCParser.StripTimestamps(plainCandidate).Trim();

        string source;
        if (response.Instrumental == true)
            source = "这首歌被标记为纯音乐";
        else if (syncedLines.Count > 0)
            source = "LRCLIB 同步歌词";
        else if (!string.IsNullOrEmpty(plainText))
            source = "LRCLIB 普通歌词";
        else
            source = "外部歌词库暂未命中";

        return new LyricsPayload
        {
            SyncedLines = syncedLines,
            PlainText = string.IsNullOrEmpty(plainText) ? null : plainText,
            Source = source
        };
    }

    private List<LRCLIBResponse> UniqueResponses(List<LRCLIBResponse> responses)
    {
        var seen = new HashSet<string>();
        return responses.Where(r =>
        {
            string id = $"{r.TrackName ?? ""}|{r.ArtistName ?? ""}|{r.AlbumName ?? ""}|{r.Duration?.ToString() ?? ""}";
            return seen.Add(id);
        }).ToList();
    }

    private LRCLIBResponse? BestMatch(List<LRCLIBResponse> responses, TrackMetadata track)
    {
        return responses.MaxBy(r => Score(r, track));
    }

    private int Score(LRCLIBResponse response, TrackMetadata track)
    {
        int total = 0;

        string targetTitle = Normalized(response.TrackName);
        string targetArtist = Normalized(response.ArtistName);
        string targetAlbum = Normalized(response.AlbumName);
        string sourceTitle = Normalized(track.Title);
        string sourceArtist = Normalized(track.Artist);
        string sourceAlbum = Normalized(track.Album);

        if (targetTitle == sourceTitle) total += 80;
        else if (targetTitle.Contains(sourceTitle) || sourceTitle.Contains(targetTitle)) total += 40;

        if (targetArtist == sourceArtist) total += 70;
        else if (targetArtist.Contains(sourceArtist) || sourceArtist.Contains(targetArtist)) total += 35;

        if (!string.IsNullOrEmpty(sourceAlbum))
        {
            if (targetAlbum == sourceAlbum) total += 30;
            else if (targetAlbum.Contains(sourceAlbum) || sourceAlbum.Contains(targetAlbum)) total += 15;
        }

        if (response.Duration.HasValue && track.Duration > 0)
        {
            double delta = Math.Abs(response.Duration.Value - track.Duration);
            if (delta < 1) total += 24;
            else if (delta < 3) total += 16;
            else if (delta < 6) total += 8;
        }

        if (response.Instrumental == true) total -= 120;

        if (response.SyncedLyrics != null) total += 18;
        else if (response.PlainLyrics != null) total += 8;

        return total;
    }

    private List<TrackMetadata> LookupCandidates(TrackMetadata track)
    {
        string baseTitle = SimplifyChinese(track.Title);
        string baseArtist = SimplifyChinese(track.Artist);
        string baseAlbum = SimplifyChinese(track.Album);
        var artistCandidates = PrimaryArtistCandidates(baseArtist);
        var titleCandidates = TitleCandidates(baseTitle);
        var albumCandidates = new[] { baseAlbum, CleanupLookupText(baseAlbum) }
            .Where(a => !string.IsNullOrWhiteSpace(a)).Distinct().ToList();

        var candidates = new List<TrackMetadata>();
        foreach (var artist in artistCandidates)
        {
            foreach (var title in titleCandidates)
            {
                candidates.Add(new TrackMetadata
                {
                    Title = title,
                    Artist = artist,
                    Album = baseAlbum,
                    Duration = track.Duration
                });

                foreach (var album in albumCandidates)
                {
                    candidates.Add(new TrackMetadata
                    {
                        Title = CleanupTrackTitle(title),
                        Artist = CleanupLookupText(artist),
                        Album = album,
                        Duration = track.Duration
                    });
                }
            }
        }

        var seen = new HashSet<string>();
        return candidates
            .Select(c => new TrackMetadata
            {
                Title = CleanupLookupText(c.Title),
                Artist = CleanupLookupText(c.Artist),
                Album = CleanupLookupText(c.Album),
                Duration = c.Duration
            })
            .Where(c => !string.IsNullOrWhiteSpace(c.Title))
            .Where(c => seen.Add(c.NormalizedIdentity))
            .ToList();
    }

    private List<string> SearchQueries(List<TrackMetadata> candidates)
    {
        var queries = new List<string>();
        foreach (var candidate in candidates)
        {
            queries.Add($"{candidate.Artist} {candidate.Title}".Trim());
            queries.Add($"{candidate.Title} {candidate.Artist}".Trim());
            queries.Add(candidate.Title);
            if (!string.IsNullOrWhiteSpace(candidate.Album))
                queries.Add($"{candidate.Artist} {candidate.Title} {candidate.Album}".Trim());
        }

        var seen = new HashSet<string>();
        return queries
            .Select(CleanupLookupText)
            .Where(q => !string.IsNullOrWhiteSpace(q))
            .Where(q => seen.Add(q.ToLowerInvariant()))
            .ToList();
    }

    private static string Normalized(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        return Regex.Replace(
            CleanupLookupText(SimplifyChinese(value)).ToLowerInvariant(),
            @"[^\p{L}\p{N}]+", "");
    }

    private static string CleanupLookupText(string value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        var result = SimplifyChinese(value);
        result = Regex.Replace(result, @"\b(feat|ft|with)\b.*$", "", RegexOptions.IgnoreCase);
        result = Regex.Replace(result, @"\[[^\]]*\]", "");
        result = Regex.Replace(result, @"[（(][^）)]*[）)]", "");
        result = Regex.Replace(result, @"\s+", " ");
        return result.Trim();
    }

    private static string CleanupTrackTitle(string value)
    {
        var result = CleanupLookupText(value);
        result = Regex.Replace(result, @"\s*(ver|version|live|mix|edit|remaster(ed)?|karaoke|伴奏)\b.*$", "", RegexOptions.IgnoreCase);
        return result.Trim();
    }

    private static List<string> PrimaryArtistCandidates(string value)
    {
        string cleaned = CleanupLookupText(value);
        string[] separators = ["&", "、", "/", " x ", " X ", " feat. ", " feat ", " ft. ", " ft "];

        var candidates = new List<string> { cleaned };
        foreach (var sep in separators)
        {
            var parts = cleaned.Split(sep, StringSplitOptions.None);
            if (parts.Length > 0)
                candidates.Add(CleanupLookupText(parts[0]));
        }

        var seen = new HashSet<string>();
        return candidates
            .Where(c => !string.IsNullOrWhiteSpace(c))
            .Where(c => seen.Add(c.ToLowerInvariant()))
            .ToList();
    }

    private static List<string> TitleCandidates(string value)
    {
        string cleaned = CleanupTrackTitle(value);
        string[] separators = [" - ", " / ", "：", ":"];

        var candidates = new List<string> { cleaned };
        foreach (var sep in separators)
        {
            var parts = cleaned.Split(sep, StringSplitOptions.None);
            if (parts.Length > 0)
                candidates.Add(CleanupTrackTitle(parts[0]));
        }

        var seen = new HashSet<string>();
        return candidates
            .Where(c => !string.IsNullOrWhiteSpace(c))
            .Where(c => seen.Add(c.ToLowerInvariant()))
            .ToList();
    }

    private static string SimplifyChinese(string value)
    {
        if (string.IsNullOrEmpty(value)) return value;
        try
        {
            return Strings.StrConv(value, VbStrConv.SimplifiedChinese, 0x0804);
        }
        catch
        {
            return value;
        }
    }

    private class LRCLIBResponse
    {
        [JsonPropertyName("id")] public int? Id { get; set; }
        [JsonPropertyName("trackName")] public string? TrackName { get; set; }
        [JsonPropertyName("artistName")] public string? ArtistName { get; set; }
        [JsonPropertyName("albumName")] public string? AlbumName { get; set; }
        [JsonPropertyName("duration")] public double? Duration { get; set; }
        [JsonPropertyName("instrumental")] public bool? Instrumental { get; set; }
        [JsonPropertyName("plainLyrics")] public string? PlainLyrics { get; set; }
        [JsonPropertyName("syncedLyrics")] public string? SyncedLyrics { get; set; }
    }
}

file static class Strings
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int LCMapStringEx(
        string? lpLocaleName, uint dwMapFlags,
        string lpSrcStr, int cchSrc,
        System.Text.StringBuilder? lpDestStr, int cchDest,
        IntPtr lpVersionInformation, IntPtr lpReserved, IntPtr sortHandle);

    private const uint LCMAP_SIMPLIFIED_CHINESE = 0x02000000;

    public static string StrConv(string value, VbStrConv conversion, int localeId)
    {
        if (string.IsNullOrEmpty(value)) return value;

        if (conversion == VbStrConv.SimplifiedChinese)
        {
            var sb = new System.Text.StringBuilder(value.Length);
            LCMapStringEx(null, LCMAP_SIMPLIFIED_CHINESE, value, value.Length, sb, sb.Capacity, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            return sb.ToString();
        }

        return value;
    }
}

file enum VbStrConv
{
    SimplifiedChinese = 256
}
