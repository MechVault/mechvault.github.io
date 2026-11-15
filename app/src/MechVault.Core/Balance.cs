namespace MechVault.Core;

public enum ViolationKind { Confess, Mission, Typo }

public sealed record ViolationAnswer(ViolationKind Kind, string Reason);

public interface IBalanceHost
{
        Task<ViolationAnswer> AskViolation(string cur, double excess, double covered, string src, int streak);
    void Notify(string title, string text);
    void Changed();
    void Log(string text);
}

public sealed class BalanceEngine
{
    readonly Env _env;
    readonly IBalanceHost _host;
    public AccountData D { get; private set; }
    public Stats Stats { get; private set; }

    sealed class Pending { public double V; public int N; }
    readonly Dictionary<string, Pending?> _pend = new() { ["credits"] = null, ["acoins"] = null };
    readonly Dictionary<string, double?> _ignore = new() { ["credits"] = null, ["acoins"] = null };

    public bool InDialog { get; private set; }

    public BalanceEngine(Env env, AccountData d, IBalanceHost host)
    {
        _env = env; _host = host; D = d; Stats = new Stats(env, d);
    }

    DateTime Now => _env.Now();

    public void SetAccount(AccountData d)
    {
        D = d; Stats = new Stats(_env, d);
        ResetPending();
    }

    public void ResetPending()
    {
        _pend["credits"] = null; _pend["acoins"] = null;
        _ignore["credits"] = null; _ignore["acoins"] = null;
    }

    public void ResetPendingReads() { _pend["credits"] = null; _pend["acoins"] = null; }

        public static double Cap(string cur) => cur == "credits" ? 500000000 : 5000000;

        public async Task ProcessRead(string cur, double v)
    {
        if (v < 0 || v > Cap(cur)) return;
        if (_ignore[cur] is { } ig)
        {
            if (ig == v) return;
            _ignore[cur] = null;
        }
        if (D.IsInit(cur) && v == D.Balance(cur)) { _pend[cur] = null; return; }
        var p = _pend[cur];
        if (p is not null && p.V == v) p.N++;
        else { p = new Pending { V = v, N = 1 }; _pend[cur] = p; }
        var need = D.IsInit(cur) && v < D.Balance(cur) ? 3 : 2;

        if (D.IsInit(cur) && v - D.Balance(cur) > Math.Max(3 * D.Balance(cur), cur == "credits" ? 100000 : 1000)) need = 6;
        if (p.N >= need) { _pend[cur] = null; await Commit(cur, v, "auto"); }
    }

        public BalanceEvent? FindBogusGain(string cur, double old, double v)
    {
        var evs = D.Events;
        var since = Now.AddHours(-24);
        for (var i = evs.Count - 1; i >= 0 && i >= evs.Count - 60; i--)
        {
            var e = evs[i];
            if (e.Cur != cur) continue;
            if (e.Time < since) break;
            if (e.Kind == "gain" && e.Delta >= 50)
            {
                var truth = old - e.Delta;
                if (Math.Abs(truth - v) <= Math.Max(5.0, 0.03 * e.Delta)) return e;
            }
        }
        return null;
    }

    public void RemoveBogusGain(BalanceEvent e, string cur, double v)
    {
        var after = false; var keep = new List<BalanceEvent>();
        foreach (var x in D.Events)
        {
            if (ReferenceEquals(x, e)) { after = true; continue; }
            if (after && x.Cur == cur) x.Bal -= e.Delta;
            keep.Add(x);
        }
        D.Events = keep;
        D.SetBalance(cur, v);
        _host.Log($"Lettura sbagliata annullata: {cur} +{e.Delta} del {e.T}, saldo {v}");
        _host.Changed();
    }

    public async Task Commit(string cur, double v, string src)
    {
        var old = D.Balance(cur);
        if (!D.IsInit(cur))
        {
            D.SetBalance(cur, v); D.SetInit(cur, true);
            D.AddEvent(Now, cur, 0, v, "init", "", src);
            _host.Changed();
            _host.Notify(_env.T("Saldo letto"), _env.T("{0}: {1} {2}. Da qui parte il conteggio.", D.AccountName, _env.Fmt(v), _env.CurName(cur)));
            return;
        }
        var delta = v - old;
        if (delta == 0) return;
        if (delta > 0)
        {
            D.SetBalance(cur, v);
            D.AddEvent(Now, cur, delta, v, "gain", "", src);
            _host.Changed();
            return;
        }
        var lost = -delta;

        if (FindBogusGain(cur, old, v) is { } bogus) { RemoveBogusGain(bogus, cur, v); return; }

        var auth = D.Purchase;
        if (auth is not null && auth.Currency == cur && Dates.ParseOr(auth.Until, DateTime.MinValue) > Now &&
            lost >= auth.Amount * 0.5 && lost <= auth.Amount * 1.03 + 10)
        {
            var g = D.Goals.FirstOrDefault(x => x.Id == auth.GoalId);
            D.SetBalance(cur, v);
            D.AddEvent(Now, cur, delta, v, "purchase", g?.Name ?? "", src);
            if (g is not null) { g.Done = true; g.DoneAt = Dates.Iso(Now); }
            D.Purchase = null;
            _host.Changed();
            _host.Notify(_env.T("Obiettivo completato!"), _env.T("{0}: te lo sei guadagnato.", g?.Name ?? _env.T("Acquisto")));
            return;
        }

        var mb = Stats.Mission(cur);
        if (lost <= mb.Left)
        {
            D.SetBalance(cur, v);
            D.AddEvent(Now, cur, delta, v, "mission", "budget missioni", src);
            _host.Changed();
            return;
        }
        var covered = mb.Left;
        var excess = lost - covered;

        var streak = Stats.Streak();
        ViolationAnswer res;
        InDialog = true;
        try { res = await _host.AskViolation(cur, excess, covered, src, streak); }
        finally { InDialog = false; }
        if (res.Kind == ViolationKind.Typo)
        {
            if (src == "auto") _ignore[cur] = v;
            return;
        }
        if (covered > 0) D.AddEvent(Now, cur, -covered, old - covered, "mission", "budget missioni", src);
        D.SetBalance(cur, v);
        if (res.Kind == ViolationKind.Mission)
        {
            D.AddEvent(Now, cur, -excess, v, "mission", "segnata come missione", src);
            _host.Changed();
            return;
        }
        D.AddEvent(Now, cur, -excess, v, "spend", res.Reason, src);
        D.Violations.Add(new Violation { T = Dates.Iso(Now), Currency = cur, Amount = excess, Reason = res.Reason, StreakLost = streak, PrevClean = D.CleanSince });
        D.BestStreak = Math.Max(D.BestStreak, streak);
        D.CleanSince = Dates.Iso(Now);
        _host.Changed();
    }

        public bool UndoViolation(string t)
    {
        var viol = D.Violations.FirstOrDefault(v => v.T == t);
        if (viol is null) return false;
        var vt = Dates.ParseOr(viol.T, DateTime.MinValue);
        D.Violations = D.Violations.Where(v => v.T != t).ToList();
        foreach (var e in D.Events)
        {
            if (e.Kind == "spend" && e.Cur == viol.Currency && Math.Abs((e.Time - vt).TotalSeconds) < 120 && Math.Abs(e.Delta + viol.Amount) < 1)
            {
                e.Kind = "mission"; e.Note = "segnata come missione";
            }
        }

        var lastV = D.Violations.OrderBy(v => Dates.ParseOr(v.T, DateTime.MinValue)).LastOrDefault();
        D.CleanSince = lastV is not null ? lastV.T
            : !string.IsNullOrEmpty(viol.PrevClean) ? viol.PrevClean!
            : D.Events.Count > 0 ? D.Events[0].T
            : D.CreatedAt;
        _host.Changed();
        return true;
    }

    public void Authorize(Goal g)
    {
        D.Purchase = new Purchase { GoalId = g.Id, Currency = g.Currency, Amount = g.Cost, Until = Dates.Iso(Now.AddHours(6)) };
        _host.Changed();
    }

    public void CancelPurchase() { D.Purchase = null; _host.Changed(); }
}

public static class Goals
{
    public static string NewId() => Guid.NewGuid().ToString("N")[..8];

    public static Goal New(string name, string cur, double cost) => new() { Id = NewId(), Name = name, Currency = cur, Cost = cost };

    public static bool Move(AccountData d, string id, int dir)
    {
        var i = d.Goals.FindIndex(g => g.Id == id);
        var j = i + dir;
        if (i < 0 || j < 0 || j >= d.Goals.Count) return false;
        (d.Goals[i], d.Goals[j]) = (d.Goals[j], d.Goals[i]);
        return true;
    }

    public static bool Remove(AccountData d, string id)
    {
        if (d.Goals.RemoveAll(g => g.Id == id) == 0) return false;
        if (d.Purchase?.GoalId == id) d.Purchase = null;
        return true;
    }
}
