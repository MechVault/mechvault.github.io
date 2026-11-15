using System.Formats.Tar;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace MechVault.Core;

public static class Updater
{
    public sealed record Entry(string Version, string Url, string Sha256);

    public sealed record Staged(string Version, string Root, string Temp);

    public static string Rid
    {
        get
        {
            var arch = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64";
            if (OperatingSystem.IsWindows()) return "win-" + arch;
            if (OperatingSystem.IsMacOS()) return "osx-" + arch;
            return "linux-" + arch;
        }
    }

    public static Entry? Pick(JsonNode? versionJson, string rid)
    {
        if (versionJson?["platforms"]?[rid] is not JsonObject o) return null;
        var v = o["version"]?.ToString(); var u = o["url"]?.ToString(); var s = o["sha256"]?.ToString();
        if (string.IsNullOrEmpty(v) || string.IsNullOrEmpty(u) || string.IsNullOrEmpty(s)) return null;
        if (!u.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return null;
        return new Entry(v, u, s.ToLowerInvariant());
    }

    public static bool IsNewer(string remote, string current) =>
        Version.TryParse(remote, out var r) && Version.TryParse(current, out var c) && r > c;

    public static string Sha256(string file)
    {
        using var f = File.OpenRead(file);
        return Convert.ToHexString(SHA256.HashData(f)).ToLowerInvariant();
    }

        public static async Task<Staged?> CheckAndStage(HttpClient http, string baseUrl, string current, CancellationToken ct = default)
    {
        var nc = DateTime.UtcNow.Ticks;
        var json = JsonNode.Parse(await http.GetStringAsync($"{baseUrl}/version.json?t={nc}", ct));
        var e = Pick(json, Rid);
        if (e is null || !IsNewer(e.Version, current)) return null;
        var tmp = Path.Combine(Path.GetTempPath(), "mvupd_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tmp);
        try
        {
            var name = Path.GetFileName(new Uri(e.Url).AbsolutePath);
            var pkg = Path.Combine(tmp, string.IsNullOrEmpty(name) ? "package" : name);
            await using (var s = await http.GetStreamAsync(e.Url, ct))
            await using (var f = File.Create(pkg)) await s.CopyToAsync(f, ct);
            var sha = Sha256(pkg);
            if (sha != e.Sha256) throw new InvalidDataException($"SHA-256 mismatch: got {sha}");
            var x = Path.Combine(tmp, "x");
            Extract(pkg, x);
            var root = FindAppRoot(x) ?? throw new InvalidDataException("program missing from the package");
            return new Staged(e.Version, root, tmp);
        }
        catch { try { Directory.Delete(tmp, true); } catch { } throw; }
    }

    public static void Extract(string pkg, string dest)
    {
        Directory.CreateDirectory(dest);
        if (pkg.EndsWith(".tar.gz", StringComparison.OrdinalIgnoreCase) || pkg.EndsWith(".tgz", StringComparison.OrdinalIgnoreCase))
        {
            using var f = File.OpenRead(pkg);
            using var gz = new GZipStream(f, CompressionMode.Decompress);
            TarFile.ExtractToDirectory(gz, dest, true);
        }
        else ZipFile.ExtractToDirectory(pkg, dest, true);
    }

        public static string? FindAppRoot(string dir)
    {
        foreach (var d in Directory.EnumerateDirectories(dir, "*", SearchOption.AllDirectories).Prepend(dir))
        {
            if (d.EndsWith(".app", StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(d, "Contents", "MacOS", "MechVault"))) return d;
            if (File.Exists(Path.Combine(d, "MechVault.exe")) || (File.Exists(Path.Combine(d, "MechVault")) && !d.Contains(".app", StringComparison.OrdinalIgnoreCase)))
                return d;
        }
        return null;
    }

        public static int Install(Staged s, string installRoot)
    {
        var list = new List<(string Src, string Dst)>();
        foreach (var f in Directory.EnumerateFiles(s.Root, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(s.Root, f);
            var first = rel.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)[0];
            if (first.Equals("dati", StringComparison.OrdinalIgnoreCase)) continue;
            list.Add((f, Path.Combine(installRoot, rel)));
        }
        try
        {
            foreach (var (src, dst) in list)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
                File.Copy(src, dst + ".new", true);
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(dst + ".new", File.GetUnixFileMode(src));
            }
            foreach (var (_, dst) in list)
            {
                if (File.Exists(dst))
                {
                    var old = dst + ".old";
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(dst, old);
                }
                File.Move(dst + ".new", dst);
            }
        }
        catch
        {
            foreach (var (_, dst) in list) { try { if (File.Exists(dst + ".new")) File.Delete(dst + ".new"); } catch { } }
            throw;
        }
        finally { try { Directory.Delete(s.Temp, true); } catch { } }
        return list.Count;
    }

    public static void CleanupOld(string installRoot)
    {
        try
        {
            foreach (var f in Directory.EnumerateFiles(installRoot, "*.old", SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(installRoot, f);
                if (rel.StartsWith("dati", StringComparison.OrdinalIgnoreCase)) continue;
                try { File.Delete(f); } catch { }
            }
        }
        catch { }
    }

        public static string InstallRoot()
    {
        var here = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        if (OperatingSystem.IsMacOS() && here.EndsWith(Path.Combine("Contents", "MacOS"), StringComparison.Ordinal))
            return Path.GetFullPath(Path.Combine(here, "..", ".."));
        return here;
    }
}
