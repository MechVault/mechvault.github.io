using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using MechVault.Core;
using static MechVault.App.Ui;

namespace MechVault.App.Views;

public partial class MainWindow : Window
{
    static AppState S => AppState.I;
    static Env E => S.Env;
    static string T(string k, params object?[] a) => S.T(k, a);

    bool _exiting;
    bool _hideTipShown;

    public MainWindow()
    {
        InitializeComponent();
        Translate(this, S.L);
        SetupChrome();
        ApplyGlass(this, Root, Sheen, S.LiquidGlass);
        WireNav();
        WireHome();
        WireGoals();
        WireTools();
        WireSettings();
        Closing += OnClosing;
        S.Changed += () => Dispatcher.UIThread.Post(Refresh);
        BuildCalc();
        UpdateMechList();
        UpdStatus.Text = T("Versione {0}.", AppState.Version);
    }

    public void AllowClose() => _exiting = true;

    void SetupChrome()
    {
        if (OperatingSystem.IsWindows())
        {
            ExtendClientAreaToDecorationsHint = true;
            ExtendClientAreaChromeHints = Avalonia.Platform.ExtendClientAreaChromeHints.NoChrome;
            ExtendClientAreaTitleBarHeightHint = -1;
        }
        else if (OperatingSystem.IsMacOS())
        {
            ExtendClientAreaToDecorationsHint = true;
            ExtendClientAreaChromeHints = Avalonia.Platform.ExtendClientAreaChromeHints.PreferSystemChrome;
            ExtendClientAreaTitleBarHeightHint = 68;
            ChromeButtons.IsVisible = false;
            Brand.Margin = new Thickness(70, 0, 0, 0);
        }
        else
        {
            ChromeButtons.IsVisible = false;
        }
        TopBar.PointerPressed += (s, e) =>
        {
            if (e.Source is not (Panel or Border or TextBlock)) return;
            if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
            if (e.ClickCount == 2) { ToggleMax(); return; }
            BeginMoveDrag(e);
        };
        BtnMin.Click += (_, _) => WindowState = WindowState.Minimized;
        BtnMax.Click += (_, _) => ToggleMax();
        BtnClose.Click += (_, _) => Close();
        PropertyChanged += (_, e) =>
        {
            if (e.Property != WindowStateProperty) return;
            var max = WindowState == WindowState.Maximized;
            Root.Margin = max && OperatingSystem.IsWindows() ? new Thickness(7) : new Thickness(0);
            BtnMaxIcon.Data = Ui.Icon(max ? "IcRestore" : "IcMax");
        };
    }

    void ToggleMax() => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        if (_exiting) return;
        e.Cancel = true;
        Hide();
        if (!_hideTipShown && !S.SelfTest)
        {
            _hideTipShown = true;
            Notifier.Show(T("MechVault resta attivo"), T("Ti sorveglio dalla barra. Per uscire: tasto destro sull'icona › Esci."));
        }
    }

    void WireNav()
    {
        NavHome.IsCheckedChanged += (_, _) => { if (NavHome.IsChecked == true) ShowPage("PageHome"); };
        NavGoals.IsCheckedChanged += (_, _) => { if (NavGoals.IsChecked == true) ShowPage("PageGoals"); };
        NavActivity.IsCheckedChanged += (_, _) => { if (NavActivity.IsChecked == true) ShowPage("PageActivity"); };
        NavTools.IsCheckedChanged += (_, _) => { if (NavTools.IsChecked == true) ShowPage("PageTools"); };
        NavSettings.IsCheckedChanged += (_, _) => { if (NavSettings.IsChecked == true) ShowPage("PageSettings"); };
        BtnAccount.Click += async (_, _) => await App.Current.ShowAccountPicker(false);
    }

    public void ShowPage(string name)
    {
        PageHome.IsVisible = name == "PageHome";
        PageGoals.IsVisible = name == "PageGoals";
        PageActivity.IsVisible = name == "PageActivity";
        PageTools.IsVisible = name == "PageTools";
        PageSettings.IsVisible = name == "PageSettings";
        var nav = name switch { "PageGoals" => NavGoals, "PageActivity" => NavActivity, "PageTools" => NavTools, "PageSettings" => NavSettings, _ => NavHome };
        nav.IsChecked = true;
        if (name == "PageHome") Dispatcher.UIThread.Post(() => { DrawSpark(SparkCred); DrawSpark(SparkAc); }, DispatcherPriority.Loaded);
    }

    public void FocusManualCredits() => Dispatcher.UIThread.Post(() => CredIn.Focus(), DispatcherPriority.Loaded);

    public void Refresh()
    {
        try
        {
            RenderHome();
            RenderGoals();
            RenderActivity();
            RenderSettings();
            RenderTools();
            UpdateStatus();
        }
        catch (Exception ex) { S.Log($"Refresh: {ex}"); }
    }

    public void UpdateStatus()
    {
        AccName.Text = S.AccountName;
        if (S.GameRunning)
        {
            StatusDot.Fill = B("#FFD60A"); StatusGlow.Fill = B("#4DFFD60A"); StatusTitle.Text = T("Sorveglianza attiva");
        }
        else
        {
            StatusDot.Fill = B("#30D158"); StatusGlow.Fill = B("#4D30D158"); StatusTitle.Text = T("Blocco attivo");
        }
        var game = S.GameRunning ? T("Mech Arena aperto") : T("Mech Arena chiuso");
        var read = !S.D.AutoRead ? T("lettura automatica spenta")
            : !S.Platform.CanRead ? T(S.Platform.Unavailable is { } u && OperatingSystem.IsWindows() ? "OCR non disponibile" : "lettura automatica non disponibile")
            : !string.IsNullOrEmpty(S.D.LastReadAt) ? T("ultima lettura {0}", E.Ago(S.D.LastReadAt))
            : T("in attesa del gioco");
        SubLine.Text = $"{E.Now().ToString("dddd d MMMM", E.C)}  ·  {game}  ·  {read}";
        StreakBig.Text = S.Stats.Streak().ToString();
        App.Current.Overlay?.Update();
    }

    void WireHome()
    {
        BtnAllActivity.Click += (_, _) => ShowPage("PageActivity");
        HeroBuy.Click += async (_, _) => { if (HeroBuy.Tag is string id) await AuthorizePurchase(id); };
        SparkCred.SizeChanged += (_, _) => DrawSpark(SparkCred);
        SparkAc.SizeChanged += (_, _) => DrawSpark(SparkAc);
    }

    void RenderHome()
    {
        var d = S.D; var st = S.Stats; var now = E.Now();
        Hello.Text = now.Hour < 12 ? T("Buongiorno, pilota") : now.Hour < 18 ? T("Buon pomeriggio, pilota") : T("Buonasera, pilota");
        var streak = st.Streak();
        StreakChipTxt.Text = streak == 1 ? T("1 giorno pulito") : T("{0} giorni puliti", streak);

        if (S.PendingCheck)
        {
            Notice.Background = B("#1FFFD60A"); Notice.BorderBrush = B("#40FFD60A"); NoticeTxt.Foreground = B("#FFE98A"); NoticeIcon.Stroke = B("#FFD60A");
            NoticeTxt.Text = T("Hai chiuso Mech Arena e la lettura automatica è spenta: aggiorna i saldi in Impostazioni.");
        }
        else if (!(d.InitCredits && d.InitAcoins))
        {
            Notice.Background = B("#1A64D2FF"); Notice.BorderBrush = B("#4064D2FF"); NoticeTxt.Foreground = B("#C8EEFF"); NoticeIcon.Stroke = B("#64D2FF");
            NoticeTxt.Text = d.AutoRead && S.Platform.CanRead ? T("Apri Mech Arena e vai nell'hangar: leggo io crediti e A-coin dalla barra in alto.")
                : T("Inserisci i saldi attuali in Impostazioni › Correggi a mano.");
        }
        else
        {
            Notice.Background = B("#0FFFFFFF"); Notice.BorderBrush = B("#1AFFFFFF"); NoticeTxt.Foreground = B("#B8FFFFFF"); NoticeIcon.Stroke = B("#B8FFFFFF");
            NoticeTxt.Text = T(AppState.Lessons[now.DayOfYear % AppState.Lessons.Length]);
        }

        var first = st.GoalStats().FirstOrDefault();
        if (first is not null)
        {
            var g = first.Goal;
            SetRing(first.Pct);
            var done = first.Remaining <= 0;
            RingPath.Stroke = Res(done ? "GSafe" : g.Currency == "credits" ? "GCred" : "GAc");
            RingPath.Effect = new DropShadowEffect { Color = Color.Parse(done ? "#30D158" : Env.CurColor(g.Currency)), BlurRadius = 16, OffsetX = 0, OffsetY = 0, Opacity = 0.45 };
            RingPct.Text = $"{Math.Floor(first.Pct * 100)}%";
            HeroName.Text = g.Name;
            HeroCost.Text = $"{E.Fmt(g.Cost)} {E.CurName(g.Currency)}";
            HeroLeft.Text = done ? "0" : E.Short(first.Remaining);
            HeroEta.Text = E.EtaDays(first.Days);
            HeroDate.Text = E.EtaDate(first.Days);
            var rate = st.GetRate(g.Currency);
            if (first.Authorized)
            {
                HeroBuy.IsVisible = false;
                HeroHint.Text = T("Acquisto autorizzato: compralo in gioco, riconosco da solo la spesa."); HeroHint.Foreground = B("#8CF0A8");
            }
            else if (first.CanBuy)
            {
                HeroBuy.IsVisible = true; HeroBuy.Tag = g.Id;
                HeroHint.Text = T("Hai il 100%: autorizza l'acquisto, poi compralo in gioco."); HeroHint.Foreground = B("#8CF0A8");
            }
            else
            {
                HeroBuy.IsVisible = false;
                HeroHint.Text = rate.V > 0 ? T("Al ritmo di ~{0} {1} al giorno ({2}).", E.Short(rate.V), E.CurName(g.Currency), rate.Src) : T("Il tempo stimato compare dopo un giorno di letture.");
                HeroHint.Foreground = B("#7AFFFFFF");
            }
        }
        else
        {
            SetRing(0);
            RingPct.Text = "—"; HeroName.Text = T("Nessun obiettivo"); HeroCost.Text = T("Aggiungine uno nella sezione Obiettivi.");
            HeroLeft.Text = "—"; HeroEta.Text = "—"; HeroDate.Text = "—"; HeroBuy.IsVisible = false; HeroHint.Text = "";
        }

        foreach (var c in new[] { "credits", "acoins" })
        {
            var isC = c == "credits";
            var val = isC ? CredVal : AcVal;
            var rateLbl = isC ? CredRate : AcRate;
            var todayLbl = isC ? CredToday : AcToday;
            var chip = isC ? CredTodayChip : AcTodayChip;
            var spark = isC ? SparkCred : SparkAc;
            val.Text = d.IsInit(c) ? E.Fmt(d.Balance(c)) : "—";
            var r = st.GetRate(c);
            rateLbl.Text = r.V > 0 ? T("~{0} al giorno · {1}", E.Short(r.V), r.Src) : T("Ritmo: gioca una partita e lo calcolo da solo");
            var (gain, spend) = st.Today(c);
            todayLbl.Text = T("oggi {0}", E.Signed(gain + spend));
            if (gain + spend < 0) { chip.Background = B("#26FF453A"); todayLbl.Foreground = B("#FFB4AB"); }
            else if (gain > 0) { chip.Background = B("#2630D158"); todayLbl.Foreground = B("#B5F5C8"); }
            else { chip.Background = B("#14FFFFFF"); todayLbl.Foreground = B("#B8FFFFFF"); }
            spark.Tag = (st.DailySeries(c, 14), Env.CurColor(c));
            DrawSpark(spark);
        }

        StreakBig.Text = streak.ToString();
        BestTxt.Text = T("Record: {0} giorni  ·  Spese confessate: {1}", Math.Max(d.BestStreak, streak), d.Violations.Count);
        Cal.Children.Clear();
        var spendDays = new HashSet<DateTime>(); var misDays = new HashSet<DateTime>();
        foreach (var e in d.Events)
        {
            if (e.Kind == "spend") spendDays.Add(e.Time.Date);
            else if (e.Kind == "mission") misDays.Add(e.Time.Date);
        }
        var firstDay = Dates.Parse(d.CreatedAt)?.Date ?? now.Date;
        if (d.Events.Count > 0 && d.Events[0].Time.Date < firstDay) firstDay = d.Events[0].Time.Date;
        for (var k = 13; k >= 0; k--)
        {
            var day = now.Date.AddDays(-k);
            var el = new Ellipse { Width = 14, Height = 14, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            el.Fill = spendDays.Contains(day) ? B("#FF6961") : day < firstDay ? B("#14FFFFFF") : misDays.Contains(day) ? B("#CCFFD60A") : k == 0 ? B("#30D158") : B("#7330D158");
            ToolTip.SetTip(el, day.ToString("ddd d MMM", E.C));
            Cal.Children.Add(el);
        }

        var mb = st.Mission("credits");
        MisUsed.Text = E.Fmt(mb.Used);
        MisTot.Text = T("/ {0} crediti", E.Fmt(mb.Budget));
        SetBar(MisBar, mb.Budget > 0 ? mb.Used / mb.Budget : 0);
        var ma = st.Mission("acoins");
        MisSub.Text = mb.Budget <= 0 ? T("Budget missioni disattivato: imposta un valore in Impostazioni.")
            : T("Restano {0} crediti{1} per le missioni giornaliere, senza rompere la serie. Si azzera a mezzanotte.", E.Fmt(mb.Left), ma.Budget > 0 ? T(" e {0} A-coin", E.Fmt(ma.Left)) : "");

        RecentList.Children.Clear();
        var recent = d.Events.Where(e => e.Kind != "init").TakeLast(5).Reverse().ToList();
        if (recent.Count == 0)
            RecentList.Children.Add(Text(T("Ancora niente. Gioca una partita: ogni guadagno o spesa comparirà qui da solo."), "#66FFFFFF", wrap: true));
        else foreach (var e in recent) RecentList.Children.Add(ActivityRow(e));
    }

    void SetRing(double pct)
    {
        const double size = 184, thick = 12;
        double r = (size - thick) / 2, c = size / 2;
        pct = Math.Min(0.9999, Math.Max(0, pct));
        if (pct < 0.005) { RingPath.Data = null; return; }
        var a = pct * 2 * Math.PI;
        double x = c + r * Math.Sin(a), y = c - r * Math.Cos(a);
        var large = pct > 0.5 ? 1 : 0;
        RingPath.Data = Geometry.Parse(string.Format(CultureInfo.InvariantCulture, "M {0},{1} A {2},{2} 0 {3} 1 {4},{5}", c, c - r, r, large, x, y));
    }

    static void SetBar(Grid g, double pct)
    {
        pct = Math.Min(1, Math.Max(0, pct));
        g.ColumnDefinitions[0].Width = new GridLength(pct, GridUnitType.Star);
        g.ColumnDefinitions[1].Width = new GridLength(1 - pct, GridUnitType.Star);
    }

    void DrawSpark(Canvas canvas)
    {
        canvas.Children.Clear();
        if (canvas.Tag is not ValueTuple<double?[], string> info) return;
        var (vals, col) = info;
        double w = canvas.Bounds.Width, h = canvas.Bounds.Height;
        if (w < 20 || h < 10) return;
        var nums = vals.Where(v => v is not null).Select(v => v!.Value).ToList();
        if (nums.Count < 1)
        {
            var t = Text(T("Il grafico si riempie man mano che giochi."), "#52FFFFFF", 11);
            Canvas.SetTop(t, h / 2 - 8);
            canvas.Children.Add(t);
            return;
        }
        double mn = nums.Min(), mx = nums.Max(), rng = mx - mn;
        if (rng <= 0) { rng = Math.Max(1.0, mx * 0.1); mn -= rng / 2; }
        var n = vals.Length;
        var line = new List<Point>();
        for (var i = 0; i < n; i++)
        {
            if (vals[i] is not { } v) continue;
            var x = n > 1 ? w * i / (n - 1) : 0;
            line.Add(new Point(x, 4 + (h - 8) * (1 - (v - mn) / rng)));
        }
        if (line.Count == 1) line.Add(new Point(w, line[0].Y));
        var c1 = Color.Parse(col);
        var area = new Polygon
        {
            Points = line.Concat(new[] { new Point(line[^1].X, h), new Point(line[0].X, h) }).ToList(),
            Fill = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Color.FromArgb(56, c1.R, c1.G, c1.B), 0), new GradientStop(Color.FromArgb(0, c1.R, c1.G, c1.B), 1) },
            },
        };
        canvas.Children.Add(area);
        canvas.Children.Add(new Polyline { Points = line, Stroke = new SolidColorBrush(c1), StrokeThickness = 2, StrokeJoin = PenLineJoin.Round, StrokeLineCap = PenLineCap.Round });
        var last = line[^1];
        var dot = new Ellipse { Width = 9, Height = 9, Fill = B("#F5F5F7"), Stroke = new SolidColorBrush(c1), StrokeThickness = 2 };
        Canvas.SetLeft(dot, last.X - 4.5); Canvas.SetTop(dot, last.Y - 4.5);
        canvas.Children.Add(dot);
    }

    static Control ActivityRow(BalanceEvent e)
    {
        var cur = e.Cur;
        var (icon, fg, title) = e.Kind switch
        {
            "gain" => ("IcPlus", "#30D158", T("Guadagno · {0}", E.CurName(cur))),
            "spend" => ("IcSpend", "#FF8A80", T("Spesa non autorizzata")),
            "mission" => ("IcFlag", "#FFD60A", T("Spesa per missione")),
            "small" => ("IcSpend", "#FFD60A", T("Piccola spesa tollerata")),
            "purchase" => ("IcCart", "#FFD60A", T("Obiettivo comprato")),
            _ => ("IcInfo", "#B8FFFFFF", T("Saldo iniziale · {0}", E.CurName(cur))),
        };
        var time = e.Time == DateTime.MinValue ? "" : e.Time.ToString("HH:mm", E.C);
        var sub = $"{time} · {(e.Src == "auto" ? T("letto dal gioco") : T("manuale"))}";
        if (!string.IsNullOrEmpty(e.Note)) sub += $" · {T(e.Note)}";
        var amt = e.Kind == "init" ? E.Fmt(e.Bal) : E.Signed(e.Delta);
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), Margin = new Thickness(0, 0, 0, 12) };
        var circle = new Border
        {
            Width = 34, Height = 34, CornerRadius = new CornerRadius(17), Background = B("#14FFFFFF"), BorderBrush = B("#1FFFFFFF"), BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center, Child = IconPath(icon, fg),
        };
        g.Children.Add(circle);
        var mid = new StackPanel { Margin = new Thickness(12, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        mid.Children.Add(new TextBlock { Text = title, Foreground = B("#F5F5F7"), TextTrimming = TextTrimming.CharacterEllipsis });
        mid.Children.Add(new TextBlock { Text = sub, Foreground = B("#66FFFFFF"), FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 2, 0, 0) });
        Grid.SetColumn(mid, 1); g.Children.Add(mid);
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(Text(amt, e.Kind == "init" ? "#B8FFFFFF" : fg, 16));
        right.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = B(Env.CurColor(cur)), Margin = new Thickness(8, 1, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(right, 2); g.Children.Add(right);
        return g;
    }

    void WireGoals()
    {
        GoalAdd.Click += async (_, _) => await AddGoalFromForm();
        GoalCost.KeyDown += async (_, e) => { if (e.Key == Key.Enter) await AddGoalFromForm(); };
    }

    async Task AddGoalFromForm()
    {
        var name = (GoalName.Text ?? "").Trim();
        var cost = Num.ParseAmount(GoalCost.Text);
        if (name == "") { await Dialogs.Message(this, T("Scrivi il nome dell'obiettivo.")); return; }
        if (cost is null || cost <= 0) { await Dialogs.Message(this, T("Costo non valido. Esempi: 827k · 932000 · 1,2M")); return; }
        var cur = RbAc.IsChecked == true ? "acoins" : "credits";
        S.D.Goals.Add(Core.Goals.New(name, cur, cost.Value));
        GoalName.Text = ""; GoalCost.Text = "";
        S.RaiseChanged();
    }

    async Task AuthorizePurchase(string id)
    {
        var g = S.D.Goals.FirstOrDefault(x => x.Id == id);
        if (g is null) return;
        var msg = T("Obiettivo raggiunto: {0}\n\nAutorizzo UNA spesa di circa {1} {2} per le prossime 6 ore.\nCompralo in gioco: riconosco l'acquisto da solo e segno l'obiettivo come completato.\n\nQualsiasi altra spesa resta vietata. Procedo?", g.Name, E.Fmt(g.Cost), E.CurName(g.Currency));
        if (!await Dialogs.Confirm(this, msg)) return;
        S.Engine.Authorize(g);
    }

    async Task RemoveGoal(string id)
    {
        var g = S.D.Goals.FirstOrDefault(x => x.Id == id);
        if (g is null) return;
        if (!await Dialogs.Confirm(this, T("Eliminare l'obiettivo «{0}»?", g.Name))) return;
        Core.Goals.Remove(S.D, id);
        S.RaiseChanged();
    }

    void RenderGoals()
    {
        var p = GoalsPanel;
        p.Children.Clear();
        var stats = S.Stats.GoalStats();
        foreach (var s in stats)
        {
            var g = s.Goal; var cur = g.Currency;
            string c1 = Env.CurColor(cur), c2 = Env.CurColor2(cur);
            var pct = Math.Min(1.0, Math.Max(0.0, s.Pct));
            if (s.Remaining <= 0) { c1 = "#8CF0A8"; c2 = "#30D158"; }
            string status, statusColor;
            if (s.Authorized) { status = T("Acquisto autorizzato · compralo in gioco, la spesa verrà riconosciuta"); statusColor = "#8CF0A8"; }
            else if (s.CanBuy) { status = T("Pronto · hai abbastanza {0}", E.CurName(cur)); statusColor = "#8CF0A8"; }
            else if (s.IsFirst) { status = T("mancano {0} · ~{1} · entro {2}", E.Short(s.Remaining), E.EtaDays(s.Days), E.EtaDate(s.Days)); statusColor = "#B8FFFFFF"; }
            else { status = T("in coda dopo «{0}» · mancano {1} in totale · entro {2}", s.After, E.Short(s.Remaining), E.EtaDate(s.Days)); statusColor = "#7AFFFFFF"; }

            var card = new Border { Classes = { "card" }, Margin = new Thickness(0, 0, 0, 12), Padding = new Thickness(24, 20) };
            var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
            var left = new StackPanel();
            var head = new StackPanel { Orientation = Orientation.Horizontal };
            head.Children.Add(new Border
            {
                Width = 38, Height = 38, CornerRadius = new CornerRadius(19), Background = B("#14FFFFFF"), BorderBrush = B("#26FFFFFF"), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 14, 0),
                Child = new TextBlock { Text = s.Rank.ToString(), FontSize = 16, FontWeight = FontWeight.SemiBold, Foreground = B(Env.CurColor(cur)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            });
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            names.Children.Add(new TextBlock { Text = g.Name, FontSize = 17, FontWeight = FontWeight.SemiBold, Foreground = B("#F5F5F7") });
            names.Children.Add(new TextBlock { Text = $"{E.Fmt(g.Cost)} {E.CurName(cur)}", Foreground = B("#7AFFFFFF"), FontSize = 12, Margin = new Thickness(0, 1, 0, 0) });
            head.Children.Add(names);
            left.Children.Add(head);
            var bar = new Grid { Margin = new Thickness(0, 16, 0, 10), Height = 8, ColumnDefinitions = new ColumnDefinitions($"{pct.ToString("0.####", CultureInfo.InvariantCulture)}*,{(1 - pct).ToString("0.####", CultureInfo.InvariantCulture)}*") };
            var track = new Border { Background = B("#17FFFFFF"), CornerRadius = new CornerRadius(4) };
            Grid.SetColumnSpan(track, 2);
            bar.Children.Add(track);
            bar.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(4),
                Background = new LinearGradientBrush
                {
                    StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 0, RelativeUnit.Relative),
                    GradientStops = { new GradientStop(Color.Parse(c2), 0), new GradientStop(Color.Parse(c1), 1) },
                },
            });
            left.Children.Add(bar);
            var foot = new DockPanel();
            var pctTxt = Text($"{Math.Floor(pct * 100)}%", "#F5F5F7", 15); pctTxt.Margin = new Thickness(12, 0, 0, 0);
            DockPanel.SetDock(pctTxt, Dock.Right);
            foot.Children.Add(pctTxt);
            var stTxt = Text(status, statusColor, 12, true); stTxt.VerticalAlignment = VerticalAlignment.Center;
            foot.Children.Add(stTxt);
            left.Children.Add(foot);
            grid.Children.Add(left);

            var btns = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(22, 0, 0, 0) };
            Button buy;
            if (s.Authorized)
            {
                buy = new Button { Content = T("Annulla"), Margin = new Thickness(0, 0, 6, 0) };
                ToolTip.SetTip(buy, T("Revoca l'autorizzazione"));
                buy.Click += (_, _) => S.Engine.CancelPurchase();
            }
            else if (s.CanBuy)
            {
                buy = new Button { Classes = { "safe" }, Content = T("Compra ora"), Margin = new Thickness(0, 0, 6, 0) };
                var id = g.Id; buy.Click += async (_, _) => await AuthorizePurchase(id);
            }
            else
            {
                var sp = new StackPanel { Orientation = Orientation.Horizontal };
                sp.Children.Add(IconPath("IcLock", "#F5F5F7"));
                var tb = Text(T("Bloccato")); tb.Margin = new Thickness(8, 0, 0, 0); sp.Children.Add(tb);
                buy = new Button { IsEnabled = false, Margin = new Thickness(0, 0, 6, 0), Content = sp };
            }
            btns.Children.Add(buy);
            var gid = g.Id;
            btns.Children.Add(IconButton("IcUp", T("Più importante"), () => { if (Core.Goals.Move(S.D, gid, -1)) S.RaiseChanged(); }));
            btns.Children.Add(IconButton("IcDown", T("Meno importante"), () => { if (Core.Goals.Move(S.D, gid, 1)) S.RaiseChanged(); }));
            btns.Children.Add(IconButton("IcTrash", T("Elimina"), async () => await RemoveGoal(gid)));
            Grid.SetColumn(btns, 1);
            grid.Children.Add(btns);
            card.Child = grid;
            p.Children.Add(card);
        }

        foreach (var g in S.D.Goals.Where(x => x.Done))
        {
            var when = Dates.Parse(g.DoneAt)?.ToString("d MMM yyyy", E.C) ?? "";
            var row = new Border { Background = B("#0AFFFFFF"), BorderBrush = B("#14FFFFFF"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(20), Padding = new Thickness(20, 10), Margin = new Thickness(0, 0, 0, 10) };
            var dp = new DockPanel();
            var gid = g.Id;
            var del = IconButton("IcTrash", T("Rimuovi dalla lista"), async () => await RemoveGoal(gid));
            DockPanel.SetDock(del, Dock.Right); dp.Children.Add(del);
            var ok = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(13), Background = B("#2630D158"), Margin = new Thickness(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Center, Child = IconPath("IcCheck", "#30D158", 11) };
            DockPanel.SetDock(ok, Dock.Left); dp.Children.Add(ok);
            var tb = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Foreground = B("#7AFFFFFF") };
            tb.Inlines!.Add(new Avalonia.Controls.Documents.Run(g.Name) { Foreground = B("#F5F5F7") });
            tb.Inlines.Add(new Avalonia.Controls.Documents.Run(T("   comprato il {0}", when)));
            dp.Children.Add(tb);
            row.Child = dp;
            p.Children.Add(row);
        }

        if (p.Children.Count == 0)
        {
            var t = Text(T("Nessun obiettivo per questo account. Aggiungine uno qui sotto."), "#7AFFFFFF"); t.Margin = new Thickness(4, 0, 0, 14);
            p.Children.Add(t);
        }
        var need = new Dictionary<string, double>();
        foreach (var s in stats) need[s.Goal.Currency] = s.Remaining;
        var parts = new List<string>();
        foreach (var c in new[] { "credits", "acoins" }) if (need.TryGetValue(c, out var v) && v > 0) parts.Add($"{E.Short(v)} {E.CurName(c)}");
        GoalsSummary.Text = parts.Count > 0 ? T("Ancora da mettere da parte: ") + string.Join("  ·  ", parts) : stats.Count > 0 ? T("Tutti gli obiettivi attivi sono coperti.") : "";
    }

    static Button IconButton(string icon, string tip, Action click)
    {
        var b = new Button { Classes = { "icon" }, Content = IconPath(icon, "#7AFFFFFF") };
        ToolTip.SetTip(b, tip);
        b.Click += (_, _) => click();
        return b;
    }

    void RenderActivity()
    {
        var d = S.D; var now = E.Now();
        var since = now.AddDays(-14);
        double gc = 0, ga = 0, sc = 0, sa = 0;
        foreach (var e in d.Events)
        {
            if (e.Time < since) continue;
            if (e.Kind == "gain") { if (e.Cur == "credits") gc += e.Delta; else ga += e.Delta; }
            else if (e.Kind == "spend") { if (e.Cur == "credits") sc -= e.Delta; else sa -= e.Delta; }
        }
        StatGainC.Text = E.Short(gc); StatGainA.Text = E.Fmt(ga);
        StatSpendC.Text = E.Short(sc); StatSpendA.Text = E.Fmt(sa);

        ActivityList.Children.Clear();
        var evs = d.Events.TakeLast(120).Reverse().ToList();
        DateTime? lastDay = null;
        foreach (var e in evs)
        {
            var day = e.Time.Date;
            if (day != lastDay)
            {
                lastDay = day;
                var lbl = day == now.Date ? T("Oggi") : day == now.Date.AddDays(-1) ? T("Ieri") : day.ToString("dddd d MMMM", E.C);
                var t = Text(lbl, "#B8FFFFFF", weight: FontWeight.SemiBold); t.Margin = new Thickness(0, 10, 0, 10);
                ActivityList.Children.Add(t);
            }
            ActivityList.Children.Add(ActivityRow(e));
        }
        if (evs.Count == 0) { var t = Text(T("Nessuna attività registrata."), "#66FFFFFF"); t.Margin = new Thickness(0, 8, 0, 0); ActivityList.Children.Add(t); }

        ViolPanel.Children.Clear();
        var v = d.Violations;
        if (v.Count == 0)
        {
            ViolTotal.Text = T("Nessuna spesa confessata. Continua così.");
            ViolTotal.Foreground = B("#8CF0A8");
            return;
        }
        var totC = v.Where(x => x.Currency == "credits").Sum(x => x.Amount);
        var totA = v.Where(x => x.Currency == "acoins").Sum(x => x.Amount);
        ViolTotal.Text = T("Totale buttato: {0} crediti · {1} A-coin", E.Fmt(totC), E.Fmt(totA));
        ViolTotal.Foreground = B("#FFB4AB");
        foreach (var e in v.TakeLast(8).Reverse())
        {
            var when = Dates.Parse(e.T)?.ToString("d MMM HH:mm", E.C) ?? "";
            var row = new Border { BorderBrush = B("#14FFFFFF"), BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(0, 12) };
            var sp = new StackPanel();
            var dp = new DockPanel();
            var w = Text(when, "#66FFFFFF", 11); w.VerticalAlignment = VerticalAlignment.Center; DockPanel.SetDock(w, Dock.Right); dp.Children.Add(w);
            dp.Children.Add(Text($"−{E.Fmt(e.Amount)} {E.CurName(e.Currency)}", "#FF8A80", 16));
            sp.Children.Add(dp);
            var reason = Text(e.Reason ?? "", "#B8FFFFFF", 12, true); reason.Margin = new Thickness(0, 3, 0, 8);
            sp.Children.Add(reason);
            var fix = new Button { Content = T("Era una missione: ripristina la serie"), HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 6), FontSize = 12 };
            var t0 = e.T;
            fix.Click += async (_, _) => await UndoViolation(t0);
            sp.Children.Add(fix);
            row.Child = sp;
            ViolPanel.Children.Add(row);
        }
    }

    async Task UndoViolation(string t)
    {
        var viol = S.D.Violations.FirstOrDefault(x => x.T == t);
        if (viol is null) return;
        if (!await Dialogs.Confirm(this, T("Segnare −{0} {1} come spesa per una missione?\nLa serie torna com'era prima.", E.Fmt(viol.Amount), E.CurName(viol.Currency)))) return;
        S.Engine.UndoViolation(t);
    }

    CalcTotals _calcTot = new(0, 0, 0, 0, 0);
    List<string> _calcKeys = new();
    bool _calcBuilding, _calcRunning;
    int _msRank = 6;
    string? _msCurrent;

    void WireTools()
    {
        BtnCopyCred.Click += async (_, _) => await CopyResource("credits");
        BtnCopyAc.Click += async (_, _) => await CopyResource("acoins");
        foreach (var tb in new[] { CalcFS, CalcFL, CalcTS, CalcTL }) tb.TextChanged += (_, _) => BuildCalc();
        CalcMyBp.TextChanged += (_, _) => UpdateCalcTotals();
        CalcWeapon.IsCheckedChanged += (_, _) => { if (CalcWeapon.IsChecked == true) { CalcEnergyPanel.IsVisible = true; BuildCalc(); } };
        CalcMech.IsCheckedChanged += (_, _) => { if (CalcMech.IsChecked == true) { CalcEnergyPanel.IsVisible = false; BuildCalc(); } };
        foreach (var r in CalcEnergies.Children.OfType<RadioButton>()) r.IsCheckedChanged += (_, _) => { if (r.IsChecked == true) BuildCalc(); };
        foreach (var r in CalcRarities.Children.OfType<RadioButton>()) r.IsCheckedChanged += (_, _) => { if (r.IsChecked == true) BuildCalc(); };
        BtnCalcMax.Click += (_, _) => { CalcTS.Text = "6"; CalcTL.Text = "7"; };
        BtnCalcGoal.Click += (_, _) => AddCalcGoal();
        BtnCalcRun.Click += (_, _) => RunCalc();
        BtnCalcDetail.Click += (_, _) => ToggleCalcDetail();
        BtnCalcImport.Click += async (_, _) => await ImportCosts();
        BtnCalcExport.Click += async (_, _) => await ExportCosts();

        CrUpg.IsCheckedChanged += (_, _) => { CrUpgGrid.IsEnabled = CrUpg.IsChecked == true; UpdateCrate(); };
        CrAddPrize.Click += (_, _) => AddCratePrize();
        CrName.TextChanged += (_, _) => UpdateCrate();
        CrName.LostFocus += (_, _) =>
        {
            if ((CrDirect.Text ?? "").Trim() != "") return;
            var k = S.Mechs.Find(CrName.Text); if (k is null) return;
            var m = S.Mechs.Mechs[k];
            CrKM.IsChecked = true;
            if (m.Rarity is { } rar) Check(CrRarities, rar.ToLowerInvariant());
            if (m.GearHub?.Amount is { } a && a != 0)
            {
                if (m.GearHub.Currency == "credits") CrDirCr.IsChecked = true; else CrDirAc.IsChecked = true;
                CrDirect.Text = E.Fmt(a);
            }
        };
        foreach (var tb in new[] { CrSpin, CrP, CrPity, CrDirect, CrBudget, CrPS, CrPL, CrDS, CrDL }) tb.TextChanged += (_, _) => UpdateCrate();
        foreach (var rb in new[] { CrAc, CrCr, CrDirCr, CrDirAc }) rb.IsCheckedChanged += (_, _) => { if (rb.IsChecked == true) UpdateCrate(); };
        CrKW.IsCheckedChanged += (_, _) => { if (CrKW.IsChecked == true) { CrEnergyPanel.IsVisible = true; UpdateCrate(); } };
        CrKM.IsCheckedChanged += (_, _) => { if (CrKM.IsChecked == true) { CrEnergyPanel.IsVisible = false; UpdateCrate(); } };
        foreach (var r in CrRarities.Children.OfType<RadioButton>())
            r.IsCheckedChanged += (_, _) =>
            {
                if (r.IsChecked != true) return;

                var rr = CostTable.Rarities.FirstOrDefault(x => x.K == r.Tag?.ToString());
                if (rr is not null) { CrDS.Text = rr.Min.ToString(); CrDL.Text = "1"; }
                UpdateCrate();
            };
        foreach (var r in CrEnergies.Children.OfType<RadioButton>()) r.IsCheckedChanged += (_, _) => { if (r.IsChecked == true) UpdateCrate(); };
        CrFromCalc.Click += (_, _) =>
        {
            if (_calcTot.N <= 0) return;
            var inp = CalcInput();
            if (inp.Err is null)
            {
                if (inp.Kind == "mech") CrKM.IsChecked = true;
                else { CrKW.IsChecked = true; Check(CrEnergies, inp.Energy.ToString()); }
                Check(CrRarities, inp.Rarity);
            }
            CrDirCr.IsChecked = true; CrDirect.Text = E.Fmt(_calcTot.C);
            if ((CrName.Text ?? "").Trim() == "") CrName.Text = CalcName.Text;
        };

        MsSearch.TextChanged += (_, _) => UpdateMechList();
        MsEditBtn.Click += (_, _) => { if (MsEdit.IsVisible) MsEdit.IsVisible = false; else OpenMechEdit(_msCurrent); };
        MeSave.Click += (_, _) => SaveMechEdit();
        MeDel.Click += (_, _) => RemoveMechEdit();
        MsRefresh.Click += (_, _) => App.Current.StartWikiUpdate(true);
    }

    void RenderTools()
    {
        var d = S.D;
        ToolAccount.Text = T("Lette dal gioco per l'account «{0}».", S.AccountName);
        ToolCred.Text = d.InitCredits ? E.Fmt(d.Credits) : "—";
        ToolAc.Text = d.InitAcoins ? E.Fmt(d.Acoins) : "—";
        UpdateCalcTotals();
        UpdateCrate();
    }

    async Task CopyResource(string cur)
    {
        var d = S.D;
        if (!d.IsInit(cur)) { ToolMsg.Text = T("Saldo non ancora letto: apri Mech Arena e vai nell'hangar."); return; }
        var cb = GetTopLevel(this)?.Clipboard;
        if (cb is null) return;
        await cb.SetTextAsync(((long)d.Balance(cur)).ToString(CultureInfo.InvariantCulture));
        ToolMsg.Text = T("{0} copiati negli appunti: {1}", E.CurName(cur), E.Fmt(d.Balance(cur)));
    }

    CalcInput CalcInput()
    {
        var kind = CalcMech.IsChecked == true ? "mech" : "weapon";
        var rar = Checked(CalcRarities) ?? "epic";
        var en = int.TryParse(Checked(CalcEnergies), out var x) ? x : 8;
        return CostTable.Input(E, kind, rar, en, CalcFS.Text ?? "", CalcFL.Text ?? "", CalcTS.Text ?? "", CalcTL.Text ?? "");
    }

    void BuildCalc()
    {
        if (CalcSteps is null) return;
        _calcBuilding = true;
        CalcSteps.Children.Clear(); _calcKeys = new();
        var inp = CalcInput();
        if (inp.Err is null)
        {
            foreach (var st in CostTable.StepPath(E, inp.Fs, inp.Fl, inp.Ts, inp.Tl))
            {
                var key = inp.Grp + "|" + st.Key;
                var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,130,110,110"), Margin = new Thickness(0, 0, 0, 6) };
                var l = Text(st.Label, st.Key.StartsWith("star|") ? "#DA8FFF" : "#B8FFFFFF"); l.VerticalAlignment = VerticalAlignment.Center;
                g.Children.Add(l);
                var e = S.Costs.Get(key);
                var fromWiki = !S.Costs.User.ContainsKey(key) && S.Costs.Base.ContainsKey(key);
                var col = 1;
                foreach (var f in new[] { 'c', 'b', 'a' })
                {
                    var tb = new TextBox { Classes = { "small" }, Margin = new Thickness(8, 0, 0, 0) };
                    var v = f == 'c' ? e?.C : f == 'b' ? e?.B : e?.A;
                    if (v is { } vv) tb.Text = E.Fmt(vv);
                    if (fromWiki) { tb.Foreground = B("#B8FFFFFF"); ToolTip.SetTip(tb, T("Dal Mech Arena Wiki: correggilo se nel gioco è diverso.")); }
                    var ff = f;
                    tb.TextChanged += (_, _) =>
                    {
                        if (_calcBuilding) return;
                        S.Costs.SetCell(key, ff, Num.ParseAmount(tb.Text));
                        UpdateCalcTotals();
                    };
                    tb.LostFocus += (_, _) => SaveCosts();
                    Grid.SetColumn(tb, col++);
                    g.Children.Add(tb);
                }
                _calcKeys.Add(key);
                CalcSteps.Children.Add(g);
            }
        }
        _calcBuilding = false;
        UpdateCalcTotals(inp);
        if (!_calcRunning && CalcResult.IsVisible)
        {
            CalcResult.IsVisible = false;
            CalcHint.Text = T("Dati cambiati: premi di nuovo «Calcola» per aggiornare il risultato.");
        }
    }

    void SaveCosts()
    {
        try { S.Costs.Save(S.Paths.Costs, E.Now()); } catch (Exception ex) { S.Log($"Salva costi: {ex.Message}"); }
    }

    void RunCalc()
    {
        _calcRunning = true;
        try { BuildCalc(); } finally { _calcRunning = false; }
        var inp = CalcInput();
        if (inp.Err is not null) { CalcResult.IsVisible = false; CalcHint.Text = inp.Err; return; }
        if (_calcTot.N == 0) { CalcResult.IsVisible = false; CalcHint.Text = T("Scegli un arrivo più alto della partenza."); return; }
        var name = (CalcName.Text ?? "").Trim();
        var kind = inp.Kind == "mech" ? "Mech" : T("Arma");
        var rar = S.Mechs.WW(CultureInfo.InvariantCulture.TextInfo.ToTitleCase(inp.Rarity));
        var en = inp.Kind == "weapon" ? $" · {inp.Energy} " + T("energia") : "";
        var item = name != "" ? $"{name} ({kind} · {rar}{en})" : $"{kind} · {rar}{en}";
        CalcSummary.Text = T("{0} · da ★{1} liv. {2} a ★{3} liv. {4} · {5} passi", item, inp.Fs, inp.Fl, inp.Ts, inp.Tl, _calcTot.N);
        CalcHint.Text = "";
        CalcResult.IsVisible = true;
    }

    void ToggleCalcDetail()
    {
        CalcBreakdown.IsVisible = !CalcBreakdown.IsVisible;
        BtnCalcDetail.Content = CalcBreakdown.IsVisible ? T("Nascondi il dettaglio") : T("Mostra il dettaglio passo per passo");
    }

    void UpdateCalcTotals(CalcInput? inp = null)
    {
        if (CalcTotC is null) return;
        var d = S.D;
        inp ??= CalcInput();
        var t = S.Costs.Totals(_calcKeys);
        _calcTot = t;
        var pre = t.Miss > 0 ? "≥ " : "";
        CalcTotC.Text = pre + E.Fmt(t.C); CalcTotB.Text = pre + E.Fmt(t.B); CalcTotA.Text = pre + E.Fmt(t.A);
        double needC = -1, needA = -1;
        string Need(double n) => n > 0 ? T("mancano {0}", E.Fmt(n)) : t.Miss > 0 ? T("per ora coperto") : T("coperto ✓");
        if (d.InitCredits) { needC = Math.Max(0, t.C - d.Credits); CalcNeedC.Text = Need(needC); } else CalcNeedC.Text = T("saldo non ancora letto");
        if (d.InitAcoins) { needA = Math.Max(0, t.A - d.Acoins); CalcNeedA.Text = Need(needA); } else CalcNeedA.Text = T("saldo non ancora letto");
        var myBp = Num.ParseAmount(CalcMyBp.Text);
        CalcNeedB.Text = myBp is null ? T("scrivi quanti ne hai") : t.B > myBp ? T("mancano {0}", E.Fmt(t.B - myBp.Value)) : t.Miss > 0 ? T("per ora coperto") : T("coperto ✓");
        if (inp.Err is not null) { CalcInfo.Text = inp.Err; return; }
        if (t.N == 0) { CalcInfo.Text = T("Scegli un arrivo più alto della partenza."); return; }
        if (t.Miss > 0) { CalcInfo.Text = T("Mancano {0} costi su {1}: copiali qui sotto dalla schermata di potenziamento del gioco. Per ora il totale è un minimo.", t.Miss, t.N); return; }
        var parts = new List<string>();
        if (needC > 0) { var r = S.Stats.GetRate("credits"); parts.Add(r.V > 0 ? T("crediti tra ~{0}", E.EtaDays(needC / r.V)) : T("crediti: imposta il ritmo")); }
        if (needA > 0) { var r = S.Stats.GetRate("acoins"); parts.Add(r.V > 0 ? T("A-coin tra ~{0}", E.EtaDays(needA / r.V)) : T("A-coin: imposta il ritmo")); }
        CalcInfo.Text = parts.Count > 0 ? T("{0} passi. Al tuo ritmo: {1}.", t.N, string.Join(" · ", parts))
            : needC == 0 && needA == 0 ? T("{0} passi. Hai già tutto il necessario.", t.N) : T("{0} passi.", t.N);
    }

    void AddCalcGoal()
    {
        var inp = CalcInput();
        var n0 = S.D.Goals.Count;
        CalcMsg.Text = CalcHelpers.AddGoals(E, S.D, CalcName.Text ?? "", inp, _calcTot);
        if (S.D.Goals.Count != n0) S.RaiseChanged();
    }

    async Task ImportCosts()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = false, FileTypeFilter = new[] { new FilePickerFileType("JSON") { Patterns = new[] { "*.json" } } },
        });
        if (files.Count == 0) return;
        var n = -1;
        try
        {
            await using var s = await files[0].OpenReadAsync();
            using var r = new StreamReader(s);
            n = S.Costs.MergeUser(System.Text.Json.Nodes.JsonNode.Parse(await r.ReadToEndAsync()));
        }
        catch (Exception ex) { S.Log($"Importa costi: {ex.Message}"); }
        if (n < 0) { CalcMsg.Text = T("File non valido: serve una tabella esportata da MechVault."); return; }
        SaveCosts(); BuildCalc();
        CalcMsg.Text = T("Importati {0} costi.", n);
    }

    async Task ExportCosts()
    {
        var f = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            SuggestedFileName = "mechvault-costi.json", DefaultExtension = "json",
            FileTypeChoices = new[] { new FilePickerFileType("JSON") { Patterns = new[] { "*.json" } } },
        });
        if (f?.TryGetLocalPath() is not { } path) return;
        try { var n = S.Costs.Save(path, E.Now(), all: true); CalcMsg.Text = T("Tabella esportata: {0} costi.", n); }
        catch (Exception ex) { S.Log($"Salva costi: {ex.Message}"); }
    }

    CrateInput CrateInputFromUi() => new()
    {
        Name = CrName.Text ?? "", SpinInCredits = CrCr.IsChecked == true, Spin = CrSpin.Text ?? "", P = CrP.Text ?? "", Pity = CrPity.Text ?? "",
        Budget = CrBudget.Text ?? "", DirectInAcoins = CrDirAc.IsChecked == true, Direct = CrDirect.Text ?? "", CountUpgrades = CrUpg.IsChecked == true,
        KindWeapon = CrKW.IsChecked == true, Rarity = Checked(CrRarities) ?? "legendary", Energy = int.TryParse(Checked(CrEnergies), out var en) ? en : 16,
        PS = CrPS.Text ?? "", PL = CrPL.Text ?? "", DS = CrDS.Text ?? "", DL = CrDL.Text ?? "",
        Prizes = CrPrizes.Children.OfType<Grid>().Select(g => (CratePrize)g.Tag!).ToList(),
    };

    void UpdateCrate()
    {
        if (CrVerdict is null) return;
        CrUpgGrid.IsEnabled = CrUpg.IsChecked == true;
        var res = new CrateAnalyzer(E, S.Stats, S.Costs, S.Mechs).Analyze(CrateInputFromUi());
        CrPrizeHead.IsVisible = CrPrizes.Children.Count > 0;
        CrVerdict.Text = res.Verdict;
        CrStats.Text = res.StatsText;
        (string fg, string bg, string bd) = res.Kind switch
        {
            Verdict.Scam => ("#FFB4AB", "#1FFF453A", "#4DFF453A"),
            Verdict.Good => ("#8CF0A8", "#1A30D158", "#4D30D158"),
            Verdict.Warn => ("#FFD60A", "#1AFFD60A", "#4DFFD60A"),
            _ => ("#F5F5F7", "#0FFFFFFF", "#1AFFFFFF"),
        };
        CrVerdict.Foreground = B(fg); CrVerdictBox.Background = B(bg); CrVerdictBox.BorderBrush = B(bd);
    }

    void AddCratePrize(string name = "", string p = "", string price = "", string cur = "acoins", bool want = true)
    {
        var prize = new CratePrize { Name = name, P = p, Price = price, Cur = cur, Want = want };
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,100,130,180,112,36"), Margin = new Thickness(0, 0, 0, 6), Tag = prize };
        var n = new TextBox { Classes = { "small" }, Text = name, Watermark = T("nome (es. Lacewing)") };
        var pp = new TextBox { Classes = { "small" }, Text = p, Watermark = T("es. 1,5"), Margin = new Thickness(8, 0, 0, 0) };
        var v = new TextBox { Classes = { "small" }, Text = price, Watermark = T("prezzo"), Margin = new Thickness(8, 0, 0, 0) };
        var grp = "crp" + Guid.NewGuid().ToString("N")[..6];
        var cr = new RadioButton { Classes = { "pill" }, GroupName = grp, Content = T("crediti"), IsChecked = cur == "credits", Margin = new Thickness(0, 0, 6, 0) };
        var ac = new RadioButton { Classes = { "pill" }, GroupName = grp, Content = "A-coin", IsChecked = cur != "credits", Margin = new Thickness(0) };
        var curs = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        curs.Children.Add(cr); curs.Children.Add(ac);
        var w = new CheckBox { Content = T("Lo voglio"), IsChecked = want, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Foreground = B("#B8FFFFFF") };
        var x = new Button { Classes = { "icon" }, Content = IconPath("IcClose", "#B8FFFFFF", 10), Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(8) };
        Grid.SetColumn(pp, 1); Grid.SetColumn(v, 2); Grid.SetColumn(curs, 3); Grid.SetColumn(w, 4); Grid.SetColumn(x, 5);
        g.Children.Add(n); g.Children.Add(pp); g.Children.Add(v); g.Children.Add(curs); g.Children.Add(w); g.Children.Add(x);
        void Sync() { prize.Name = n.Text ?? ""; prize.P = pp.Text ?? ""; prize.Price = v.Text ?? ""; prize.Cur = cr.IsChecked == true ? "credits" : "acoins"; prize.Want = w.IsChecked == true; }
        n.TextChanged += (_, _) =>
        {
            Sync();

            if (CrateHelpers.FillPrizePrice(prize, S.Mechs, E)) { v.Text = prize.Price; if (prize.Cur == "credits") cr.IsChecked = true; else ac.IsChecked = true; }
            UpdateCrate();
        };
        foreach (var tb in new[] { pp, v }) tb.TextChanged += (_, _) => { Sync(); UpdateCrate(); };
        foreach (var rb in new[] { cr, ac }) rb.IsCheckedChanged += (_, _) => { Sync(); UpdateCrate(); };
        w.IsCheckedChanged += (_, _) => { Sync(); UpdateCrate(); };
        x.Click += (_, _) => { CrPrizes.Children.Remove(g); UpdateCrate(); };
        CrPrizes.Children.Add(g);
        UpdateCrate();
    }

    void UpdateMechList()
    {
        var q = (MsSearch.Text ?? "").Trim().ToLowerInvariant();
        MsList.Children.Clear();
        var keys = S.Mechs.Mechs.Keys.OrderBy(k => k, StringComparer.OrdinalIgnoreCase).Where(k => q == "" || k.ToLowerInvariant().Contains(q)).ToList();
        MsCount.Text = T("{0} mech nel database · {1} mostrati", S.Mechs.Mechs.Count, keys.Count);
        if (!App.Current.WikiBusy) MsSource.Text = WikiSourceText();
        var ratings = S.Mechs.Ratings(6);
        foreach (var k in keys)
        {
            var m = S.Mechs.Mechs[k];
            var b = new Button { Content = k, Tag = k, Margin = new Thickness(0, 0, 6, 6), Padding = new Thickness(12, 6), FontSize = 12 };
            b.Click += (_, _) => ShowMech(k);
            if (m.Custom) b.BorderBrush = B("#8CF0A8");
            if (m.Hp is null or 0) { b.Opacity = 0.6; ToolTip.SetTip(b, T("Dati incompleti: aggiungili tu")); }
            else if (ratings.TryGetValue(k, out var r)) b.Content = $"{k}  ·  {r.Tier}";
            MsList.Children.Add(b);
        }
        if (keys.Count == 1) ShowMech(keys[0]);
    }

    public void MechsReloaded()
    {
        UpdateMechList();
        if (_msCurrent is not null) ShowMech(_msCurrent);
        UpdateCrate();
    }

    public void SetWikiStatus(string text) => MsSource.Text = text;

    static string WikiSourceText() => File.Exists(S.Paths.WikiCache)
        ? T("Dati dal Mech Arena Wiki, aggiornati il {0}.", File.GetLastWriteTime(S.Paths.WikiCache).ToString("d MMM yyyy HH:mm", E.C))
        : T("Dati inclusi nell'app (Mech Arena Wiki). Premi Aggiorna per scaricare la versione più recente.");

    void ShowMech(string k)
    {
        _msCurrent = k;
        var pr = S.Mechs.MechProfile(k);
        if (pr is null) { MsDetail.IsVisible = false; return; }
        var m = pr.M;
        if (MsEdit.IsVisible) OpenMechEdit(k);
        MsDetail.IsVisible = true;
        MsName.Text = k;
        MsTag.Text = $"{S.Mechs.WW(m.Role)} · {S.Mechs.WW(m.Rarity)} · {S.Mechs.WW(m.Class)}";
        MsVerdict.Text = m.Hp is { } hp0 && hp0 != 0 ? pr.Summary : T("Dati incompleti: premi «+ Aggiungi o correggi» e scrivili come li vedi nel gioco.");
        if (m.Custom) MsTag.Text += " · " + T("dati tuoi");
        MsBars.Children.Clear();
        var idx = _msRank;
        S.Mechs.Ratings(idx).TryGetValue(k, out var r);
        BuildRankPills();
        BuildRankTable(k, idx);
        if (r is not null)
        {
            MsTierBox.IsVisible = true; MsTier.Text = r.Tier; MsScore.Text = $"{r.Score}/100";
            var col = r.Tier switch { "S" => "#FFD60A", "A" => "#30D158", "B" => "#64D2FF", "C" => "#FF9F0A", _ => "#FF453A" };
            MsTier.Foreground = B(col); MsTierBox.BorderBrush = B(col);
            MsAbilityAxes.Text = T("Abilità") + ":  " + S.Mechs.AbilityLine(r) + (string.IsNullOrEmpty(r.Ab.Note) ? "" : "\n" + r.Ab.Note);
        }
        else { MsTierBox.IsVisible = false; MsAbilityAxes.Text = ""; }
        var energyLabel = T("Energia per le armi");
        var bars = new (string L, string V, double? F, string C)[]
        {
            (T("Abilità"), r is not null ? m.Ability ?? "" : "—", r?.AbP, "#FFD60A"),
            (T("HP"), r is not null ? E.Fmt(r.Hp) : m.Hp is { } h && h != 0 && idx == 6 ? E.Fmt(h) : "—", r?.HpP, "#30D158"),
            (T("Velocità"), m.Speed is { } sp && sp != 0 ? $"{sp.ToString(CultureInfo.InvariantCulture)} km/h" : "—", r is not null ? r.SpP : pr.SpP, "#64D2FF"),
            (energyLabel, r is not null ? r.En.ToString(CultureInfo.InvariantCulture) : m.Energy is { } en && en != 0 ? en.ToString(CultureInfo.InvariantCulture) : "—",
                r is not null ? r.En / 32.0 : m.Energy is { } en2 && en2 != 0 ? en2 / 32.0 : null, "#DA8FFF"),
        };
        foreach (var b in bars)
        {
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("150,*,240"), Margin = new Thickness(0, 0, 0, 8) };
            var l = Text(b.L, "#B8FFFFFF"); l.VerticalAlignment = VerticalAlignment.Center; g.Children.Add(l);
            var frac = b.F is { } f ? Math.Max(0.03, Math.Min(1.0, f)) : 0;
            var track = new Grid { Height = 8, VerticalAlignment = VerticalAlignment.Center, ColumnDefinitions = new ColumnDefinitions($"{frac.ToString("0.####", CultureInfo.InvariantCulture)}*,{(1 - frac).ToString("0.####", CultureInfo.InvariantCulture)}*") };
            var bg = new Border { CornerRadius = new CornerRadius(4), Background = B("#1AFFFFFF") }; Grid.SetColumnSpan(bg, 2); track.Children.Add(bg);
            if (frac > 0) track.Children.Add(new Border { CornerRadius = new CornerRadius(4), Background = B(b.C) });
            Grid.SetColumn(track, 1); g.Children.Add(track);
            var txt = b.V;
            if (b.F is { } ff && b.L != energyLabel) txt += "  ·  " + T("meglio del {0}", $"{Num.ToInt(ff * 100)}%");
            var vt = Text(txt); vt.HorizontalAlignment = HorizontalAlignment.Right; vt.VerticalAlignment = VerticalAlignment.Center; vt.Margin = new Thickness(12, 0, 0, 0);
            vt.TextTrimming = TextTrimming.CharacterEllipsis;
            Grid.SetColumn(vt, 2); g.Children.Add(vt);
            MsBars.Children.Add(g);
        }
        var cd = !string.IsNullOrEmpty(m.Cooldown) ? " · " + T("ricarica {0}", m.Cooldown) : "";
        MsAbility.Text = T("Abilità: {0}", m.Ability) + cd + (m.Traits.Count > 0 ? " · " + string.Join(", ", m.Traits) : "");
        var gh = m.GearHub;
        var ghTxt = gh?.Amount is { } ga && ga != 0 ? T("Gear Hub: {0} {1}", E.Fmt(ga), E.CurName(gh.Currency)) : gh?.Currency == "money" ? T("Gear Hub: solo a pagamento") : "";
        if (ghTxt != "") MsAbility.Text += "\n" + ghTxt;
        MsAbilityText.Text = m.AbilityText ?? "";
        MsWiki.Text = !string.IsNullOrEmpty(m.Viability) ? T("Dal wiki: ") + "“" + m.Viability + "”" : "";
    }

    void BuildRankPills()
    {
        if (MsRankPills.Children.Count == 7)
        {
            for (var i = 0; i < 7; i++) ((RadioButton)MsRankPills.Children[i]).IsChecked = i == _msRank;
            return;
        }
        MsRankPills.Children.Clear();
        for (var i = 0; i < 7; i++)
        {
            var rb = new RadioButton { Classes = { "pill" }, Content = MechDb.RankLabels[i], Tag = i, GroupName = "msrank", IsChecked = i == _msRank };
            var ii = i;
            rb.Click += (_, _) => { _msRank = ii; if (_msCurrent is not null) ShowMech(_msCurrent); };
            MsRankPills.Children.Add(rb);
        }
    }

    void BuildRankTable(string k, int sel)
    {
        var g = MsRankTable; var m = S.Mechs.Mechs[k];
        g.Children.Clear(); g.RowDefinitions.Clear(); g.ColumnDefinitions.Clear();
        if (m.Ranks is not { Count: > 0 } rows)
        {
            MsRankNote.Text = T("Per questo mech le fonti non pubblicano ancora le statistiche per rango.");
            return;
        }
        g.ColumnDefinitions.Add(new ColumnDefinition(1.6, GridUnitType.Star));
        for (var i = 0; i < 7; i++) g.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));
        for (var r = 0; r <= rows.Count; r++) g.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
        var hl = new Border { Background = B("#14FFFFFF"), CornerRadius = new CornerRadius(8) };
        Grid.SetColumn(hl, sel + 1); Grid.SetRowSpan(hl, rows.Count + 1);
        g.Children.Add(hl);
        void Cell(string text, int row, int col, string fg, bool bold)
        {
            var t = new TextBlock { Text = text, Foreground = B(fg), Margin = new Thickness(6, 3), FontSize = 12, FontWeight = bold ? FontWeight.SemiBold : FontWeight.Normal };
            if (col > 0) t.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetRow(t, row); Grid.SetColumn(t, col);
            g.Children.Add(t);
        }
        for (var i = 0; i < 7; i++) Cell(MechDb.RankLabels[i], 0, i + 1, "#7AFFFFFF", i == sel);
        var rr = 1;
        foreach (var p in rows)
        {
            Cell(S.Mechs.WW(p.Key), rr, 0, "#B8FFFFFF", false);
            for (var i = 0; i < 7; i++)
            {
                var v = i < p.Value.Length && p.Value[i] is { } dv ? (dv >= 1000 ? E.Short(dv) : dv.ToString("0.##", E.C)) : "—";
                Cell(v, rr, i + 1, i == sel ? "#F5F5F7" : "#B8FFFFFF", i == sel);
            }
            rr++;
        }
        var note = T("Fonte: {0}. ★N = rango N livello 1, Max = ★6 livello 7.", string.IsNullOrEmpty(m.RanksSource) ? "Mech Arena Wiki" : m.RanksSource);
        var hpRow = m.RankRow("HP");
        if (hpRow is not null && m.Hp is { } mh && mh != 0 && hpRow.Length > 6 && hpRow[6] is { } h6 && h6 != 0 && Math.Abs(h6 - mh) / mh > 0.02)
            note += " " + T("Attenzione: le fonti non concordano sugli HP massimi ({0} contro {1}).", E.Fmt(mh), E.Fmt(h6));
        MsRankNote.Text = note;
    }

    void OpenMechEdit(string? k)
    {
        MsEdit.IsVisible = true; MeMsg.Text = "";
        Mech? m = k is not null && S.Mechs.Mechs.TryGetValue(k, out var mm) ? mm : null;
        MeName.Text = k ?? (MsSearch.Text ?? "").Trim();
        MeHp.Text = m?.Hp is { } h && h != 0 ? E.Fmt(h) : "";
        MeSpeed.Text = m?.Speed is { } s && s != 0 ? s.ToString(CultureInfo.InvariantCulture) : "";
        MeEnergy.Text = m?.Energy is { } e && e != 0 ? e.ToString(CultureInfo.InvariantCulture) : "";
        MeAbility.Text = m?.Ability ?? "";
        if (m?.Role is { } role) Check(MeRoles, role);
        if (m?.Rarity is { } rar) Check(MeRarities, rar);
    }

    void SaveMechEdit()
    {
        var name = (MeName.Text ?? "").Trim();
        if (name == "") { MeMsg.Text = T("Scrivi il nome del mech."); return; }
        var hp = Num.ParseAmount(MeHp.Text);
        double.TryParse((MeSpeed.Text ?? "").Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var sp);
        int.TryParse((MeEnergy.Text ?? "").Trim(), out var en);
        if (hp is null || hp < 20000 || hp > 2000000) { MeMsg.Text = T("HP non validi: scrivi gli HP massimi, per esempio 198.900."); return; }
        if (sp < 5 || sp > 60) { MeMsg.Text = T("Velocità non valida: di solito tra 14 e 30 km/h."); return; }
        if (en is not (16 or 18 or 20 or 24 or 32)) { MeMsg.Text = T("Energia non valida: 16, 24 o 32."); return; }
        var role = Checked(MeRoles); var rar = Checked(MeRarities);
        var cls = en >= 32 ? "Heavy" : en >= 24 ? "Medium" : "Light";
        var all = ReadCustom();
        var key = S.Mechs.Find(name) ?? name;
        all[key] = new System.Text.Json.Nodes.JsonObject
        {
            ["role"] = role, ["rarity"] = rar, ["class"] = cls, ["energy"] = en, ["hp"] = hp, ["speed"] = sp, ["ability"] = (MeAbility.Text ?? "").Trim(),
        };
        try { Json.WriteAtomic(S.Paths.MechCustom, all.ToJsonString(Json.Options)); } catch (Exception ex) { MeMsg.Text = ex.Message; return; }
        ReloadMechs();
        ShowMech(key);
        MeMsg.Text = T("Salvato: {0}.", key);
    }

    void RemoveMechEdit()
    {
        var key = S.Mechs.Find(MeName.Text);
        if (key is null || !File.Exists(S.Paths.MechCustom)) return;
        var all = ReadCustom();
        all.Remove(key);
        try { Json.WriteAtomic(S.Paths.MechCustom, all.ToJsonString(Json.Options)); } catch { }
        ReloadMechs();
        if (S.Mechs.Mechs.ContainsKey(key)) ShowMech(key); else MsDetail.IsVisible = false;
        MeMsg.Text = T("Tolti i tuoi dati per {0}.", key);
    }

    static System.Text.Json.Nodes.JsonObject ReadCustom()
    {
        try
        {
            if (File.Exists(S.Paths.MechCustom) && System.Text.Json.Nodes.JsonNode.Parse(Json.ReadText(S.Paths.MechCustom)) is System.Text.Json.Nodes.JsonObject o) return o;
        }
        catch { }
        return new();
    }

    void ReloadMechs()
    {
        S.Mechs.Load(S.Paths.CalcDir, S.Paths.WikiCache, S.Paths.MechCustom);
        UpdateMechList();
    }

    void WireSettings()
    {
        foreach (var l in Loc.Languages(S.Paths.LangDir))
        {
            var rb = new RadioButton { Classes = { "pill" }, Content = l.Name, Tag = l.Code, GroupName = "lang", IsChecked = l.Code == S.L.Lang };
            rb.Click += (_, _) => App.Current.SetLanguage(l.Code);
            LangPanel.Children.Add(rb);
        }
        BtnAccSwitch.Click += async (_, _) => await App.Current.ShowAccountPicker(false);
        BtnAccRename.Click += (_, _) => RenameAccount();
        AccRename.KeyDown += (_, e) => { if (e.Key == Key.Enter) RenameAccount(); };
        BtnAccDelete.Click += async (_, _) => await RemoveAccount();
        CredBtn.Click += async (_, _) => await SubmitManual("credits");
        AcBtn.Click += async (_, _) => await SubmitManual("acoins");
        CredIn.KeyDown += async (_, e) => { if (e.Key == Key.Enter) await SubmitManual("credits"); };
        AcIn.KeyDown += async (_, e) => { if (e.Key == Key.Enter) await SubmitManual("acoins"); };
        RateSave.Click += async (_, _) => await SaveRates();
        MisSave.Click += (_, _) => SaveMissions();
        ProcSave.Click += async (_, _) => await SaveProcPattern();
        BtnTestRead.Click += async (_, _) => await TestReadNow();
        BtnGrant.Click += (_, _) => { S.Platform.RequestPermission(); RenderSettings(); };
        ChkAuto.Click += (_, _) => { S.D.AutoRead = ChkAuto.IsChecked == true; S.Save(); UpdateStatus(); };
        ChkAutostart.Click += (_, _) => { S.D.Autostart = ChkAutostart.IsChecked == true; Autostart.Set(S.D.Autostart, S.Paths); S.Save(); };
        ChkGlass.IsChecked = S.LiquidGlass;
        ChkGlass.Click += (_, _) => App.Current.SetLiquidGlass(ChkGlass.IsChecked == true);
        ChkAutoUpdate.IsChecked = S.Prefs.GetBool("autoUpdate", true);
        ChkAutoUpdate.Click += (_, _) => { try { S.Prefs.Set("autoUpdate", ChkAutoUpdate.IsChecked == true); } catch (Exception ex) { S.Log($"ui.json: {ex.Message}"); } };
        BtnUpdate.Click += (_, _) => App.Current.StartUpdateCheck(true);
        BtnOverlayReset.Click += (_, _) => App.Current.ResetOverlay();
        ChkBanner.Click += (_, _) =>
        {
            S.D.ShowBanner = ChkBanner.IsChecked == true; S.Save();
            if (!S.D.ShowBanner) App.Current.HideOverlay(); else if (S.GameRunning) App.Current.ShowOverlay();
        };
        BtnQuit.Click += async (_, _) => await App.Current.ExitApp();
        if (!OperatingSystem.IsWindows()) ChkAutostart.Content = T("Avvia MechVault all'accesso");
        DataDirTxt.Text = T("Dati salvati in: {0}", S.Paths.Data);
    }

    public void SetUpdateStatus(string t) => UpdStatus.Text = t;

    void RenderSettings()
    {
        var d = S.D;
        RateCred.Text = E.Fmt(d.RateCredits); RateAc.Text = E.Fmt(d.RateAcoins);
        RateAutoCred.Text = S.Stats.FormatAutoRate("credits"); RateAutoAc.Text = S.Stats.FormatAutoRate("acoins");
        MisCred.Text = E.Fmt(d.MissionCredits); MisAc.Text = E.Fmt(d.MissionAcoins);
        ProcPat.Text = d.ProcessPattern;
        ChkAuto.IsChecked = d.AutoRead;
        ChkAutostart.IsChecked = d.Autostart;
        ChkBanner.IsChecked = d.ShowBanner;
        var accs = S.Store.List();
        AccInfo.Text = T("Attivo: {0}  ·  Account salvati: {1}\nQuando apri Mech Arena ti chiedo sempre con quale giochi.", S.AccountName, string.Join(", ", accs.Select(a => a.Name)));
        var pl = S.Platform;
        ReadUnavailBox.IsVisible = pl.Unavailable is not null;
        ReadUnavail.Text = pl.Unavailable is { } u ? T(u) : "";
        ReadHelp.Text = pl.Help is { } h ? T(h) : "";
        ReadHelp.IsVisible = pl.Help is not null;
        BtnGrant.IsVisible = pl.CanRequestPermission;
    }

    void RenameAccount()
    {
        var n = (AccRename.Text ?? "").Trim();
        if (n == "") return;
        S.Store.Rename(n);
        AccRename.Text = "";
        S.RaiseChanged();
    }

    async Task RemoveAccount()
    {
        if (S.Store.List().Count <= 1) { await Dialogs.Message(this, T("È l'unico account: non si può eliminare.")); return; }
        var msg = T("Eliminare l'account «{0}» con tutti i suoi obiettivi e la cronologia?\n\nIl file viene spostato nel Cestino di Windows.", S.AccountName);
        if (!OperatingSystem.IsWindows()) msg = T("Eliminare l'account «{0}» con tutti i suoi obiettivi e la cronologia?\n\nIl file viene spostato nel Cestino.", S.AccountName);
        if (!await Dialogs.Confirm(this, msg, danger: true)) return;
        S.Store.RemoveActive();
        S.AccountSwitched();
    }

    async Task SubmitManual(string cur)
    {
        var tb = cur == "credits" ? CredIn : AcIn;
        var v = Num.ParseAmount(tb.Text);
        if (v is null) { await Dialogs.Message(this, T("Numero non valido. Esempi: 512000 · 512k · 1,2M")); return; }
        tb.Text = "";
        S.PendingCheck = false;
        await S.Engine.Commit(cur, v.Value, "manuale");
        Refresh();
    }

    async Task SaveRates()
    {
        var rc = Num.ParseAmount(RateCred.Text); var ra = Num.ParseAmount(RateAc.Text);
        if (rc > 2000000 || ra > 50000)
        {
            await Dialogs.Message(this, T("Ritmo troppo alto: massimo 2.000.000 crediti e 50.000 A-coin al giorno. Lascia 0 per il calcolo automatico."));
            RenderSettings(); return;
        }
        S.D.RateCredits = rc ?? 0; S.D.RateAcoins = ra ?? 0;
        S.RaiseChanged();
    }

    void SaveMissions()
    {
        S.D.MissionCredits = Num.ParseAmount(MisCred.Text) ?? 0;
        S.D.MissionAcoins = Num.ParseAmount(MisAc.Text) ?? 0;
        S.RaiseChanged();
    }

    async Task SaveProcPattern()
    {
        var t = (ProcPat.Text ?? "").Trim();
        if (t == "") return;
        if (Platform.GamePlatform.Pattern(t) is null) { await Dialogs.Message(this, T("Espressione non valida.")); return; }
        S.D.ProcessPattern = t;
        S.RaiseChanged();
    }

    async Task TestReadNow()
    {
        var lbl = TestReadTxt;
        if (!S.Platform.CanRead) { lbl.Text = T(S.Platform.Unavailable ?? "OCR di Windows non disponibile su questo PC."); lbl.Foreground = B("#FF8A80"); return; }
        var p = await Task.Run(() => S.Platform.FindGame(S.D.ProcessPattern));
        if (p is null) { lbl.Text = T("Mech Arena non è aperto."); lbl.Foreground = B("#FFE98A"); return; }
        var r = await S.Platform.ReadBalances(p);
        if (r.Count == 0) { lbl.Text = T("Barra delle valute non visibile: vai nell'hangar (non in battaglia) e riprova."); lbl.Foreground = B("#FFE98A"); return; }
        var parts = new List<string>();
        if (r.TryGetValue("credits", out var c)) parts.Add($"{T("crediti")} {E.Fmt(c)}");
        if (r.TryGetValue("acoins", out var a)) parts.Add($"A-coin {E.Fmt(a)}");
        lbl.Text = T("Letto: ") + string.Join(" · ", parts); lbl.Foreground = B("#8CF0A8");
    }
}
