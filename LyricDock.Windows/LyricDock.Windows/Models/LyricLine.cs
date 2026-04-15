namespace LyricDock.Windows.Models;

public class LyricLine
{
    public double Time { get; init; }
    public string Text { get; init; } = string.Empty;

    public string Id => $"{(int)(Time * 1000)}-{Text}";
}
