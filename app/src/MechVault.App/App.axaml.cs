using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Media;
using Avalonia.Platform;
using Avalonia.Threading;
using MechVault.App.Platform;
using MechVault.App.Views;
using MechVault.Core;

namespace MechVault.App;

public partial class App : Application, IBalanceHost
{
    public static new App Current => (App)Application.Current!;
    public static WindowIcon AppIcon { get; } = new(AssetLoader.Open(new Uri("avares://MechVault/Assets/mechvault.png")));

    static AppState S => AppState.I;
    static string T(string k, params object?[] a) => S.T(k, a);

    IClassicDesktopStyleApplicationLifetime _life = null!;
    public MainWindow Main { get; private set; } = null!;
    public OverlayWindow? Overlay { get; private set; }
    TrayIcon? _tray;
    WarnWindow? _warn;
    readonly DispatcherTimer _watch = new() { Interval = TimeSpan.FromSeconds(3) };
    bool _watchBusy, _watchStarted, _inDialog, _updPrompt;
    int _tick;
    Task? _updJob;
    public bool WikiBusy { get; private set; }

    public const string UpdateBase = "https://mechvault.github.io";

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime life) { base.OnFrameworkInitializationCompleted(); return; }
        _life = life;
        AppState.Create(this);
        Updater.CleanupOld(Updater.InstallRoot());
        if (!S.LiquidGlass)
        {
            Resources["GlassFill"] = new SolidColorBrush(Color.Parse("#FF26262A"));
            Resources["GlassEdge"] = new SolidColorBrush(Color.Parse("#24FFFFFF"));
            Resources["GlassFillStrong"] = new SolidColorBrush(Color.Parse("#FF303035"));
        }
        Dispatcher.UIThread.UnhandledException += (_, e) => { S.Log(e.Exception.ToString()); e.Handled = true; };

        Main = new MainWindow();
        Main.Refresh();
        if (S.SelfTest) { _ = SelfTest.Run(this, Main); base.OnFrameworkInitializationCompleted(); return; }

        SetupTray();
        _watch.Tick += async (_, _) => await WatchTick();
        _watch.Start();
        if (S.D.Autostart) Autostart.Set(true, S.Paths);
        var minimized = Program.Args.Contains("--minimized");
        if (S.D.FirstRun)
        {
            S.D.FirstRun = false;
            S.Save();
            ShowMain();
        }
        else if (minimized)
        {
            var first = S.Stats.GoalStats().FirstOrDefault();
            var msg = T("{0} · {1} giorni senza spendere.", S.AccountName, S.Stats.Streak());
            if (first is not null) msg += $" {first.Goal.Name}: {Math.Floor(first.Pct * 100)}%";
            Notifier.Show(T("MechVault attivo"), msg);
        }
        else ShowMain();

        var upd = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        upd.Tick += (_, _) => { upd.Interval = TimeSpan.FromHours(6); StartUpdateCheck(false); };
        upd.Start();
        StartWikiUpdate(false);
        base.OnFrameworkInitializationCompleted();
    }

    void SetupTray()
    {
        var menu = new NativeMenu();
        var open = new NativeMenuItem(T("Apri MechVault")); open.Click += (_, _) => ShowMain();
        var acc = new NativeMenuItem(T("Cambia account")); acc.Click += async (_, _) => await ShowAccountPicker(false);
        var quit = new NativeMenuItem(T("Esci")); quit.Click += async (_, _) => await ExitApp();
        menu.Add(open); menu.Add(acc); menu.Add(new NativeMenuItemSeparator()); menu.Add(quit);
        _tray = new TrayIcon { Icon = AppIcon, ToolTipText = "MechVault", Menu = menu, IsVisible = true };
        _tray.Clicked += (_, _) => ShowMain();
        TrayIcon.SetIcons(this, new TrayIcons { _tray });
        S.Changed += UpdateTrayTip;
        UpdateTrayTip();
    }

    void UpdateTrayTip()
    {
        if (_tray is null) return;
        var first = S.Stats.GoalStats().FirstOrDefault();
        var tip = T("MechVault · {0} · {1} gg puliti", S.AccountName, S.Stats.Streak());
        if (first is not null) tip += $" · {Math.Floor(first.Pct * 100)}%";
        _tray.ToolTipText = tip.Length > 63 ? tip[..63] : tip;
    }

    public void ShowMain()
    {
        Main.Refresh();
        Main.Show();
        if (Main.WindowState == WindowState.Minimized) Main.WindowState = WindowState.Normal;
        Main.Activate();
    }

    async Task WatchTick()
    {
        if (SingleInstance.ConsumeShowRequest()) ShowMain();
        if (_watchBusy || _inDialog || S.Engine.InDialog) return;
        _watchBusy = true;
        try
        {
            var pattern = S.D.ProcessPattern;
            var game = await Task.Run(() => S.Platform.FindGame(pattern));
            var running = game is not null;
            var firstCheck = !_watchStarted; _watchStarted = true;
            if (running && !S.GameRunning) { S.GameRunning = true; await OnGameStart(firstCheck); return; }
            if (!running && S.GameRunning) { S.GameRunning = false; await OnGameStop(); }

            if (running && S.D.AutoRead && S.Platform.CanRead && !_inDialog)
            {
                var r = await S.Platform.ReadBalances(game!);
                if (r.Count > 0)
                {
                    S.D.LastReadAt = Dates.Iso(DateTime.Now);
                    foreach (var c in new[] { "credits", "acoins" })
                        if (r.TryGetValue(c, out var v) && !_inDialog) await S.Engine.ProcessRead(c, v);
                }
            }
            if (++_tick % 10 == 0) Main.UpdateStatus();
        }
        catch (Exception ex) { S.Log($"Sorveglianza: {ex.Message}"); }
        finally { _watchBusy = false; }
    }

    async Task OnGameStart(bool quiet)
    {
        S.Engine.ResetPendingReads();
        if (quiet)
        {
            Main.UpdateStatus();
            ShowOverlay();
            Notifier.Show(T("Mech Arena aperto"), T("{0}: blocco spese attivo. Per cambiare account: icona MechVault › Cambia account.", S.AccountName));
            return;
        }
        await ShowAccountPicker(true);
        Main.UpdateStatus();
        ShowLaunchWarning();
        ShowOverlay();
        Notifier.Show(T("Mech Arena aperto"), T("{0}: blocco spese attivo.", S.AccountName));
    }

    async Task OnGameStop()
    {
        HideOverlay();
        Main.UpdateStatus();
        if (_updPrompt) { _updPrompt = false; await PromptUpdateRestart(); }
        if (!(S.D.AutoRead && S.Platform.CanRead))
        {
            S.PendingCheck = true;
            ShowMain();
            Main.ShowPage("PageSettings");
            Main.FocusManualCredits();
        }
        else
        {
            var d = S.D; var E = S.Env;
            Notifier.Show(T("Partita finita"), T("{0}: {1} crediti · {2} A-coin. Serie: {3} giorni.", S.AccountName,
                d.InitCredits ? E.Fmt(d.Credits) : "—", d.InitAcoins ? E.Fmt(d.Acoins) : "—", S.Stats.Streak()));
        }
    }

    void ShowLaunchWarning()
    {
        if (_warn is not null) return;
        _warn = new WarnWindow();
        _warn.Closed += (_, _) => _warn = null;
        Ui.Translate(_warn, S.L);
        _warn.Show();
        _warn.Activate();
    }

    public void ShowOverlay()
    {
        if (Overlay is not null || !S.D.ShowBanner) return;
        Overlay = new OverlayWindow();
        Overlay.Show();
    }

    public void HideOverlay()
    {
        Overlay?.Close();
        Overlay = null;
    }

    public void ResetOverlay()
    {
        var o = OverlayPrefs.Load(S.Paths.Overlay);
        o.X = null; o.Y = null; o.Mode = "full"; o.Save(S.Paths.Overlay);
        Overlay?.ResetPosition();
    }

    public async Task ShowAccountPicker(bool fromGame)
    {
        if (_inDialog) return;
        _inDialog = true;
        string? picked;
        try
        {
            var w = new AccountDialog(fromGame);
            await w.ShowAsync(Main.IsVisible ? Main : null);
            picked = w.Picked;
        }
        finally { _inDialog = false; }
        if (picked is null) return;
        if (picked.StartsWith("new:")) { S.Store.Create(picked[4..]); S.AccountSwitched(); }
        else if (picked != S.Store.ActiveId && S.Store.Switch(picked)) S.AccountSwitched();
    }

    public async Task<ViolationAnswer> AskViolation(string cur, double excess, double covered, string src, int streak)
    {
        _inDialog = true;
        try { return await ViolationDialog.Ask(Main.IsVisible ? Main : null, cur, excess, covered, src, streak); }
        finally { _inDialog = false; }
    }

    public void Notify(string title, string text) => Notifier.Show(title, text);
    public void Changed() => S.RaiseChanged();
    public void Log(string text) => S.Log(text);

    public void SetLanguage(string code)
    {
        if (code == S.L.Lang) return;
        try { File.WriteAllText(S.Paths.LangFile, code); } catch (Exception ex) { S.Log($"lang.txt: {ex.Message}"); return; }
        Restart();
    }

    public void SetLiquidGlass(bool on)
    {
        if (on == S.LiquidGlass) return;
        try { S.Prefs.Set("liquidGlass", on); } catch (Exception ex) { S.Log($"ui.json: {ex.Message}"); return; }
        Restart();
    }

        public void Restart()
    {
        S.Save();
        HideOverlay();
        var exe = Environment.ProcessPath;
        Quit();
        SingleInstance.Release();
        if (exe is not null) try { Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false }); } catch (Exception ex) { S.Log($"Riavvio: {ex.Message}"); }
    }

    public async Task ExitApp()
    {
        var owner = Main.IsVisible ? Main : null;
        if (!await Dialogs.Confirm(owner, T("Se chiudi MechVault smette di sorvegliarti fino al prossimo avvio del PC.\n\nVuoi davvero uscire?"), danger: true)) return;
        S.Save();
        HideOverlay();
        Quit();
    }

    void Quit()
    {
        _watch.Stop();
        if (_tray is not null) _tray.IsVisible = false;
        Main.AllowClose();
        _life.Shutdown();
    }

    public void StartUpdateCheck(bool manual)
    {
        if (S.SelfTest || _updJob is not null) return;
        if (S.UpdateReady is { } ready)
        {
            Main.SetUpdateStatus(T("Versione {0} installata. Si attiva al prossimo avvio di MechVault.", ready));
            if (manual) _ = PromptUpdateRestart();
            return;
        }
        if (!manual && !S.Prefs.GetBool("autoUpdate", true)) return;
        Main.SetUpdateStatus(T("Controllo aggiornamenti…"));
        var baseUrl = Environment.GetEnvironmentVariable("MECHVAULT_UPDATE_BASE") is { Length: > 0 } b ? b.TrimEnd('/') : UpdateBase;
        _updJob = Task.Run(async () =>
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("MechVault/" + AppState.Version);
            var staged = await Updater.CheckAndStage(http, baseUrl, AppState.Version);
            if (staged is null) return (string?)null;
            var n = Updater.Install(staged, Updater.InstallRoot());
            S.Log($"Aggiornamento: installata la {staged.Version} ({n} file)");
            return staged.Version;
        });
        _updJob.ContinueWith(t => Dispatcher.UIThread.Post(async () =>
        {
            _updJob = null;
            if (t.IsFaulted)
            {
                var msg = t.Exception?.InnerException?.Message ?? "no answer";
                S.Log($"Aggiornamento: {msg}");
                Main.SetUpdateStatus(T("Controllo non riuscito ({0}). Riprova più tardi.", msg));
                return;
            }
            var v = ((Task<string?>)t).Result;
            if (v is null) { Main.SetUpdateStatus(T("Hai l'ultima versione ({0}).", AppState.Version)); return; }
            S.UpdateReady = v;
            Main.SetUpdateStatus(T("Versione {0} installata. Si attiva al prossimo avvio di MechVault.", v));
            await PromptUpdateRestart();
        }));
    }

        async Task PromptUpdateRestart()
    {
        if (S.UpdateReady is not { } v) return;
        if (S.GameRunning || _inDialog) { _updPrompt = true; return; }
        _updPrompt = false;
        if (!Main.IsVisible) { Notifier.Show("MechVault", T("Versione {0} installata. Si attiva al prossimo avvio di MechVault.", v)); return; }
        if (await Dialogs.Confirm(Main, T("MechVault {0} è installato. Riavviare adesso per usarlo?", v))) Restart();
    }

    public void StartWikiUpdate(bool force)
    {
        if (WikiBusy || S.SelfTest) return;
        if (!force && File.Exists(S.Paths.WikiCache) && (DateTime.Now - File.GetLastWriteTime(S.Paths.WikiCache)).TotalDays < 3) return;
        WikiBusy = true;
        S.Log("Wiki: aggiornamento avviato");
        Main.SetWikiStatus(T("Aggiornamento dal wiki in corso…"));
        Task.Run(() => Wiki.Update(S.Paths.WikiCache)).ContinueWith(t => Dispatcher.UIThread.Post(() =>
        {
            WikiBusy = false;
            if (t.IsFaulted) S.Log($"Wiki: {t.Exception?.InnerException?.Message}");
            S.Log($"Wiki: aggiornamento finito ({File.Exists(S.Paths.WikiCache)})");
            S.Mechs.Load(S.Paths.CalcDir, S.Paths.WikiCache, S.Paths.MechCustom);
            Main.MechsReloaded();
        }));
    }
}
