using System.Diagnostics;
using MechVault.Core;

namespace MechVault.App;

public static class Autostart
{
    const string Name = "MechVault";

    static string Exe => Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName ?? "";

    public static void Set(bool on, AppPaths paths)
    {
        if (AppState.I.SelfTest) return;
        try
        {
            if (OperatingSystem.IsWindows()) SetWindows(on);
            else if (OperatingSystem.IsMacOS()) SetMac(on);
            else SetLinux(on);
        }
        catch (Exception ex) { paths.Log($"Autostart: {ex.Message}"); }
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    static void SetWindows(bool on)
    {
        using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (on) k.SetValue(Name, $"\"{Exe}\" --minimized");
        else if (k.GetValue(Name) is not null) k.DeleteValue(Name);
    }

    static void SetMac(bool on)
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "LaunchAgents");
        var f = Path.Combine(dir, "io.github.mechvault.plist");
        if (!on) { if (File.Exists(f)) File.Delete(f); return; }
        Directory.CreateDirectory(dir);
        var exe = System.Security.SecurityElement.Escape(Exe);
        File.WriteAllText(f, $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>io.github.mechvault</string>
              <key>ProgramArguments</key><array><string>{exe}</string><string>--minimized</string></array>
              <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """);
    }

    static void SetLinux(bool on)
    {
        var cfg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (string.IsNullOrEmpty(cfg)) cfg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(cfg, "autostart");
        var f = Path.Combine(dir, "mechvault.desktop");
        if (!on) { if (File.Exists(f)) File.Delete(f); return; }
        Directory.CreateDirectory(dir);
        File.WriteAllText(f, $"[Desktop Entry]\nType=Application\nName=MechVault\nExec=\"{Exe}\" --minimized\nX-GNOME-Autostart-enabled=true\nTerminal=false\n");
    }
}
