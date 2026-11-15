using System.IO.Compression;
using System.Text.Json.Nodes;
using MechVault.Core;

namespace MechVault.Tests;

public class PlatformTests
{
        static Pixels Frame(int w = 1600, int h = 900)
    {
        var p = new Pixels(w, h, new byte[w * h * 4]);
        void Fill(int x0, int y0, int x1, int y1, byte r, byte g, byte b)
        {
            for (var y = y0; y < y1; y++)
                for (var x = x0; x < x1; x++)
                {
                    var i = y * p.Stride + x * 4;
                    p.Bgra[i] = b; p.Bgra[i + 1] = g; p.Bgra[i + 2] = r; p.Bgra[i + 3] = 255;
                }
        }
        Fill(0, 0, w, h, 20, 22, 30);
        Fill(1000, 20, 1020, 50, 40, 200, 255);
        Fill(1030, 26, 1100, 44, 245, 245, 245);
        Fill(1110, 18, 1126, 52, 40, 200, 255);
        return p;
    }

    [Fact]
    public void FindsTheCreditsPill()
    {
        var f = Frame();
        var r = BalanceReader.FindAmountRect(f, 172, 206);
        Assert.False(r.IsEmpty);
        Assert.InRange(r.X, 1020, 1030);
        Assert.InRange(r.X + r.W, 1100, 1110);
        Assert.Equal(18, r.Y);
        Assert.True(BalanceReader.FindAmountRect(f, 278, 322).IsEmpty);
        var prep = BalanceReader.PrepForOcr(f, r, 2);
        Assert.Equal(r.W * 2 + 48, prep.W);

        var mid = (24 + 16) * prep.Stride + (24 + (1060 - r.X) * 2) * 4;
        Assert.Equal(0, prep.Bgra[mid]);
        Assert.Equal(255, prep.Bgra[0]);
    }

    [Fact]
    public async Task ReadUsesOcrAndParses()
    {
        var calls = 0;
        var res = await BalanceReader.Read(Frame(), _ => { calls++; return Task.FromResult(calls == 1 ? "garbage" : "1,047,092"); });
        Assert.Equal(1047092, res["credits"]);
        Assert.False(res.ContainsKey("acoins"));
        Assert.Equal(2, calls);
    }

    [Fact]
    public void PngHasSignatureAndSize()
    {
        var png = Png.Encode(Pixels.White(7, 3));
        Assert.Equal(new byte[] { 137, 80, 78, 71 }, png[..4]);
        Assert.Equal(7, png[16 + 3]);
        Assert.Equal(3, png[20 + 3]);
    }

    [Fact]
    public void UpdaterPicksEntryAndComparesVersions()
    {
        var j = JsonNode.Parse("""{"version":"1.1.7","sha256":"aa","platforms":{"win-x64":{"version":"2.1.0","url":"https://x/y.zip","sha256":"ABC"},"linux-x64":{"version":"2.1.0","url":"http://insecure","sha256":"abc"}}}""");
        var e = Updater.Pick(j, "win-x64");
        Assert.NotNull(e);
        Assert.Equal("abc", e!.Sha256);
        Assert.Null(Updater.Pick(j, "linux-x64"));
        Assert.Null(Updater.Pick(j, "osx-arm64"));
        Assert.True(Updater.IsNewer("2.1.0", "2.0.0"));
        Assert.False(Updater.IsNewer("2.0.0", "2.0.0"));
        Assert.False(Updater.IsNewer("1.1.7", "2.0.0"));
    }

    [Fact]
    public void UpdaterInstallNeverTouchesData()
    {
        var root = Directory.CreateTempSubdirectory("mvupd").FullName;
        try
        {
            var install = Path.Combine(root, "install"); var pkg = Path.Combine(root, "pkg", "MechVault");
            Directory.CreateDirectory(Path.Combine(install, "dati", "accounts")); Directory.CreateDirectory(Path.Combine(install, "calc"));
            File.WriteAllText(Path.Combine(install, "dati", "accounts", "a.json"), "mine");
            File.WriteAllText(Path.Combine(install, "MechVault.exe"), "old");
            File.WriteAllText(Path.Combine(install, "calc", "x.json"), "old");
            Directory.CreateDirectory(Path.Combine(pkg, "calc")); Directory.CreateDirectory(Path.Combine(pkg, "dati"));
            File.WriteAllText(Path.Combine(pkg, "MechVault.exe"), "new");
            File.WriteAllText(Path.Combine(pkg, "calc", "x.json"), "new");
            File.WriteAllText(Path.Combine(pkg, "dati", "evil.json"), "should not be copied");

            var zip = Path.Combine(root, "MechVault-win-x64.zip");
            ZipFile.CreateFromDirectory(Path.Combine(root, "pkg"), zip);
            var x = Path.Combine(root, "tmp", "x");
            Updater.Extract(zip, x);
            var appRoot = Updater.FindAppRoot(x);
            Assert.NotNull(appRoot);
            var n = Updater.Install(new Updater.Staged("2.1.0", appRoot!, Path.Combine(root, "tmp")), install);
            Assert.Equal(2, n);
            Assert.Equal("new", File.ReadAllText(Path.Combine(install, "MechVault.exe")));
            Assert.Equal("new", File.ReadAllText(Path.Combine(install, "calc", "x.json")));
            Assert.Equal("mine", File.ReadAllText(Path.Combine(install, "dati", "accounts", "a.json")));
            Assert.False(File.Exists(Path.Combine(install, "dati", "evil.json")));
            Assert.True(File.Exists(Path.Combine(install, "MechVault.exe.old")));
            Updater.CleanupOld(install);
            Assert.False(File.Exists(Path.Combine(install, "MechVault.exe.old")));
            Assert.Equal("mine", File.ReadAllText(Path.Combine(install, "dati", "accounts", "a.json")));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void WikiTemplateAndRankTable()
    {
        const string t = """
        {{Mech Information
        |rarity = [[Epic]]
        |role = Tank [[File:Tank.png|20px]]
        |maxhp = 215,500 (max)
        |speed = 20 km/h
        |energy_capacity = 24 (Medium)
        |ability = Dome Shield
        |ability_cooldown = 10 seconds
        |price = 1,865 {{AcoinsIcon}}
        }}
        == Viability ==
        Aegis has the HP to survive well in endgame.
        == Stats ==
        {| class="wikitable"
        ! Rank !! 1 !! 2 !! 3 !! 4 !! 5 !! 6 !! Max
        |-
        | HP || 13,500 || 35,000 || 60,900 || 94,200 || 122,900 || 158,400 || 215,100
        |-
        | Energy || 6 || 8 || 12 || 16 || 18 || 20 || 24
        |}
        """;
        var m = Wiki.ParseMech(t.Replace("\r\n", "\n"), new List<string> { "Mech", "Ability:Exterior Shield" })!;
        Assert.Equal("Tank", m["role"]!.ToString());
        Assert.Equal("Epic", m["rarity"]!.ToString());
        Assert.Equal(215500, (double)m["hp"]!);
        Assert.Equal("Medium", m["class"]!.ToString());
        Assert.Equal(1865, (int)m["gearHub"]!["amount"]!);
        Assert.Equal("acoins", m["gearHub"]!["currency"]!.ToString());
        Assert.StartsWith("Aegis has the HP", m["viability"]!.ToString());
        Assert.Contains("exterior shield", m["abilityTags"]!.AsArray().Select(x => x!.ToString()));
        var rk = Wiki.RankTable(t.Replace("\r\n", "\n"))!;
        Assert.Equal(215100, (double)rk["HP"]![6]!);
        Assert.Equal(24, (double)rk["Energy"]![6]!);
    }
}
