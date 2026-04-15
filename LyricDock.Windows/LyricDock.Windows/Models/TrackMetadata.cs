namespace LyricDock.Windows.Models;

public class TrackMetadata
{
    public string Title { get; init; } = string.Empty;
    public string Artist { get; init; } = string.Empty;
    public string Album { get; init; } = string.Empty;
    public double Duration { get; init; }

    public string NormalizedIdentity =>
        string.Join("|",
            Title.Trim().ToLowerInvariant(),
            Artist.Trim().ToLowerInvariant(),
            Album.Trim().ToLowerInvariant());

    public string Subtitle =>
        string.Join(" · ", new[] { Artist, Album }.Where(s => !string.IsNullOrWhiteSpace(s)));

    public string DisplayText =>
        string.IsNullOrWhiteSpace(Artist) ? Title : $"{Title} · {Artist}";
}
