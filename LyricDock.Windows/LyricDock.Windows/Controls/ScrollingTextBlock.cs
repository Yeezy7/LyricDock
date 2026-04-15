using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace LyricDock.Windows.Controls;

public class ScrollingTextBlock : Control
{
    private const double ScrollSpeed = 32.0;
    private const double Gap = 28.0;
    private static readonly TimeSpan InitialPause = TimeSpan.FromSeconds(1.1);

    private FormattedText? _formattedText;
    private double _measuredWidth;
    private DateTime _scrollStartTime;

    static ScrollingTextBlock()
    {
        DefaultStyleKeyProperty.OverrideMetadata(typeof(ScrollingTextBlock),
            new FrameworkPropertyMetadata(typeof(ScrollingTextBlock)));
    }

    public static readonly DependencyProperty TextProperty =
        DependencyProperty.Register(nameof(Text), typeof(string), typeof(ScrollingTextBlock),
            new FrameworkPropertyMetadata(string.Empty, OnTextChanged));

    public static readonly DependencyProperty ScrollWidthProperty =
        DependencyProperty.Register(nameof(ScrollWidth), typeof(double), typeof(ScrollingTextBlock),
            new FrameworkPropertyMetadata(200.0, OnLayoutChanged));

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public double ScrollWidth
    {
        get => (double)GetValue(ScrollWidthProperty);
        set => SetValue(ScrollWidthProperty, value);
    }

    private static void OnTextChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var ctrl = (ScrollingTextBlock)d;
        ctrl._scrollStartTime = DateTime.Now;
        ctrl.MeasureText();
        ctrl.InvalidateVisual();
    }

    private static void OnLayoutChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var ctrl = (ScrollingTextBlock)d;
        ctrl.MeasureText();
        ctrl.InvalidateVisual();
    }

    private void MeasureText()
    {
        var typeface = new Typeface(FontFamily, FontStyle, FontWeight, FontStretch);
        _formattedText = new FormattedText(
            Text,
            System.Globalization.CultureInfo.CurrentCulture,
            FlowDirection.LeftToRight,
            typeface,
            FontSize,
            Foreground,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
        _measuredWidth = _formattedText.Width;
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);

        if (_formattedText == null) MeasureText();
        if (_formattedText == null) return;

        double clipWidth = ScrollWidth;

        if (_measuredWidth <= clipWidth)
        {
            drawingContext.DrawText(_formattedText, new Point(0, 0));
            return;
        }

        double travel = _measuredWidth + Gap;
        double cycleDuration = travel / ScrollSpeed;
        double totalCycleDuration = cycleDuration + InitialPause.TotalSeconds;

        double elapsed = (DateTime.Now - _scrollStartTime).TotalSeconds;
        double timeInCycle = elapsed % totalCycleDuration;

        double offset;
        if (timeInCycle < InitialPause.TotalSeconds)
        {
            offset = 0;
        }
        else
        {
            double progress = (timeInCycle - InitialPause.TotalSeconds) / cycleDuration;
            offset = -travel * progress;
        }

        drawingContext.PushClip(new RectangleGeometry(new Rect(0, 0, clipWidth, ActualHeight)));

        drawingContext.DrawText(_formattedText, new Point(offset, 0));

        var secondText = _formattedText;
        drawingContext.DrawText(secondText, new Point(offset + travel, 0));

        drawingContext.Pop();
    }
}
