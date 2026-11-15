using MechVault.Core;

namespace MechVault.Tests;

public class ReferenceTests
{
    readonly Env _env = Fixture.Env();
    readonly AccountData _d = Fixture.MainAccount();
    Stats Stats => new(_env, _d);

    MechDb Mechs()
    {
        var m = new MechDb(_env);
        m.Load(Fixture.CalcDir, null, null);
        return m;
    }

    CostTable Costs()
    {
        var c = new CostTable();
        c.Load(Fixture.CalcDir, null);
        return c;
    }

    [Fact]
    public void AutoRates()
    {
        Assert.Equal(Fixture.Seg("rateC"), Fixture.As1252(Stats.FormatAutoRate("credits")));
        Assert.Equal(Fixture.Seg("rateA"), Fixture.As1252(Stats.FormatAutoRate("acoins")));
    }

    CrateAnalyzer Crate(CostTable? c = null, MechDb? m = null) => new(_env, Stats, c ?? Costs(), m ?? Mechs());

    static CrateInput Preset(string name, double spin, double direct, Env env) => new()
    {
        Name = name, SpinInCredits = false, DirectInAcoins = false, Spin = env.Fmt(spin), Direct = env.Fmt(direct), Pity = env.Fmt(7000),
    };

    static string Join(IEnumerable<string> lines) => string.Join(" / ", lines.Select(l => "• " + l));

    [Fact]
    public void CrateRushSequence()
    {
        var an = Crate();

        var i = Preset("Legendary scout", 1000, 937500, _env);
        i.P = "1"; i.Budget = "20000";
        var r1 = an.Analyze(i);
        Assert.Equal(Fixture.Seg("crate1"), Fixture.As1252(r1.Verdict));

        var i2 = Preset("Epic weapon 16", 350, 826000, _env);
        i2.P = ""; i2.Budget = "20000";
        var r2 = an.Analyze(i2);
        Assert.Equal(Fixture.Seg("crate2"), Fixture.As1252(r2.Verdict + " | " + Join(r2.Lines)));

        i2.SpinInCredits = true; i2.Spin = "50000"; i2.Pity = "500000"; i2.DirectInAcoins = true; i2.Direct = "3000"; i2.CountUpgrades = false;
        var r3 = an.Analyze(i2);
        Assert.Equal(Fixture.Seg("crate3"), Fixture.As1252(r3.Verdict + " | " + Join(r3.Lines.Take(2))));

        var mechs = Mechs();
        var i4 = Preset("Mimicker", 1000, 937500, _env);
        i4.P = "1"; i4.Budget = ""; i4.CountUpgrades = false;
        var lw = new CratePrize { Name = "Lacewing", P = "1", Price = "", Cur = "credits", Want = true };
        Assert.True(CrateHelpers.FillPrizePrice(lw, mechs, _env));
        Assert.Equal(Fixture.Val("autofill"), $"{lw.Price}/{(lw.Cur == "acoins" ? "True" : "False")}");
        i4.Prizes.Add(lw);
        i4.Prizes.Add(new CratePrize { Name = "Charge Rocket 12", P = "3", Price = "200000", Cur = "credits", Want = true });
        i4.Prizes.Add(new CratePrize { Name = "Particle Beam 12", P = "3", Price = "200000", Cur = "credits", Want = false });
        var r4 = Crate(m: mechs).Analyze(i4);
        Assert.Equal(Fixture.Seg("multi"), Fixture.As1252(r4.Verdict + " | " + Join(r4.Lines.Where(l => l.Contains("spin", StringComparison.OrdinalIgnoreCase)).Take(2))));

        i4.Prizes.Clear(); i4.Name = "Redox"; i4.Spin = "1"; i4.P = "100"; i4.Pity = "1";
        i4.DirectInAcoins = false; i4.Direct = "1"; i4.CountUpgrades = true;
        i4.PS = "6"; i4.PL = "7"; i4.DS = "1"; i4.DL = "1";
        var r5 = Crate(m: mechs).Analyze(i4);
        Assert.Equal(Fixture.Seg("absurd"), Fixture.As1252(r5.Verdict + " | " + Join(r5.Lines.Take(4))));
    }

    [Fact]
    public void Ratings()
    {
        var m = Mechs();
        var r = m.Ratings(6);
        Assert.Equal(Fixture.Val("mechs"), m.Mechs.Count.ToString());
        Assert.Equal(Fixture.Val("rated"), r.Count.ToString());
        Assert.Equal(Fixture.Val("ranked"), m.Mechs.Values.Count(x => x.Ranks is { Count: > 0 }).ToString());
        var mine = r.OrderByDescending(p => p.Value.Score).ThenBy(p => p.Key, StringComparer.Ordinal).Select(p => $"{p.Key} {p.Value.Tier}{p.Value.Score}").ToList();
        var refl = Fixture.RatingsRef.Where(l => l.Trim() != "").ToList();

        Assert.Equal(refl.OrderBy(x => x, StringComparer.Ordinal), mine.OrderBy(x => x, StringComparer.Ordinal));
        var refScores = refl.Select(l => int.Parse(System.Text.RegularExpressions.Regex.Match(l, @"(\d+)$").Value)).ToList();
        Assert.Equal(refScores, r.Values.Select(x => (int)x.Score).OrderByDescending(x => x).ToList());

        var r4 = m.Ratings(3);
        var l4 = r4["Lacewing"];
        Assert.Equal(Fixture.Val("lace4"), $"{l4.Tier}{l4.Score}/hp{l4.Hp}");
        Assert.Equal(Fixture.Val("rated4"), r4.Count.ToString());
        Assert.Equal(Fixture.Seg("mech"), Fixture.As1252(m.MechProfile("Lacewing")!.Summary));
    }

    [Fact]
    public void CustomMechWinsAndCounts()
    {
        var dir = Directory.CreateTempSubdirectory("mv").FullName;
        try
        {
            var f = Path.Combine(dir, "mech-miei.json");
            File.WriteAllText(f, "{\"Testmech\":{\"role\":\"Tank\",\"rarity\":null,\"class\":\"Heavy\",\"energy\":32,\"hp\":250000,\"speed\":21,\"ability\":\"\"}}");
            var m = new MechDb(_env);
            m.Load(Fixture.CalcDir, null, f);
            var custom = Fixture.Seg("custom");
            Assert.EndsWith(Fixture.As1252(m.MechProfile("Testmech")!.Summary), custom);
            Assert.Equal(Fixture.Val("n"), m.Mechs.Count.ToString());
            Assert.True(m.Mechs["Testmech"].Custom);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void Calculator()
    {
        var c = Costs();
        Assert.Equal(Fixture.Val("wiki"), c.Base.Count.ToString());

        var inp = CostTable.Input(_env, "weapon", "epic", 10, "4", "1", "6", "7");
        Assert.Null(inp.Err);
        var keys = c.Keys(_env, inp);
        var t = c.Totals(keys);
        Assert.Equal(Fixture.Val("path"), t.N.ToString());
        Assert.Equal(Fixture.Val("miss"), t.Miss.ToString());
        Assert.Equal(Fixture.Val("tot"), $"{t.C}/{t.B}/{t.A}");

        var d = Fixture.MainAccount();
        var n0 = d.Goals.Count;
        var msg = CalcHelpers.AddGoals(_env, d, "Epic beam", inp, t);
        Assert.Contains(Fixture.As1252($"goals+{d.Goals.Count - n0} msg={msg} override="), Fixture.Result);

        c.SetCell(keys[0], 'c', Num.ParseAmount("6000"));
        var g = c.Get(keys[0])!;
        Assert.Equal(Fixture.Val("override"), $"{g.C}/{g.B}");
        Assert.Equal(Fixture.Val("user"), c.User.Count.ToString());

        var leg = CostTable.Input(_env, "mech", "legendary", 10, "3", "7", "6", "7");
        var lt = c.Totals(c.Keys(_env, leg));
        Assert.Equal(Fixture.Val("leg3"), $"{lt.C}/{lt.B}/{lt.A}");

        var dir = Directory.CreateTempSubdirectory("mv").FullName;
        try
        {
            var f = Path.Combine(dir, "costi.json");
            var cnt = c.User.Count;
            c.Save(f, Fixture.Now);
            c.Load(Fixture.CalcDir, f);
            Assert.Equal(Fixture.Val("roundtrip"), $"{cnt}/{c.User.Count}");
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void Accounts()
    {
        var dir = Directory.CreateTempSubdirectory("mv").FullName;
        try
        {
            var p = new AppPaths(dir, Path.Combine(dir, "dati"));
            var s = new AccountStore(p, new Env(_env.L, () => DateTime.Now));
            s.Init(importOld: false);
            s.Data.AccountName = "Main";
            s.Save();
            Thread.Sleep(20);
            s.Create("Alt");
            var main = s.List().First(a => a.Name == "Main");
            Assert.True(s.Switch(main.Id));
            Assert.Equal(Fixture.Val("accounts"), string.Join(",", s.List().Select(a => a.Name)));
            Assert.Equal(Fixture.Val("active"), s.Data.AccountName);
        }
        finally { Directory.Delete(dir, true); }
    }
}
