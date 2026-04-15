namespace LyricDock.Windows.Models;

public class PlaybackSnapshot
{
    private const double LyricLeadTime = 0.36;

    public TrackMetadata? Track { get; init; }
    public PlaybackState State { get; init; } = PlaybackState.Stopped;
    public double Position { get; init; }
    public DateTime UpdatedAt { get; init; } = DateTime.MinValue;
    public string? SourceAppUserModelId { get; init; }
    public List<LyricLine> Lyrics { get; init; } = [];
    public string? PlainLyrics { get; init; }
    public string LyricSource { get; init; } = "等待播放器";

    public static PlaybackSnapshot Empty { get; } = new()
    {
        Track = null,
        State = PlaybackState.Stopped,
        Position = 0,
        UpdatedAt = DateTime.MinValue,
        SourceAppUserModelId = null,
        Lyrics = [],
        PlainLyrics = null,
        LyricSource = "等待播放器"
    };

    public double PlaybackTimeAt(DateTime date)
    {
        double raw;
        if (State.IsPlaying())
            raw = Position + Math.Max(0, (date - UpdatedAt).TotalSeconds);
        else
            raw = Position;

        if (Track is null || Track.Duration <= 0)
            return Math.Max(0, raw);

        return Math.Min(Math.Max(0, raw), Track.Duration);
    }

    public LyricWindow LyricWindowAt(DateTime date)
    {
        if (Track is null)
        {
            return new LyricWindow
            {
                Current = "等待播放器开始播放",
                Next = "LyricDock 会在这里显示实时歌词",
                Caption = "未连接到播放内容"
            };
        }

        double progress = PlaybackTimeAt(date);
        double lyricProgress = LyricPlaybackTimeAt(date);

        int? activeIdx = ActiveLyricIndexAt(date);
        if (activeIdx.HasValue)
        {
            var currentLine = Lyrics[activeIdx.Value];
            string? nextLine = Lyrics.Count > activeIdx.Value + 1
                ? Lyrics[activeIdx.Value + 1].Text
                : null;

            return new LyricWindow
            {
                Current = currentLine.Text,
                Next = nextLine,
                Caption = $"{Track.Title} · {Formatted(progress)}/{Formatted(Track.Duration)}"
            };
        }

        if (Lyrics.Count > 0 && lyricProgress < Lyrics[0].Time)
        {
            string? nextLine = Lyrics.Count > 1 ? Lyrics[1].Text : null;
            double countdown = Math.Max(0, Lyrics[0].Time - lyricProgress);
            return new LyricWindow
            {
                Current = Lyrics[0].Text,
                Next = nextLine,
                Caption = $"前奏中 · {Formatted(countdown)} 后进入首句"
            };
        }

        if (!string.IsNullOrWhiteSpace(PlainLyrics))
        {
            var lines = PlainLyrics
                .Split('\n')
                .Select(l => l.Trim())
                .Where(l => !string.IsNullOrEmpty(l))
                .ToList();
            string current = lines.FirstOrDefault() ?? "歌词已加载";
            string? next = lines.Skip(1).FirstOrDefault();
            return new LyricWindow
            {
                Current = current,
                Next = next,
                Caption = $"{Track.Title} · 非逐字同步歌词"
            };
        }

        string currentText;
        if (LyricSource == "正在查找歌词…")
            currentText = Track.Title;
        else if (LyricSource.Contains("暂未命中"))
            currentText = "暂未找到歌词";
        else if (LyricSource.Contains("纯音乐"))
            currentText = "纯音乐";
        else if (LyricSource.StartsWith("歌词加载失败"))
            currentText = "歌词加载失败";
        else
            currentText = Track.Title;

        return new LyricWindow
        {
            Current = currentText,
            Next = string.IsNullOrWhiteSpace(Track.Subtitle) ? null : Track.Subtitle,
            Caption = LyricSource
        };
    }

    public int? ActiveLyricIndexAt(DateTime date)
    {
        if (Lyrics.Count == 0) return null;

        double currentTime = LyricPlaybackTimeAt(date);
        int? lastIdx = null;
        for (int i = 0; i < Lyrics.Count; i++)
        {
            if (Lyrics[i].Time <= currentTime)
                lastIdx = i;
            else
                break;
        }
        return lastIdx;
    }

    private double LyricPlaybackTimeAt(DateTime date)
    {
        double baseTime = PlaybackTimeAt(date);
        if (!State.IsPlaying()) return baseTime;

        if (Track is null || Track.Duration <= 0)
            return Math.Max(0, baseTime + LyricLeadTime);

        return Math.Min(Track.Duration, Math.Max(0, baseTime + LyricLeadTime));
    }

    private static string Formatted(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds <= 0)
            return "0:00";
        int total = (int)Math.Floor(seconds);
        return $"{total / 60}:{total % 60:D2}";
    }
}
