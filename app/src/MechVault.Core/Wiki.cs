using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace MechVault.Core;

public static class Wiki
{
    const string Api = "https://mech-arena-robot-showdown.fandom.com/api.php";

    public static string Clean(string v)
    {
        v = Regex.Replace(v, @"\[\[(?:File|Image):[^\]]*\]\]", "");
        v = Regex.Replace(v, @"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", "$1");
        v = Regex.Replace(v, "<[^>]+>", " ");
        v = v.Replace("'''", "").Replace("''", "");
        return Regex.Replace(v, @"\s+", " ").Trim();
    }

        public static Dictionary<string, string>? Template(string t)
    {
        var i = t.IndexOf("{{Mech Information", StringComparison.Ordinal);
        if (i < 0) i = t.IndexOf("{{Mech_Information", StringComparison.Ordinal);
        if (i < 0) return null;
        int dep = 0, j = i;
        while (j < t.Length)
        {
            if (j + 1 < t.Length && t[j] == '{' && t[j + 1] == '{') { dep++; j += 2; continue; }
            if (j + 1 < t.Length && t[j] == '}' && t[j + 1] == '}') { dep--; j += 2; if (dep == 0) break; continue; }
            j++;
        }
        var body = t.Substring(i + 2, Math.Max(0, j - i - 4));
        body = Regex.Replace(body, @"\{\{\s*AcoinsIcon\s*\}\}", " ACOINS", RegexOptions.IgnoreCase);
        body = Regex.Replace(body, @"\{\{\s*CreditsIcon\s*\}\}", " CREDITS", RegexOptions.IgnoreCase);
        string b0;
        do { b0 = body; body = Regex.Replace(body, @"\{\{[^{}]*\}\}", ""); } while (body != b0);
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var part in body.Split('|').Skip(1))
        {
            var q = part.IndexOf('=');
            if (q < 1) continue;
            d[part[..q].Trim().TrimEnd(':').ToLowerInvariant()] = Clean(part[(q + 1)..]);
        }
        return d;
    }

        public static JsonObject? RankTable(string t)
    {
        foreach (Match tm in Regex.Matches(t, @"\{\|(.*?)\n\|\}", RegexOptions.Singleline))
        {
            var rows = new JsonObject();
            foreach (var r in Regex.Split(tm.Groups[1].Value, @"\n\|-[^\n]*"))
            {
                var cells = new List<string>();
                foreach (var line0 in r.Split('\n'))
                {
                    var line = line0.Trim();
                    if (line.StartsWith("|+") || line.StartsWith("{|")) continue;
                    if (line.StartsWith('!') || line.StartsWith('|'))
                    {
                        foreach (var c0 in Regex.Split(line[1..], @"\|\||!!"))
                        {
                            var c = Regex.Replace(c0, "^\\s*[^|]*?style=\"[^\"]*\"\\s*\\|", "");
                            cells.Add(Clean(c));
                        }
                    }
                    else if (cells.Count > 0 && line != "") cells[^1] += " " + Clean(line);
                }
                if (cells.Count < 8) continue;
                var lab = cells[0].Trim();
                var vals = new JsonArray();
                var n = 0;
                for (var i = 1; i <= 7; i++)
                {
                    var mm = Regex.Match(Regex.Replace(cells[i], @"[,\s]", ""), @"^-?\d+(?:\.\d+)?");
                    if (mm.Success) { vals.Add(double.Parse(mm.Value, System.Globalization.CultureInfo.InvariantCulture)); n++; }
                    else vals.Add(null);
                }
                if (lab != "" && !Regex.IsMatch(lab, "^(?i)rank") && n >= 6) rows[lab] = vals;
            }
            if (rows.Any(p => Regex.IsMatch(p.Key, "^(?i)hp"))) return rows;
        }
        return null;
    }

    static readonly string[] Cats = { "Stealth", "Healing", "Heal", "Repair", "Speed boost", "Damage boost", "Personal shield", "Exterior shield", "Emp", "Daze", "Stasis", "Dash" };

    public static JsonObject? ParseMech(string t, List<string> cats)
    {
        var d = Template(t);
        if (d is null) return null;
        string G(string k) => d.TryGetValue(k, out var v) ? v : "";
        var hp = Regex.Replace(G("maxhp").Split('(')[0], @"[^\d]", "");
        var sp = Regex.Match(G("speed"), @"(\d+(?:\.\d+)?)");
        var en = Regex.Match(G("energy_capacity"), @"(\d+)");
        var ec = G("energy_capacity");
        var cls = ec.Contains("Heavy", StringComparison.OrdinalIgnoreCase) || (en.Success && int.Parse(en.Value) >= 32) ? "Heavy"
            : ec.Contains("Medium", StringComparison.OrdinalIgnoreCase) || (en.Success && int.Parse(en.Value) >= 24) ? "Medium"
            : en.Success || ec.Contains("Light", StringComparison.OrdinalIgnoreCase) ? "Light" : "";
        var role = G("role").Split(' ')[0];
        if (role == "") foreach (var c in new[] { "Tank", "Scout", "Attacker", "Support" }) if (cats.Contains(c, StringComparer.OrdinalIgnoreCase)) role = c;
        var rar = Regex.Split(G("rarity"), "[ /]")[^1];
        if (rar == "") foreach (var c in new[] { "Legendary", "Epic", "Rare", "Uncommon", "Common" }) if (cats.Contains(c, StringComparer.OrdinalIgnoreCase)) rar = c;
        int? energy = en.Success ? int.Parse(en.Value) : cls switch { "Heavy" => 32, "Medium" => 24, "Light" => 16, _ => null };
        JsonObject? gh = null;
        var pm = Regex.Matches(G("price"), @"([\d][\d,\.]*)\s*(ACOINS|CREDITS)");
        if (pm.Count > 0)
        {
            var last = pm[^1];
            gh = new JsonObject { ["amount"] = int.Parse(Regex.Replace(last.Groups[1].Value, @"[^\d]", "")), ["currency"] = last.Groups[2].Value == "ACOINS" ? "acoins" : "credits" };
        }
        else if (Regex.IsMatch(G("price"), @"^\s*\$")) gh = new JsonObject { ["amount"] = null, ["currency"] = "money" };
        var via = "";
        var vm = Regex.Match(t, @"==\s*Viability\s*==\s*(.+?)(?:\n==|\[\[Category|$)", RegexOptions.Singleline);
        if (vm.Success) { via = Clean(vm.Groups[1].Value); if (via.Length > 280) via = via[..280]; }
        var am = Regex.Match(t, @"==\s*Abilit(?:y|ies)\s*==(.+?)(?:\n==[^=]|$)", RegexOptions.Singleline);
        if (!am.Success) am = Regex.Match(t, @"==\s*Mech Information\s*==(.+?)(?:\n==[^=]|$)", RegexOptions.Singleline);
        var atext = "";
        if (am.Success) { atext = Clean(Regex.Replace(am.Groups[1].Value, @"\{\{[^}]*\}\}", "")); if (atext.Length > 600) atext = atext[..600]; }
        var tags = cats.Where(c => Regex.IsMatch(c, "^abilit?r?y:", RegexOptions.IgnoreCase)).Select(c => Regex.Replace(c, @"^abilit?r?y:\s*", "", RegexOptions.IgnoreCase).Trim().ToLowerInvariant()).ToList();
        tags.AddRange(cats.Where(c => Cats.Contains(c, StringComparer.OrdinalIgnoreCase)).Select(c => c.ToLowerInvariant()));
        var traits = new JsonArray();
        foreach (var k in new[] { "trait1", "trait2" }) if (G(k) != "") traits.Add(G(k));
        return new JsonObject
        {
            ["role"] = role, ["rarity"] = rar, ["class"] = cls, ["energy"] = energy,
            ["hp"] = hp != "" && double.Parse(hp) > 10000 ? double.Parse(hp) : null,
            ["speed"] = sp.Success ? double.Parse(sp.Value, System.Globalization.CultureInfo.InvariantCulture) : null,
            ["ability"] = Regex.Replace(G("ability"), @"\s*\d+px.*$", "").Trim(), ["cooldown"] = G("ability_cooldown"),
            ["abilityDuration"] = G("ability_duration"), ["abilityDamage"] = G("ability_damage"),
            ["traits"] = traits, ["viability"] = via, ["gearHub"] = gh,
            ["abilityTags"] = new JsonArray(tags.Distinct().Select(x => (JsonNode?)x).ToArray()), ["abilityText"] = atext,
        };
    }

        public static async Task<int> Update(string outFile, CancellationToken ct = default)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("MechVault/2.0 (fan tool)");
        var list = JsonNode.Parse(await http.GetStringAsync($"{Api}?action=query&list=categorymembers&cmtitle=Category:Mech&cmlimit=500&format=json", ct));
        var res = new JsonObject();
        foreach (var cm in list?["query"]?["categorymembers"]?.AsArray() ?? new JsonArray())
        {
            var title = cm?["title"]?.ToString() ?? "";
            if ((int?)cm?["ns"] != 0 || title is "Crates" or "Test" or "") continue;
            JsonNode? r;
            try { r = JsonNode.Parse(await http.GetStringAsync($"{Api}?action=parse&format=json&prop=wikitext|categories&redirects=1&page={Uri.EscapeDataString(title)}", ct)); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch { continue; }
            var t = r?["parse"]?["wikitext"]?["*"]?.ToString() ?? "";
            var cats = (r?["parse"]?["categories"]?.AsArray() ?? new JsonArray()).Select(c => (c?["*"]?.ToString() ?? "").Replace('_', ' ')).ToList();
            var m = ParseMech(t, cats);
            if (m is null) continue;
            var rk = RankTable(t);
            if (rk is null)
            {
                var g = Regex.Replace(Regex.Replace(Regex.Replace(title, @"^M\.D\.$", "M.D"), "^Dreadnought$", "Dreadnaught"), "^Volti$", "Voti");
                for (var attempt = 0; attempt < 3 && rk is null; attempt++)
                {
                    try
                    {
                        var r2 = JsonNode.Parse(await http.GetStringAsync($"https://mecharena.wiki.gg/api.php?action=parse&format=json&prop=wikitext&redirects=1&page={Uri.EscapeDataString("Mech:" + g)}", ct));
                        rk = RankTable(r2?["parse"]?["wikitext"]?["*"]?.ToString() ?? "");
                        if (rk is not null) m["ranksSource"] = "Mech Arena Wiki (wiki.gg, CC BY-SA 4.0)";
                        break;
                    }
                    catch (HttpRequestException ex) when ((int?)ex.StatusCode == 429) { await Task.Delay(8000, ct); }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                    catch { break; }
                }
                await Task.Delay(2500, ct);
            }
            else m["ranksSource"] = "Mech Arena Wiki (Fandom)";
            if (rk is not null) m["ranks"] = rk;
            res[title] = m;
            await Task.Delay(120, ct);
        }
        if (res.Count < 30) throw new InvalidDataException($"Wiki: solo {res.Count} mech letti");
        var o = new JsonObject
        {
            ["format"] = "mechvault-mechs", ["version"] = 1, ["source"] = "Mech Arena: Robot Showdown Wiki (Fandom)", ["license"] = "CC BY-SA 3.0",
            ["retrieved"] = Dates.Iso(DateTime.Now), ["mechs"] = res,
        };
        Json.WriteAtomic(outFile, o.ToJsonString(Json.Options));
        return res.Count;
    }
}
