using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace ServerMaster.Windows.Views;

/// <summary>
/// The moving colour behind the window, the effect Apple Music puts behind a playing album, and
/// the Windows counterpart of the Mac <c>AmbientBackground</c>. WinUI has no mesh gradient, so it
/// is the Mac fallback done properly: large soft radial blobs of six shades of one hue drift on
/// Lissajous paths; their transparent falloff blends where they meet. (An acrylic layer over them
/// was tried and dropped: its luminosity pass turns the palette grey.)
/// The motion runs as composition expression animations, off the UI thread, so it stays smooth
/// while the app is busy.
/// </summary>
public sealed class AmbientBackground : Grid
{
    private const int BlobCount = 8;
    private readonly Canvas _canvas = new() { IsHitTestVisible = false };
    private readonly List<Ellipse> _blobs = [];
    private readonly Compositor _compositor;
    private readonly CompositionPropertySet _clock;
    private IReadOnlyList<Color> _palette = [];
    private double _speed = 1;
    private bool _enabled = true;
    private bool _animating;

    public AmbientBackground()
    {
        IsHitTestVisible = false;
        _compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
        _clock = _compositor.CreatePropertySet();
        _clock.InsertScalar("t", 0);
        _clock.InsertScalar("w", 1);
        _clock.InsertScalar("h", 1);
        _clock.InsertScalar("r", 1);
        Children.Add(_canvas);
        for (var index = 0; index < BlobCount; index++)
        {
            var blob = new Ellipse();
            ElementCompositionPreview.SetIsTranslationEnabled(blob, true);
            _canvas.Children.Add(blob);
            _blobs.Add(blob);
            Attach(blob, index);
        }
        SizeChanged += (_, args) => Resize(args.NewSize.Width, args.NewSize.Height);
        Unloaded += (_, _) => StopClock();
        Loaded += (_, _) => Restart();
    }

    /// <summary>Six shades (the Mac palette), how fast they drift (0 stops), and whether to draw at all.</summary>
    public void Apply(IReadOnlyList<Color> palette, double speed, bool enabled)
    {
        var changedMotion = Math.Abs(speed - _speed) > 0.001 || enabled != _enabled;
        _palette = palette;
        _speed = speed;
        _enabled = enabled;
        Background = new SolidColorBrush(palette.Count > 0 ? palette[0] : Color.FromArgb(255, 31, 33, 37));
        _canvas.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        for (var index = 0; index < _blobs.Count && palette.Count > 1; index++)
        {
            // Skip the base shade so every blob adds colour on top of it.
            var colour = palette[1 + index % (palette.Count - 1)];
            _blobs[index].Fill = new RadialGradientBrush
            {
                GradientStops =
                {
                    new GradientStop { Color = colour, Offset = 0 },
                    new GradientStop { Color = Color.FromArgb(200, colour.R, colour.G, colour.B), Offset = .35 },
                    new GradientStop { Color = Color.FromArgb(0, colour.R, colour.G, colour.B), Offset = 1 }
                }
            };
        }
        if (changedMotion || !_animating) Restart();
    }

    private void Resize(double width, double height)
    {
        var radius = (float)(Math.Max(width, height) * .42);
        _clock.InsertScalar("w", (float)width);
        _clock.InsertScalar("h", (float)height);
        _clock.InsertScalar("r", radius);
        foreach (var blob in _blobs) blob.Width = blob.Height = radius * 2;
    }

    /// <summary>Each blob follows its own phase of the Mac blob path, centred on its position.</summary>
    private void Attach(Ellipse blob, int index)
    {
        var phase = (index * 2.4f).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var phaseY = (index * 2.4f * 1.3f).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var expression = _compositor.CreateExpressionAnimation(
            $"Vector3(c.w * (0.5 + 0.45 * Sin(c.t + {phase})) - c.r, c.h * (0.5 + 0.40 * Cos(c.t * 0.73 + {phaseY})) - c.r, 0)");
        expression.SetReferenceParameter("c", _clock);
        ElementCompositionPreview.GetElementVisual(blob).StartAnimation("Translation", expression);
    }

    private void Restart()
    {
        StopClock();
        // Respect "Animation effects" off in Windows, as the Mac respects Reduce Motion.
        var animations = new global::Windows.UI.ViewManagement.UISettings().AnimationsEnabled;
        if (!_enabled || _speed <= 0 || !animations) return;
        // Radians per second: the Mac mesh turns time * speed / 2.6.
        var rate = (float)(_speed / 2.6);
        var duration = TimeSpan.FromHours(8);
        var run = _compositor.CreateScalarKeyFrameAnimation();
        run.InsertKeyFrame(0, 0);
        run.InsertKeyFrame(1, rate * (float)duration.TotalSeconds, _compositor.CreateLinearEasingFunction());
        run.Duration = duration;
        run.IterationBehavior = AnimationIterationBehavior.Forever;
        _clock.StartAnimation("t", run);
        _animating = true;
    }

    private void StopClock()
    {
        _clock.StopAnimation("t");
        _animating = false;
    }
}
