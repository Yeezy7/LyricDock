namespace LyricDock.Windows.Models;

public class LyricsPayload
{
    public List<LyricLine> SyncedLines { get; init; } = [];
    public string? PlainText { get; init; }
    public string Source { get; init; } = string.Empty;

    public bool HasRenderableLyrics =>
        SyncedLines.Count > 0 ||
        (!string.IsNullOrWhiteSpace(PlainText));
}
