using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using MechVault.Core;
using static MechVault.App.Ui;

namespace MechVault.App.Views;

public static class NoFocus
{
    [DllImport("user32.dll")] static extern int GetWindowLong(nint h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(nint h, int i, int v);

        public static void Apply(Window w)
    {
        w.ShowActivated = false;
        w.Focusable = false;
        if (!OperatingSystem.IsWindows()) return;
        w.Opened += (_, _) =>
        {
            var h = w.TryGetPlatformHandle()?.Handle ?? 0;
            if (h == 0) return;
            var ex = GetWindowLong(h, -20);
            SetWindowLong(h, -20, ex | 0x80 | 0x08000000);
        };
    }
}

public sealed class OverlayWindow : Window
{
    static AppState S => AppState.I;
    static string T(string k, params object?[] a) => S.T(k, a);

    readonly LayoutTransformControl _scale;
    readonly StackPanel _full, _mini;
    readonly TextBlock _bal, _txt, _miniTxt;
    readonly Avalonia.Controls.Shapes.Path _sizeIcon;
    bool _dragging, _placed;

    public OverlayWindow()
    {
        SystemDecorations = SystemDecorations.None;
        Topmost = true;
        ShowInTaskbar = false;
        CanResize = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        TransparencyLevelHint = new[] { WindowTransparencyLevel.Transparent };
        Background = Brushes.Transparent;
        Title = "MechVault";
        Icon = App.AppIcon;
        NoFocus.Apply(this);

        var glass = S.LiquidGlass;
        var root = new Grid { Margin = new Thickness(16), Cursor = new Cursor(StandardCursorType.SizeAll) };
        ToolTip.SetTip(root, T("Trascina per spostare"));
        root.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(26),
            Background = glass
                ? new LinearGradientBrush
                {
                    StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
                    GradientStops = { new GradientStop(Color.Parse("#B01C1C22"), 0), new GradientStop(Color.Parse("#A010121A"), 0.5), new GradientStop(Color.Parse("#B01C1C22"), 1) },
                }
                : B("#F21E1E22"),
            BoxShadow = BoxShadows.Parse("0 4 24 0 #73000000"),
        });
        if (glass)
        {
            root.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(26), IsHitTestVisible = false,
                Background = new RadialGradientBrush
                {
                    Center = new RelativePoint(0.5, 0.5, RelativeUnit.Relative), GradientOrigin = new RelativePoint(0.5, 0.5, RelativeUnit.Relative),
                    RadiusX = new RelativeScalar(0.75, RelativeUnit.Relative), RadiusY = new RelativeScalar(0.9, RelativeUnit.Relative),
                    GradientStops = { new GradientStop(Color.Parse("#05FFFFFF"), 0.55), new GradientStop(Color.Parse("#2BFFFFFF"), 0.92), new GradientStop(Color.Parse("#40FFFFFF"), 1) },
                },
            });
            root.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(26), BorderThickness = new Thickness(1.2), IsHitTestVisible = false,
                BorderBrush = new LinearGradientBrush
                {
                    StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
                    GradientStops = { new GradientStop(Color.Parse("#F2FFFFFF"), 0), new GradientStop(Color.Parse("#40FFFFFF"), 0.32), new GradientStop(Color.Parse("#1AFFFFFF"), 0.55), new GradientStop(Color.Parse("#B3FFFFFF"), 1) },
                },
            });
            root.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(24, 24, 60, 60), Margin = new Thickness(4, 3, 4, 0), VerticalAlignment = VerticalAlignment.Top, Height = 20, IsHitTestVisible = false,
                Background = new LinearGradientBrush
                {
                    StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                    GradientStops = { new GradientStop(Color.Parse("#59FFFFFF"), 0), new GradientStop(Color.Parse("#00FFFFFF"), 1) },
                },
            });
        }
        else root.Children.Add(new Border { CornerRadius = new CornerRadius(26), BorderThickness = new Thickness(1), BorderBrush = B("#2EFFFFFF"), IsHitTestVisible = false });

        var dock = new DockPanel { Margin = new Thickness(18, 11, 11, 11) };
        _sizeIcon = IconPath("IcShrink", "#E6FFFFFF", 10);
        var sizeBtn = new Button
        {
            Width = 24, Height = 24, Padding = new Thickness(0), CornerRadius = new CornerRadius(12), Background = B("#1FFFFFFF"), BorderBrush = B("#66FFFFFF"),
            Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Focusable = false, Content = _sizeIcon, Cursor = new Cursor(StandardCursorType.Hand),
        };
        ToolTip.SetTip(sizeBtn, T("Rimpicciolisci / ingrandisci"));
        DockPanel.SetDock(sizeBtn, Dock.Right);
        dock.Children.Add(sizeBtn);

        var content = new Grid();
        _full = new StackPanel { Width = 310 };
        var head = new StackPanel { Orientation = Orientation.Horizontal };
        head.Children.Add(new Avalonia.Controls.Shapes.Ellipse { Width = 7, Height = 7, Fill = B("#30D158"), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center });
        head.Children.Add(Text(T("Risparmio attivo · non spendere"), "#A8F5BE", 11, weight: FontWeight.SemiBold));
        _full.Children.Add(head);
        _bal = Text("", "#FFFFFF", 15, weight: FontWeight.SemiBold); _bal.Margin = new Thickness(0, 4, 0, 0);
        _txt = Text("", "#CCFFFFFF", 11); _txt.Margin = new Thickness(0, 1, 0, 0); _txt.TextTrimming = TextTrimming.CharacterEllipsis;
        _full.Children.Add(_bal); _full.Children.Add(_txt);
        _mini = new StackPanel { Orientation = Orientation.Horizontal, IsVisible = false, VerticalAlignment = VerticalAlignment.Center };
        _mini.Children.Add(new Avalonia.Controls.Shapes.Ellipse { Width = 7, Height = 7, Fill = B("#30D158"), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center });
        _miniTxt = Text("", "#FFFFFF", 12, weight: FontWeight.SemiBold); _miniTxt.VerticalAlignment = VerticalAlignment.Center;
        _mini.Children.Add(_miniTxt);
        content.Children.Add(_full); content.Children.Add(_mini);
        content.Effect = new DropShadowEffect { BlurRadius = 8, OffsetX = 0, OffsetY = 0, Opacity = 0.7, Color = Colors.Black };
        dock.Children.Add(content);
        root.Children.Add(dock);

        _scale = new LayoutTransformControl { Child = root };
        Content = _scale;

        root.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed || e.Source is Button) return;
            _dragging = true;
            BeginMoveDrag(e);
            SavePosition();
            _dragging = false;
        };

        var settle = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
        settle.Tick += (_, _) => { settle.Stop(); if (IsVisible) SavePosition(); };
        PositionChanged += (_, _) => { if (_placed && !_dragging) { settle.Stop(); settle.Start(); } };
        sizeBtn.Click += (_, _) =>
        {
            var o = OverlayPrefs.Load(S.Paths.Overlay);
            o.Mode = o.NextMode();
            var scaling = RenderScaling;
            var right = Position.X + Bounds.Width * scaling; var bottom = Position.Y + Bounds.Height * scaling;
            ApplyMode(o.Mode);
            Dispatcher.UIThread.Post(() =>
            {
                Position = new PixelPoint((int)(right - Bounds.Width * RenderScaling), (int)(bottom - Bounds.Height * RenderScaling));
                o.X = Position.X; o.Y = Position.Y; o.Save(S.Paths.Overlay);
            }, DispatcherPriority.Render);
        };
        Opened += (_, _) => Dispatcher.UIThread.Post(() => { Place(); _placed = true; }, DispatcherPriority.Render);
        ApplyMode(OverlayPrefs.Load(S.Paths.Overlay).Mode);
        Update();
    }

    void SavePosition()
    {
        var o = OverlayPrefs.Load(S.Paths.Overlay);
        o.X = Position.X; o.Y = Position.Y;
        o.Save(S.Paths.Overlay);
    }

    public void ApplyMode(string mode)
    {
        var sc = mode == "small" ? 0.78 : 1.0;
        _scale.LayoutTransform = new ScaleTransform(sc, sc);
        _full.IsVisible = mode != "mini";
        _mini.IsVisible = mode == "mini";
        _sizeIcon.Data = Ui.Icon(mode == "mini" ? "IcGrow" : "IcShrink");
    }

        public void Place()
    {
        var o = OverlayPrefs.Load(S.Paths.Overlay);
        var screens = Screens.All;
        var w = (int)Math.Max(40, Bounds.Width * RenderScaling); var h = (int)Math.Max(20, Bounds.Height * RenderScaling);
        if (o.X is { } x && o.Y is { } y && screens.Any(s => s.Bounds.Contains(new PixelPoint((int)x, (int)y)) && s.Bounds.Contains(new PixelPoint((int)x + 40, (int)y + 20))))
        {
            Position = new PixelPoint((int)x, (int)y);
            return;
        }
        var wa = (Screens.Primary ?? screens.FirstOrDefault())?.WorkingArea ?? new PixelRect(0, 0, 1280, 720);
        Position = new PixelPoint(wa.Right - w - 18, wa.Bottom - h - 18);
    }

    public void ResetPosition()
    {
        var o = OverlayPrefs.Load(S.Paths.Overlay);
        o.X = null; o.Y = null; o.Mode = "full"; o.Save(S.Paths.Overlay);
        ApplyMode("full");
        Dispatcher.UIThread.Post(Place, DispatcherPriority.Render);
    }

    public void Update()
    {
        var d = S.D; var E = S.Env;
        var cTxt = d.InitCredits ? E.Fmt(d.Credits) : "—";
        var aTxt = d.InitAcoins ? E.Fmt(d.Acoins) : "—";
        _bal.Text = T("{0} crediti  ·  {1} A-coin", cTxt, aTxt);
        var first = S.Stats.GoalStats().FirstOrDefault();
        var mb = S.Stats.Mission("credits");
        var tail = mb.Budget > 0 ? T(" · missioni {0} rimasti", E.Short(mb.Left)) : "";
        _miniTxt.Text = first is not null ? $"{Math.Floor(first.Pct * 100)}% · {E.Short(d.Credits)} cr · {E.Short(d.Acoins)} A" : $"{E.Short(d.Credits)} cr · {E.Short(d.Acoins)} A";
        _txt.Text = first is not null ? $"{S.AccountName} · {first.Goal.Name} {Math.Floor(first.Pct * 100)}%{tail}" : $"{S.AccountName} · {T("{0} giorni puliti", S.Stats.Streak())}{tail}";
    }
}

public static class Notifier
{
    public static void Show(string title, string text)
    {
        if (AppState.I.SelfTest) return;
        try
        {
            if (OperatingSystem.IsMacOS())
            {
                static string Esc(string s) => s.Replace("\\", "\\\\").Replace("\"", "\\\"");
                _ = Platform.GamePlatform.Run("/usr/bin/osascript", new[] { "-e", $"display notification \"{Esc(text)}\" with title \"{Esc(title)}\"" }, 5000);
                return;
            }
            if (OperatingSystem.IsLinux() && Platform.GamePlatform.Which("notify-send") is { } ns)
            {
                _ = Platform.GamePlatform.Run(ns, new[] { "-a", "MechVault", title, text }, 5000);
                return;
            }
        }
        catch { }
        Dispatcher.UIThread.Post(() => new Toast(title, text).Show());
    }

    sealed class Toast : Window
    {
        public Toast(string title, string text)
        {
            SystemDecorations = SystemDecorations.None; Topmost = true; ShowInTaskbar = false; CanResize = false;
            SizeToContent = SizeToContent.WidthAndHeight; Background = Brushes.Transparent;
            TransparencyLevelHint = new[] { WindowTransparencyLevel.Transparent };
            NoFocus.Apply(this);
            var sp = new StackPanel { Width = 320 };
            sp.Children.Add(Text(title, "#F5F5F7", 13, weight: FontWeight.SemiBold));
            var t = Text(text, "#B8FFFFFF", 12, true); t.Margin = new Thickness(0, 4, 0, 0); sp.Children.Add(t);
            Content = new Border
            {
                Margin = new Thickness(12), Padding = new Thickness(18, 14), CornerRadius = new CornerRadius(18), Background = B("#F21C1C1E"),
                BorderBrush = B("#33FFFFFF"), BorderThickness = new Thickness(1), BoxShadow = BoxShadows.Parse("0 4 20 0 #66000000"), Child = sp,
            };
            PointerPressed += (_, _) => Close();
            Opened += (_, _) => Dispatcher.UIThread.Post(() =>
            {
                var wa = Screens.Primary?.WorkingArea ?? new PixelRect(0, 0, 1280, 720);
                Position = new PixelPoint(wa.Right - (int)(Bounds.Width * RenderScaling) - 12, wa.Bottom - (int)(Bounds.Height * RenderScaling) - 12);
            }, DispatcherPriority.Render);
            DispatcherTimer.RunOnce(Close, TimeSpan.FromSeconds(6));
        }
    }
}
