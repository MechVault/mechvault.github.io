using System.Globalization;
using System.Text.Json;

namespace MechVault.Core;

public sealed class Loc
{
    readonly Dictionary<string, string> _map = new(StringComparer.Ordinal);

    public string Lang { get; private set; } = "it";
    public CultureInfo Culture { get; private set; } = CultureInfo.GetCultureInfo("it-IT");
    public IReadOnlyDictionary<string, string> Map => _map;

    public static Loc Italian() => new();

        public static Loc Load(string langDir, string code)
    {
        var loc = new Loc();
        if (string.IsNullOrWhiteSpace(code) || code == "it") return loc;
        var f = Path.Combine(langDir, code + ".json");
        if (!File.Exists(f)) return loc;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(f));
            foreach (var pair in doc.RootElement.GetProperty("strings").EnumerateArray())
            {
                if (pair.GetArrayLength() < 2) continue;
                var k = pair[0].GetString();
                var v = pair[1].GetString();
                if (!string.IsNullOrEmpty(k) && !string.IsNullOrEmpty(v)) loc._map[k] = v;
            }
            if (doc.RootElement.TryGetProperty("culture", out var c) && c.GetString() is { Length: > 0 } cs)
                loc.Culture = CultureInfo.GetCultureInfo(cs);
            loc.Lang = code;
        }
        catch
        {
            loc._map.Clear();
            loc.Culture = CultureInfo.GetCultureInfo("it-IT");
            loc.Lang = "it";
        }
        return loc;
    }

        public string T(string k, params object?[] args)
    {
        if (!_map.TryGetValue(k, out var v) || string.IsNullOrEmpty(v)) v = k;
        return args.Length > 0 ? string.Format(Culture, v, args) : v;
    }

    public sealed record LangInfo(string Code, string Name);

        public static List<LangInfo> Languages(string langDir)
    {
        var list = new List<LangInfo>();
        if (Directory.Exists(langDir))
        {
            var files = Directory.GetFiles(langDir, "*.json")
                .OrderBy(f => Path.GetFileNameWithoutExtension(f) == "en" ? 0 : 1)
                .ThenBy(f => Path.GetFileName(f), StringComparer.OrdinalIgnoreCase);
            foreach (var f in files)
            {
                var code = Path.GetFileNameWithoutExtension(f);
                var name = code;
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(f));
                    if (doc.RootElement.TryGetProperty("name", out var n) && n.GetString() is { Length: > 0 } ns) name = ns;
                }
                catch { }
                list.Add(new LangInfo(code, name));
            }
        }
        list.Add(new LangInfo("it", "Italiano"));
        return list;
    }
}
