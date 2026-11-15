using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using MechVault.Core;
using static MechVault.App.Ui;

namespace MechVault.App.Views;

public class GlassDialog : Window
{
    protected static AppState S => AppState.I;
    protected static string T(string k, params object?[] a) => S.T(k, a);
    public Border Panel { get; }

    public GlassDialog(string title, double width)
    {
        Title = title;
        Width = width;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        SystemDecorations = SystemDecorations.None;
        Topmost = true;
        ShowInTaskbar = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = App.AppIcon;
        TransparencyLevelHint = new[] { WindowTransparencyLevel.Transparent, WindowTransparencyLevel.None };
        Background = Brushes.Transparent;
        Panel = new Border
        {
            Padding = new Thickness(36, 32), CornerRadius = new CornerRadius(22), BorderThickness = new Thickness(1.2),
            Background = S.LiquidGlass ? B("#E61A1A1E") : B("#FF1B1B1F"),
            BorderBrush = S.LiquidGlass ? Res("GlassEdge") : B("#2EFFFFFF"),
        };
        Content = Panel;
        Opened += (_, _) =>
        {
            if (ActualTransparencyLevel == WindowTransparencyLevel.None) { Background = B("#FF1B1B1F"); Panel.CornerRadius = new CornerRadius(0); }
        };
        Panel.PointerPressed += (_, e) => { if (e.Source == Panel && e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) BeginMoveDrag(e); };
    }

        public Task ShowAsync(Window? owner)
    {
        Translate(this, S.L);
        if (owner is { IsVisible: true })
        {
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            return ShowDialog(owner);
        }
        var tcs = new TaskCompletionSource();
        Closed += (_, _) => tcs.TrySetResult();
        Show();
        Activate();
        return tcs.Task;
    }

    protected static Border Chip(string text, string fg, string bg, string border, string? icon = null)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        if (icon is not null) { var ic = IconPath(icon, fg, 11); ic.Margin = new Thickness(0, 0, 8, 0); sp.Children.Add(ic); }
        sp.Children.Add(Text(text, fg, 12, weight: FontWeight.SemiBold));
        return new Border { HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(12), Padding = new Thickness(12, 5), Background = B(bg), BorderBrush = B(border), BorderThickness = new Thickness(1), Child = sp };
    }
}

public static class Dialogs
{
    static string T(string k, params object?[] a) => AppState.I.T(k, a);

    public static async Task<bool> Confirm(Window? owner, string text, bool danger = false) => await Show(owner, text, true, danger);
    public static async Task Message(Window? owner, string text) => await Show(owner, text, false, false);

    static async Task<bool> Show(Window? owner, string text, bool yesNo, bool danger)
    {
        var w = new GlassDialog("MechVault", 460);
        var result = false;
        var sp = new StackPanel();
        var msg = Text(text, "#F5F5F7", 15, true); msg.LineHeight = 22; msg.Margin = new Thickness(0, 0, 0, 22);
        sp.Children.Add(msg);
        var btns = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var no = new Button { Content = T("Annulla"), Margin = new Thickness(0, 0, 8, 0), IsVisible = yesNo };
        var yes = new Button { Content = yesNo ? T("Conferma") : "OK", MinWidth = 96, Classes = { danger ? "danger" : "primary" } };
        no.Click += (_, _) => { result = false; w.Close(); };
        yes.Click += (_, _) => { result = true; w.Close(); };
        btns.Children.Add(no); btns.Children.Add(yes);
        sp.Children.Add(btns);
        w.Panel.Child = sp;
        w.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) w.Close();
            else if (e.Key == Key.Enter) { result = true; w.Close(); }
        };
        await w.ShowAsync(owner);
        return yesNo ? result : true;
    }
}

public sealed class ViolationDialog : GlassDialog
{
    ViolationAnswer? _result;
    readonly TextBox _why;

    public ViolationDialog(string cur, double lost, double covered, string src, int streak) : base(T("MechVault - spesa rilevata"), 580)
    {
        var E = S.Env;
        var sp = new StackPanel();
        sp.Children.Add(Chip(src == "auto" ? T("Spesa rilevata dal gioco") : T("Spesa rilevata"), "#FFB4AB", "#29FF453A", "#59FF453A", "IcWarn"));
        var amt = Text($"−{E.Fmt(lost)} {E.CurName(cur)}", "#FF8A80", 52, weight: FontWeight.Light); amt.Margin = new Thickness(0, 10, 0, 0);
        sp.Children.Add(amt);
        var body = "";
        if (covered > 0) body += T("Il budget missioni di oggi ha coperto {0} {1}; questo è il resto. ", E.Fmt(covered), E.CurName(cur));
        body += streak > 0 ? T("Avevi {0} giorni puliti: la serie riparte da zero.", streak) : T("La serie riparte da zero.");
        var rate = S.Stats.GetRate(cur).V;
        if (rate > 0) body += T(" Hai bruciato circa {0} giorni di grind.", Math.Round(lost / rate, 1).ToString("0.#", E.C));
        body += "\n" + T("Se era per una missione giornaliera premi «Era una missione»: non rompe la serie.");
        var b = Text(body, "#B8FFFFFF", 13, true); b.LineHeight = 21; b.Margin = new Thickness(0, 6, 0, 20);
        sp.Children.Add(b);
        sp.Children.Add(Text(T("Perché l'hai fatto? (obbligatorio, almeno 15 caratteri)"), "#7AFFFFFF", 12));
        _why = new TextBox { Margin = new Thickness(0, 8, 0, 18), Height = 80, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, VerticalContentAlignment = VerticalAlignment.Top, Padding = new Thickness(14, 10) };
        sp.Children.Add(_why);
        var dp = new DockPanel();
        var ok = new Button { Content = T("Confesso. Azzera la serie."), Classes = { "danger" }, IsEnabled = false };
        DockPanel.SetDock(ok, Dock.Right);
        dp.Children.Add(ok);
        var left = new StackPanel { Orientation = Orientation.Horizontal };
        var mission = new Button { Content = T("Era una missione"), Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(mission, T("Non rompe la serie: viene contata nel budget missioni"));
        var typo = new Button { Content = T("Lettura sbagliata"), Classes = { "ghost" }, Padding = new Thickness(8, 10) };
        left.Children.Add(mission); left.Children.Add(typo);
        dp.Children.Add(left);
        sp.Children.Add(dp);
        Panel.Child = sp;
        _why.TextChanged += (_, _) => ok.IsEnabled = (_why.Text ?? "").Trim().Length >= 15;
        ok.Click += (_, _) => { _result = new(ViolationKind.Confess, (_why.Text ?? "").Trim()); Close(); };
        mission.Click += (_, _) => { _result = new(ViolationKind.Mission, (_why.Text ?? "").Trim()); Close(); };
        typo.Click += (_, _) => { _result = new(ViolationKind.Typo, ""); Close(); };
        Closing += (_, e) => { if (_result is null) e.Cancel = true; };
        Opened += (_, _) => _why.Focus();
    }

    public static async Task<ViolationAnswer> Ask(Window? owner, string cur, double lost, double covered, string src, int streak)
    {
        var d = new ViolationDialog(cur, lost, covered, src, streak);
        await d.ShowAsync(owner);
        return d._result ?? new(ViolationKind.Typo, "");
    }
}

public sealed class AccountDialog : GlassDialog
{
    public string? Picked { get; private set; }

    public AccountDialog(bool fromGame) : base(T("MechVault - account"), 480)
    {
        var sp = new StackPanel();
        sp.Children.Add(Chip(fromGame ? T("Mech Arena rilevato") : T("Cambia account"), "#F5F5F7", "#1FFFFFFF", "#33FFFFFF"));
        var h = Text(T("Con quale account giochi?"), "#F5F5F7", 26, weight: FontWeight.SemiBold); h.Margin = new Thickness(0, 14, 0, 4);
        sp.Children.Add(h);
        var sub = Text(T("Ogni account ha saldi, obiettivi e serie separati."), "#B8FFFFFF"); sub.Margin = new Thickness(0, 0, 0, 20);
        sp.Children.Add(sub);
        foreach (var a in S.Store.List())
        {
            var active = a.Id == S.Store.ActiveId;
            var b = new Button
            {
                Content = active ? T("{0}   ·   ultimo usato", a.Name) : a.Name, Margin = new Thickness(0, 0, 0, 10), Padding = new Thickness(18, 13), FontSize = 15,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            if (active) b.Classes.Add("primary");
            var id = a.Id;
            b.Click += (_, _) => { Picked = id; Close(); };
            sp.Children.Add(b);
        }
        var nl = Text(T("Nuovo account"), "#7AFFFFFF", 12, weight: FontWeight.SemiBold); nl.Margin = new Thickness(0, 12, 0, 8);
        sp.Children.Add(nl);
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        var name = new TextBox { Watermark = T("Nome del nuovo account") };
        var create = new Button { Content = T("Crea e usa"), Margin = new Thickness(8, 0, 0, 0) };
        Grid.SetColumn(create, 1);
        g.Children.Add(name); g.Children.Add(create);
        sp.Children.Add(g);
        void Create() { var n = (name.Text ?? "").Trim(); if (n != "") { Picked = "new:" + n; Close(); } }
        create.Click += (_, _) => Create();
        name.KeyDown += (_, e) => { if (e.Key == Key.Enter) Create(); };
        Panel.Child = sp;
        Closing += (_, _) => Picked ??= S.Store.ActiveId;
    }
}

public sealed class WarnWindow : GlassDialog
{
    int _left = 8;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };

    public WarnWindow() : base(T("MechVault - prima di giocare"), 600)
    {
        var E = S.Env;
        var sp = new StackPanel();
        sp.Children.Add(Chip(T("Mech Arena rilevato"), "#FFE98A", "#24FFD60A", "#4DFFD60A", "IcWarn"));
        var h = Text(T("Prima di giocare, leggi."), "#F5F5F7", 32, weight: FontWeight.SemiBold); h.Margin = new Thickness(0, 14, 0, 4);
        sp.Children.Add(h);
        sp.Children.Add(Text(T("{0} · sei a {1} giorni senza spendere. Non buttarli via per una cassa.", S.AccountName, S.Stats.Streak()), "#B8FFFFFF", wrap: true));
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,12,*"), Margin = new Thickness(0, 22, 0, 0) };
        Border Box(string head, string headColor, string bg, string border, string body)
        {
            var s = new StackPanel();
            s.Children.Add(Text(head, headColor, 12, weight: FontWeight.SemiBold));
            var t = Text(body, "#F5F5F7", 13, true); t.Margin = new Thickness(0, 6, 0, 0); s.Children.Add(t);
            return new Border { CornerRadius = new CornerRadius(20), Padding = new Thickness(18, 14), Background = B(bg), BorderBrush = B(border), BorderThickness = new Thickness(1), Child = s };
        }
        g.Children.Add(Box(T("Vietato"), "#FF8A80", "#1AFF453A", "#40FF453A", T("Crate Rush · casse · offerte a tempo · spin · scorciatoie")));
        var mb = S.Stats.Mission("credits");
        var allowed = mb.Budget > 0 ? T("Giocare, farmare, missioni giornaliere (fino a {0} crediti al giorno). Comprare solo l'obiettivo #1 al 100%.", E.Fmt(mb.Budget))
            : T("Giocare, farmare, missioni giornaliere. Comprare solo l'obiettivo #1 al 100%.");
        var right = Box(T("Consentito"), "#8CF0A8", "#1A30D158", "#4030D158", allowed);
        Grid.SetColumn(right, 2); g.Children.Add(right);
        sp.Children.Add(g);
        var gl = Text(T("I tuoi obiettivi"), "#7AFFFFFF", 12, weight: FontWeight.SemiBold); gl.Margin = new Thickness(0, 22, 0, 8);
        sp.Children.Add(gl);
        var goals = Text(string.Join("\n", S.Stats.GoalLines()), "#B8FFFFFF", 13, true); goals.LineHeight = 24;
        sp.Children.Add(goals);
        var lesson = Text(T(AppState.Lessons[Random.Shared.Next(AppState.Lessons.Length)]), "#FFE98A", 13, true); lesson.FontStyle = FontStyle.Italic; lesson.Margin = new Thickness(0, 18, 0, 0);
        sp.Children.Add(lesson);
        var watch = Text(T("Ti sto guardando: se i saldi scendono, lo vedo da solo."), "#7AFFFFFF", 12); watch.Margin = new Thickness(0, 6, 0, 0);
        sp.Children.Add(watch);
        var ok = new Button { Classes = { "primary" }, Margin = new Thickness(0, 24, 0, 0), Padding = new Thickness(14, 13), IsEnabled = false, HorizontalAlignment = HorizontalAlignment.Stretch, Content = T("Leggi... ({0})", _left) };
        sp.Children.Add(ok);
        Panel.Child = sp;
        _timer.Tick += (_, _) =>
        {
            _left--;
            if (_left <= 0) { _timer.Stop(); ok.IsEnabled = true; ok.Content = T("Ho capito: oggi non spendo"); }
            else ok.Content = T("Leggi... ({0})", _left);
        };
        ok.Click += (_, _) => Close();
        Closing += (_, e) => { if (_left > 0 && !S.SelfTest) e.Cancel = true; };
        Closed += (_, _) => _timer.Stop();
        _timer.Start();
    }
}
