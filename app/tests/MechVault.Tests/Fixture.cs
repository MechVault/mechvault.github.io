using System.Text;
using System.Text.RegularExpressions;
using MechVault.Core;

namespace MechVault.Tests;

public static class Fixture
{
        public static readonly DateTime Now = new(2026, 11, 15, 12, 20, 0, DateTimeKind.Local);

    public static string Root
    {
        get
        {
            var d = new DirectoryInfo(AppContext.BaseDirectory);
            while (d is not null && !File.Exists(Path.Combine(d.FullName, "calc", "wiki-costs.json"))) d = d.Parent;
            return d?.FullName ?? throw new InvalidOperationException("repo root not found");
        }
    }

    public static string CalcDir => Path.Combine(Root, "calc");
    public static string LangDir => Path.Combine(Root, "lang");

    public static Env Env(string lang = "en") => new(Loc.Load(LangDir, lang), () => Now);

    public static AccountData MainAccount()
    {
        var d = AccountData.Default(Now);
        d.AccountName = "Main";
        double c = 300000, a = 40;
        var evs = new List<BalanceEvent>();
        void Add(DateTime t, string cur, double delta, double bal, string kind, string note) =>
            evs.Add(new BalanceEvent { T = Dates.Iso(t), Cur = cur, Delta = delta, Bal = bal, Kind = kind, Note = note, Src = "auto" });
        for (var k = 12; k >= 0; k--)
        {
            var day = Now.Date.AddDays(-k).AddHours(15);
            if (k == 12) { Add(day, "credits", 0, c, "init", ""); Add(day, "acoins", 0, a, "init", ""); continue; }
            var gc = 14000.0 + (k * 7919 % 11000); c += gc;
            Add(day, "credits", gc, c, "gain", "");
            var ga = 15.0 + (k * 31 % 25); a += ga;
            Add(day.AddMinutes(20), "acoins", ga, a, "gain", "");
            if (k == 6) { a -= 120; Add(day.AddMinutes(40), "acoins", -120, a, "spend", "Timed offer"); }
            if (k is 0 or 2) { c -= 1200; Add(day.AddMinutes(50), "credits", -1200, c, "mission", "budget missioni"); }
        }
        d.Events = evs;
        d.Credits = c; d.InitCredits = true;
        d.Acoins = a; d.InitAcoins = true;
        d.Violations = new() { new Violation { T = Dates.Iso(Now.Date.AddDays(-6).AddHours(15).AddMinutes(40)), Currency = "acoins", Amount = 120, Reason = "Timed offer.", StreakLost = 3, PrevClean = Dates.Iso(Now.AddDays(-12)) } };
        d.CleanSince = Dates.Iso(Now.Date.AddDays(-6).AddHours(16));
        d.BestStreak = 6;
        d.FirstRun = false;
        d.CreatedAt = Dates.Iso(Now.AddDays(-12));
        d.LastReadAt = Dates.Iso(Now.AddMinutes(-2));
        d.Goals.Add(Goals.New("Epic weapon ★6 lvl 7", "credits", 683000));
        d.Goals.Add(Goals.New("Legendary mech ★6 lvl 7", "credits", 2450000));
        d.Goals.Add(Goals.New("A-coin reserve", "acoins", 2500));
        return d;
    }

    static string? _ref;
        public static string Result
    {
        get
        {
            if (_ref is null)
            {
                Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
                _ref = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "reference", "result.txt"), Encoding.GetEncoding(1252)).Trim();
            }
            return _ref;
        }
    }

    public static string[] RatingsRef => File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "reference", "ratings.txt"));

        public static string As1252(string s)
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var enc = Encoding.GetEncoding(1252, new EncoderReplacementFallback("?"), new DecoderReplacementFallback("?"));
        return enc.GetString(enc.GetBytes(s));
    }

        public static string Seg(string key)
    {
        var r = Result;
        var i = r.IndexOf(" " + key + "=[", StringComparison.Ordinal);
        Assert.True(i >= 0, $"{key} not in reference");
        i += key.Length + 3;
        var depth = 1; var j = i;
        for (; j < r.Length; j++)
        {
            if (r[j] == '[') depth++;
            else if (r[j] == ']' && --depth == 0) break;
        }
        return r[i..j];
    }

    public static string Val(string key)
    {
        var m = Regex.Match(Result, @"(?:^| )" + Regex.Escape(key) + @"=(\S+)");
        Assert.True(m.Success, $"{key} not in reference");
        return m.Groups[1].Value;
    }
}
