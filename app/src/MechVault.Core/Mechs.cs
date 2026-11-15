using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace MechVault.Core;

public sealed class GearHub
{
    public double? Amount { get; set; }
    public string Currency { get; set; } = "credits";
}

public sealed class Mech
{
    public string? Role, Rarity, Class, Ability, Cooldown, Viability, AbilityDuration, AbilityDamage, AbilityText, RanksSource;
    public double? Energy, Hp, Speed;
    public List<string> Traits = new(), AbilityTags = new();
    public GearHub? GearHub;
        public List<KeyValuePair<string, double?[]>>? Ranks;
    public bool Custom;

    public Mech Clone()
    {
        var m = (Mech)MemberwiseClone();
        m.Traits = new(Traits); m.AbilityTags = new(AbilityTags);
        m.Ranks = Ranks is null ? null : new(Ranks);
        return m;
    }

    static bool Truthy(double? v) => v is { } d && d != 0;

    static string? Str(JsonNode? n) => n switch
    {
        null => null,
        JsonValue v when v.TryGetValue<string>(out var s) => s,
        JsonValue v when v.TryGetValue<double>(out var d) => d.ToString(CultureInfo.InvariantCulture),
        JsonValue v when v.TryGetValue<bool>(out var b) => b ? "True" : "False",
        _ => n.ToJsonString(),
    };

    static double? Dbl(JsonNode? n)
    {
        if (n is not JsonValue v) return null;
        if (v.TryGetValue<double>(out var d)) return d;
        if (v.TryGetValue<string>(out var s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var x)) return x;
        return null;
    }

    static List<string> Strs(JsonNode? n) => n switch
    {
        JsonArray a => a.Select(Str).Where(s => !string.IsNullOrEmpty(s)).Select(s => s!).ToList(),
        null => new(),
        _ => Str(n) is { Length: > 0 } s ? new() { s } : new(),
    };

    static bool IsEmpty(JsonNode? v) =>
        v is null || (v is JsonValue jv && jv.TryGetValue<string>(out var s) && s.Length == 0) || (v is JsonArray a && a.Count == 0);

        public void Apply(JsonObject o, bool skipEmpty)
    {
        foreach (var (k, v) in o)
        {
            if (skipEmpty && IsEmpty(v)) continue;
            switch (k.ToLowerInvariant())
            {
                case "role": Role = Str(v); break;
                case "rarity": Rarity = Str(v); break;
                case "class": Class = Str(v); break;
                case "energy": Energy = Dbl(v); break;
                case "hp": Hp = Dbl(v); break;
                case "speed": Speed = Dbl(v); break;
                case "ability": Ability = Str(v); break;
                case "cooldown": Cooldown = Str(v); break;
                case "traits": Traits = Strs(v); break;
                case "viability": Viability = Str(v); break;
                case "abilityduration": AbilityDuration = Str(v); break;
                case "abilitydamage": AbilityDamage = Str(v); break;
                case "abilitytext": AbilityText = Str(v); break;
                case "abilitytags": AbilityTags = Strs(v); break;
                case "rankssource": RanksSource = Str(v); break;
                case "custom": Custom = v is JsonValue cv && cv.TryGetValue<bool>(out var cb) && cb; break;
                case "gearhub":
                    GearHub = v is JsonObject g ? new GearHub { Amount = Dbl(g["amount"]), Currency = Str(g["currency"]) ?? "credits" } : null;
                    break;
                case "ranks":
                    if (v is JsonObject r)
                        Ranks = r.Select(p => new KeyValuePair<string, double?[]>(p.Key,
                            p.Value is JsonArray arr ? arr.Select(Dbl).ToArray() : new[] { Dbl(p.Value) })).ToList();
                    else Ranks = null;
                    break;
            }
        }
    }

    public static Mech From(JsonObject o) { var m = new Mech(); m.Apply(o, false); return m; }

    public double?[]? RankRow(string name)
    {
        if (Ranks is null || Ranks.Count == 0) return null;
        foreach (var p in Ranks) if (string.Equals(p.Key, name, StringComparison.OrdinalIgnoreCase)) return p.Value;
        return null;
    }

        public double? StatAt(string stat, int idx)
    {
        var row = RankRow(stat);
        if (row is not null && row.Length > idx && row[idx] is { } x) return x;
        if (idx == 6)
        {
            if (stat.Equals("HP", StringComparison.OrdinalIgnoreCase) && Truthy(Hp)) return Hp;
            if (stat.Equals("Energy", StringComparison.OrdinalIgnoreCase) && Truthy(Energy)) return Energy;
        }
        if (stat.Equals("Speed", StringComparison.OrdinalIgnoreCase) && Truthy(Speed)) return Speed;
        return null;
    }

        public double? StatAtLevel(string stat, int star, int lvl)
    {
        var i = Math.Max(0, Math.Min(5, star - 1));
        var a = StatAt(stat, i);
        var b = StatAt(stat, star >= 6 ? 6 : i + 1);
        if (a is null) return b;
        if (b is null || lvl <= 1) return a;
        return a + (b - a) * (Math.Min(7, lvl) - 1) / 6.0;
    }
}

public sealed record AbilityProfile(double P, double[] Ax, string? En, string? It);

public sealed class AbilityInfo
{
    public double Raw, P;
    public Dictionary<char, double> Axes = new();
    public double? Uptime, Cd, Dur;
    public List<string> Tags = new();
    public bool Est;
    public string? Note;
}

public sealed class Rating
{
    public double Score;
    public string Tier = "D";
    public double AbP;
    public AbilityInfo Ab = new();
    public int Adj;
    public double Hp, HpP, En, Sp, SpP;
    public int Idx;
}

public sealed class MechDb
{
    public Dictionary<string, Mech> Mechs { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, AbilityProfile> Abilities { get; } = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<int, Dictionary<string, Rating>> _cache = new();
    readonly Env _env;

    public static readonly string[] RankLabels = { "★1", "★2", "★3", "★4", "★5", "★6", "Max" };

    public MechDb(Env env) { _env = env; }

    public static readonly Dictionary<string, Dictionary<char, double>> AbilityModel = new(StringComparer.OrdinalIgnoreCase)
    {
        ["personal shield"] = new() { ['s'] = 6 }, ["shield"] = new() { ['s'] = 4 }, ["exterior shield"] = new() { ['s'] = 5, ['t'] = 4 },
        ["external shield"] = new() { ['s'] = 5, ['t'] = 4 }, ["damage reduction"] = new() { ['s'] = 5 }, ["stealth"] = new() { ['s'] = 5, ['m'] = 2 },
        ["heal"] = new() { ['s'] = 4, ['t'] = 3 }, ["healing"] = new() { ['s'] = 4 }, ["repair"] = new() { ['s'] = 3 },
        ["spawn drop"] = new() { ['s'] = 4, ['m'] = 3 }, ["invulnerable"] = new() { ['s'] = 8 }, ["damage"] = new() { ['o'] = 4 },
        ["damage boost"] = new() { ['o'] = 6 }, ["weapon system"] = new() { ['o'] = 5 }, ["emp"] = new() { ['c'] = 6 },
        ["daze"] = new() { ['c'] = 4 }, ["stasis"] = new() { ['c'] = 5 }, ["dash"] = new() { ['m'] = 6, ['o'] = 1 },
        ["jump"] = new() { ['m'] = 6 }, ["speed boost"] = new() { ['m'] = 4 },
    };
    public static readonly Dictionary<char, double> AxisW = new() { ['s'] = 0.35, ['o'] = 0.30, ['c'] = 0.20, ['m'] = 0.15, ['t'] = 0.10 };
    static readonly char[] AxisOrder = { 's', 'o', 'c', 'm', 't' };

        public void Load(string calcDir, string? wikiCache, string? customFile)
    {
        Mechs.Clear(); Abilities.Clear();
        var f = Path.Combine(calcDir, "mech-stats.json");
        if (File.Exists(f))
            try { if (JsonNode.Parse(Json.ReadText(f))?["mechs"] is JsonObject ms) foreach (var (k, v) in ms) if (v is JsonObject o) Mechs[k] = Mech.From(o); } catch { }
        if (wikiCache is not null && File.Exists(wikiCache))
            try
            {
                if (JsonNode.Parse(Json.ReadText(wikiCache))?["mechs"] is JsonObject ms)
                    foreach (var (k, v) in ms)
                    {
                        if (v is not JsonObject o) continue;
                        if (!Mechs.TryGetValue(k, out var b)) Mechs[k] = Mech.From(o);
                        else b.Apply(o, true);
                    }
            }
            catch { }

        var fx = Path.Combine(calcDir, "mech-fixes.json");
        if (File.Exists(fx))
            try
            {
                if (JsonNode.Parse(Json.ReadText(fx))?["mechs"] is JsonObject ms)
                    foreach (var (k, v) in ms) if (v is JsonObject o && Mechs.TryGetValue(k, out var b)) b.Apply(o, false);
            }
            catch { }

        if (customFile is not null && File.Exists(customFile))
            try
            {
                if (JsonNode.Parse(Json.ReadText(customFile)) is JsonObject all)
                    foreach (var (k, v) in all)
                    {
                        if (v is not JsonObject o) continue;
                        Mechs.TryGetValue(k, out var b);
                        var m = new Mech
                        {
                            Role = o["role"]?.ToString(), Rarity = o["rarity"]?.ToString(), Class = o["class"]?.ToString(),
                            Ability = o["ability"]?.ToString() is { Length: > 0 } ab ? ab : b?.Ability ?? "",
                            Cooldown = b?.Cooldown ?? "", Viability = b?.Viability ?? "", GearHub = b?.GearHub, Custom = true,
                            AbilityTags = b is null ? new() : new(b.AbilityTags), AbilityDuration = b?.AbilityDuration ?? "",
                            AbilityText = b?.AbilityText ?? "",
                        };
                        m.Apply(new JsonObject { ["energy"] = o["energy"]?.DeepClone(), ["hp"] = o["hp"]?.DeepClone(), ["speed"] = o["speed"]?.DeepClone() }, false);
                        Mechs[k] = m;
                    }
            }
            catch { }

        foreach (var m in Mechs.Values)
        {
            m.Role = CleanField(m.Role); m.Rarity = CleanField(m.Rarity); m.Class = CleanField(m.Class); m.Ability = CleanField(m.Ability);
        }
        var ar = Path.Combine(calcDir, "ability-ratings.json");
        if (File.Exists(ar))
            try
            {
                if (JsonNode.Parse(Json.ReadText(ar))?["mechs"] is JsonObject ms)
                    foreach (var (k, v) in ms)
                    {
                        if (v is not JsonObject o) continue;
                        var ax = o["ax"] is JsonArray a ? a.Select(x => x is JsonValue jv && jv.TryGetValue<double>(out var d) ? d : 0).ToArray() : new double[5];
                        if (ax.Length < 5) Array.Resize(ref ax, 5);
                        Abilities[k] = new AbilityProfile(o["p"] is JsonValue pv && pv.TryGetValue<double>(out var p) ? p : 0, ax, o["en"]?.ToString(), o["it"]?.ToString());
                    }
            }
            catch { }
        _cache.Clear();
    }

    static string? CleanField(string? v)
    {
        if (v is null || !Regex.IsMatch(v, @"\[\[|\{\{|<")) return v;
        v = Regex.Replace(v, @"\[\[[^\]]*\]\]", "");
        v = Regex.Replace(v, @"\[\[.*$", "");
        v = Regex.Replace(v, @"\{\{.*$", "");
        v = Regex.Replace(v, "<[^>]*>", "");
        return v.Trim();
    }

    public string? Find(string? name)
    {
        if (string.IsNullOrEmpty(name)) return null;
        var n = Norm(name.Trim());
        foreach (var k in Mechs.Keys) if (Norm(k) == n) return k;
        foreach (var k in Mechs.Keys) { var kk = Norm(k); if (kk.Length >= 4 && n.StartsWith(kk, StringComparison.Ordinal)) return k; }
        return null;
    }

    static string Norm(string s) => Regex.Replace(s.ToLowerInvariant(), @"[^a-z\.]", "");

    public static double? Seconds(string? t)
    {
        if (string.IsNullOrEmpty(t)) return null;
        if (Regex.IsMatch(t, "infinite", RegexOptions.IgnoreCase)) return double.PositiveInfinity;
        if (Regex.IsMatch(t, @"^\s*(instant|none)", RegexOptions.IgnoreCase)) return 0.0;
        var m = Regex.Match(t, @"(\d+(?:[\.,]\d+)?)");
        return m.Success ? double.Parse(m.Groups[1].Value.Replace(',', '.'), CultureInfo.InvariantCulture) : null;
    }

        public static double? DurSeconds(string? t)
    {
        if (string.IsNullOrEmpty(t)) return null;
        if (Regex.IsMatch(t, "infinite", RegexOptions.IgnoreCase)) return double.PositiveInfinity;
        if (Regex.IsMatch(t, @"^\s*(instant|none)", RegexOptions.IgnoreCase)) return 0.0;
        var x = Regex.Match(t, @"(\d+(?:\.\d+)?)\s*seconds?\s*\(duration\)", RegexOptions.IgnoreCase);
        if (!x.Success) x = Regex.Match(t, @"(\d+(?:\.\d+)?)\s*(?:s|sec|seconds?)\b(?!\s*back)", RegexOptions.IgnoreCase);
        if (x.Success) return double.Parse(x.Groups[1].Value, CultureInfo.InvariantCulture);
        var y = Regex.Match(t, @"^\s*(\d+(?:\.\d+)?)\s*$");
        return y.Success ? double.Parse(y.Groups[1].Value, CultureInfo.InvariantCulture) : null;
    }

    public static List<string> AbilityTagsOf(Mech m)
    {
        var tags = m.AbilityTags.Where(t => !string.IsNullOrEmpty(t)).ToList();
        var txt = m.AbilityText ?? "";
        if (Regex.IsMatch(txt, "immaterial|cannot take damage|invulnerab|untargetable", RegexOptions.IgnoreCase)) tags.Add("invulnerable");
        if (Regex.IsMatch(txt, @"\bteleport|\bwarp", RegexOptions.IgnoreCase)) tags.Add("spawn drop");
        if (Regex.IsMatch(txt, @"\bfreez|\bstasis", RegexOptions.IgnoreCase)) tags.Add("stasis");
        return tags.Distinct(StringComparer.Ordinal).ToList();
    }

        public AbilityInfo? AbilityRaw(Mech m, string name = "", double? cdBase = null)
    {
        var dur = DurSeconds(m.AbilityDuration); var cd = Seconds(m.Cooldown);
        double? up = null;
        if (dur is { } du && du > 0 && cd is { } c0) up = double.IsInfinity(du) || c0 <= 0 ? 1.0 : du / (du + c0);
        var f = 1.0;
        if (cdBase is { } cb && cb > 0 && cd is { } c1 && c1 > 0) f = Math.Max(0.85, Math.Min(1.0, Math.Pow(cb / c1, 0.25)));
        if (name != "" && Abilities.TryGetValue(name, out var cur))
        {
            var axv = new Dictionary<char, double>();
            for (var i = 0; i < 5; i++) axv[AxisOrder[i]] = cur.Ax[i];
            var note = _env.L.Lang == "it" && !string.IsNullOrEmpty(cur.It) ? cur.It : cur.En;
            return new AbilityInfo { Raw = cur.P * f, P = cur.P, Axes = axv, Uptime = up, Cd = cd, Dur = dur, Tags = AbilityTagsOf(m), Est = false, Note = note };
        }
        var tags = AbilityTagsOf(m);
        if (tags.Count == 0) return null;
        var ax = AxisOrder.ToDictionary(k => k, _ => new List<double>());
        foreach (var tg in tags)
            if (AbilityModel.TryGetValue(tg, out var v)) foreach (var (k, x) in v) ax[k].Add(x);
        var axes = new Dictionary<char, double>();
        foreach (var (k, l0) in ax)
        {
            var l = l0.OrderByDescending(x => x).ToList();
            axes[k] = Math.Min(10.0, l.Count > 0 ? l[0] + 0.4 * (l.Count > 1 ? l[1] : 0) + 0.2 * (l.Count > 2 ? l[2] : 0) : 0);
        }
        var raw = axes.Sum(p => p.Value * AxisW[p.Key]);
        var tempo = up is { } u ? 0.9 + 0.2 * u : 1.0;

        var pp = Math.Max(20, Math.Min(70, 15 + 9 * raw * tempo));
        return new AbilityInfo { Raw = pp * f, P = pp, Axes = axes, Uptime = up, Cd = cd, Dur = dur, Tags = tags, Est = true, Note = _env.T("Stima dalle categorie del wiki: nessun profilo rivisto per questo mech.") };
    }

    public double? RankPctile(string stat, int idx, double v)
    {
        var vals = Mechs.Values.Select(m => m.StatAt(stat, idx)).Where(x => x is not null).Select(x => x!.Value).ToList();
        if (vals.Count < 2) return null;
        return vals.Count(x => x < v) / (double)(vals.Count - 1);
    }

        public double Pctile(string prop, double v)
    {
        var vals = Mechs.Values.Select(m => prop == "hp" ? m.Hp : m.Speed).Where(x => x is { } d && d != 0).Select(x => x!.Value).ToList();
        if (vals.Count == 0) return 0;
        return vals.Count(x => x < v) / (double)vals.Count;
    }

    static readonly Regex VBad = new(@"early game only|no longer viable|not (?:be )?(?:viable|played)|should not be|useless|(?:out|over)[- ]?powered by|becomes? overpowered|bested by|replaced by", RegexOptions.IgnoreCase);
    static readonly Regex VMeh = new(@"(?:not|n't|never)[^.]{0,40}end ?game|struggle", RegexOptions.IgnoreCase);
    static readonly Regex VGood = new(@"end ?game|all (?:levels|stages)", RegexOptions.IgnoreCase);
    static readonly Regex VTop = new(@"dominant|one of the best|very strong|\bmeta\b", RegexOptions.IgnoreCase);

    public static string TierOf(double score) => score >= 78 ? "S" : score >= 64 ? "A" : score >= 50 ? "B" : score >= 36 ? "C" : "D";

    public Dictionary<string, Rating> Ratings(int idx = 6)
    {
        if (_cache.TryGetValue(idx, out var hit)) return hit;
        var abil = new Dictionary<string, AbilityInfo>(StringComparer.OrdinalIgnoreCase);
        foreach (var (k, m) in Mechs)
        {
            var cdr = m.StatAt("Ability Cooldown", idx);
            var mm = m;
            if (cdr is { } c) { mm = m.Clone(); mm.Cooldown = c.ToString(CultureInfo.InvariantCulture) + " s"; }
            var a = AbilityRaw(mm, k, Seconds(m.Cooldown));
            if (a is not null) abil[k] = a;
        }
        var vals = abil.Values.Select(a => a.Raw).ToList();
        var res = new Dictionary<string, Rating>(StringComparer.OrdinalIgnoreCase);
        foreach (var (k, m) in Mechs)
        {
            var hp = m.StatAt("HP", idx); var en = m.StatAt("Energy", idx); var sp = m.StatAt("Speed", idx);
            if (hp is null || en is null || sp is null || !abil.TryGetValue(k, out var a)) continue;
            var abP = (vals.Count(x => x < a.Raw) + 0.5 * (vals.Count(x => x == a.Raw) - 1)) / Math.Max(1, vals.Count - 1);
            var hpP = RankPctile("HP", idx, hp.Value);
            if (hpP is null) continue;
            var spP = Pctile("speed", sp.Value);
            var enF = Math.Min(1.0, en.Value / 32.0);
            var (wh, wa, ws, we) = (m.Role ?? "").ToLowerInvariant() switch
            {
                "tank" => (0.32, 0.48, 0.04, 0.16),
                "scout" => (0.20, 0.50, 0.12, 0.18),
                "support" => (0.24, 0.52, 0.08, 0.16),
                _ => (0.24, 0.50, 0.08, 0.18),
            };

            var abS = Math.Max(0.0, Math.Min(1.0, (a.Raw - 20) / 75.0));
            var score = 100 * (wh * hpP.Value + wa * abS + ws * spP + we * enF);

            var v = m.Viability ?? ""; var adj = 0;
            if (VBad.IsMatch(v)) adj -= 6;
            else if (VMeh.IsMatch(v)) adj -= 4;
            else if (VGood.IsMatch(v)) adj += 6;
            if (VTop.IsMatch(v)) adj += 3;

            var rf = (m.Rarity ?? "").ToLowerInvariant() switch { "common" => 0.72, "uncommon" => 0.8, "rare" => 0.88, "epic" => 0.95, "legendary" => 1.0, _ => 1.0 };
            score = Math.Max(0, Math.Min(100, score * rf + adj));
            res[k] = new Rating
            {
                Score = Math.Round(score), Tier = TierOf(score), AbP = abP, Ab = a, Adj = adj,
                Hp = hp.Value, HpP = hpP.Value, En = en.Value, Sp = sp.Value, SpP = spP, Idx = idx,
            };
        }
        _cache[idx] = res;
        return res;
    }

        public (Rating? R, int Idx) RatingAt(string k, int star, int lvl)
    {
        var idx = star >= 6 && lvl >= 7 ? 6 : lvl >= 4 && star < 6 ? star : star - 1;
        idx = Math.Max(0, Math.Min(6, idx));
        return (Ratings(idx).TryGetValue(k, out var r) ? r : null, idx);
    }

    public sealed record Profile(Mech M, double? HpP, double? SpP, string Summary);

    public Profile? MechProfile(string k)
    {
        if (!Mechs.TryGetValue(k, out var m)) return null;
        double? hpP = m.Hp is { } h && h != 0 ? Pctile("hp", h) : null;
        double? spP = m.Speed is { } s && s != 0 ? Pctile("speed", s) : null;
        var tank = hpP is null ? _env.T("resistenza sconosciuta") : hpP >= 0.75 ? _env.T("molto resistente") : hpP >= 0.5 ? _env.T("resistente") : hpP >= 0.25 ? _env.T("resistenza media") : _env.T("fragile");
        var fast = spP is null ? "" : spP >= 0.75 ? _env.T("molto veloce") : spP >= 0.4 ? _env.T("velocità media") : _env.T("lento");
        var en = (m.Energy ?? 0) >= 32 ? _env.T("armi pesanti (32 energia)") : (m.Energy ?? 0) >= 24 ? _env.T("armi medie (24 energia)") : m.Energy is { } e && e != 0 ? _env.T("armi leggere (16 energia)") : "";
        return new Profile(m, hpP, spP, string.Join(" · ", new[] { tank, fast, en }.Where(x => x != "")));
    }

    static string Dots(double v)
    {
        var n = (int)Math.Min(5, Math.Round(v / 2, MidpointRounding.AwayFromZero));
        return new string('●', n) + new string('○', 5 - n);
    }

    public string AbilityLine(Rating r)
    {
        var names = new Dictionary<char, string> { ['s'] = _env.T("Sopravvivenza"), ['o'] = _env.T("Danno"), ['c'] = _env.T("Controllo"), ['m'] = _env.T("Mobilità"), ['t'] = _env.T("Squadra") };
        var parts = AxisOrder.Where(k => r.Ab.Axes.TryGetValue(k, out var x) && x > 0).Select(k => $"{names[k]} {Dots(r.Ab.Axes[k])}").ToList();
        var tempo = r.Ab.Uptime is { } u ? _env.T("attiva il {0} del tempo", $"{Num.ToInt(u * 100)}%")
            : r.Ab.Cd is { } cd && cd != 0 ? _env.T("ricarica {0} s", cd.ToString(CultureInfo.InvariantCulture)) : "";
        parts.Add(tempo);
        return string.Join("  ·  ", parts.Where(p => p != ""));
    }

        public static readonly Dictionary<string, string> WikiIt = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Energy"] = "Energia", ["Speed"] = "Velocità", ["Power"] = "Potenza", ["Ability Cooldown"] = "Ricarica abilità",
        ["Ability Duration"] = "Durata abilità", ["Shield Durability"] = "Resistenza scudo", ["Tank"] = "Tank", ["Scout"] = "Scout",
        ["Attacker"] = "Attaccante", ["Support"] = "Supporto", ["Legendary"] = "Leggendario", ["Epic"] = "Epico", ["Rare"] = "Raro",
        ["Uncommon"] = "Non comune", ["Common"] = "Comune", ["Heavy"] = "Pesante", ["Medium"] = "Medio", ["Light"] = "Leggero",
    };

    public string WW(string? w)
    {
        w ??= "";
        return _env.L.Lang == "it" && WikiIt.TryGetValue(w, out var it) ? it : _env.T(w);
    }
}
