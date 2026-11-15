using System.Diagnostics;
using System.Text.RegularExpressions;
using MechVault.Core;

namespace MechVault.App.Platform;

public sealed record GameHandle(int Pid, string Name, nint Window);

public interface IGamePlatform
{
        bool CanRead { get; }

        string? Unavailable { get; }

        string? Help { get; }

        bool CanRequestPermission { get; }

    void RequestPermission();

    GameHandle? FindGame(string pattern);

        Task<Dictionary<string, double>> ReadBalances(GameHandle g);
}

public static class GamePlatform
{
    public static IGamePlatform Create(AppPaths paths)
    {
#if WINDOWS
        return new WindowsPlatform(paths);
#else
        if (OperatingSystem.IsMacOS()) return new MacPlatform(paths);
        if (OperatingSystem.IsLinux()) return new LinuxPlatform(paths);
        return new ManualOnly("Lettura automatica non disponibile su questo sistema: inserisci i saldi a mano.");
#endif
    }

    public static Regex? Pattern(string pattern)
    {
        try { return new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200)); }
        catch { return null; }
    }

        public static GameHandle? FindByProcessName(string pattern, bool needWindow)
    {
        var rx = Pattern(pattern);
        if (rx is null) return null;
        GameHandle? best = null;
        foreach (var p in Process.GetProcesses())
        {
            try
            {
                if (!rx.IsMatch(p.ProcessName)) continue;
                nint h = 0;
                if (needWindow) { try { h = p.MainWindowHandle; } catch { } }
                var g = new GameHandle(p.Id, p.ProcessName, h);
                if (best is null || (best.Window == 0 && h != 0)) best = g;
            }
            catch { }
            finally { p.Dispose(); }
        }
        return best;
    }

        public static async Task<(int Code, string Out)> Run(string exe, IEnumerable<string> args, int timeoutMs = 15000)
    {
        var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi);
        if (p is null) return (-1, "");
        var outTask = p.StandardOutput.ReadToEndAsync();
        _ = p.StandardError.ReadToEndAsync();
        using var cts = new CancellationTokenSource(timeoutMs);
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException) { try { p.Kill(true); } catch { } return (-1, ""); }
        return (p.ExitCode, await outTask);
    }

    public static string? Which(string name)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            if (dir == "") continue;
            var f = Path.Combine(dir, name);
            if (File.Exists(f)) return f;
        }
        return null;
    }
}

public sealed class ManualOnly : IGamePlatform
{
    public ManualOnly(string reason, string? help = null) { Unavailable = reason; Help = help; }
    public bool CanRead => false;
    public string? Unavailable { get; }
    public string? Help { get; }
    public bool CanRequestPermission => false;
    public void RequestPermission() { }
    public GameHandle? FindGame(string pattern) => GamePlatform.FindByProcessName(pattern, false);
    public Task<Dictionary<string, double>> ReadBalances(GameHandle g) => Task.FromResult(new Dictionary<string, double>());
}
