using System.Windows;
using System.Windows.Media.Imaging;
using LyricDock.Windows.Models;
using LyricDock.Windows.Services;

namespace LyricDock.Windows.ViewModels;

public class MainViewModel : IDisposable
{
    private readonly MediaTransportService _mediaService;
    private readonly LRCLyricsService _lyricsService;
    private readonly ArtworkLookupService _artworkService;
    private readonly LyricCacheStore _lyricCacheStore;
    private readonly SettingsService _settingsService;
    private readonly Dictionary<string, LyricsPayload> _memoryCache = new();
    private CancellationTokenSource? _lyricLoadCts;
    private string? _lyricLoadIdentity;
    private string? _lastTrackIdentity;
    private PlaybackState _lastPlaybackState;
    private DateTime _lastTrackChangeDate = DateTime.MinValue;
    private static readonly TimeSpan TrackTransitionDuration = TimeSpan.FromSeconds(2.2);

    public PlaybackSnapshot Snapshot { get; private set; } = PlaybackSnapshot.Empty;
    public SettingsService Settings => _settingsService;

    public event Action? SnapshotChanged;
    public event Action<BitmapImage?>? ArtworkChanged;

    public MainViewModel()
    {
        _mediaService = new MediaTransportService();
        _lyricsService = new LRCLyricsService();
        _artworkService = new ArtworkLookupService();
        _lyricCacheStore = new LyricCacheStore();
        _settingsService = new SettingsService();
    }

    public async Task StartAsync()
    {
        _mediaService.PlaybackChanged += OnPlaybackChanged;
        await _mediaService.StartAsync();
    }

    public async Task TogglePlayPauseAsync() => await _mediaService.TogglePlayPauseAsync();
    public async Task NextTrackAsync() => await _mediaService.NextTrackAsync();
    public async Task PreviousTrackAsync() => await _mediaService.PreviousTrackAsync();

    public async Task ManualRefreshAsync()
    {
        var playback = await _mediaService.GetCurrentPlaybackAsync();
        await ApplyPlaybackAsync(playback, forceLyricReload: true);
    }

    public string GetBarDisplayText()
    {
        var snapshot = Snapshot;
        var track = snapshot.Track;
        if (track == null) return "等待播放";

        if (!snapshot.State.IsPlaying()) return track.DisplayText;

        bool isTrackTransition = DateTime.Now - _lastTrackChangeDate < TrackTransitionDuration;
        if (isTrackTransition) return track.DisplayText;

        if (snapshot.LyricSource == "正在查找歌词…") return track.DisplayText;

        if (_settingsService.Preferences.PreferLyrics)
        {
            var lyricWindow = snapshot.LyricWindowAt(DateTime.Now);
            if (lyricWindow.Current != "等待播放器开始播放" && lyricWindow.Current != track.Title)
                return lyricWindow.Current;
        }

        return track.DisplayText;
    }

    private void OnPlaybackChanged(PlaybackSnapshot playback)
    {
        _ = ApplyPlaybackAsync(playback);
    }

    private async Task ApplyPlaybackAsync(PlaybackSnapshot playback, bool forceLyricReload = false)
    {
        string? trackIdentity = playback.Track?.NormalizedIdentity;
        bool stateChanged = playback.State != _lastPlaybackState;
        bool trackChanged = trackIdentity != _lastTrackIdentity;

        var immediatePayload = ImmediateLyricsPayload(playback.Track, forceLyricReload);

        var newSnapshot = new PlaybackSnapshot
        {
            Track = playback.Track,
            State = playback.State,
            Position = playback.Position,
            UpdatedAt = playback.UpdatedAt,
            SourceAppUserModelId = playback.SourceAppUserModelId,
            Lyrics = immediatePayload.SyncedLines,
            PlainLyrics = immediatePayload.PlainText,
            LyricSource = immediatePayload.Source
        };

        if (stateChanged || trackChanged)
        {
            if (trackChanged) _lastTrackChangeDate = DateTime.Now;
            Snapshot = newSnapshot;
            _lastPlaybackState = playback.State;
            _lastTrackIdentity = trackIdentity;
            SnapshotChanged?.Invoke();

            if (playback.Track != null)
                _ = LoadArtworkAsync(playback.Track);
        }
        else if (Math.Abs(playback.Position - Snapshot.Position) > 1.0 ||
                 Math.Abs((playback.UpdatedAt - Snapshot.UpdatedAt).TotalSeconds) > 2.0)
        {
            Snapshot = new PlaybackSnapshot
            {
                Track = Snapshot.Track,
                State = Snapshot.State,
                Position = playback.Position,
                UpdatedAt = playback.UpdatedAt,
                SourceAppUserModelId = Snapshot.SourceAppUserModelId,
                Lyrics = Snapshot.Lyrics,
                PlainLyrics = Snapshot.PlainLyrics,
                LyricSource = Snapshot.LyricSource
            };
            SnapshotChanged?.Invoke();
        }

        if (playback.Track == null) return;

        string currentTrackIdentity = playback.Track.NormalizedIdentity;
        if (forceLyricReload || _lyricLoadIdentity != currentTrackIdentity)
        {
            _lyricLoadCts?.Cancel();
            _lyricLoadIdentity = null;
        }

        bool shouldFetch = forceLyricReload || !HasResolvedLyrics(playback.Track);
        if (!shouldFetch) return;

        if (_lyricLoadIdentity == currentTrackIdentity && _lyricLoadCts != null) return;

        _lyricLoadIdentity = currentTrackIdentity;
        _lyricLoadCts = new CancellationTokenSource();
        var token = _lyricLoadCts.Token;

        _ = Task.Run(async () =>
        {
            try
            {
                var payload = await ResolveLyricsAsync(playback.Track, forceLyricReload);
                if (token.IsCancellationRequested) return;

                Application.Current.Dispatcher.Invoke(() =>
                {
                    if (Snapshot.Track?.NormalizedIdentity != trackIdentity) return;

                    Snapshot = new PlaybackSnapshot
                    {
                        Track = Snapshot.Track,
                        State = Snapshot.State,
                        Position = Snapshot.Position,
                        UpdatedAt = Snapshot.UpdatedAt,
                        SourceAppUserModelId = Snapshot.SourceAppUserModelId,
                        Lyrics = payload.SyncedLines,
                        PlainLyrics = payload.PlainText,
                        LyricSource = payload.Source
                    };

                    if (_lyricLoadIdentity == currentTrackIdentity)
                    {
                        _lyricLoadCts?.Dispose();
                        _lyricLoadCts = null;
                        _lyricLoadIdentity = null;
                    }

                    SnapshotChanged?.Invoke();
                });
            }
            catch (OperationCanceledException)
            {
                // expected
            }
        }, token);
    }

    private LyricsPayload ImmediateLyricsPayload(TrackMetadata? track, bool forceReload)
    {
        if (track == null)
            return new LyricsPayload { Source = "没有活动歌曲" };

        if (!forceReload &&
            Snapshot.Track?.NormalizedIdentity == track.NormalizedIdentity &&
            (Snapshot.Lyrics.Count > 0 || !string.IsNullOrWhiteSpace(Snapshot.PlainLyrics)))
        {
            return new LyricsPayload
            {
                SyncedLines = Snapshot.Lyrics,
                PlainText = Snapshot.PlainLyrics,
                Source = Snapshot.LyricSource
            };
        }

        if (!forceReload && _memoryCache.TryGetValue(track.NormalizedIdentity, out var cached))
            return cached;

        return new LyricsPayload { Source = "正在查找歌词…" };
    }

    private bool HasResolvedLyrics(TrackMetadata track)
    {
        if (Snapshot.Track?.NormalizedIdentity == track.NormalizedIdentity)
            return Snapshot.Lyrics.Count > 0
                || !string.IsNullOrWhiteSpace(Snapshot.PlainLyrics)
                || Snapshot.LyricSource != "正在查找歌词…";

        return _memoryCache.TryGetValue(track.NormalizedIdentity, out var cached)
            && (cached.HasRenderableLyrics || cached.Source != "正在查找歌词…");
    }

    private async Task<LyricsPayload> ResolveLyricsAsync(TrackMetadata track, bool forceReload)
    {
        string cacheKey = track.NormalizedIdentity;

        if (!forceReload && _memoryCache.TryGetValue(cacheKey, out var cached))
            return cached;

        if (!forceReload && _lyricCacheStore.CachedPayload(cacheKey) is { } diskCached)
        {
            _memoryCache[cacheKey] = diskCached;
            return diskCached;
        }

        try
        {
            var payload = await _lyricsService.FetchLyricsAsync(track);
            _memoryCache[cacheKey] = payload;
            _lyricCacheStore.Save(payload, cacheKey);
            return payload;
        }
        catch (Exception ex)
        {
            var failurePayload = new LyricsPayload
            {
                Source = $"歌词加载失败：{ex.Message}"
            };
            _memoryCache[cacheKey] = failurePayload;
            return failurePayload;
        }
    }

    private async Task LoadArtworkAsync(TrackMetadata track)
    {
        try
        {
            var data = await _artworkService.ArtworkDataAsync(track);
            if (data == null)
            {
                ArtworkChanged?.Invoke(null);
                return;
            }

            Application.Current.Dispatcher.Invoke(() =>
            {
                var image = new BitmapImage();
                using var stream = new System.IO.MemoryStream(data);
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.StreamSource = stream;
                image.EndInit();
                image.Freeze();
                ArtworkChanged?.Invoke(image);
            });
        }
        catch
        {
            ArtworkChanged?.Invoke(null);
        }
    }

    public void Dispose()
    {
        _mediaService.Dispose();
        _lyricLoadCts?.Cancel();
        _lyricLoadCts?.Dispose();
    }
}
