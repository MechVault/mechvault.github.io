namespace MechVault.Core;

public sealed record AutoRate(double V, int Days, double Freq, double PerDay, bool Partial = false, int Bonus = 0, bool Negative = false)
{
    public static readonly AutoRate None = new(0, 0, 0, 0);
}

public sealed record Rate(double V, string Src);

public sealed record GoalStat(Goal Goal, int Rank, double Pct, double Remaining, double Days, bool IsFirst, string? After, bool CanBuy, bool Authorized);

public sealed record MissionInfo(double Budget, double Used, double Left);

public sealed class Stats
{
    readonly Env _env;
    public AccountData D { get; }

    public Stats(Env env, AccountData d) { _env = env; D = d; }

    DateTime Now => _env.Now();

        public AutoRate AutoRateInfo(string cur)
    {
        var ev = D.Events.Where(e => e.Cur == cur).ToList();
        if (ev.Count == 0) return AutoRate.None;
        var today = Now.Date;
        var winStart = today.AddDays(-27);
        var fg = ev.Where(e => e.Kind == "gain").ToList();
        if (fg.Count == 0) return AutoRate.None;
        var first = fg[0].Time.Date;
        var start = first > winStart ? first : winStart;

        var gains = ev.Where(e => e.Kind == "gain" && e.Time.Date >= start).Select(e => e.Delta).OrderBy(x => x).ToList();
        var cap = double.MaxValue;
        if (gains.Count >= 4) cap = 10 * Math.Max(1.0, gains[(int)Math.Floor((gains.Count - 1) / 2.0)]);
        var net = new Dictionary<DateTime, double>();
        var mis = new Dictionary<DateTime, double>();
        var bonus = 0;
        var mBudget = D.MissionBudget(cur);
        var hard = cur == "credits" ? 5000000 : 100000;
        foreach (var e in ev)
        {
            var t = e.Time.Date;
            if (t < start) continue;
            if (e.Kind == "gain" && (e.Delta > cap || e.Delta > hard)) { bonus++; continue; }
            if (!net.ContainsKey(t) && (e.Kind == "gain" || e.Kind == "mission")) { net[t] = 0; mis[t] = 0; }
            if (e.Kind == "gain") net[t] += e.Delta;
            else if (e.Kind == "mission")
            {
                var take = Math.Min(-e.Delta, Math.Max(0.0, mBudget - mis[t]));
                mis[t] += take; net[t] -= take;
            }
        }
        var play = net.Keys.Where(k => net[k] != 0).OrderBy(k => k).ToList();
        if (play.Count == 0) return AutoRate.None;

        var full = play.Where(d => d < today).ToList();
        var use = play;
        if (full.Count >= 1 && net.ContainsKey(today))
        {
            var avg = full.Average(d => net[d]);
            if (net[today] < avg) use = full;
        }
        double sw = 0, sv = 0;
        foreach (var d in use)
        {
            var w = Math.Pow(0.5, (today - d).TotalDays / 7.0);
            sw += w; sv += w * net[d];
        }
        var perDay = sv / sw;
        if (perDay <= 0) return new AutoRate(0, use.Count, 0, perDay, false, bonus, true);
        var lastDay = use.Contains(today) ? today : today.AddDays(-1);
        var span = Math.Max(1.0, (lastDay - start).TotalDays + 1);

        var freq = span >= 7 ? Math.Min(1.0, use.Count / span) : 1.0;
        return new AutoRate(perDay * freq, use.Count, freq, perDay, use.Count == 1 && use[0] == today, bonus);
    }

    public Rate GetRate(string cur)
    {
        var manual = D.ManualRate(cur);
        if (manual > (cur == "credits" ? 2000000 : 50000)) manual = 0;
        if (manual > 0) return new Rate(manual, _env.T("impostato da te"));
        var a = AutoRateInfo(cur);
        if (a.V > 0)
        {
            var src = a.Partial ? _env.T("automatico · prima sessione")
                : a.Days == 1 ? _env.T("automatico · 1 giorno giocato")
                : _env.T("automatico · {0} giorni giocati", a.Days);
            return new Rate(a.V, src);
        }
        if (cur == "acoins") return new Rate(150.0, _env.T("stima iniziale"));
        return new Rate(0, "");
    }

    public string FormatAutoRate(string cur)
    {
        var a = AutoRateInfo(cur);
        var name = _env.CurName(cur);
        if (a.Negative) return _env.T("{0}: ultimamente spendi più di quanto guadagni, il ritmo è zero.", name);
        if (a.V <= 0) return _env.T("{0}: ancora nessun guadagno registrato.", name);
        var dd = a.Days == 1 ? _env.T("1 giorno di dati") : _env.T("{0} giorni di dati", a.Days);
        var txt = _env.T("{0}: ~{1} al giorno · {2} per giorno giocato · giochi {3} giorni su 7 · {4}",
            name, _env.Fmt(a.V), _env.Fmt(a.PerDay), Math.Round(a.Freq * 7, 1).ToString("0.#", _env.C), dd);
        if (a.Bonus > 0) txt += _env.T(" · esclusi {0} guadagni una tantum", a.Bonus);
        if (a.Partial) txt += _env.T(" (solo oggi: si assesta nei prossimi giorni)");
        return txt;
    }

    public (double Gain, double Spend) Today(string cur)
    {
        var today = Now.Date;
        double g = 0, s = 0;
        foreach (var e in D.Events)
        {
            if (e.Cur != cur || e.Time < today) continue;
            if (e.Kind == "gain") g += e.Delta;
            else if (e.Kind is "spend" or "mission" or "purchase") s += e.Delta;
        }
        return (g, s);
    }

    public MissionInfo Mission(string cur)
    {
        var budget = D.MissionBudget(cur);
        var today = Now.Date;
        double used = 0;
        foreach (var e in D.Events)
            if (e.Cur == cur && e.Kind == "mission" && e.Time >= today) used += -e.Delta;
        return new MissionInfo(budget, used, Math.Max(0.0, budget - used));
    }

        public int Streak()
    {
        var since = Dates.ParseOr(D.CleanSince, Now);
        return (int)Math.Max(0.0, Math.Floor((Now - since).TotalDays));
    }

    public List<GoalStat> GoalStats()
    {
        var res = new List<GoalStat>();
        var cum = new Dictionary<string, double> { ["credits"] = 0, ["acoins"] = 0 };
        var prev = new Dictionary<string, string?> { ["credits"] = null, ["acoins"] = null };
        var rank = 0;
        foreach (var g in D.Goals)
        {
            if (g.Done) continue;
            rank++;
            var cur = g.Currency == "acoins" ? "acoins" : "credits";
            var bal = D.Balance(cur);
            var cost = g.Cost;
            var before = cum[cur];
            cum[cur] += cost;
            var have = Math.Max(0.0, Math.Min(cost, bal - before));
            var pct = cost > 0 ? have / cost : 1.0;
            var remaining = Math.Max(0.0, cum[cur] - bal);
            var rate = GetRate(cur);
            var days = remaining <= 0 ? 0 : rate.V > 0 ? remaining / rate.V : -1;
            var isFirst = prev[cur] is null;
            var auth = D.Purchase;
            res.Add(new GoalStat(g, rank, pct, remaining, days, isFirst, prev[cur],
                isFirst && bal >= cost && D.IsInit(cur),
                auth is not null && auth.GoalId == g.Id && Dates.ParseOr(auth.Until, DateTime.MinValue) > Now));
            prev[cur] = g.Name;
        }
        return res;
    }

    public List<string> GoalLines()
    {
        var lines = GoalStats().Select(s => string.Format("{0}.  {1}  —  {2}% · {3}", s.Rank, s.Goal.Name, Math.Floor(s.Pct * 100),
            s.Remaining <= 0 ? _env.T("pronto") : _env.T("mancano {0} {1}", _env.Short(s.Remaining), _env.CurName(s.Goal.Currency)))).ToList();
        if (lines.Count == 0) lines.Add(_env.T("Nessun obiettivo attivo."));
        return lines;
    }

        public double?[] DailySeries(string cur, int days)
    {
        var ev = D.Events.Where(e => e.Cur == cur).ToList();
        var outv = new double?[days];
        var i = 0; double? last = null;
        for (var k = days - 1; k >= 0; k--)
        {
            var end = Now.Date.AddDays(1 - k);
            while (i < ev.Count && ev[i].Time < end) { last = ev[i].Bal; i++; }
            outv[days - 1 - k] = last;
        }
        return outv;
    }
}
