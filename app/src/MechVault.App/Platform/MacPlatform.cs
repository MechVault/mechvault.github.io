using MechVault.Core;

namespace MechVault.App.Platform;

public sealed class MacPlatform : IGamePlatform
{
    readonly AppPaths _paths;
    readonly string _helper;
    bool? _granted;
    DateTime _checked;

    public MacPlatform(AppPaths paths)
    {
        _paths = paths;
        _helper = Path.Combine(AppContext.BaseDirectory, "mvhelper");
    }

    bool HelperOk => File.Exists(_helper);

    bool Granted
    {
        get
        {
            if (!HelperOk) return false;
            if (_granted is null || (DateTime.Now - _checked).TotalSeconds > 20)
            {
                _checked = DateTime.Now;
                try
                {
                    var r = GamePlatform.Run(_helper, new[] { "perm" }, 5000).GetAwaiter().GetResult();
                    _granted = r.Out.Trim() == "granted";
                }
                catch { _granted = false; }
            }
            return _granted == true;
        }
    }

    public bool CanRead => Granted;

    public string? Unavailable => !HelperOk
        ? "Lettura automatica non disponibile: manca il componente di lettura. Inserisci i saldi a mano."
        : !Granted ? "Serve il permesso Registrazione schermo per leggere i saldi." : null;

    public string? Help => "macOS chiede il permesso «Registrazione schermo» (Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio). MechVault lo usa solo per guardare la barra delle valute di Mech Arena, come uno screenshot: niente viene salvato o inviato. Dopo averlo attivato, riapri MechVault.";

    public bool CanRequestPermission => HelperOk && !Granted;

    public void RequestPermission()
    {
        if (!HelperOk) return;
        _ = GamePlatform.Run(_helper, new[] { "request" }, 60000);
        _granted = null;
    }

    public GameHandle? FindGame(string pattern) => GamePlatform.FindByProcessName(pattern, false);

    public async Task<Dictionary<string, double>> ReadBalances(GameHandle g)
    {
        if (!CanRead) return new();
        var dir = Path.Combine(Path.GetTempPath(), "mechvault-read");
        Directory.CreateDirectory(dir);
        var raw = Path.Combine(dir, "shot.bgra");
        try
        {
            var (code, _) = await GamePlatform.Run(_helper, new[] { "capture", g.Pid.ToString(), raw }, 10000);
            if (code != 0 || !File.Exists(raw)) return new();
            var shot = ReadRaw(raw);
            if (shot is null) return new();
            var n = 0;
            return await BalanceReader.Read(shot, async p =>
            {
                var png = Path.Combine(dir, $"ocr{n++}.png");
                await File.WriteAllBytesAsync(png, Png.Encode(p));
                var (c, text) = await GamePlatform.Run(_helper, new[] { "ocr", png }, 10000);
                return c == 0 ? text : "";
            });
        }
        catch (Exception ex) { _paths.Log($"Lettura: {ex.Message}"); return new(); }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

        static Pixels? ReadRaw(string f)
    {
        var b = File.ReadAllBytes(f);
        if (b.Length < 8) return null;
        int w = BitConverter.ToInt32(b, 0), h = BitConverter.ToInt32(b, 4);
        if (w < 200 || h < 150 || b.Length < 8 + w * h * 4) return null;
        var px = new byte[w * h * 4];
        Buffer.BlockCopy(b, 8, px, 0, px.Length);
        return new Pixels(w, h, px);
    }
}
