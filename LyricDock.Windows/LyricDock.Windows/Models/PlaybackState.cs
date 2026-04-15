namespace LyricDock.Windows.Models;

public enum PlaybackState
{
    Playing,
    Paused,
    Stopped
}

public static class PlaybackStateExtensions
{
    public static string DisplayName(this PlaybackState state) => state switch
    {
        PlaybackState.Playing => "播放中",
        PlaybackState.Paused => "已暂停",
        PlaybackState.Stopped => "未播放",
        _ => "未知"
    };

    public static bool IsPlaying(this PlaybackState state) => state == PlaybackState.Playing;
}
