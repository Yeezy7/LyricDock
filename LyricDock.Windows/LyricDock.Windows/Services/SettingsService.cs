using System.Text.Json;
using LyricDock.Windows.Models;

namespace LyricDock.Windows.Services;

public class SettingsService
{
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "LyricDock", "settings.json");

    public AppearancePreferences Preferences { get; private set; } = Load();

    public void Save(AppearancePreferences preferences)
    {
        Preferences = preferences;
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);
            var json = JsonSerializer.Serialize(preferences, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(SettingsPath, json);
        }
        catch
        {
            // ignore
        }
    }

    private static AppearancePreferences Load()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return new AppearancePreferences();
            var json = File.ReadAllText(SettingsPath);
            return JsonSerializer.Deserialize<AppearancePreferences>(json) ?? new AppearancePreferences();
        }
        catch
        {
            return new AppearancePreferences();
        }
    }

    public bool IsStartWithSystemEnabled()
    {
        try
        {
            string keyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(keyPath, false);
            return key?.GetValue("LyricDock") != null;
        }
        catch
        {
            return false;
        }
    }

    public void SetStartWithSystem(bool enabled)
    {
        try
        {
            string keyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(keyPath, true)!;
            if (enabled)
            {
                string exePath = Environment.ProcessPath ?? "";
                key.SetValue("LyricDock", $"\"{exePath}\"");
            }
            else
            {
                key.DeleteValue("LyricDock", false);
            }
        }
        catch
        {
            // ignore
        }
    }
}
