namespace MechVault.Core;

public sealed class CratePrize
{
    public string Name { get; set; } = "";
    public string P { get; set; } = "";
    public string Price { get; set; } = "";
    public string Cur { get; set; } = "acoins";
    public bool Want { get; set; } = true;
}

public sealed class CrateInput
{
    public string Name { get; set; } = "";
    public bool SpinInCredits { get; set; }
    public string Spin { get; set; } = "";
    public string P { get; set; } = "";
    public string Pity { get; set; } = "7.000";
    public string Budget { get; set; } = "";
    public bool DirectInAcoins { get; set; }
    public string Direct { get; set; } = "";
    public bool CountUpgrades { get; set; } = true;
    public bool KindWeapon { get; set; }
    public string Rarity { get; set; } = "legendary";
    public int Energy { get; set; } = 16;
    public string PS { get; set; } = "4";
    public string PL { get; set; } = "1";
    public string DS { get; set; } = "5";
    public string DL { get; set; } = "1";
    public List<CratePrize> Prizes { get; set; } = new();
}

public enum Verdict { Neutral, Scam, Good, Warn }

public sealed record CrateResult(string Verdict, Verdict Kind, List<string> Lines)
{
    public string StatsText => string.Join("\n", Lines.Select(l => "• " + l));
}

public sealed record CurvePoint(int N, double Ev, double Net);

public sealed class CrateAnalyzer
{
    readonly Env _env;
    readonly Stats _stats;
    readonly CostTable _costs;
    readonly MechDb _mechs;

    public CrateAnalyzer(Env env, Stats stats, CostTable costs, MechDb mechs) { _env = env; _stats = stats; _costs = costs; _mechs = mechs; }

    string T(string k, params object?[] a) => _env.T(k, a);

    public static int SpinsFor(double p, double q, int pity)
    {
        if (p >= 1) return 1;
        var k = Num.ToInt(Math.Ceiling(Math.Log(1 - q) / Math.Log(1 - p)));
        if (pity > 0) k = Math.Min(k, pity);
        return Math.Max(1, k);
    }

        public static (CurvePoint Best, List<CurvePoint> Rows) Curve(double p0, double v0, int pity, IList<(string Name, double P, double Days)> others, double spinDays, int nMax)
    {
        var best = new CurvePoint(0, 0, 0);
        var rows = new List<CurvePoint>();
        for (var n = 1; n <= nMax; n++)
        {
            var P0 = pity > 0 && n >= pity ? 1.0 : 1 - Math.Pow(1 - p0, n);
            var ev = v0 * P0;
            foreach (var o in others) ev += o.Days * (1 - Math.Pow(1 - o.P, n));
            var net = ev - n * spinDays;
            if (net > best.Net) best = new CurvePoint(n, ev, net);
            rows.Add(new CurvePoint(n, ev, net));
        }
        return (best, rows);
    }

    static (int S, int L)? StarLvl(string s, string l)
    {
        var a = Num.ParseIntIn(s, 1, 6); var b = Num.ParseIntIn(l, 1, 7);
        return a is null || b is null ? null : (a.Value, b.Value);
    }

    sealed record Upg(string? Err, (double C, double B, double A, int Miss) Box = default, (double C, double B, double A, int Miss) Dir = default,
        int Miss = 0, int BoxS = 0, int DirS = 0, string BoxLbl = "", string DirLbl = "");

    Upg Upgrades(CrateInput i)
    {
        var rar = CostTable.Rarities.FirstOrDefault(r => r.K == i.Rarity) ?? CostTable.Rarities[4];
        var en = CostTable.Energies.Contains(i.Energy) ? i.Energy : 16;
        var grp = CostTable.Group(i.KindWeapon ? "weapon" : "mech", rar.K, en);
        var p = StarLvl(i.PS, i.PL); var d = StarLvl(i.DS, i.DL);
        if (p is null || d is null) return new Upg(T("Potenziamenti: stelle da 1 a 6, livelli da 1 a 7."));

        var t = p.Value.S * 10 + p.Value.L >= d.Value.S * 10 + d.Value.L ? p.Value : d.Value;
        var box = _costs.UpgSum(_env, grp, p.Value, t); var dir = _costs.UpgSum(_env, grp, d.Value, t);
        return new Upg(null, box, dir, box.Miss + dir.Miss, p.Value.S, d.Value.S,
            $"★{p.Value.S} {T("liv. {0}", p.Value.L)}", $"★{d.Value.S} {T("liv. {0}", d.Value.L)}");
    }

    static readonly Dictionary<string, string> RarityKey = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Common"] = "common", ["Uncommon"] = "uncommon", ["Rare"] = "rare", ["Epic"] = "epic", ["Legendary"] = "legendary",
    };

    static string Title(string k) => k.Length == 0 ? k : char.ToUpperInvariant(k[0]) + k[1..];

    public CrateResult Analyze(CrateInput i)
    {
        var cur = i.SpinInCredits ? "credits" : "acoins";
        var cn = _env.CurName(cur);
        var spin = Num.ParseAmount(i.Spin);
        var direct = Num.ParseAmount(i.Direct);
        var p = Num.ParsePct(i.P);

        var pityAmt = Num.ParseAmount(i.Pity) ?? 0;
        var pity = 0;
        var budget = Num.ParseAmount(i.Budget);
        var rc = _stats.GetRate("credits").V; var rx = _stats.GetRate(cur).V;
        var lines = new List<string>();
        var verdict = ""; var kind = Verdict.Neutral;
        if (spin is null || spin <= 0) return new CrateResult(T("Scrivi il costo di uno spin."), Verdict.Neutral, new());
        var sp = spin.Value;
        if (pityAmt > 0) pity = (int)Math.Ceiling(pityAmt / sp);

        double? dDays = null, beSpins = null, beCost = null, budgetDays = null;
        var ra = _stats.GetRate("acoins").V;
        Upg? upg = null;
        if (i.CountUpgrades && direct > 0) upg = Upgrades(i);
        if (upg?.Err is not null) { lines.Add(upg.Err); upg = null; }

        var dCur = i.DirectInAcoins ? "acoins" : "credits";
        var rd = dCur == "credits" ? rc : ra;
        if (direct > 0 && rd > 0) dDays = direct / rd;
        if (upg is not null && dDays is not null && ra > 0)
        {
            var dirTot = dDays.Value + upg.Dir.C / rc + upg.Dir.A / ra;
            var boxUpg = upg.Box.C / rc + upg.Box.A / ra;
            lines.Add(T("Via diretta: {0} {6}, poi da {1} servono {2} crediti, {3} A-coin e {4} blueprint = ~{5} in tutto.",
                _env.Fmt(direct!.Value), upg.DirLbl, _env.Fmt(upg.Dir.C), _env.Fmt(upg.Dir.A), _env.Fmt(upg.Dir.B), _env.EtaFine(dirTot), _env.CurName(dCur)));
            lines.Add(T("Con la cassa: da {0} servono ancora {1} crediti, {2} A-coin e {3} blueprint (~{4}).",
                upg.BoxLbl, _env.Fmt(upg.Box.C), _env.Fmt(upg.Box.A), _env.Fmt(upg.Box.B), _env.EtaFine(boxUpg)));
            if (upg.BoxS < upg.DirS)
                lines.Add(T("Il premio arriva a ★{0}, dal Gear Hub a ★{1}: finché non paghi le stelle mancanti non hai i bonus di rango (per esempio la Voidghost sblocca la doppia abilità a rango 5).", upg.BoxS, upg.DirS));
            if (upg.Box.B != upg.Dir.B) lines.Add(T("Blueprint: con la cassa ne servono {0} in più (non convertibili in giorni).", _env.Fmt(upg.Box.B - upg.Dir.B)));
            if (upg.Miss > 0) lines.Add(T("Mancano {0} costi di potenziamento nella tabella: il confronto è approssimato.", upg.Miss));
            budgetDays = dirTot - boxUpg;
            if (rx > 0) beCost = Math.Max(0.0, budgetDays.Value * rx);
            if (budgetDays <= 0) lines.Add(T("Il premio della cassa arriva così basso che i soli potenziamenti costano più della via diretta."));
        }
        else
        {
            if (direct > 0)
            {
                if (cur == dCur) beCost = direct;
                else if (dDays is not null && rx > 0) beCost = dDays * rx;
            }
            if (dDays is not null) lines.Add(T("Via diretta: {0} {2} = ~{1} di grind.", _env.Fmt(direct!.Value), _env.EtaFine(dDays.Value), _env.CurName(dCur)));
        }
        if (beCost is not null) beSpins = Math.Floor(beCost.Value / sp);

        if (p is { } pp)
        {
            var E = pity > 0 ? (1 - Math.Pow(1 - pp, pity)) / pp : 1 / pp;
            var expCost = E * sp;
            var expTxt = rx > 0 ? T(" (~{0} di grind)", _env.EtaFine(expCost / rx)) : "";
            lines.Add(T("In media servono {0} spin = {1} {2}{3}.", Math.Round(E, 1).ToString("0.#", _env.C), _env.Fmt(expCost), cn, expTxt));
            var s50 = SpinsFor(pp, 0.5, pity); var s90 = SpinsFor(pp, 0.9, pity);
            lines.Add(T("Metà dei giocatori lo prende entro {0} spin ({1} {3}), 9 su 10 entro {2} ({4} {3}).", s50, _env.Fmt(s50 * sp), s90, cn, _env.Fmt(s90 * sp)));
            if (pity > 0) lines.Add(T("Caso peggiore, con il garantito: {0} spin = {1} {2}.", pity, _env.Fmt(pity * sp), cn));
            else lines.Add(T("Nessun garantito: 1 giocatore su 10 spende più di {0} {1} e non c'è un tetto.", _env.Fmt(s90 * sp), cn));
            if (budget > 0)
            {
                var n = Math.Floor(budget.Value / sp);
                var pr = pity > 0 && n >= pity ? 1.0 : 1 - Math.Pow(1 - pp, n);
                lines.Add(T("Con {0} {1} ({2} spin) hai il {3} di probabilità di prenderlo.", _env.Fmt(budget.Value), cn, n, _env.Pct(pr)));
            }
            if (beCost is { } bc)
            {
                var ratio = expCost / bc;
                if (ratio > 1.15) { verdict = T("Truffa: in media costa {0} volte la via diretta.", ratio.ToString("0.#", _env.C)); kind = Verdict.Scam; }
                else if (ratio < 0.85) { verdict = T("In media conviene ({0} della via diretta), ma resta un azzardo.", _env.Pct(ratio)); kind = Verdict.Good; }
                else { verdict = T("Pari con la via diretta: nessun vantaggio, solo rischio."); kind = Verdict.Warn; }
            }
            else verdict = T("Scrivi il costo a crediti per avere il giudizio.");
        }
        else if (pity > 0 && beCost is { } bc)
        {
            var worst = pity * sp;
            var wTxt = rx > 0 ? T(" (~{0} di grind)", _env.EtaFine(worst / rx)) : "";
            lines.Add(T("Garantito: al massimo {0} spin = {1} {2}{3}, qualunque sia la fortuna.", pity, _env.Fmt(worst), cn, wTxt));
            if (worst <= bc) { verdict = T("Conviene: anche nel caso peggiore costa {0} della via diretta.", _env.Pct(worst / bc)); kind = Verdict.Good; }
            else
            {
                var rr = bc > 0 ? (worst / bc).ToString("0.#", _env.C) : "∞";
                verdict = T("Rischio: nel caso peggiore costa {0} volte la via diretta. Scrivi la probabilità per il costo medio.", rr); kind = Verdict.Warn;
            }
        }
        else
        {
            verdict = T("Scrivi la probabilità del premio per il giudizio.");
            if (beSpins is { } bs && bs >= 1)
                lines.Add(T("Conviene solo se lo prendi entro {0} spin: serve almeno il {1} a spin. Se le info della Crate Rush dicono meno, è una truffa.", bs, _env.Pct(1.0 / bs)));
            else if (beSpins is not null) { verdict = T("Truffa: un solo spin costa più della via diretta."); kind = Verdict.Scam; }
        }
        if (upg is not null && budgetDays is not null && budgetDays <= 0)
        {
            verdict = T("Truffa: anche gratis, il premio della cassa ti costa più potenziamenti della via diretta."); kind = Verdict.Scam;
        }

        var others = new List<(string Name, double P, double Days)>(); var skipped = 0;
        foreach (var o in i.Prizes)
        {
            if (!o.Want) continue;
            var r = o.Cur == "credits" ? rc : ra;
            var op = Num.ParsePct(o.P); var price = Num.ParseAmount(o.Price);
            if (op is null || !(price > 0) || r <= 0) { skipped++; continue; }
            others.Add((o.Name.Trim(), op.Value, price!.Value / r));
        }
        if (others.Count > 0 && rx > 0)
        {
            var v0 = beCost is not null && p is not null ? beCost.Value / rx : 0.0;
            var p0 = p ?? 0.0;
            var ptot = p0 + others.Sum(o => o.P);
            var nMax = pity > 0 ? pity : (int)Math.Min(400, Math.Max(10, Math.Ceiling(Math.Log(0.02) / Math.Log(1 - Math.Min(0.99, ptot)))));
            var (best, rows) = Curve(p0, v0, pity, others, sp / rx, nMax);
            var wantNames = string.Join(", ", others.Select(o => o.Name).Where(n => n != ""));
            lines.Add(T("Premi che vuoi oltre al principale: {0}.", wantNames != "" ? wantNames : others.Count));
            if (skipped > 0) lines.Add(T("{0} premi senza probabilità o prezzo non sono contati.", skipped));
            if (best.N > 0)
            {
                lines.Add(T("Il punto migliore è fermarsi a {0} spin ({1} {2}): valore atteso ~{3} contro ~{4} spesi.",
                    best.N, _env.Fmt(best.N * sp), cn, _env.EtaFine(best.Ev), _env.EtaFine(best.N * sp / rx)));
                var last = rows[^1];
                if (pity > 0) lines.Add(T("Fino al garantito ({0} spin): valore atteso ~{1} contro ~{2} spesi.", pity, _env.EtaFine(last.Ev), _env.EtaFine(pity * sp / rx)));
                verdict = T("Conviene fino a {0} spin con tutti i premi che vuoi: oltre, ogni spin vale meno di quanto costa.", best.N); kind = Verdict.Good;
                beSpins = best.N;
            }
            else
            {
                verdict = T("Truffa: nemmeno contando tutti i premi che vuoi un solo spin ripaga quello che costa."); kind = Verdict.Scam;
                beSpins = 0;
            }
        }

        var mk = _mechs.Find(i.Name);
        if (mk is not null)
        {
            var pr = _mechs.MechProfile(mk)!;
            if (_mechs.Ratings(6).TryGetValue(mk, out var rt))
            {
                lines.Add(T("{0}: fascia {1} ({2}/100) al massimo · {3} · abilità migliore del {4} dei mech.", mk, rt.Tier, rt.Score, pr.Summary, $"{Num.ToInt(rt.AbP * 100)}%"));
                if (StarLvl(i.PS, i.PL) is { } ps2)
                {
                    var (r2, idx) = _mechs.RatingAt(mk, ps2.S, ps2.L);
                    if (r2 is not null)
                        lines.Add(T("Al rango con cui arriva dalla cassa ({0}): fascia {1} ({2}/100), {3} HP, più resistente del {4} dei mech allo stesso rango.",
                            MechDb.RankLabels[idx], r2.Tier, r2.Score, _env.Fmt(r2.Hp), $"{Num.ToInt(r2.HpP * 100)}%"));
                }
                if (rt.Tier is "C" or "D") lines.Add(T("Attenzione: {0} è un mech debole (fascia {1}). Anche se il prezzo conviene, valuta se lo useresti davvero.", mk, rt.Tier));
            }
            else lines.Add(T("{0}: {1}. Dettagli in «Scheda mech».", mk, pr.Summary));
        }
        if (beSpins is { } b2 && b2 >= 1)
            lines.Add(T("Budget massimo sensato: {0} {1} ({2} spin). Oltre, la via diretta costa meno.", _env.Fmt(b2 * sp), cn, b2));
        if (cur == "acoins") lines.Add(T("Ricorda: le A-coin servono anche per salire di stella (810 per un'arma epica, 1.875 per un mech epico)."));
        if (cur == "acoins" && rx > 0) lines.Add(T("Calcolato con il tuo ritmo: ~{0} crediti e ~{1} A-coin al giorno.", _env.Fmt(rc), _env.Fmt(rx)));

        var warn = new List<string>();
        var rr2 = CostTable.Rarities.FirstOrDefault(r => r.K == i.Rarity);
        if (i.CountUpgrades && StarLvl(i.DS, i.DL) is { } dd && rr2 is not null && dd.S < rr2.Min)
            warn.Add(T("Il Gear Hub vende questa rarità a partire da ★{0}, non da ★{1}.", rr2.Min, dd.S));
        if (mk is not null && direct > 0)
        {
            var m = _mechs.Mechs[mk];
            if (m.GearHub is { Amount: { } gha and not 0 } gh)
            {
                var dCur2 = i.DirectInAcoins ? "acoins" : "credits";
                if (gh.Currency != dCur2 || Math.Abs(direct.Value - gha) / gha > 0.5)
                    warn.Add(T("Nel Gear Hub {0} costa {1} {2}, tu hai scritto {3} {4}.", mk, _env.Fmt(gha), _env.CurName(gh.Currency), _env.Fmt(direct.Value), _env.CurName(dCur2)));
            }
            if (RarityKey.TryGetValue(m.Rarity ?? "", out var rk) && rr2 is not null && rk != rr2.K)
                warn.Add(T("{0} è {1}, non {2}.", mk, _mechs.WW(m.Rarity), _mechs.WW(Title(rr2.K))));
        }
        if (rx > 0 && sp / rx < 0.02 && (dDays is null || dDays < 0.02)) warn.Add(T("Importi troppo piccoli per un confronto sensato."));
        if (warn.Count > 0)
        {
            verdict = T("Controlla i dati: qualcosa non torna."); kind = Verdict.Warn;
            lines = warn.Concat(lines).ToList();
        }
        return new CrateResult(verdict, kind, lines);
    }
}

public static class CrateHelpers
{
        public static bool FillPrizePrice(CratePrize p, MechDb mechs, Env env)
    {
        if (p.Price.Trim() != "") return false;
        var k = mechs.Find(p.Name);
        if (k is null) return false;
        var gh = mechs.Mechs[k].GearHub;
        if (gh?.Amount is not { } a || a == 0) return false;
        p.Cur = gh.Currency == "credits" ? "credits" : "acoins";
        p.Price = env.Fmt(a);
        return true;
    }
}

public static class CalcHelpers
{
        public static string AddGoals(Env env, AccountData d, string name, CalcInput inp, CalcTotals t)
    {
        if (inp.Err is not null) return inp.Err;
        if (t.N == 0) return env.T("Scegli un arrivo più alto della partenza.");
        if (t.Miss > 0) return env.T("Prima compila tutti i costi ({0} mancanti).", t.Miss);
        name = name.Trim();
        if (name == "") name = inp.Kind == "mech" ? "Mech" : env.T("Arma");
        var label = $"{name} ★{inp.Ts} " + env.T("liv. {0}", inp.Tl);
        var add = new List<Goal>();
        if (t.C > 0) add.Add(Goals.New(label, "credits", t.C));
        if (t.A > 0) add.Add(Goals.New(label + " · A-coin", "acoins", t.A));
        if (add.Count == 0) return env.T("Costo totale zero: niente da aggiungere.");
        d.Goals.AddRange(add);
        return env.T("Aggiunto agli obiettivi: {0}", label);
    }
}
