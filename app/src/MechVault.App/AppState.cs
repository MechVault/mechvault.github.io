using MechVault.App.Platform;
using MechVault.Core;

namespace MechVault.App;

public sealed class AppState
{
    public static AppState I { get; private set; } = null!;

    public const string Version = "2.0.1";

    public AppPaths Paths { get; }
    public Env Env { get; }
    public Loc L => Env.L;
    public UiPrefs Prefs { get; }
    public AccountStore Store { get; }
    public BalanceEngine Engine { get; }
    public CostTable Costs { get; } = new();
    public MechDb Mechs { get; }
    public IGamePlatform Platform { get; }
    public bool LiquidGlass { get; }
    public bool SelfTest { get; }

    public AccountData D => Store.Data;
    public Stats Stats => Engine.Stats;

    public bool GameRunning { get; set; }
    public bool PendingCheck { get; set; }
    public string? UpdateReady { get; set; }

        public event Action? Changed;

    AppState(IBalanceHost host)
    {
        Paths = AppPaths.Default();
        SelfTest = Environment.GetEnvironmentVariable("MECHVAULT_SELFTEST") is { Length: > 0 };
        var lang = "en";
        var envLang = Environment.GetEnvironmentVariable("MECHVAULT_LANG");
        if (!string.IsNullOrEmpty(envLang)) lang = envLang;
        else if (File.Exists(Paths.LangFile)) { try { var l = File.ReadAllText(Paths.LangFile).Trim(); if (l != "") lang = l; } catch { } }
        Env = new Env(Loc.Load(Paths.LangDir, lang));
        Prefs = new UiPrefs(Paths.Ui);
        LiquidGlass = Environment.GetEnvironmentVariable("MECHVAULT_GLASS") == "off" ? false : Prefs.GetBool("liquidGlass", true);
        Store = new AccountStore(Paths, Env);
        Store.Init(importOld: !SelfTest);
        Engine = new BalanceEngine(Env, Store.Data, host);
        Mechs = new MechDb(Env);
        Costs.Load(Paths.CalcDir, Paths.Costs);
        Mechs.Load(Paths.CalcDir, Paths.WikiCache, Paths.MechCustom);
        Platform = GamePlatform.Create(Paths);
    }

    public static AppState Create(IBalanceHost host) => I = new AppState(host);

    public string T(string k, params object?[] a) => Env.T(k, a);

    public void Save() => Store.Save();

    public void RaiseChanged()
    {
        Save();
        Changed?.Invoke();
    }

    public void AccountSwitched()
    {
        Engine.SetAccount(Store.Data);
        Changed?.Invoke();
    }

    public void Log(string m) => Paths.Log(m);

    public string AccountName => string.IsNullOrEmpty(D.AccountName) ? "?" : D.AccountName;

    public static readonly string[] Lessons =
    {
        "Una Crate Rush senza garantito non ha un tetto di spesa. Un obiettivo a crediti sì.",
        "Le casse sono progettate per farti perdere. Un obiettivo fisso no.",
        "Ogni giorno senza spendere avvicina il tuo prossimo obiettivo.",
        "Un'arma sicura vale più di dieci tentativi a vuoto.",
        "La voglia di aprire una cassa passa in 5 minuti. Il saldo vuoto resta.",
        "Le offerte a tempo esistono per farti decidere senza pensare. Pensa.",
    };
}
