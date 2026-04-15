using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LyricDock.Windows.ViewModels;

namespace LyricDock.Windows.Views;

public partial class LyricBarWindow : Window
{
    private readonly MainViewModel _viewModel;
    private bool _isDragging;
    private Point _dragStartPoint;
    private readonly DispatcherTimer _refreshTimer;
    private BitmapImage? _currentArtwork;

    private const double SnapThreshold = 20.0;

    public LyricBarWindow(MainViewModel viewModel)
    {
        _viewModel = viewModel;

        InitializeComponent();

        _viewModel.SnapshotChanged += OnSnapshotChanged;
        _viewModel.ArtworkChanged += OnArtworkChanged;

        _refreshTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(500)
        };
        _refreshTimer.Tick += OnRefreshTimerTick;
        _refreshTimer.Start();

        UpdateDisplayText();
    }

    private void OnSnapshotChanged()
    {
        Dispatcher.Invoke(UpdateDisplayText);
    }

    private void OnArtworkChanged(BitmapImage? image)
    {
        Dispatcher.Invoke(() =>
        {
            _currentArtwork = image;
            if (image != null)
            {
                ArtworkImage.Source = image;
                ArtworkImage.Visibility = Visibility.Visible;
                MusicIcon.Visibility = Visibility.Collapsed;
            }
            else
            {
                ArtworkImage.Source = null;
                ArtworkImage.Visibility = Visibility.Collapsed;
                MusicIcon.Visibility = Visibility.Visible;
            }
        });
    }

    private void UpdateDisplayText()
    {
        string displayText = _viewModel.GetBarDisplayText();
        LyricText.Text = displayText;

        bool isPlaying = _viewModel.Snapshot.State.IsPlaying();
        _refreshTimer.Interval = isPlaying ? TimeSpan.FromMilliseconds(500) : TimeSpan.FromSeconds(2);

        UpdatePlayPauseIcon(isPlaying);
    }

    private void UpdatePlayPauseIcon(bool isPlaying)
    {
        var template = PlayPauseButton.Template;
        if (template.FindName("Icon", PlayPauseButton) is not System.Windows.Shapes.Path icon) return;

        if (isPlaying)
        {
            icon.Data = Geometry.Parse("M4,2 L4,14 M12,2 L12,14");
            icon.Stroke = System.Windows.Media.Brushes.Black;
            icon.StrokeThickness = 2;
            icon.Fill = null;
            icon.Stretch = Stretch.Uniform;
            icon.Width = 10;
            icon.Height = 10;
            PlayPauseButton.ToolTip = "暂停";
        }
        else
        {
            icon.Data = Geometry.Parse("M4,2 L4,14 L14,8 Z");
            icon.Fill = new System.Windows.Media.SolidColorBrush(
                System.Windows.Media.Color.FromArgb(0xD9, 0, 0, 0));
            icon.Stroke = null;
            icon.Stretch = Stretch.Uniform;
            icon.Width = 10;
            icon.Height = 10;
            PlayPauseButton.ToolTip = "播放";
        }
    }

    private void OnRefreshTimerTick(object? sender, EventArgs e)
    {
        LyricText.InvalidateVisual();
    }

    private void OnPreviousClick(object sender, RoutedEventArgs e)
    {
        _ = _viewModel.PreviousTrackAsync();
    }

    private void OnPlayPauseClick(object sender, RoutedEventArgs e)
    {
        _ = _viewModel.TogglePlayPauseAsync();
    }

    private void OnNextClick(object sender, RoutedEventArgs e)
    {
        _ = _viewModel.NextTrackAsync();
    }

    private void OnArtworkClick(object sender, MouseButtonEventArgs e)
    {
    }

    #region Drag & Snap

    private void OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _isDragging = true;
        _dragStartPoint = e.GetPosition(this);
        CaptureMouse();
    }

    private void OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_isDragging) return;
        _isDragging = false;
        ReleaseMouseCapture();
        SnapToEdge();
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (!_isDragging) return;

        var currentPos = e.GetPosition(this);
        double dx = currentPos.X - _dragStartPoint.X;
        double dy = currentPos.Y - _dragStartPoint.Y;

        Left += dx;
        Top += dy;
    }

    private void OnLocationChanged(object? sender, EventArgs e)
    {
        SnapToEdge();
    }

    private void SnapToEdge()
    {
        if (_isDragging) return;

        var screen = SystemParameters.WorkArea;

        if (Top < SnapThreshold)
            Top = 0;
        else if (Top + Height > screen.Height - SnapThreshold)
            Top = screen.Height - Height;

        if (Left < SnapThreshold)
            Left = 0;
        else if (Left + Width > screen.Width - SnapThreshold)
            Left = screen.Width - Width;
    }

    #endregion

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        var screen = SystemParameters.WorkArea;
        Left = (screen.Width - Width) / 2;
        Top = 0;
    }

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _refreshTimer.Stop();
        _viewModel.SnapshotChanged -= OnSnapshotChanged;
        _viewModel.ArtworkChanged -= OnArtworkChanged;
    }
}
