using Avalonia;

namespace MechVault.App;

static class Program
{
    public static string[] Args { get; private set; } = Array.Empty<string>();

    [STAThread]
    public static int Main(string[] args)
    {
        Args = args;
        if (args.Length >= 1 && args[0] == "--probe") return Probe.Run(args.Length > 1 ? args[1] : null);
#if WINDOWS
        if (args.Length >= 3 && args[0] == "--probe-ocr")
        {
            var pl = new Platform.WindowsPlatform(new MechVault.Core.AppPaths(AppContext.BaseDirectory, Path.Combine(Path.GetTempPath(), "mechvault-probe")));
            File.WriteAllText(args[2], pl.OcrFile(args[1]).GetAwaiter().GetResult());
            return 0;
        }
#endif
        if (!SingleInstance.TryAcquire())
        {
            SingleInstance.SignalOther();
            return 0;
        }
        try
        {
            return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args, Avalonia.Controls.ShutdownMode.OnExplicitShutdown);
        }
        finally { SingleInstance.Release(); }
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .With(new MacOSPlatformOptions { ShowInDock = true })
            .LogToTrace();
}

static class SingleInstance
{
    static Mutex? _mutex;
    static FileStream? _lock;
    static string Dir => Path.Combine(Path.GetTempPath(), "MechVault-" + Environment.UserName);
    public static string ShowFlag => Path.Combine(Dir, "show.flag");

    public static bool TryAcquire()
    {
        if (Environment.GetEnvironmentVariable("MECHVAULT_SELFTEST") is { Length: > 0 }) return true;
        if (OperatingSystem.IsWindows())
        {
            _mutex = new Mutex(true, @"Local\MechVault2_SingleInstance", out var created);
            return created;
        }
        Directory.CreateDirectory(Dir);
        try
        {
            _lock = new FileStream(Path.Combine(Dir, "lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            return true;
        }
        catch (IOException) { return false; }
    }

    public static void SignalOther()
    {
        try { Directory.CreateDirectory(Dir); File.WriteAllText(ShowFlag, DateTime.Now.ToString("o")); } catch { }
    }

    public static bool ConsumeShowRequest()
    {
        try { if (File.Exists(ShowFlag)) { File.Delete(ShowFlag); return true; } } catch { }
        return false;
    }

    public static void Release()
    {
        try { _mutex?.ReleaseMutex(); } catch { }
        _mutex?.Dispose();
        _lock?.Dispose();
    }
}

static class Probe
{
    public static int Run(string? outFile)
    {
        var lines = new List<string>();
        try
        {
            var tmp = Path.Combine(Path.GetTempPath(), "mechvault-probe");
            var paths = new MechVault.Core.AppPaths(AppContext.BaseDirectory, tmp);
            var pl = Platform.GamePlatform.Create(paths);
            lines.Add($"platform={pl.GetType().Name} canRead={pl.CanRead} unavailable={pl.Unavailable}");
            var g = pl.FindGame("mech.?arena");
            lines.Add(g is null ? "game=not running" : $"game={g.Name} pid={g.Pid} window={g.Window}");
            if (g is not null && pl.CanRead)
            {
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var r = pl.ReadBalances(g).GetAwaiter().GetResult();
                lines.Add($"read in {sw.ElapsedMilliseconds} ms: " + (r.Count == 0 ? "currency bar not visible" : string.Join(" ", r.Select(p => $"{p.Key}={p.Value}"))));
#if WINDOWS
                if (outFile is not null && pl is Platform.WindowsPlatform wp)
                    lines.AddRange(wp.Diagnose(g, Path.Combine(Path.GetDirectoryName(Path.GetFullPath(outFile))!, "probe")).GetAwaiter().GetResult());
#endif
            }
        }
        catch (Exception ex) { lines.Add("ERR " + ex); }
        if (outFile is not null) File.WriteAllLines(outFile, lines); else foreach (var l in lines) Console.WriteLine(l);
        return 0;
    }
}
