using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using MechVault.App.Views;
using MechVault.Core;

namespace MechVault.App;

static class SelfTest
{
    public static async Task Run(App app, MainWindow main)
    {
        var outDir = Environment.GetEnvironmentVariable("MECHVAULT_SELFTEST")!;
        Directory.CreateDirectory(outDir);
        var S = AppState.I;
        var log = new List<string>();
        try
        {
            Demo(S);
            S.AccountSwitched();
            main.Width = 1180; main.Height = 1320;
            main.Show();
            main.Root.Background = Fake;
            main.Refresh();
            foreach (var page in new[] { "PageHome", "PageGoals", "PageActivity", "PageTools", "PageSettings" })
            {
                main.ShowPage(page);
                await Task.Delay(700);
                Save(main.Content as Control, Path.Combine(outDir, page.Replace("Page", "").ToLowerInvariant() + ".png"));
            }
            app.ShowOverlay();
            await Task.Delay(800);
            if (app.Overlay?.Content is Control oc) Save(oc, Path.Combine(outDir, "overlay.png"));
            app.Overlay!.ApplyMode("mini"); await Task.Delay(400);
            if (app.Overlay?.Content is Control oc2) Save(oc2, Path.Combine(outDir, "overlay_mini.png"));
            app.HideOverlay();
            var warn = new WarnWindow(); Ui.Translate(warn, S.L); warn.Show(); await Task.Delay(600);
            Save(warn.Content as Control, Path.Combine(outDir, "warn.png")); warn.Close();
            var viol = new ViolationDialog("acoins", 2480, 800, "auto", 6); Ui.Translate(viol, S.L); viol.Show(); await Task.Delay(600);
            Save(viol.Content as Control, Path.Combine(outDir, "violation.png"));
            log.Add($"OK platform={S.Platform.GetType().Name} canRead={S.Platform.CanRead} unavailable={S.Platform.Unavailable} accounts={string.Join(",", S.Store.List().Select(a => a.Name))} rateC=[{S.Stats.FormatAutoRate("credits")}]");
        }
        catch (Exception ex) { log.Add("ERR " + ex); }
        File.WriteAllLines(Path.Combine(outDir, "result.txt"), log);
        main.AllowClose();
        (Application.Current!.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.Shutdown();
    }

    static void Save(Control? c, string path)
    {
        if (c is null) return;
        var size = new PixelSize(Math.Max(1, (int)c.Bounds.Width), Math.Max(1, (int)c.Bounds.Height));
        using var rtb = new RenderTargetBitmap(size);
        rtb.Render(c);
        rtb.Save(path);
    }

    static readonly IBrush Fake = new LinearGradientBrush
    {
        StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.FromRgb(58, 60, 66), 0), new GradientStop(Color.FromRgb(34, 35, 40), 0.6), new GradientStop(Color.FromRgb(46, 44, 52), 1) },
    };

    static void Demo(AppState S)
    {
        var now = DateTime.Now;
        var d = S.D;
        d.AccountName = "Main";
        double c = 300000, a = 40;
        d.Events.Clear();
        for (var k = 12; k >= 0; k--)
        {
            var day = now.Date.AddDays(-k).AddHours(15);
            if (k == 12) { d.AddEvent(day, "credits", 0, c, "init", "", "auto"); d.AddEvent(day, "acoins", 0, a, "init", "", "auto"); continue; }
            var gc = 14000.0 + (k * 7919 % 11000); c += gc; d.AddEvent(day, "credits", gc, c, "gain", "", "auto");
            var ga = 15.0 + (k * 31 % 25); a += ga; d.AddEvent(day.AddMinutes(20), "acoins", ga, a, "gain", "", "auto");
            if (k == 6) { a -= 120; d.AddEvent(day.AddMinutes(40), "acoins", -120, a, "spend", "Timed offer", "auto"); }
            if (k is 0 or 2) { c -= 1200; d.AddEvent(day.AddMinutes(50), "credits", -1200, c, "mission", "budget missioni", "auto"); }
        }
        d.Credits = c; d.InitCredits = true; d.Acoins = a; d.InitAcoins = true;
        d.Violations = new() { new Violation { T = Dates.Iso(now.Date.AddDays(-6).AddHours(15).AddMinutes(40)), Currency = "acoins", Amount = 120, Reason = "Timed offer.", StreakLost = 3, PrevClean = Dates.Iso(now.AddDays(-12)) } };
        d.CleanSince = Dates.Iso(now.Date.AddDays(-6).AddHours(16));
        d.BestStreak = 6; d.FirstRun = false; d.CreatedAt = Dates.Iso(now.AddDays(-12)); d.LastReadAt = Dates.Iso(now.AddMinutes(-2));
        d.Goals = new() { Goals.New("Epic weapon ★6 lvl 7", "credits", 683000), Goals.New("Legendary mech ★6 lvl 7", "credits", 2450000), Goals.New("A-coin reserve", "acoins", 2500) };
        S.Save();
        S.Store.Create("Alt");
        S.Store.Switch(S.Store.List().First(x => x.Name == "Main").Id);
    }
}
