using System.Drawing;
using System.Windows;
using Hardcodet.Wpf.TaskbarNotification;
using LyricDock.Windows.ViewModels;
using LyricDock.Windows.Views;

namespace LyricDock.Windows;

public partial class App : Application
{
    private MainViewModel? _viewModel;
    private LyricBarWindow? _lyricBarWindow;
    private TaskbarIcon? _notifyIcon;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _viewModel = new MainViewModel();
        await _viewModel.StartAsync();

        _lyricBarWindow = new LyricBarWindow(_viewModel);
        _lyricBarWindow.Show();

        SetupTrayIcon();
    }

    private void SetupTrayIcon()
    {
        _notifyIcon = new TaskbarIcon
        {
            ToolTipText = "LyricDock - 歌词显示",
            Icon = SystemIcons.Application,
            ContextMenu = CreateTrayContextMenu()
        };

        _notifyIcon.TrayMouseDoubleClick += (_, _) => ToggleLyricBar();
    }

    private System.Windows.Controls.ContextMenu CreateTrayContextMenu()
    {
        var menu = new System.Windows.Controls.ContextMenu();

        var showItem = new System.Windows.Controls.MenuItem { Header = "显示歌词条" };
        showItem.Click += (_, _) => ToggleLyricBar();
        menu.Items.Add(showItem);

        var refreshItem = new System.Windows.Controls.MenuItem { Header = "刷新歌词" };
        refreshItem.Click += async (_, _) =>
        {
            if (_viewModel != null) await _viewModel.ManualRefreshAsync();
        };
        menu.Items.Add(refreshItem);

        menu.Items.Add(new System.Windows.Controls.Separator());

        var startWithSystemItem = new System.Windows.Controls.MenuItem
        {
            Header = "开机自启",
            IsCheckable = true,
            IsChecked = _viewModel?.Settings.IsStartWithSystemEnabled() ?? false
        };
        startWithSystemItem.Click += (_, _) =>
        {
            if (_viewModel != null)
            {
                _viewModel.Settings.SetStartWithSystem(startWithSystemItem.IsChecked);
            }
        };
        menu.Items.Add(startWithSystemItem);

        menu.Items.Add(new System.Windows.Controls.Separator());

        var quitItem = new System.Windows.Controls.MenuItem { Header = "退出 LyricDock" };
        quitItem.Click += (_, _) => Shutdown();
        menu.Items.Add(quitItem);

        return menu;
    }

    private void ToggleLyricBar()
    {
        if (_lyricBarWindow == null) return;

        if (_lyricBarWindow.Visibility == Visibility.Visible)
        {
            _lyricBarWindow.Hide();
        }
        else
        {
            _lyricBarWindow.Show();
            _lyricBarWindow.Topmost = true;
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _notifyIcon?.Dispose();
        _viewModel?.Dispose();
        base.OnExit(e);
    }
}
