using System.Text.Json;
using LyricDock.Windows.Models;

namespace LyricDock.Windows.Services;

public class LyricCacheStore
{
    private class CachedLyricsEntry
    {
        public LyricsPayload Payload { get; set; } = new();
        public DateTime CachedAt { get; set; }
    }

    private static readonly TimeSpan CacheLifetime = TimeSpan.FromDays(14);
    private static readonly TimeSpan PurgeInterval = TimeSpan.FromHours(1);
    private readonly string _cachePath;
    private Dictionary<string, CachedLyricsEntry> _cache;
    private DateTime _lastPurgeDate = DateTime.MinValue;

    public LyricCacheStore()
    {
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string cacheDir = Path.Combine(appData, "LyricDock");
        Directory.CreateDirectory(cacheDir);
        _cachePath = Path.Combine(cacheDir, "lyrics-cache.json");
        _cache = LoadCache();
    }

    public LyricsPayload? CachedPayload(string key)
    {
        PurgeExpiredEntriesIfNeeded();
        if (!_cache.TryGetValue(key, out var entry)) return null;
        if (DateTime.Now - entry.CachedAt >= CacheLifetime)
        {
            _cache.Remove(key);
            return null;
        }
        return entry.Payload;
    }

    public void Save(LyricsPayload payload, string key)
    {
        _cache[key] = new CachedLyricsEntry { Payload = payload, CachedAt = DateTime.Now };
        Persist();
    }

    private void PurgeExpiredEntriesIfNeeded()
    {
        var now = DateTime.Now;
        if (now - _lastPurgeDate < PurgeInterval) return;
        _lastPurgeDate = now;

        int originalCount = _cache.Count;
        _cache = _cache
            .Where(kvp => now - kvp.Value.CachedAt < CacheLifetime)
            .ToDictionary(kvp => kvp.Key, kvp => kvp.Value);

        if (_cache.Count != originalCount) Persist();
    }

    private void Persist()
    {
        try
        {
            var json = JsonSerializer.Serialize(_cache);
            File.WriteAllText(_cachePath, json);
        }
        catch
        {
            // ignore
        }
    }

    private Dictionary<string, CachedLyricsEntry> LoadCache()
    {
        try
        {
            if (!File.Exists(_cachePath)) return [];
            var json = File.ReadAllText(_cachePath);
            return JsonSerializer.Deserialize<Dictionary<string, CachedLyricsEntry>>(json) ?? [];
        }
        catch
        {
            return [];
        }
    }
}
