using System.Text.Json;
using MechVault.Core;

namespace MechVault.Tests;

sealed class FakeHost : IBalanceHost
{
    public ViolationAnswer Answer = new(ViolationKind.Confess, "Crate rush, my bad");
    public int Asked; public double LastExcess, LastCovered;
    public List<string> Notes = new();
    public Task<ViolationAnswer> AskViolation(string cur, double excess, double covered, string src, int streak)
    {
        Asked++; LastExcess = excess; LastCovered = covered;
        return Task.FromResult(Answer);
    }
    public void Notify(string title, string text) => Notes.Add(title);
    public void Changed() { }
    public void Log(string text) { }
}

public class LogicTests
{
    DateTime _now = Fixture.Now;
    Env Env() => new(Loc.Load(Fixture.LangDir, "en"), () => _now);

    [Theory]
    [InlineData("512000", 512000.0)]
    [InlineData("512k", 512000.0)]
    [InlineData("1,2M", 1200000.0)]
    [InlineData("827.000", 827000.0)]
    [InlineData(" 1 250 ", 1250.0)]
    [InlineData("-5", null)]
    [InlineData("abc", null)]
    [InlineData("", null)]
    public void ParseAmount(string s, double? v) => Assert.Equal(v, Num.ParseAmount(s));

    [Theory]
    [InlineData("47,092", 47092.0)]
    [InlineData("1,047,092", 1047092.0)]
    [InlineData("1.25M", 1250000.0)]
    [InlineData("131", 131.0)]
    [InlineData("12.5K", 12500.0)]
    [InlineData("4O,OOO", 40000.0)]
    [InlineData("1,2,3", null)]
    [InlineData("12345678", null)]
    public void ParseGameNumber(string s, double? v) => Assert.Equal(v, Num.ParseGameNumber(s));

    static AccountData Fresh(DateTime now, double cr = 100000, double ac = 500)
    {
        var d = AccountData.Default(now.AddDays(-10));
        d.Credits = cr; d.Acoins = ac; d.InitCredits = d.InitAcoins = true;
        d.AddEvent(now.AddDays(-10), "credits", 0, cr, "init", "", "auto");
        d.AddEvent(now.AddDays(-10), "acoins", 0, ac, "init", "", "auto");
        return d;
    }

    [Fact]
    public async Task ReadingsMustRepeat()
    {
        var env = Env(); var d = Fresh(_now); var h = new FakeHost();
        var b = new BalanceEngine(env, d, h);
        await b.ProcessRead("credits", 105000);
        Assert.Equal(100000, d.Credits);
        await b.ProcessRead("credits", 105000);
        Assert.Equal(105000, d.Credits);
        Assert.Equal("gain", d.Events[^1].Kind);

        await b.ProcessRead("credits", 104000); await b.ProcessRead("credits", 104000);
        Assert.Equal(105000, d.Credits);
        await b.ProcessRead("credits", 104000);
        Assert.Equal(104000, d.Credits);
        Assert.Equal("mission", d.Events[^1].Kind);
        Assert.Equal(0, h.Asked);
    }

    [Fact]
    public async Task HugeJumpNeedsSixAndCapsAreIgnored()
    {
        var env = Env(); var d = Fresh(_now); var b = new BalanceEngine(env, d, new FakeHost());
        for (var i = 0; i < 5; i++) await b.ProcessRead("credits", 900000);
        Assert.Equal(100000, d.Credits);
        await b.ProcessRead("credits", 900000);
        Assert.Equal(900000, d.Credits);
        for (var i = 0; i < 10; i++) await b.ProcessRead("acoins", 6000000);
        Assert.Equal(500, d.Acoins);
    }

    [Fact]
    public async Task MisreadGainIsUndone()
    {
        var env = Env(); var d = Fresh(_now); var h = new FakeHost(); var b = new BalanceEngine(env, d, h);
        await b.Commit("credits", 147000, "auto");
        _now = _now.AddMinutes(1);
        await b.Commit("credits", 100100, "auto");
        Assert.Equal(100100, d.Credits);
        Assert.DoesNotContain(d.Events, e => e.Kind == "gain" && e.Delta == 47000);
        Assert.Equal(0, h.Asked);
        Assert.Empty(d.Violations);
    }

    [Fact]
    public async Task SpendAboveBudgetIsAViolationAndResetsStreak()
    {
        var env = Env(); var d = Fresh(_now); var h = new FakeHost(); var b = new BalanceEngine(env, d, h);
        d.CleanSince = Dates.Iso(_now.AddDays(-5).AddHours(-1));
        Assert.Equal(5, b.Stats.Streak());
        await b.Commit("credits", 90000, "auto");
        Assert.Equal(1, h.Asked);
        Assert.Equal(8000, h.LastExcess);
        Assert.Equal(2000, h.LastCovered);
        Assert.Equal(90000, d.Credits);
        Assert.Single(d.Violations);
        Assert.Equal(5, d.Violations[0].StreakLost);
        Assert.Equal(5, d.BestStreak);
        Assert.Equal(0, b.Stats.Streak());
        Assert.Equal(new[] { "mission", "spend" }, d.Events.TakeLast(2).Select(e => e.Kind));

        Assert.True(b.UndoViolation(d.Violations[0].T));
        Assert.Empty(d.Violations);
        Assert.Equal(5, b.Stats.Streak());
        Assert.Equal("mission", d.Events[^1].Kind);
    }

    [Fact]
    public async Task TypoKeepsBalanceAndIgnoresSameReading()
    {
        var env = Env(); var d = Fresh(_now); var h = new FakeHost { Answer = new(ViolationKind.Typo, "") };
        var b = new BalanceEngine(env, d, h);
        for (var i = 0; i < 3; i++) await b.ProcessRead("credits", 50000);
        Assert.Equal(1, h.Asked);
        Assert.Equal(100000, d.Credits);
        for (var i = 0; i < 6; i++) await b.ProcessRead("credits", 50000);
        Assert.Equal(1, h.Asked);
    }

    [Fact]
    public async Task AuthorizedPurchaseCompletesGoal()
    {
        var env = Env(); var d = Fresh(_now, 900000); var h = new FakeHost(); var b = new BalanceEngine(env, d, h);
        var g = Goals.New("Compound Beam", "credits", 827000);
        d.Goals.Add(g);
        var st = b.Stats.GoalStats()[0];
        Assert.True(st.CanBuy);
        b.Authorize(g);
        Assert.True(b.Stats.GoalStats()[0].Authorized);
        await b.Commit("credits", 900000 - 826000, "auto");
        Assert.True(g.Done);
        Assert.Null(d.Purchase);
        Assert.Equal("purchase", d.Events[^1].Kind);
        Assert.Equal(0, h.Asked);
    }

    [Fact]
    public void GoalQueueAndRates()
    {
        var env = Env(); var d = Fixture.MainAccount(); var s = new Stats(new Env(env.L, () => Fixture.Now), d);
        var gs = s.GoalStats();
        Assert.Equal(3, gs.Count);
        Assert.True(gs[0].IsFirst);
        Assert.Equal("Epic weapon ★6 lvl 7", gs[1].After);
        Assert.True(gs[2].IsFirst);
        Assert.Equal(Math.Max(0, 683000 + 2450000 - d.Credits), gs[1].Remaining);
        Assert.True(Goals.Move(d, gs[1].Goal.Id, -1));
        Assert.Equal("Legendary mech ★6 lvl 7", d.Goals[0].Name);

        var empty = AccountData.Default(Fixture.Now);
        Assert.Equal(150, new Stats(env, empty).GetRate("acoins").V);
        empty.RateCredits = 30000;
        Assert.Equal(30000, new Stats(env, empty).GetRate("credits").V);
        empty.RateCredits = 3000000;
        Assert.Equal(0, new Stats(env, empty).GetRate("credits").V);
    }

    [Fact]
    public void MissionBudgetCountsToday()
    {
        var env = Env(); var d = Fresh(_now);
        d.AddEvent(_now.AddHours(-1), "credits", -500, 99500, "mission", "budget missioni", "auto");
        d.AddEvent(_now.AddDays(-1), "credits", -1500, 98000, "mission", "budget missioni", "auto");
        var m = new Stats(env, d).Mission("credits");
        Assert.Equal(new MissionInfo(2000, 500, 1500), m);
    }

    [Fact]
    public void CrateCurveAndSpins()
    {
        Assert.Equal(69, CrateAnalyzer.SpinsFor(0.01, 0.5, 0));
        Assert.Equal(20, CrateAnalyzer.SpinsFor(0.01, 0.9, 20));
        Assert.Equal(1, CrateAnalyzer.SpinsFor(1, 0.9, 0));
        var (best, rows) = CrateAnalyzer.Curve(0.1, 10, 0, new List<(string, double, double)> { ("x", 0.05, 4) }, 0.5, 50);
        Assert.Equal(50, rows.Count);
        Assert.True(best.N > 0 && best.Net == rows.Max(r => r.Net));
    }

    [Fact]
    public void AccountFileFromPowerShellLoadsAndKeepsUnknownFields()
    {
        const string ps = """
        {
            "credits":  117661,
            "acoins":  185,
            "initCredits":  true,
            "initAcoins":  true,
            "goals":  { "id": "9296f732", "name": "Compound Beam", "currency": "credits", "cost": 827000, "done": true, "doneAt": "2026-11-11T16:46:52.4440024+01:00" },
            "violations":  null,
            "cleanSince":  "2026-11-12T15:50:51.7567373+01:00",
            "bestStreak":  2,
            "processPattern":  "mech.?arena",
            "version":  3,
            "events":  [ { "t": "2026-11-09T16:58:45.5734363+01:00", "cur": "credits", "delta": 0, "bal": 25649, "kind": "init", "note": "", "src": "auto" } ],
            "purchase":  null,
            "accountName":  "Ex cfp",
            "createdAt":  "2026-11-10T21:50:11.5404799+01:00",
            "missionCredits":  2000,
            "missionAcoins":  0,
            "futureField":  { "a": 1 },
            "tolCredits": 5
        }
        """;
        var dir = Directory.CreateTempSubdirectory("mv").FullName;
        try
        {
            var p = new AppPaths(dir, dir);
            var f = Path.Combine(dir, "x.json");
            File.WriteAllText(f, ps, new System.Text.UTF8Encoding(true));
            var store = new AccountStore(p, Env());
            var d = store.Load(f);
            Assert.Equal("Ex cfp", d.AccountName);
            Assert.Single(d.Goals);
            Assert.Empty(d.Violations);
            Assert.True(d.AutoRead);
            var back = JsonSerializer.Serialize(d, Json.Options);
            Assert.Contains("\"futureField\"", back);
            Assert.DoesNotContain("tolCredits", back);
            Assert.Contains("\"credits\": 117661", back);
            Assert.Contains("\"purchase\": null", back);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void ItalianIsTheKey()
    {
        var it = Loc.Italian();
        Assert.Equal("crediti", it.T("crediti"));
        var en = Loc.Load(Fixture.LangDir, "en");
        Assert.Equal("credits", en.T("crediti"));
        Assert.Equal("missing {0}", en.T("missing {0}"));
        Assert.Contains(Loc.Languages(Fixture.LangDir), l => l.Code == "it");
        Assert.Equal("en", Loc.Languages(Fixture.LangDir)[0].Code);
    }
}
