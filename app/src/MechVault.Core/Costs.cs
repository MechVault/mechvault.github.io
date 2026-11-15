using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace MechVault.Core;

public sealed class CostEntry
{
    public double? C { get; set; }
    public double? B { get; set; }
    public double? A { get; set; }
    public CostEntry Clone() => new() { C = C, B = B, A = A };
    public bool IsEmpty => C is null && B is null && A is null;
}

public sealed record Rarity(string K, int Min);

public sealed record CalcStep(string Key, string Label);

public sealed record CalcInput(string? Err, string Kind = "weapon", string Rarity = "epic", int Energy = 8, string Grp = "",
    int Fs = 0, int Fl = 0, int Ts = 0, int Tl = 0);

public sealed record CalcTotals(double C, double B, double A, int Miss, int N);

public sealed class CostTable
{
    public static readonly Rarity[] Rarities =
    {
        new("common", 1), new("uncommon", 2), new("rare", 3), new("epic", 4), new("legendary", 5),
    };
    public static readonly int[] Energies = { 2, 4, 6, 8, 10, 12, 14, 16 };

    static readonly Regex KeyRx = new(@"^(mech\|(common|uncommon|rare|epic|legendary)|weapon\|(common|uncommon|rare|epic|legendary)\|e(2|4|6|8|10|12|14|16))\|(lvl\|[1-6]\|[2-7]|star\|[2-6])$", RegexOptions.IgnoreCase);

    public Dictionary<string, CostEntry> Base { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, CostEntry> User { get; } = new(StringComparer.OrdinalIgnoreCase);

    public CostEntry? Get(string key) => User.TryGetValue(key, out var e) ? e : Base.TryGetValue(key, out var b) ? b : null;

    public static double? NumOrNull(JsonNode? v)
    {
        if (v is null) return null;
        if (v is JsonValue jv)
        {
            if (jv.TryGetValue<double>(out var d)) return d;
            if (jv.TryGetValue<string>(out var s))
                return s == "" ? null : double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var x) ? x : null;
        }
        return null;
    }

        public static int Merge(JsonNode? j, Dictionary<string, CostEntry> target)
    {
        if (j is not JsonObject o || (string?)o["format"] != "mechvault-costs" || o["costs"] is not JsonObject costs) return -1;
        var n = 0;
        foreach (var (k, v) in costs)
        {
            if (!KeyRx.IsMatch(k)) continue;
            var e = new CostEntry { C = NumOrNull(v?["c"]), B = NumOrNull(v?["b"]), A = NumOrNull(v?["a"]) };
            if (e.IsEmpty) continue;
            target[k] = e; n++;
        }
        return n;
    }

    public int MergeUser(JsonNode? j) => Merge(j, User);

    public void Load(string calcDir, string? userFile)
    {
        Base.Clear(); User.Clear();
        foreach (var f in new[] { Path.Combine(calcDir, "wiki-costs.json"), Path.Combine(calcDir, "cost-fixes.json") })
            if (File.Exists(f)) try { Merge(JsonNode.Parse(Json.ReadText(f)), Base); } catch { }
        if (userFile is not null && File.Exists(userFile)) try { Merge(JsonNode.Parse(Json.ReadText(userFile)), User); } catch { }
    }

        public int Save(string path, DateTime now, bool all = false)
    {
        var src = new Dictionary<string, CostEntry>(StringComparer.OrdinalIgnoreCase);
        if (all) foreach (var (k, v) in Base) src[k] = v;
        foreach (var (k, v) in User) src[k] = v;
        var costs = new JsonObject();
        foreach (var k in src.Keys.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
        {
            var v = src[k];
            costs[k] = new JsonObject { ["c"] = v.C, ["b"] = v.B, ["a"] = v.A };
        }
        var j = new JsonObject { ["format"] = "mechvault-costs", ["version"] = 1, ["updated"] = Dates.Iso(now), ["costs"] = costs };
        Json.WriteAtomic(path, j.ToJsonString(Json.Options));
        return src.Count;
    }

        public void SetCell(string key, char field, double? v)
    {
        if (!User.TryGetValue(key, out var e))
        {
            e = Base.TryGetValue(key, out var b0) ? b0.Clone() : new CostEntry();
            User[key] = e;
        }
        switch (field) { case 'c': e.C = v; break; case 'b': e.B = v; break; default: e.A = v; break; }
        if (e.IsEmpty) User.Remove(key);
    }

    public static string Group(string kind, string rarity, int energy) => kind == "mech" ? $"mech|{rarity}" : $"weapon|{rarity}|e{energy}";

        public static CalcInput Input(Env env, string kind, string rarity, int energy, string fs, string fl, string ts, string tl)
    {
        var v = new int[4];
        var src = new[] { fs, fl, ts, tl };
        for (var i = 0; i < 4; i++)
        {
            var x = Num.ParseIntIn(src[i], 1, i % 2 == 0 ? 6 : 7);
            if (x is null) return new CalcInput(env.T("Stelle da 1 a 6, livelli da 1 a 7."));
            v[i] = x.Value;
        }
        if (!Rarities.Any(r => r.K == rarity)) rarity = "epic";
        if (!Energies.Contains(energy)) energy = 8;
        kind = kind == "mech" ? "mech" : "weapon";
        return new CalcInput(null, kind, rarity, energy, Group(kind, rarity, energy), v[0], v[1], v[2], v[3]);
    }

    public static List<CalcStep> StepPath(Env env, int fs, int fl, int ts, int tl)
    {
        var steps = new List<CalcStep>();
        int s = fs, l = fl;
        while (s < ts || (s == ts && l < tl))
        {
            if (l < 7) { steps.Add(new CalcStep($"lvl|{s}|{l + 1}", env.T("★{0} · liv. {1} → {2}", s, l, l + 1))); l++; }
            else { steps.Add(new CalcStep($"star|{s + 1}", env.T("★{0} → ★{1}", s, s + 1))); s++; l = 1; }
        }
        return steps;
    }

    public List<string> Keys(Env env, CalcInput i) =>
        i.Err is not null ? new() : StepPath(env, i.Fs, i.Fl, i.Ts, i.Tl).Select(st => i.Grp + "|" + st.Key).ToList();

    public CalcTotals Totals(IEnumerable<string> keys)
    {
        double c = 0, b = 0, a = 0; int miss = 0, n = 0;
        foreach (var k in keys)
        {
            n++;
            var e = Get(k);
            if (e is null) { miss++; continue; }
            if (e.C is { } x) c += x;
            if (e.B is { } y) b += y;
            if (e.A is { } z) a += z;
        }
        return new CalcTotals(c, b, a, miss, n);
    }

        public (double C, double B, double A, int Miss) UpgSum(Env env, string grp, (int S, int L) from, (int S, int L) to)
    {
        double c = 0, b = 0, a = 0; var miss = 0;
        if (from.S > to.S || (from.S == to.S && from.L >= to.L)) return (c, b, a, miss);
        foreach (var st in StepPath(env, from.S, from.L, to.S, to.L))
        {
            var e = Get(grp + "|" + st.Key);
            if (e is null) { miss++; continue; }
            if (e.C is { } x) c += x;
            if (e.B is { } y) b += y;
            if (e.A is { } z) a += z;
        }
        return (c, b, a, miss);
    }
}
