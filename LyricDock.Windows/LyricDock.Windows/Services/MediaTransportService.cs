using Windows.Media.Control;
using LyricDock.Windows.Models;

namespace LyricDock.Windows.Services;

public class MediaTransportService : IDisposable
{
    private GlobalSystemMediaTransportControlsSessionManager? _sessionManager;
    private GlobalSystemMediaTransportControlsSession? _currentSession;
    private bool _disposed;

    public event Action<PlaybackSnapshot>? PlaybackChanged;

    public async Task StartAsync()
    {
        _sessionManager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
        _sessionManager.SessionsChanged += OnSessionsChanged;
        UpdateCurrentSession();
    }

    public async Task<PlaybackSnapshot> GetCurrentPlaybackAsync()
    {
        try
        {
            var session = _sessionManager?.GetCurrentSession();
            if (session == null) return PlaybackSnapshot.Empty;

            var mediaProperties = await session.TryGetMediaPropertiesAsync();
            var timeline = session.GetTimelineProperties();
            var playbackInfo = session.GetPlaybackInfo();

            var state = playbackInfo.PlaybackStatus switch
            {
                GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing => PlaybackState.Playing,
                GlobalSystemMediaTransportControlsSessionPlaybackStatus.Paused => PlaybackState.Paused,
                _ => PlaybackState.Stopped
            };

            var track = new TrackMetadata
            {
                Title = mediaProperties?.Title ?? "",
                Artist = mediaProperties?.Artist ?? "",
                Album = mediaProperties?.AlbumTitle ?? "",
                Duration = timeline.EndTime.TotalSeconds
            };

            return new PlaybackSnapshot
            {
                Track = string.IsNullOrWhiteSpace(track.Title) ? null : track,
                State = state,
                Position = timeline.Position.TotalSeconds,
                UpdatedAt = DateTime.Now,
                SourceAppUserModelId = session.SourceAppUserModelId,
                Lyrics = [],
                PlainLyrics = null,
                LyricSource = "正在查找歌词…"
            };
        }
        catch
        {
            return PlaybackSnapshot.Empty;
        }
    }

    public async Task TogglePlayPauseAsync()
    {
        try
        {
            var session = _sessionManager?.GetCurrentSession();
            if (session == null) return;

            if (session.GetPlaybackInfo().PlaybackStatus ==
                GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
                await session.TryPauseAsync();
            else
                await session.TryPlayAsync();
        }
        catch
        {
            // ignore
        }
    }

    public async Task NextTrackAsync()
    {
        try
        {
            var session = _sessionManager?.GetCurrentSession();
            if (session != null)
                await session.TrySkipNextAsync();
        }
        catch
        {
            // ignore
        }
    }

    public async Task PreviousTrackAsync()
    {
        try
        {
            var session = _sessionManager?.GetCurrentSession();
            if (session != null)
                await session.TrySkipPreviousAsync();
        }
        catch
        {
            // ignore
        }
    }

    private void OnSessionsChanged(GlobalSystemMediaTransportControlsSessionManager sender, SessionsChangedEventArgs args)
    {
        UpdateCurrentSession();
    }

    private void UpdateCurrentSession()
    {
        if (_currentSession != null)
        {
            _currentSession.MediaPropertiesChanged -= OnMediaPropertiesChanged;
            _currentSession.PlaybackInfoChanged -= OnPlaybackInfoChanged;
            _currentSession.TimelinePropertiesChanged -= OnTimelinePropertiesChanged;
        }

        _currentSession = _sessionManager?.GetCurrentSession();

        if (_currentSession != null)
        {
            _currentSession.MediaPropertiesChanged += OnMediaPropertiesChanged;
            _currentSession.PlaybackInfoChanged += OnPlaybackInfoChanged;
            _currentSession.TimelinePropertiesChanged += OnTimelinePropertiesChanged;
        }

        _ = RefreshPlayback();
    }

    private void OnMediaPropertiesChanged(GlobalSystemMediaTransportControlsSession sender, MediaPropertiesChangedEventArgs args)
    {
        _ = RefreshPlayback();
    }

    private void OnPlaybackInfoChanged(GlobalSystemMediaTransportControlsSession sender, PlaybackInfoChangedEventArgs args)
    {
        _ = RefreshPlayback();
    }

    private void OnTimelinePropertiesChanged(GlobalSystemMediaTransportControlsSession sender, TimelinePropertiesChangedEventArgs args)
    {
        _ = RefreshPlayback();
    }

    private async Task RefreshPlayback()
    {
        var snapshot = await GetCurrentPlaybackAsync();
        PlaybackChanged?.Invoke(snapshot);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        if (_currentSession != null)
        {
            _currentSession.MediaPropertiesChanged -= OnMediaPropertiesChanged;
            _currentSession.PlaybackInfoChanged -= OnPlaybackInfoChanged;
            _currentSession.TimelinePropertiesChanged -= OnTimelinePropertiesChanged;
        }

        if (_sessionManager != null)
        {
            _sessionManager.SessionsChanged -= OnSessionsChanged;
        }
    }
}
