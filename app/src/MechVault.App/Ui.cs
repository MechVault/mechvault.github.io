using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.LogicalTree;
using Avalonia.Media;
using MechVault.Core;

namespace MechVault.App;

public static class Ui
{
    static readonly Dictionary<string, IBrush> Cache = new();

    public static IBrush B(string hex)
    {
        if (!Cache.TryGetValue(hex, out var b)) Cache[hex] = b = new SolidColorBrush(Color.Parse(hex)).ToImmutable();
        return b;
    }

    public static IBrush Res(string key) =>
        Application.Current!.TryGetResource(key, Application.Current.ActualThemeVariant, out var v) && v is IBrush b ? b : Brushes.Transparent;

    public static Geometry Icon(string key) =>
        Application.Current!.TryGetResource(key, Application.Current.ActualThemeVariant, out var v) && v is Geometry g ? g : new StreamGeometry();

    public static Avalonia.Controls.Shapes.Path IconPath(string key, string stroke, double size = 12) => new()
    {
        Data = Icon(key), Stroke = B(stroke), StrokeThickness = 1.6, StrokeLineCap = PenLineCap.Round, StrokeJoin = PenLineJoin.Round,
        Stretch = Stretch.Uniform, Width = size, Height = size,
    };

    public static TextBlock Text(string text, string fg = "#F5F5F7", double size = 13, bool wrap = false, FontWeight? weight = null) => new()
    {
        Text = text, Foreground = B(fg), FontSize = size, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        FontWeight = weight ?? FontWeight.Normal,
    };

        public static void Translate(ILogical root, Loc loc)
    {
        if (loc.Map.Count == 0) return;
        string Tr(string s) => loc.Map.TryGetValue(s, out var v) && !string.IsNullOrEmpty(v) ? v : s;
        void Walk(ILogical o)
        {
            switch (o)
            {
                case TextBlock tb when tb.Inlines is { Count: > 0 } inl:
                    foreach (var i in inl) if (i is Run r && !string.IsNullOrEmpty(r.Text)) r.Text = Tr(r.Text);
                    break;
                case TextBlock tb when !string.IsNullOrEmpty(tb.Text):
                    tb.Text = Tr(tb.Text);
                    break;
                case ContentControl cc when cc.Content is string s:
                    cc.Content = Tr(s);
                    break;
                case TextBox tx when !string.IsNullOrEmpty(tx.Watermark):
                    tx.Watermark = Tr(tx.Watermark);
                    break;
            }
            if (o is Window w && !string.IsNullOrEmpty(w.Title)) w.Title = Tr(w.Title);
            if (o is Control c && ToolTip.GetTip(c) is string tip) ToolTip.SetTip(c, Tr(tip));
            foreach (var ch in o.LogicalChildren.ToList()) Walk(ch);
        }
        Walk(root);
    }

    public static IEnumerable<T> All<T>(ILogical root) where T : class
    {
        foreach (var c in root.LogicalChildren)
        {
            if (c is T t) yield return t;
            foreach (var x in All<T>(c)) yield return x;
        }
    }

        public static string? Checked(Panel p) => p.Children.OfType<RadioButton>().FirstOrDefault(r => r.IsChecked == true)?.Tag?.ToString();

    public static void Check(Panel p, string tag)
    {
        foreach (var r in p.Children.OfType<RadioButton>()) if (string.Equals(r.Tag?.ToString(), tag, StringComparison.OrdinalIgnoreCase)) r.IsChecked = true;
    }

        public static void ApplyGlass(Window w, Panel? root, Control? sheen, bool glass)
    {
        if (glass)
        {
            w.TransparencyLevelHint = new[] { WindowTransparencyLevel.Transparent, WindowTransparencyLevel.None };
            w.Background = B("#B0100C0C");
            w.Opened += (_, _) =>
            {
                if (w.ActualTransparencyLevel == WindowTransparencyLevel.None) w.Background = B("#F21C1C1E");
            };
        }
        else
        {
            w.TransparencyLevelHint = new[] { WindowTransparencyLevel.None };
            w.Background = B("#FF1B1B1F");
            if (sheen is not null) sheen.IsVisible = false;
        }
    }
}
