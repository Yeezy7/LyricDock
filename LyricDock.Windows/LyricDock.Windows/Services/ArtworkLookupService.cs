using System.Text.Json;
using System.Text.Json.Serialization;
using LyricDock.Windows.Models;

namespace LyricDock.Windows.Services;

public class ArtworkLookupService
{
    private readonly HttpClient _httpClient;
    private readonly Dictionary<string, byte[]?> _cache = new();

    public ArtworkLookupService(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient();
        _httpClient.DefaultRequestHeaders.Add("User-Agent", "LyricDock/1.0");
        _httpClient.Timeout = TimeSpan.FromSeconds(10);
    }

    public async Task<byte[]?> ArtworkDataAsync(TrackMetadata track)
    {
        string cacheKey = track.NormalizedIdentity;
        if (_cache.TryGetValue(cacheKey, out var cached))
            return cached;

        foreach (var query in SearchTerms(track))
        {
            var artworkUrl = await LookupArtworkUrlAsync(query, track);
            if (artworkUrl == null) continue;

            var data = await DownloadArtworkAsync(artworkUrl);
            if (data != null)
            {
                _cache[cacheKey] = data;
                return data;
            }
        }

        _cache[cacheKey] = null;
        return null;
    }

    private async Task<string?> LookupArtworkUrlAsync(string query, TrackMetadata track)
    {
        var queryParams = new List<string>
        {
            $"term={Uri.EscapeDataString(query)}",
            "entity=song",
            "limit=8",
            $"country={StorefrontCountryCode(track)}",
            "lang=zh_CN"
        };

        var url = $"https://itunes.apple.com/search?{string.Join("&", queryParams)}";

        try
        {
            var response = await _httpClient.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;

            var json = await response.Content.ReadAsStringAsync();
            var payload = JsonSerializer.Deserialize<ITunesSearchResponse>(json);
            return BestArtworkUrl(payload?.Results, track);
        }
        catch
        {
            return null;
        }
    }

    private string? BestArtworkUrl(List<ITunesSongResult>? results, TrackMetadata track)
    {
        if (results == null || results.Count == 0) return null;

        var best = results.MaxBy(r => ScoreResult(r, track));
        string? artworkUrl = best?.ArtworkUrl100 ?? best?.ArtworkUrl60;
        if (artworkUrl == null) return null;

        return artworkUrl
            .Replace("100x100bb", "600x600bb")
            .Replace("60x60bb", "600x600bb");
    }

    private async Task<byte[]?> DownloadArtworkAsync(string url)
    {
        try
        {
            var response = await _httpClient.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;
            return await response.Content.ReadAsByteArrayAsync();
        }
        catch
        {
            return null;
        }
    }

    private List<string> SearchTerms(TrackMetadata track)
    {
        var artistCandidates = PrimaryArtistCandidates(track.Artist);
        var titleCandidates = TitleCandidates(track.Title);
        string albumCandidate = CleanupLookupText(track.Album);

        var terms = new List<string>();
        foreach (var artist in artistCandidates)
        {
            foreach (var title in titleCandidates)
            {
                terms.Add($"{artist} {title}");
                if (!string.IsNullOrWhiteSpace(albumCandidate))
                    terms.Add($"{artist} {title} {albumCandidate}");
            }
        }
        terms.AddRange(titleCandidates);

        var seen = new HashSet<string>();
        return terms
            .Select(CleanupLookupText)
            .Where(t => !string.IsNullOrWhiteSpace(t))
            .Where(t => seen.Add(t.ToLowerInvariant()))
            .ToList();
    }

    private int ScoreResult(ITunesSongResult result, TrackMetadata track)
    {
        int total = 0;

        string sourceTitle = Normalized(track.Title);
        string sourceArtist = Normalized(track.Artist);
        string sourceAlbum = Normalized(track.Album);
        string targetTitle = Normalized(result.TrackName ?? "");
        string targetArtist = Normalized(result.ArtistName ?? "");
        string targetAlbum = Normalized(result.CollectionName ?? "");

        if (targetTitle == sourceTitle) total += 90;
        else if (targetTitle.Contains(sourceTitle) || sourceTitle.Contains(targetTitle)) total += 45;

        if (targetArtist == sourceArtist) total += 80;
        else if (targetArtist.Contains(sourceArtist) || sourceArtist.Contains(targetArtist)) total += 36;

        if (!string.IsNullOrEmpty(sourceAlbum))
        {
            if (targetAlbum == sourceAlbum) total += 26;
            else if (targetAlbum.Contains(sourceAlbum) || sourceAlbum.Contains(targetAlbum)) total += 12;
        }

        if (result.TrackTimeMillis.HasValue && track.Duration > 0)
        {
            double delta = Math.Abs(result.TrackTimeMillis.Value / 1000.0 - track.Duration);
            if (delta < 1) total += 24;
            else if (delta < 4) total += 12;
        }

        return total;
    }

    private static string StorefrontCountryCode(TrackMetadata track)
    {
        string joined = $"{track.Title} {track.Artist} {track.Album}";
        return ContainsChinese(joined) ? "cn" : "us";
    }

    private static bool ContainsChinese(string value)
    {
        return value.Any(c => c >= 0x4E00 && c <= 0x9FFF || c >= 0x3400 && c <= 0x4DBF);
    }

    private static string Normalized(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        return Regex.Replace(
            CleanupLookupText(value).ToLowerInvariant(),
            @"[^\p{L}\p{N}]+", "");
    }

    private static string CleanupLookupText(string value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        var result = Regex.Replace(value, @"\b(feat|ft|with)\b.*$", "", RegexOptions.IgnoreCase);
        result = Regex.Replace(result, @"\[[^\]]*\]", "");
        result = Regex.Replace(result, @"[（(][^）)]*[）)]", "");
        result = Regex.Replace(result, @"\s+", " ");
        return result.Trim();
    }

    private static string CleanupTrackTitle(string value)
    {
        var result = CleanupLookupText(value);
        result = Regex.Replace(result, @"\s*(ver|version|live|mix|edit|remaster(ed)?|karaoke)\b.*$", "", RegexOptions.IgnoreCase);
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

    private class ITunesSearchResponse
    {
        [JsonPropertyName("results")] public List<ITunesSongResult> Results { get; set; } = [];
    }

    private class ITunesSongResult
    {
        [JsonPropertyName("trackName")] public string? TrackName { get; set; }
        [JsonPropertyName("artistName")] public string? ArtistName { get; set; }
        [JsonPropertyName("collectionName")] public string? CollectionName { get; set; }
        [JsonPropertyName("trackTimeMillis")] public int? TrackTimeMillis { get; set; }
        [JsonPropertyName("artworkUrl100")] public string? ArtworkUrl100 { get; set; }
        [JsonPropertyName("artworkUrl60")] public string? ArtworkUrl60 { get; set; }
    }
}
