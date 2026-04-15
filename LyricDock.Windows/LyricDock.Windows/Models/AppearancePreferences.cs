namespace LyricDock.Windows.Models;

public class AppearancePreferences
{
    public string Theme { get; set; } = "Sunrise";
    public double PanelOpacity { get; set; } = 0.92;
    public double LyricScale { get; set; } = 1.0;
    public bool ShowNextLine { get; set; } = true;
    public bool PreferLyrics { get; set; } = true;
    public double BarWidth { get; set; } = 500;
    public bool StartWithSystem { get; set; } = false;

    public static AppearancePreferences Default { get; } = new();
}
